/// Errors surfaced by `SFTPSession`.
///
/// Note: Citadel also declares a type named `SFTPError`. Within FerryKit the
/// unqualified name resolves to this type; refer to `FerryKit.SFTPError`
/// explicitly from code that also imports Citadel (e.g. tests).
public enum SFTPError: Error, Equatable {
    case connectionFailed
    case authenticationFailed
    case hostKeyChanged(fingerprint: String)
    case hostKeyRejected
    case timeout
    case io(String)
    /// The connection to the jump (ProxyJump) host itself failed to establish.
    /// Distinct from `.connectionFailed`, which (in a two-hop connect) means the
    /// jump host was reached but the hop to the *target* failed.
    case jumpConnectionFailed
    /// Authentication to the jump (ProxyJump) host failed. Distinct from
    /// `.authenticationFailed`, which denotes a target-host auth failure.
    case jumpAuthenticationFailed
}
