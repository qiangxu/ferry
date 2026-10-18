import Foundation
import Security

public struct CredentialStoreError: Error, Equatable, CustomStringConvertible {
    public let status: OSStatus
    public var description: String {
        let msg = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
        return "Keychain error \(status): \(msg)"
    }
}

/// Stores SFTP secrets in the macOS Keychain, keyed by favorite id.
public struct CredentialStore {
    public let service: String

    public init(service: String) {
        self.service = service
    }

    private func baseQuery(for id: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ]
    }

    public func setPassword(_ p: String, for id: UUID) throws {
        let data = Data(p.utf8)
        let query = baseQuery(for: id)
        let updateStatus = SecItemUpdate(query as CFDictionary,
                                         [kSecValueData as String: data] as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var add = query
            add[kSecValueData as String] = data
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw CredentialStoreError(status: addStatus) }
        default:
            throw CredentialStoreError(status: updateStatus)
        }
    }

    public func password(for id: UUID) throws -> String? {
        var query = baseQuery(for: id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw CredentialStoreError(status: status)
        }
    }

    public func removePassword(for id: UUID) throws {
        let status = SecItemDelete(baseQuery(for: id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError(status: status)
        }
    }
}
