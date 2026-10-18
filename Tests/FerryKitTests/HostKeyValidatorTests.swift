import Foundation
import Testing
@testable import FerryKit

private final class Captured: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [(String, Int, String)] = []
    func add(_ h: String, _ p: Int, _ f: String) { lock.lock(); _calls.append((h, p, f)); lock.unlock() }
    var calls: [(String, Int, String)] { lock.lock(); defer { lock.unlock() }; return _calls }
}

@Test func test_unknownHost_confirmReceivesHostAndPort() async throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("ferry-hkv-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("known_hosts")
    let captured = Captured()
    let validator = TOFUHostKeyValidator(store: KnownHostsStore(fileURL: url)) { host, port, fp in
        captured.add(host, port, fp)
        return true
    }
    let blob = Data("ferry-test-blob".utf8)
    try await validator.validate(host: "Jump.Example", port: 2222, keyType: "ssh-ed25519", blob: blob)

    #expect(captured.calls.count == 1)
    #expect(captured.calls.first?.0 == "jump.example")
    #expect(captured.calls.first?.1 == 2222)
    #expect(captured.calls.first?.2 == sha256Fingerprint(keyType: "ssh-ed25519", blob: blob))
}
