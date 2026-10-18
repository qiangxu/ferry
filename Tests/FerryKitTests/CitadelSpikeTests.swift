import Crypto
import NIO
import NIOConcurrencyHelpers
import NIOSSH
import Citadel
import Testing

@Suite struct CitadelSpikeTests {
    @Test func customValidatorReceivesServerHostKey() async throws {
        let server = LoopbackSSHServer(username: "u", password: "p", authorizedEd25519PublicKey: nil)
        let port = try await server.start()
        let captured = NIOLockedValueBox<NIOSSHPublicKey?>(nil)
        do {
            let client = try await connectCapturingHostKey(
                host: "127.0.0.1", port: port,
                authenticationMethod: .passwordBased(username: "u", password: "p")
            ) { key in captured.withLockedValue { $0 = key } }
            try await client.close()
        } catch {
            await server.stop()
            throw error
        }
        await server.stop()

        let got = captured.withLockedValue { $0 }
        #expect(got != nil, "validator was never handed a host key")
        #expect(sha256Fingerprint(got) == sha256Fingerprint(server.hostKey))
        #expect(sha256Fingerprint(got)?.hasPrefix("SHA256:") ?? false)
    }

    @Test func publicKeyAuthAgainstLoopbackServer() async throws {
        let clientKey = Curve25519.Signing.PrivateKey()
        let authorized = NIOSSHPrivateKey(ed25519Key: clientKey).publicKey
        let server = LoopbackSSHServer(username: "u", password: "p", authorizedEd25519PublicKey: authorized)
        let port = try await server.start()
        do {
            let client = try await connectCapturingHostKey(
                host: "127.0.0.1", port: port,
                authenticationMethod: .ed25519(username: "u", privateKey: clientKey)
            ) { _ in }
            try await client.close()
        } catch {
            await server.stop()
            throw error
        }
        await server.stop()
    }

    @Test func loopbackServerServesSFTPSubsystem() async throws {
        let server = LoopbackSSHServer(username: "u", password: "p", authorizedEd25519PublicKey: nil, sftpDelegate: StubSFTPDelegate())
        let port = try await server.start()
        var names: [String] = []
        do {
            let client = try await connectCapturingHostKey(
                host: "127.0.0.1", port: port,
                authenticationMethod: .passwordBased(username: "u", password: "p")
            ) { _ in }
            let sftp = try await client.openSFTP()
            let listing = try await sftp.listDirectory(atPath: "/")
            names = listing.flatMap { $0.components.map(\.filename) }
            try await sftp.close()
            try await client.close()
        } catch {
            await server.stop()
            throw error
        }
        await server.stop()
        #expect(names.contains("hello.txt"), "got \(names)")
    }
}
