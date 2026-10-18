import FerryKit
import Foundation
import Testing
@testable import FerryApp

@MainActor
@Suite struct SessionViewModelTests {
    private struct Fixture {
        let server: LoopbackSSHServer
        let port: Int
        let root: URL
    }

    private func makeFixture(home: String = "/") async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ferry-vm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("sub"), withIntermediateDirectories: true
        )
        try Data("hi".utf8).write(to: root.appendingPathComponent("a.txt"))
        try Data("yo".utf8).write(to: root.appendingPathComponent("sub/b.txt"))
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("home/u"), withIntermediateDirectories: true
        )
        try Data("h".utf8).write(to: root.appendingPathComponent("home/u/inhome.txt"))
        let server = LoopbackSSHServer(
            username: "u", password: "p", authorizedEd25519PublicKey: nil,
            sftpDelegate: TempDirSFTPDelegate(root: root, home: home)
        )
        return Fixture(server: server, port: try await server.start(), root: root)
    }

    private func favorite(port: Int, initialPath: String = "/") -> Favorite {
        Favorite(id: UUID(), name: "t", host: "127.0.0.1", port: port, username: "u",
                 auth: .password, privateKeyPath: nil, initialPath: initialPath,
                 colorLabel: nil, note: "")
    }

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _sessions: [SFTPSession] = []
        var sessions: [SFTPSession] { lock.lock(); defer { lock.unlock() }; return _sessions }
        func add(_ s: SFTPSession) { lock.lock(); _sessions.append(s); lock.unlock() }
    }

    private func makeVM(recorder: Recorder = Recorder(), confirm: Bool = true) -> SessionViewModel {
        let hosts = FileManager.default.temporaryDirectory
            .appendingPathComponent("ferry-vm-kh-\(UUID().uuidString)/known_hosts")
        let cache = CachePaths(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("ferry-vm-cache-\(UUID().uuidString)"))
        return SessionViewModel(
            knownHosts: KnownHostsStore(fileURL: hosts),
            cache: cache,
            passwordProvider: { _ in "p" },
            confirmHostKey: { _, _, _ in confirm },
            connector: { host, port, user, auth, validator, jumpHost, jumpPort in
                let s = try await SFTPSession.connect(
                    host: host, port: port, username: user, auth: auth, validator: validator,
                    jumpHost: jumpHost, jumpPort: jumpPort
                )
                recorder.add(s)
                return s
            }
        )
    }

    @Test func connectSuccessPublishesEntries() async throws {
        let f = try await makeFixture()
        let vm = makeVM()
        await vm.connect(favorite(port: f.port))
        #expect(vm.state == .connected)
        #expect(!vm.entries.isEmpty)
        #expect(vm.currentPath == "/")
        await vm.disconnect()
        await f.server.stop()
    }

    @Test func emptyInitialPathLandsInHomeDirectory() async throws {
        let f = try await makeFixture(home: "/home/u")
        let vm = makeVM()
        await vm.connect(favorite(port: f.port, initialPath: ""))
        #expect(vm.state == .connected)
        #expect(vm.currentPath == "/home/u")
        #expect(vm.entries.map(\.name) == ["inhome.txt"])
        await vm.disconnect()
        await f.server.stop()
    }

    @Test func hostKeyRejectedFails() async throws {
        let f = try await makeFixture()
        let vm = makeVM(confirm: false)
        await vm.connect(favorite(port: f.port))
        #expect(vm.state == .failed("Host key rejected."))
        await f.server.stop()
    }

    @Test func navigateAndGoUp() async throws {
        let f = try await makeFixture()
        let vm = makeVM()
        await vm.connect(favorite(port: f.port))
        await vm.navigate(to: "/sub")
        #expect(vm.currentPath == "/sub")
        #expect(vm.entries.map(\.name) == ["b.txt"])
        await vm.goUp()
        #expect(vm.currentPath == "/")
        #expect(vm.entries.contains { $0.name == "a.txt" })
        await vm.disconnect()
        await f.server.stop()
    }

    @Test func goUpAtRootIsIdempotent() async throws {
        let f = try await makeFixture()
        let vm = makeVM()
        await vm.connect(favorite(port: f.port))
        let before = vm.entries
        await vm.goUp()
        #expect(vm.currentPath == "/")
        #expect(vm.entries == before)
        #expect(vm.state == .connected)
        await vm.disconnect()
        await f.server.stop()
    }

    @Test func secondConnectDisconnectsPreviousSession() async throws {
        let f = try await makeFixture()
        let rec = Recorder()
        let vm = makeVM(recorder: rec)
        await vm.connect(favorite(port: f.port))
        let first = try #require(rec.sessions.first)
        _ = try await first.list("/")  // alive before

        await vm.connect(favorite(port: f.port))
        #expect(rec.sessions.count == 2)
        #expect(vm.state == .connected)

        // The old session was disconnected: using it now fails.
        await #expect(throws: (any Error).self) { _ = try await first.list("/") }
        await vm.disconnect()
        await f.server.stop()
    }

    @Test func navigateFailureKeepsSessionConnectedAndSetsErrorMessage() async throws {
        let f = try await makeFixture()
        let rec = Recorder()
        let vm = makeVM(recorder: rec)
        await vm.connect(favorite(port: f.port))
        // Kill the underlying link so the next list fails while the VM still thinks it is connected.
        await rec.sessions.first?.disconnect()
        await vm.navigate(to: "/sub")
        #expect(vm.state == .connected)
        #expect(vm.errorMessage != nil)
        #expect(!vm.entries.isEmpty)
        vm.dismissError()
        #expect(vm.errorMessage == nil)
        await vm.disconnect()
        await f.server.stop()
    }
}
