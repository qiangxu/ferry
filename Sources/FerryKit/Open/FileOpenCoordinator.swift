import AppKit
import Foundation

/// Opens a local file with the user's default application.
public protocol FileOpening: Sendable {
    func open(url: URL)
}

/// Production opener backed by `NSWorkspace`.
public struct WorkspaceFileOpener: FileOpening {
    public init() {}

    public func open(url: URL) {
        NSWorkspace.shared.open(url)
    }
}

/// "Click a remote file and it opens": downloads into the content-addressed
/// cache (skipped when a cached copy already exists), then hands the local URL
/// to the opener. View-only; no write-back.
public struct FileOpenCoordinator: Sendable {
    private let session: SFTPSession
    private let cache: CachePaths
    private let opener: FileOpening

    public init(session: SFTPSession, cache: CachePaths, opener: FileOpening = WorkspaceFileOpener()) {
        self.session = session
        self.cache = cache
        self.opener = opener
    }

    public func open(_ entry: RemoteEntry) async throws {
        let fm = FileManager.default
        let url = cache.cacheURL(
            host: session.host, remotePath: entry.path, mtime: entry.modified, size: entry.size
        )
        if !fm.fileExists(atPath: url.path) {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await session.download(entry.path, to: url)
        }
        opener.open(url: url)
    }
}
