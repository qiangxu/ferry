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
}
