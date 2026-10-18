import Foundation
import Testing
@testable import FerryKit

private let root = URL(fileURLWithPath: "/tmp-test-root", isDirectory: true)
private let paths = CachePaths(root: root)
private let mtime = Date(timeIntervalSince1970: 1_700_000_000)

@Test func sameParametersYieldSameURL() {
    let a = paths.cacheURL(host: "h", remotePath: "/a/b.html", mtime: mtime, size: 10)
    let b = paths.cacheURL(host: "h", remotePath: "/a/b.html", mtime: mtime, size: 10)
    #expect(a == b)
}

@Test func changedMtimeYieldsDifferentURL() {
    let a = paths.cacheURL(host: "h", remotePath: "/a/b.html", mtime: mtime, size: 10)
    let b = paths.cacheURL(host: "h", remotePath: "/a/b.html", mtime: mtime.addingTimeInterval(1), size: 10)
    #expect(a != b)
}

@Test func changedSizeYieldsDifferentURL() {
    let a = paths.cacheURL(host: "h", remotePath: "/a/b.html", mtime: mtime, size: 10)
    let b = paths.cacheURL(host: "h", remotePath: "/a/b.html", mtime: mtime, size: 11)
    #expect(a != b)
}

@Test func changedHostOrPathYieldsDifferentURL() {
    let a = paths.cacheURL(host: "h", remotePath: "/a/b.html", mtime: mtime, size: 10)
    #expect(a != paths.cacheURL(host: "h2", remotePath: "/a/b.html", mtime: mtime, size: 10))
    #expect(a != paths.cacheURL(host: "h", remotePath: "/a/c.html", mtime: mtime, size: 10))
}

@Test func fileNameKeepsOriginalExtension() {
    let url = paths.cacheURL(host: "h", remotePath: "/a/b.html", mtime: mtime, size: 10)
    #expect(url.lastPathComponent == "b.html")
    #expect(url.pathExtension == "html")
}

@Test func urlIsUnderRoot() {
    let url = paths.cacheURL(host: "h", remotePath: "/a/b.html", mtime: mtime, size: 10)
    #expect(url.path.hasPrefix(root.path + "/"))
}

@Test func defaultRootIsFerryUnderCaches() throws {
    let root = try CachePaths.defaultRoot()
    #expect(root.lastPathComponent == "Ferry")
    #expect(root.deletingLastPathComponent().lastPathComponent == "Caches")
}
