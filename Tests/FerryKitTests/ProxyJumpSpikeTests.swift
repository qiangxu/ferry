import Citadel
import Foundation
import NIO
import NIOConcurrencyHelpers
import NIOSSH
import Testing

/// Records the host key each hop presents; accepts everything unless told to reject.
private final class RecordingHostKeyDelegate: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let seen = NIOLockedValueBox<NIOSSHPublicKey?>(nil)
    private let reject: Bool
    struct Rejected: Error {}
    init(reject: Bool = false) { self.reject = reject }
    var seenKey: NIOSSHPublicKey? { seen.withLockedValue { $0 } }
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        seen.withLockedValue { $0 = hostKey }
        if reject { validationCompletePromise.fail(Rejected()) } else { validationCompletePromise.succeed(()) }
    }
}

@Suite struct ProxyJumpSpikeTests {
    private func makeDir(file: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ferry-jump-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url.appendingPathComponent(file))
        return url
    }

    private func settings(port: Int, validator: RecordingHostKeyDelegate) -> SSHClientSettings {
        SSHClientSettings(
            host: "127.0.0.1",
            port: port,
            authenticationMethod: { .passwordBased(username: "u", password: "p") },
            hostKeyValidator: .custom(validator)
        )
    }

    @Test func test_connectTargetThroughJump_overLoopback() async throws {
        let jumpRoot = try makeDir(file: "jump-only.txt")
        let targetRoot = try makeDir(file: "target-only.txt")
        let jump = LoopbackSSHServer(username: "u", password: "p", authorizedEd25519PublicKey: nil,
                                     sftpDelegate: TempDirSFTPDelegate(root: jumpRoot), allowDirectTCPIP: true)
        let target = LoopbackSSHServer(username: "u", password: "p", authorizedEd25519PublicKey: nil,
                                       sftpDelegate: TempDirSFTPDelegate(root: targetRoot))
        let jumpPort = try await jump.start()
        let targetPort = try await target.start()

        let jumpValidator = RecordingHostKeyDelegate()
        let targetValidator = RecordingHostKeyDelegate()

        let jumpClient = try await SSHClient.connect(to: settings(port: jumpPort, validator: jumpValidator))
        let targetClient = try await jumpClient.jump(to: settings(port: targetPort, validator: targetValidator))
        let sftp = try await targetClient.openSFTP()
        let names = try await sftp.listDirectory(atPath: "/").flatMap { (n: SFTPMessage.Name) in n.components.map { $0.filename } }

        #expect(names.contains("target-only.txt"))
        #expect(!names.contains("jump-only.txt"))
        // Each hop validated its own host key.
        #expect(jumpValidator.seenKey == jump.hostKey)
        #expect(targetValidator.seenKey == target.hostKey)

        try? await sftp.close()
        try? await targetClient.close()
        try? await jumpClient.close()
        await jump.stop()
        await target.stop()
    }

    @Test func test_jumpFailures_vsTargetFailures_areDistinguishable() async throws {
        let root = try makeDir(file: "a.txt")
        let jump = LoopbackSSHServer(username: "u", password: "p", authorizedEd25519PublicKey: nil,
                                     sftpDelegate: TempDirSFTPDelegate(root: root), allowDirectTCPIP: true)
        let target = LoopbackSSHServer(username: "u", password: "p", authorizedEd25519PublicKey: nil,
                                       sftpDelegate: TempDirSFTPDelegate(root: root))
        let jumpPort = try await jump.start()
        let targetPort = try await target.start()

        // (a) jump host key rejected: throws at SSHClient.connect, target never attempted.
        let rejectJump = RecordingHostKeyDelegate(reject: true)
        var jumpError: Error?
        do { _ = try await SSHClient.connect(to: settings(port: jumpPort, validator: rejectJump)) } catch { jumpError = error }
        print("SPIKE jump-hostkey-rejected:", String(describing: jumpError))
        #expect(jumpError != nil)

        // (b) target host key rejected: connect(jump) OK, jump(to:) throws.
        let jumpClient = try await SSHClient.connect(to: settings(port: jumpPort, validator: RecordingHostKeyDelegate()))
        var targetError: Error?
        do { _ = try await jumpClient.jump(to: settings(port: targetPort, validator: RecordingHostKeyDelegate(reject: true))) } catch { targetError = error }
        print("SPIKE target-hostkey-rejected:", String(describing: targetError))
        #expect(targetError is RecordingHostKeyDelegate.Rejected)

        // (c) target port closed (nothing listening): jump(to:) throws.
        var refusedError: Error?
        do { _ = try await jumpClient.jump(to: settings(port: 1, validator: RecordingHostKeyDelegate())) } catch { refusedError = error }
        print("SPIKE target-unreachable:", String(describing: refusedError))
        #expect(refusedError != nil)

        // (d) forwarding disabled on jump host.
        let noFwd = LoopbackSSHServer(username: "u", password: "p", authorizedEd25519PublicKey: nil)
        let noFwdPort = try await noFwd.start()
        let c2 = try await SSHClient.connect(to: settings(port: noFwdPort, validator: RecordingHostKeyDelegate()))
        var noFwdError: Error?
        do { _ = try await c2.jump(to: settings(port: targetPort, validator: RecordingHostKeyDelegate())) } catch { noFwdError = error }
        print("SPIKE forwarding-disabled:", String(describing: noFwdError))
        #expect(noFwdError != nil)

        // (e) wrong target password
        var authError: Error?
        var bad = settings(port: targetPort, validator: RecordingHostKeyDelegate())
        bad.authenticationMethod = { .passwordBased(username: "u", password: "wrong") }
        do { _ = try await jumpClient.jump(to: bad) } catch { authError = error }
        print("SPIKE target-auth-failed:", String(describing: authError))
        #expect(authError != nil)

        try? await c2.close()
        try? await jumpClient.close()
        await noFwd.stop(); await jump.stop(); await target.stop()
    }
}
