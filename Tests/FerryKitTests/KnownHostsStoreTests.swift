import Foundation
import Testing
@testable import FerryKit

private func tmpURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("ferry-knownhosts-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("known_hosts")
}

private let blobA = Data("ferry-test-blob".utf8)
private let blobB = Data("another-blob".utf8)

@Test func unknownHostReturnsUnknownWithFingerprint() throws {
    let store = KnownHostsStore(fileURL: tmpURL())
    let d = try store.decision(host: "h.example", port: 22, keyType: "ssh-ed25519", blob: blobA)
    guard case .unknown(let fp) = d else { Issue.record("expected unknown, got \(d)"); return }
    #expect(!fp.isEmpty)
    #expect(fp == sha256Fingerprint(keyType: "ssh-ed25519", blob: blobA))
}

@Test func trustThenDecisionReturnsMatch() throws {
    let store = KnownHostsStore(fileURL: tmpURL())
    try store.trust(host: "h.example", port: 22, keyType: "ssh-ed25519", blob: blobA)
    #expect(try store.decision(host: "h.example", port: 22, keyType: "ssh-ed25519", blob: blobA) == .match)
}

@Test func sameHostDifferentKeyReturnsChanged() throws {
    let store = KnownHostsStore(fileURL: tmpURL())
    try store.trust(host: "h.example", port: 22, keyType: "ssh-ed25519", blob: blobA)
    let d = try store.decision(host: "h.example", port: 22, keyType: "ssh-ed25519", blob: blobB)
    #expect(d == .changed(fingerprint: sha256Fingerprint(keyType: "ssh-ed25519", blob: blobB)))
}

@Test func differentPortIsIndependentEntry() throws {
    let store = KnownHostsStore(fileURL: tmpURL())
    try store.trust(host: "h.example", port: 22, keyType: "ssh-ed25519", blob: blobA)
    let d = try store.decision(host: "h.example", port: 2222, keyType: "ssh-ed25519", blob: blobB)
    guard case .unknown = d else { Issue.record("expected unknown, got \(d)"); return }
}

@Test func nonStandardPortRoundTripsWithBracketNotation() throws {
    let url = tmpURL()
    let store = KnownHostsStore(fileURL: url)
    try store.trust(host: "h.example", port: 2222, keyType: "ssh-ed25519", blob: blobA)
    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(text.contains("[h.example]:2222 ssh-ed25519 \(blobA.base64EncodedString())"))
    #expect(try store.decision(host: "h.example", port: 2222, keyType: "ssh-ed25519", blob: blobA) == .match)
}

@Test func standardPortLineHasNoBrackets() throws {
    let url = tmpURL()
    let store = KnownHostsStore(fileURL: url)
    try store.trust(host: "h.example", port: 22, keyType: "ssh-ed25519", blob: blobA)
    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(text == "h.example ssh-ed25519 \(blobA.base64EncodedString())\n")
}

@Test func fingerprintMatchesKnownVector() {
    #expect(sha256Fingerprint(keyType: "ssh-ed25519", blob: blobA)
            == "SHA256:WjlUcXBU/kP3ZV9ejUY9wr+OFntHYnHGT5TANQhvsvc")
}

@Test func removeThenDecisionReturnsUnknown() throws {
    let store = KnownHostsStore(fileURL: tmpURL())
    try store.trust(host: "h.example", port: 22, keyType: "ssh-ed25519", blob: blobA)
    try store.remove(host: "h.example", port: 22)
    let d = try store.decision(host: "h.example", port: 22, keyType: "ssh-ed25519", blob: blobA)
    #expect(d == .unknown(fingerprint: sha256Fingerprint(keyType: "ssh-ed25519", blob: blobA)))
}

@Test func removeKeepsOtherHostsVerbatim() throws {
    let url = tmpURL()
    let store = KnownHostsStore(fileURL: url)
    try store.trust(host: "a.example", port: 22, keyType: "ssh-ed25519", blob: blobA)
    try store.trust(host: "b.example", port: 22, keyType: "ssh-ed25519", blob: blobB)
    try store.remove(host: "a.example", port: 22)
    #expect(try store.decision(host: "b.example", port: 22, keyType: "ssh-ed25519", blob: blobB) == .match)
    guard case .unknown = try store.decision(host: "a.example", port: 22, keyType: "ssh-ed25519", blob: blobA)
    else { Issue.record("a.example should be unknown"); return }
    #expect(try String(contentsOf: url, encoding: .utf8) == "b.example ssh-ed25519 \(blobB.base64EncodedString())\n")
}

@Test func removeNonStandardPortBracketFormLeavesOtherPorts() throws {
    let store = KnownHostsStore(fileURL: tmpURL())
    try store.trust(host: "h.example", port: 22, keyType: "ssh-ed25519", blob: blobA)
    try store.trust(host: "h.example", port: 2222, keyType: "ssh-ed25519", blob: blobB)
    try store.remove(host: "h.example", port: 2222)
    guard case .unknown = try store.decision(host: "h.example", port: 2222, keyType: "ssh-ed25519", blob: blobB)
    else { Issue.record("2222 should be unknown"); return }
    #expect(try store.decision(host: "h.example", port: 22, keyType: "ssh-ed25519", blob: blobA) == .match)
}

@Test func removeMissingFileIsNoOp() throws {
    let url = tmpURL()
    try KnownHostsStore(fileURL: url).remove(host: "h.example", port: 22)
    #expect(!FileManager.default.fileExists(atPath: url.path))
}

@Test func removeKeepsCommentsAndCommaListSiblings() throws {
    let url = tmpURL()
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let b = blobA.base64EncodedString()
    try "# note\na.example,b.example ssh-ed25519 \(b)\nc.example ssh-ed25519 \(b)\n"
        .write(to: url, atomically: true, encoding: .utf8)
    let store = KnownHostsStore(fileURL: url)
    try store.remove(host: "A.example", port: 22)
    #expect(try String(contentsOf: url, encoding: .utf8)
            == "# note\nb.example ssh-ed25519 \(b)\nc.example ssh-ed25519 \(b)\n")
}

@Test func test_remove_prefixNeighborHostUntouched() throws {
    let store = KnownHostsStore(fileURL: tmpURL())
    try store.trust(host: "a.example", port: 22, keyType: "ssh-ed25519", blob: blobA)
    try store.trust(host: "a.example.com", port: 22, keyType: "ssh-ed25519", blob: blobA)
    try store.remove(host: "a.example", port: 22)
    #expect(try store.decision(host: "a.example.com", port: 22, keyType: "ssh-ed25519", blob: blobA) == .match)
}
