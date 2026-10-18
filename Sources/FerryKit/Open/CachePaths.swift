import CryptoKit
import Foundation

/// Maps a remote file to a local cache location. The directory name is a hash of
/// (host, remotePath, mtime, size), so a changed remote file never reuses a stale
/// cached copy. The last path component keeps the remote file name and extension
/// so that NSWorkspace can open the file with the right application.
public struct CachePaths: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// `Caches/Ferry/` inside the user's caches directory.
    public static func defaultRoot() throws -> URL {
        try FileManager.default
            .url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Ferry", isDirectory: true)
    }

    public func cacheURL(host: String, remotePath: String, mtime: Date, size: Int64) -> URL {
        // Unit separator between fields so that ("ab", "c") and ("a", "bc") hash differently.
        let key = [
            host,
            remotePath,
            String(mtime.timeIntervalSince1970.bitPattern),
            String(size),
        ].joined(separator: "\u{1F}")
        let digest = SHA256.hash(data: Data(key.utf8))
        let dirName = digest.map { String(format: "%02x", $0) }.joined()

        return root
            .appendingPathComponent(dirName, isDirectory: true)
            .appendingPathComponent(Self.fileName(of: remotePath), isDirectory: false)
    }

    private static func fileName(of remotePath: String) -> String {
        let last = remotePath.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? ""
        return (last.isEmpty || last == "." || last == "..") ? "file" : last
    }
}
