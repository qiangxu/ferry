import Testing
@testable import FerryKit

@Test func joinAddsSegmentUnderDirectory() {
    #expect(RemotePath.join("/a", "b") == "/a/b")
}

@Test func joinHandlesTrailingSlashOnBase() {
    #expect(RemotePath.join("/a/", "b") == "/a/b")
}

@Test func joinKeepsSpacesRaw() {
    #expect(RemotePath.join("/a", "my file") == "/a/my file")
}

@Test func joinUnderRootWithNonASCIIName() {
    #expect(RemotePath.join("/", "日志") == "/日志")
}

@Test func parentOfNestedPath() {
    #expect(RemotePath.parent("/a/b") == "/a")
}

@Test func parentOfRootStaysRoot() {
    #expect(RemotePath.parent("/") == "/")
}

@Test func nameOfFilePath() {
    #expect(RemotePath.name(of: "/a/b.log") == "b.log")
}
