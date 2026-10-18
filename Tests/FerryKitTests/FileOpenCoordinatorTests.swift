import Foundation
import Testing
@testable import FerryKit

private final class SpyOpener: FileOpening, @unchecked Sendable {
    private let lock = NSLock()
    private var _urls: [URL] = []
    var urls: [URL] { lock.lock(); defer { lock.unlock() }; return _urls }
    func open(url: URL) { lock.lock(); _urls.append(url); lock.unlock() }
}

@Suite struct FileOpenCoordinatorTests {
    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ferry-open-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private struct Fixture {
        let server: LoopbackSSHServer
        let session: SFTPSession
        let remoteRoot: URL
        let cache: CachePaths
        let spy: SpyOpener
        let coordinator: FileOpenCoordinator
    }

    private func makeFixture() async throws -> Fixture {
        let remoteRoot = try makeTempDir()
        let server = LoopbackSSHServer(
            username: "u", password: "p", authorizedEd25519PublicKey: nil,
            sftpDelegate: TempDirSFTPDelegate(root: remoteRoot)
        )
        let port = try await server.start()
        let knownHosts = makeTempDir0().appendingPathComponent("known_hosts")
        let validator = TOFUHostKeyValidator(store: KnownHostsStore(fileURL: knownHosts), confirm: { _ in true })
        let session: SFTPSession
        do {
            session = try await SFTPSession.connect(
                host: "127.0.0.1", port: port, username: "u",
                auth: .password("p"), validator: validator
            )
        } catch {
            await server.stop()
            throw error
        }
        let cache = CachePaths(root: try makeTempDir())
        let spy = SpyOpener()
        return Fixture(server: server, session: session, remoteRoot: remoteRoot, cache: cache, spy: spy,
                       coordinator: FileOpenCoordinator(session: session, cache: cache, opener: spy))
    }

    private func makeTempDir0() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ferry-kh-\(UUID().uuidString)", isDirectory: true)
    }

    private func teardown(_ f: Fixture) async {
        await f.session.disconnect()
        await f.server.stop()
    }

    private func entry(_ path: String, size: Int64, modified: Date) -> RemoteEntry {
        RemoteEntry(name: (path as NSString).lastPathComponent, path: path,
                    isDirectory: false, size: size, modified: modified)
    }

    @Test func test_open_firstTime_downloadsAndOpensCacheURL() async throws {
        let f = try await makeFixture()
        defer { Task { await teardown(f) } }
        try Data("hello".utf8).write(to: f.remoteRoot.appendingPathComponent("a.txt"))
        let e = entry("/a.txt", size: 5, modified: Date(timeIntervalSince1970: 1_700_000_000))

        try await f.coordinator.open(e)

        let expected = f.cache.cacheURL(host: "127.0.0.1", remotePath: e.path, mtime: e.modified, size: e.size)
        #expect(f.spy.urls == [expected])
        #expect(try Data(contentsOf: expected) == Data("hello".utf8))
    }

    @Test func test_open_sameEntryTwice_doesNotRedownload() async throws {
        let f = try await makeFixture()
        defer { Task { await teardown(f) } }
        let remoteFile = f.remoteRoot.appendingPathComponent("a.txt")
        try Data("hello".utf8).write(to: remoteFile)
        let e = entry("/a.txt", size: 5, modified: Date(timeIntervalSince1970: 1_700_000_000))

        try await f.coordinator.open(e)
        // Remove the remote file: a second download would now fail.
        try FileManager.default.removeItem(at: remoteFile)
        try await f.coordinator.open(e)

        #expect(f.spy.urls.count == 2)
        #expect(f.spy.urls[0] == f.spy.urls[1])
    }

    @Test func test_open_changedMtime_redownloadsToNewURL() async throws {
        let f = try await makeFixture()
        defer { Task { await teardown(f) } }
        let remoteFile = f.remoteRoot.appendingPathComponent("a.txt")
        try Data("v1".utf8).write(to: remoteFile)
        let e1 = entry("/a.txt", size: 2, modified: Date(timeIntervalSince1970: 1_700_000_000))
        try await f.coordinator.open(e1)

        try Data("v2".utf8).write(to: remoteFile)
        let e2 = entry("/a.txt", size: 2, modified: Date(timeIntervalSince1970: 1_700_000_100))
        try await f.coordinator.open(e2)

        #expect(f.spy.urls.count == 2)
        #expect(f.spy.urls[0] != f.spy.urls[1])
        #expect(try Data(contentsOf: f.spy.urls[0]) == Data("v1".utf8))
        #expect(try Data(contentsOf: f.spy.urls[1]) == Data("v2".utf8))
    }

    @Test func test_open_failedDownload_leavesNoFileAndLaterOpenSucceeds() async throws {
        let f = try await makeFixture()
        defer { Task { await teardown(f) } }
        try Data("done".utf8).write(to: f.remoteRoot.appendingPathComponent("a.txt"))
        let e = entry("/a.txt", size: 4, modified: Date(timeIntervalSince1970: 1_700_000_000))
        let url = f.cache.cacheURL(host: "127.0.0.1", remotePath: e.path, mtime: e.modified, size: e.size)
        let dir = url.deletingLastPathComponent()
        let fm = FileManager.default

        // Read-only target dir: the remote read succeeds but writing locally fails.
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        await #expect(throws: (any Error).self) { try await f.coordinator.open(e) }
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)

        #expect(!fm.fileExists(atPath: url.path))
        #expect(f.spy.urls.isEmpty)
        #expect(try fm.contentsOfDirectory(atPath: dir.path).isEmpty)

        try await f.coordinator.open(e)
        #expect(f.spy.urls == [url])
        #expect(try Data(contentsOf: url) == Data("done".utf8))
    }
}
