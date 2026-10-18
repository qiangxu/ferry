import Foundation

/// A single entry in a remote SFTP directory listing.
public struct RemoteEntry: Equatable, Sendable {
    public let name: String
    public let path: String
    public let isDirectory: Bool
    public let size: Int64
    public let modified: Date

    public init(name: String, path: String, isDirectory: Bool, size: Int64, modified: Date) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
    }
}
