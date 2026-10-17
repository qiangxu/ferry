import Crypto
import Foundation
import NIO
import NIOSSH
import Citadel

/// Throwaway, test-local fingerprint helper (the production one lands in Task 4).
/// Returns OpenSSH-style "SHA256:<base64 without padding>" over the SSH wire blob of the key.
func sha256Fingerprint(_ key: NIOSSHPublicKey?) -> String? {
    guard let key else { return nil }
    var buffer = ByteBufferAllocator().buffer(capacity: 256)
    key.write(to: &buffer)
    let digest = SHA256.hash(data: Data(buffer.readableBytesView))
    let b64 = Data(digest).base64EncodedString().replacingOccurrences(of: "=", with: "")
    return "SHA256:" + b64
}

/// Custom validator that hands the raw server host key to a closure, then accepts it.
final class CapturingHostKeyValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let onKey: @Sendable (NIOSSHPublicKey) -> Void
    init(onKey: @escaping @Sendable (NIOSSHPublicKey) -> Void) { self.onKey = onKey }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        onKey(hostKey)
        validationCompletePromise.succeed(())
    }
}

/// Connects with a capturing custom `hostKeyValidator`, reports the host key, and returns the live client.
func connectCapturingHostKey(
    host: String,
    port: Int,
    authenticationMethod: SSHAuthenticationMethod,
    onHostKey: @escaping @Sendable (NIOSSHPublicKey) -> Void
) async throws -> SSHClient {
    try await SSHClient.connect(
        host: host,
        port: port,
        authenticationMethod: authenticationMethod,
        hostKeyValidator: .custom(CapturingHostKeyValidator(onKey: onHostKey)),
        reconnect: .never
    )
}
