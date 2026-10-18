import Citadel
import Crypto
import Foundation
import NIO
import NIOConcurrencyHelpers
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
        TOFUHostKeyValidator(store: KnownHostsStore(fileURL: tempKnownHostsURL()), confirm: { _, _, _ in true })
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

    /// Starts a loopback server that also acts as a jump host (direct-tcpip forwarding on).
    private func startJumpServer(root: URL) async throws -> (LoopbackSSHServer, Int) {
        let server = LoopbackSSHServer(
            username: "u",
            password: "p",
            authorizedEd25519PublicKey: nil,
            sftpDelegate: TempDirSFTPDelegate(root: root),
            allowDirectTCPIP: true
        )
        let port = try await server.start()
        return (server, port)
    }

    /// Records (host, port) for each `confirm` prompt, in order.
    private final class ConfirmRecorder: @unchecked Sendable {
        private let box = NIOLockedValueBox<[(host: String, port: Int)]>([])
        var calls: [(host: String, port: Int)] { box.withLockedValue { $0 } }
        func record(_ host: String, _ port: Int) {
            box.withLockedValue { $0.append((host, port)) }
        }
    }

    // MARK: - Tests

    @Test func test_connect_unknownHost_whenValidatorAccepts_succeeds() async throws {
        let root = try makeTempDir()
        let (server, port) = try await startServer(root: root)
        let knownHosts = tempKnownHostsURL()
        let validator = TOFUHostKeyValidator(
            store: KnownHostsStore(fileURL: knownHosts),
            confirm: { _, _, _ in true }
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
        let validator = TOFUHostKeyValidator(store: store, confirm: { _, _, _ in true })

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

    // MARK: - Two-hop (ProxyJump) connect

    @Test func test_connectThroughJump_listsTargetDirectory() async throws {
        let jumpRoot = try makeTempDir()
        try Data("j".utf8).write(to: jumpRoot.appendingPathComponent("jump-only.txt"))
        let targetRoot = try makeTempDir()
        try Data("t".utf8).write(to: targetRoot.appendingPathComponent("target-only.txt"))

        let (jump, jumpPort) = try await startJumpServer(root: jumpRoot)
        let (target, targetPort) = try await startServer(root: targetRoot)

        var names: [String] = []
        do {
            let session = try await SFTPSession.connect(
                host: "127.0.0.1", port: targetPort, username: "u",
                auth: .password("p"), validator: acceptingValidator(),
                jumpHost: "127.0.0.1", jumpPort: jumpPort
            )
            names = try await session.list("/").map(\.name)
            await session.disconnect()
        } catch {
            await jump.stop(); await target.stop()
            throw error
        }
        await jump.stop(); await target.stop()

        #expect(names.contains("target-only.txt"), "names: \(names)")
        #expect(!names.contains("jump-only.txt"), "names: \(names)")
    }

    @Test func test_jumpHostChangedKey_throws() async throws {
        // Security: a changed key on the JUMP hop must abort before the target is
        // ever contacted, and must never be offered to `confirm`.
        let (jump, jumpPort) = try await startJumpServer(root: try makeTempDir())
        let (target, targetPort) = try await startServer(root: try makeTempDir())

        // Pre-record a DIFFERENT key for the jump host:port -> reads as "changed".
        let store = KnownHostsStore(fileURL: tempKnownHostsURL())
        let bogus = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey()).publicKey
        try store.trust(host: "127.0.0.1", port: jumpPort, keyType: "ssh-ed25519", blob: sshWireBlob(bogus))
        let recorder = ConfirmRecorder()
        let validator = TOFUHostKeyValidator(store: store, confirm: { host, port, _ in
            recorder.record(host, port); return true
        })

        var thrown: Error?
        do {
            let session = try await SFTPSession.connect(
                host: "127.0.0.1", port: targetPort, username: "u",
                auth: .password("p"), validator: validator,
                jumpHost: "127.0.0.1", jumpPort: jumpPort
            )
            await session.disconnect()
        } catch {
            thrown = error
        }
        await jump.stop(); await target.stop()

        if let error = thrown as? FerryKit.SFTPError, case .hostKeyChanged = error {
            // expected
        } else {
            Issue.record("expected SFTPError.hostKeyChanged, got \(String(describing: thrown))")
        }
        // A changed key is never offered for trust; the target is never reached.
        #expect(recorder.calls.isEmpty, "confirm must not be called: \(recorder.calls)")
    }

    @Test func test_targetHostChangedKey_throws() async throws {
        // Security: a changed key on the TARGET hop (reached through a trusted
        // jump) must be rejected as hostKeyChanged and never offered to `confirm`.
        let (jump, jumpPort) = try await startJumpServer(root: try makeTempDir())
        let (target, targetPort) = try await startServer(root: try makeTempDir())

        let store = KnownHostsStore(fileURL: tempKnownHostsURL())
        let bogus = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey()).publicKey
        try store.trust(host: "127.0.0.1", port: targetPort, keyType: "ssh-ed25519", blob: sshWireBlob(bogus))
        let recorder = ConfirmRecorder()
        let validator = TOFUHostKeyValidator(store: store, confirm: { host, port, _ in
            recorder.record(host, port); return true
        })

        var thrown: Error?
        do {
            let session = try await SFTPSession.connect(
                host: "127.0.0.1", port: targetPort, username: "u",
                auth: .password("p"), validator: validator,
                jumpHost: "127.0.0.1", jumpPort: jumpPort
            )
            await session.disconnect()
        } catch {
            thrown = error
        }
        await jump.stop(); await target.stop()

        if let error = thrown as? FerryKit.SFTPError, case .hostKeyChanged = error {
            // expected
        } else {
            Issue.record("expected SFTPError.hostKeyChanged, got \(String(describing: thrown))")
        }
        // The unknown jump key may be prompted; the changed target key never is.
        #expect(!recorder.calls.contains { $0.port == targetPort },
                "target must not be offered for trust: \(recorder.calls)")
    }

    @Test func test_firstTimeJump_promptsForJumpThenTarget() async throws {
        // Security: first-time TOFU prompts once for the jump host, then once for
        // the target, each with the correct host:port.
        let (jump, jumpPort) = try await startJumpServer(root: try makeTempDir())
        let (target, targetPort) = try await startServer(root: try makeTempDir())

        let recorder = ConfirmRecorder()
        let validator = TOFUHostKeyValidator(
            store: KnownHostsStore(fileURL: tempKnownHostsURL()),
            confirm: { host, port, _ in recorder.record(host, port); return true }
        )

        do {
            let session = try await SFTPSession.connect(
                host: "127.0.0.1", port: targetPort, username: "u",
                auth: .password("p"), validator: validator,
                jumpHost: "127.0.0.1", jumpPort: jumpPort
            )
            await session.disconnect()
        } catch {
            await jump.stop(); await target.stop()
            throw error
        }
        await jump.stop(); await target.stop()

        #expect(recorder.calls.count == 2, "calls: \(recorder.calls)")
        #expect(recorder.calls.first?.port == jumpPort, "first prompt should be the jump host")
        #expect(recorder.calls.last?.port == targetPort, "second prompt should be the target host")
    }

    @Test func test_jumpUnreachable_vs_targetUnreachable_distinctErrors() async throws {
        // (a) Jump host unreachable: the direct TCP connect to the jump is refused.
        let (target, targetPort) = try await startServer(root: try makeTempDir())
        var jumpUnreachableError: Error?
        do {
            _ = try await SFTPSession.connect(
                host: "127.0.0.1", port: targetPort, username: "u",
                auth: .password("p"), validator: acceptingValidator(),
                jumpHost: "127.0.0.1", jumpPort: 1
            )
        } catch {
            jumpUnreachableError = error
        }
        await target.stop()

        // (b) Target unreachable: jump host is reachable, but the forwarded hop to
        // the target port (nothing listening) is rejected.
        let (jump, jumpPort) = try await startJumpServer(root: try makeTempDir())
        var targetUnreachableError: Error?
        do {
            _ = try await SFTPSession.connect(
                host: "127.0.0.1", port: 1, username: "u",
                auth: .password("p"), validator: acceptingValidator(),
                jumpHost: "127.0.0.1", jumpPort: jumpPort
            )
        } catch {
            targetUnreachableError = error
        }
        await jump.stop()

        #expect((jumpUnreachableError as? FerryKit.SFTPError) == .jumpConnectionFailed,
                "got \(String(describing: jumpUnreachableError))")
        #expect((targetUnreachableError as? FerryKit.SFTPError) == .connectionFailed,
                "got \(String(describing: targetUnreachableError))")
        #expect((jumpUnreachableError as? FerryKit.SFTPError)
                != (targetUnreachableError as? FerryKit.SFTPError))
    }

    @Test func test_jumpAuthFailure_throwsJumpAuthenticationFailed() async throws {
        // Wrong credentials fail at the jump hop; the target is never contacted.
        let (jump, jumpPort) = try await startJumpServer(root: try makeTempDir())
        let (target, targetPort) = try await startServer(root: try makeTempDir())

        var thrown: Error?
        do {
            _ = try await SFTPSession.connect(
                host: "127.0.0.1", port: targetPort, username: "u",
                auth: .password("WRONG"), validator: acceptingValidator(),
                jumpHost: "127.0.0.1", jumpPort: jumpPort
            )
        } catch {
            thrown = error
        }
        await jump.stop(); await target.stop()

        #expect((thrown as? FerryKit.SFTPError) == .jumpAuthenticationFailed,
                "got \(String(describing: thrown))")
    }
}
