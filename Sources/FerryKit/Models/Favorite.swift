import Foundation

public enum AuthMethod: String, Codable, Sendable {
    case password
    case privateKey
}

/// A saved SFTP connection. Contains no secrets: passwords and passphrases live in Keychain.
public struct Favorite: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var host: String
    public var port: Int
    public var username: String
    public var auth: AuthMethod
    public var privateKeyPath: String?
    public var initialPath: String
    public var colorLabel: String?
    public var note: String

    public init(id: UUID, name: String, host: String, port: Int = 22, username: String,
                auth: AuthMethod, privateKeyPath: String?, initialPath: String,
                colorLabel: String?, note: String) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.auth = auth
        self.privateKeyPath = privateKeyPath
        self.initialPath = initialPath
        self.colorLabel = colorLabel
        self.note = note
    }
}
