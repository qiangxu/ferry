import Foundation

/// Validates a server's SSH host key during connection setup.
///
/// A validator returns normally to accept the key, or throws an `SFTPError`
/// (typically `.hostKeyChanged` or `.hostKeyRejected`) to abort the connection.
public protocol HostKeyValidating: Sendable {
    /// - Parameters:
    ///   - host: The host being connected to (as supplied by the caller).
    ///   - port: The port being connected to.
    ///   - keyType: The SSH key type string, e.g. `"ssh-ed25519"`.
    ///   - blob: The SSH wire-format public key blob presented by the server.
    func validate(host: String, port: Int, keyType: String, blob: Data) async throws
}

/// Trust-on-first-use host key validator backed by a `KnownHostsStore`.
///
/// Policy:
/// - `.match`  -> accept.
/// - `.unknown` -> ask the injected `confirm` closure; on `true`, record the key
///   via `trust(...)` and accept; on `false`, reject with `.hostKeyRejected`.
/// - `.changed` -> reject with `.hostKeyChanged`. A changed key is never offered
///   for trust, so an existing record is never overwritten.
public struct TOFUHostKeyValidator: HostKeyValidating {
    private let store: KnownHostsStore
    private let confirm: @Sendable (_ fingerprint: String) async -> Bool

    public init(
        store: KnownHostsStore,
        confirm: @escaping @Sendable (_ fingerprint: String) async -> Bool
    ) {
        self.store = store
        self.confirm = confirm
    }

    public func validate(host: String, port: Int, keyType: String, blob: Data) async throws {
        // Hardening: a known_hosts record is a single space-separated line, so a
        // host or key type carrying whitespace/newlines could forge extra lines.
        // Lowercase the host for consistent matching and reject the forged shapes.
        let host = host.lowercased()
        guard !Self.containsWhitespaceOrNewline(host),
              !Self.containsWhitespaceOrNewline(keyType) else {
            throw SFTPError.hostKeyRejected
        }

        let decision: HostKeyDecision
        do {
            decision = try store.decision(host: host, port: port, keyType: keyType, blob: blob)
        } catch {
            throw SFTPError.io("known_hosts read failed: \(error)")
        }

        switch decision {
        case .match:
            return
        case .changed(let fingerprint):
            throw SFTPError.hostKeyChanged(fingerprint: fingerprint)
        case .unknown(let fingerprint):
            guard await confirm(fingerprint) else {
                throw SFTPError.hostKeyRejected
            }
            do {
                try store.trust(host: host, port: port, keyType: keyType, blob: blob)
            } catch {
                throw SFTPError.io("known_hosts write failed: \(error)")
            }
        }
    }

    private static func containsWhitespaceOrNewline(_ value: String) -> Bool {
        value.unicodeScalars.contains { CharacterSet.whitespacesAndNewlines.contains($0) }
    }
}
