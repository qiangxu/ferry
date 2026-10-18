import CryptoKit
import Foundation

/// OpenSSH-style fingerprint: `SHA256:` + base64(SHA256(blob)) without `=` padding.
/// `blob` is the SSH wire-format public key (already carries the key type header).
public func sha256Fingerprint(keyType: String, blob: Data) -> String {
    let digest = Data(SHA256.hash(data: blob))
    let b64 = digest.base64EncodedString().trimmingCharacters(in: CharacterSet(charactersIn: "="))
    return "SHA256:" + b64
}
