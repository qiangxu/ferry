import Citadel
import Crypto
import Foundation
import NIO
import NIOSSH
import Testing
@testable import FerryKit

@Suite struct SFTPSessionTests {
    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ferry-sftp-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func tempKnownHostsURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ferry-known-hosts-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("known_hosts")
    }

    private func acceptingValidator() -> TOFUHostKeyValidator {
        TOFUHostKeyValidator(store: KnownHostsStore(fileURL: tempKnownHostsURL()), confirm: { _ in true })
    }

    private func sshWireBlob(_ key: NIOSSHPublicKey) -> Data {
        var buffer = ByteBufferAllocator().buffer(capacity: 256)
        key.write(to: &buffer)
        return Data(buffer.readableBytesView)
    }

    /// Starts a loopback server serving the given directory over SFTP.
    private func startServer(root: URL) async throws -> (LoopbackSSHServer, Int) {
        let server = LoopbackSSHServer(
            username: "u",
            password: "p",
            authorizedEd25519PublicKey: nil,
            sftpDelegate: TempDirSFTPDelegate(root: root)
        )
        let port = try await server.start()
        return (server, port)
    }

    // MARK: - Tests

    @Test func test_connect_unknownHost_whenValidatorAccepts_succeeds() async throws {
        let root = try makeTempDir()
        let (server, port) = try await startServer(root: root)
        let knownHosts = tempKnownHostsURL()
        let validator = TOFUHostKeyValidator(
            store: KnownHostsStore(fileURL: knownHosts),
            confirm: { _ in true }
        )

        do {
            let session = try await SFTPSession.connect(
                host: "127.0.0.1", port: port, username: "u",
                auth: .password("p"), validator: validator
            )
            await session.disconnect()
        } catch {
            await server.stop()
            throw error
        }
        await server.stop()

        // Accepting an unknown host must record it for next time (TOFU).
        #expect(FileManager.default.fileExists(atPath: knownHosts.path))
    }

    @Test func test_connect_changedHostKey_throwsHostKeyChanged() async throws {
        let root = try makeTempDir()
        let (server, port) = try await startServer(root: root)

        // Pre-record a DIFFERENT key for this host:port, so the server's real
        // key reads as "changed".
        let store = KnownHostsStore(fileURL: tempKnownHostsURL())
        let otherKey = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey()).publicKey
        try store.trust(host: "127.0.0.1", port: port, keyType: "ssh-ed25519", blob: sshWireBlob(otherKey))
        let validator = TOFUHostKeyValidator(store: store, confirm: { _ in true })

        var thrown: Error?
        do {
            let session = try await SFTPSession.connect(
                host: "127.0.0.1", port: port, username: "u",
                auth: .password("p"), validator: validator
            )
            await session.disconnect()
        } catch {
            thrown = error
        }
        await server.stop()

        if let error = thrown as? FerryKit.SFTPError, case .hostKeyChanged = error {
            // expected
        } else {
            Issue.record("expected SFTPError.hostKeyChanged, got \(String(describing: thrown))")
        }
    }

    @Test func test_connect_wrongPassword_throwsAuthenticationFailed() async throws {
        let root = try makeTempDir()
        let (server, port) = try await startServer(root: root)

        var thrown: Error?
        do {
            let session = try await SFTPSession.connect(
                host: "127.0.0.1", port: port, username: "u",
                auth: .password("WRONG"), validator: acceptingValidator()
            )
            await session.disconnect()
        } catch {
            thrown = error
        }
        await server.stop()

        #expect((thrown as? FerryKit.SFTPError) == .authenticationFailed,
                "got \(String(describing: thrown))")
    }

    @Test func test_list_returnsEntries_withUnicodeAndSpaceNames() async throws {
        let root = try makeTempDir()
        try Data("hi".utf8).write(to: root.appendingPathComponent("a b.txt"))
        try Data("log".utf8).write(to: root.appendingPathComponent("日志.log"))
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("folder"), withIntermediateDirectories: true
        )
        let (server, port) = try await startServer(root: root)

        var entries: [RemoteEntry] = []
        do {
            let session = try await SFTPSession.connect(
                host: "127.0.0.1", port: port, username: "u",
                auth: .password("p"), validator: acceptingValidator()
            )
            entries = try await session.list("/")
            await session.disconnect()
        } catch {
            await server.stop()
            throw error
        }
        await server.stop()

        let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0) })
        #expect(byName["a b.txt"] != nil, "entries: \(entries.map(\.name))")
        #expect(byName["日志.log"] != nil, "entries: \(entries.map(\.name))")
        #expect(byName["a b.txt"]?.isDirectory == false)
        #expect(byName["a b.txt"]?.size == 2)
        #expect(byName["a b.txt"]?.path == "/a b.txt")
        #expect(byName["folder"]?.isDirectory == true)
    }

    @Test func test_download_writesByteIdenticalFile() async throws {
        let root = try makeTempDir()
        let payload = Data((0 ..< 5000).map { _ in UInt8.random(in: 0 ... 255) })
        try payload.write(to: root.appendingPathComponent("blob.bin"))
        let (server, port) = try await startServer(root: root)

        let localURL = try makeTempDir().appendingPathComponent("downloaded.bin")
        do {
            let session = try await SFTPSession.connect(
                host: "127.0.0.1", port: port, username: "u",
                auth: .password("p"), validator: acceptingValidator()
            )
            try await session.download("/blob.bin", to: localURL)
            await session.disconnect()
        } catch {
            await server.stop()
            throw error
        }
        await server.stop()

        let downloaded = try Data(contentsOf: localURL)
        #expect(downloaded == payload)
    }

    @Test func test_upload_thenList_showsUploadedFile() async throws {
        let root = try makeTempDir()
        let (server, port) = try await startServer(root: root)

        let payload = Data((0 ..< 3333).map { _ in UInt8.random(in: 0 ... 255) })
        let localURL = try makeTempDir().appendingPathComponent("to-upload.bin")
        try payload.write(to: localURL)

        var entries: [RemoteEntry] = []
        var roundTripped = Data()
        do {
            let session = try await SFTPSession.connect(
                host: "127.0.0.1", port: port, username: "u",
                auth: .password("p"), validator: acceptingValidator()
            )
            try await session.upload(localURL, to: "/uploaded.bin")
            entries = try await session.list("/")

            let backURL = try makeTempDir().appendingPathComponent("back.bin")
            try await session.download("/uploaded.bin", to: backURL)
            roundTripped = try Data(contentsOf: backURL)
            await session.disconnect()
        } catch {
            await server.stop()
            throw error
        }
        await server.stop()

        #expect(entries.contains { $0.name == "uploaded.bin" }, "entries: \(entries.map(\.name))")
        #expect(roundTripped == payload)
    }
}
