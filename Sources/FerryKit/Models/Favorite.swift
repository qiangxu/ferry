import Foundation

public enum AuthMethod: String, Codable, Sendable {
    case password
    case privateKey
}

/// A saved directory inside a connection — a "second-level" favorite. Selecting it
/// connects to the parent favorite's host (reusing its credentials and jump host) and
/// lands straight in `path`.
public struct DirBookmark: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var path: String

    public init(id: UUID = UUID(), name: String, path: String) {
        self.id = id
        self.name = name
        self.path = path
    }
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
    /// Optional jump-host address. Username and auth are shared with the target.
    public var jumpHost: String?
    public var jumpPort: Int
    /// Saved directories under this connection, shown as a second level in the sidebar.
    public var bookmarks: [DirBookmark]

    public init(id: UUID, name: String, host: String, port: Int = 22, username: String,
                auth: AuthMethod, privateKeyPath: String?, initialPath: String,
                colorLabel: String?, note: String,
                jumpHost: String? = nil, jumpPort: Int = 22,
                bookmarks: [DirBookmark] = []) {
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
        self.jumpHost = jumpHost
        self.jumpPort = jumpPort
        self.bookmarks = bookmarks
    }

    // Custom decoding so favorites saved before jump-host fields existed still load as direct connections.
    // New stored properties MUST be added to CodingKeys and init(from:) below; a missed key is silently dropped.
    private enum CodingKeys: String, CodingKey {
        case id, name, host, port, username, auth, privateKeyPath, initialPath, colorLabel, note
        case jumpHost, jumpPort, bookmarks
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        host = try c.decode(String.self, forKey: .host)
        port = try c.decode(Int.self, forKey: .port)
        username = try c.decode(String.self, forKey: .username)
        auth = try c.decode(AuthMethod.self, forKey: .auth)
        privateKeyPath = try c.decodeIfPresent(String.self, forKey: .privateKeyPath)
        initialPath = try c.decode(String.self, forKey: .initialPath)
        colorLabel = try c.decodeIfPresent(String.self, forKey: .colorLabel)
        note = try c.decode(String.self, forKey: .note)
        jumpHost = try c.decodeIfPresent(String.self, forKey: .jumpHost)
        jumpPort = try c.decodeIfPresent(Int.self, forKey: .jumpPort) ?? 22
        bookmarks = try c.decodeIfPresent([DirBookmark].self, forKey: .bookmarks) ?? []
    }
}
