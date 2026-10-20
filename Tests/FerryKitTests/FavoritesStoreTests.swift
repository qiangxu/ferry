import Foundation
import Testing
@testable import FerryKit

private func tmpURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("ferry-favorites-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("favorites.json")
}

@Test func saveThenLoadRoundTrips() throws {
    let url = tmpURL()
    let store = FavoritesStore(fileURL: url)
    let fav = Favorite(id: UUID(), name: "dolphin", host: "10.0.0.180", port: 22,
                       username: "qiangxu", auth: .privateKey, privateKeyPath: "~/.ssh/id_ed25519",
                       initialPath: "/home/qiangxu", colorLabel: nil, note: "")
    try store.save([fav])
    #expect(try store.load() == [fav])
}

@Test func loadMissingFileReturnsEmpty() throws {
    #expect(try FavoritesStore(fileURL: tmpURL()).load() == [])
}

@Test func savedJSONContainsNoPasswordField() throws {
    let url = tmpURL()
    let store = FavoritesStore(fileURL: url)
    let fav = Favorite(id: UUID(), name: "box", host: "example.com", port: 2222,
                       username: "me", auth: .password, privateKeyPath: nil,
                       initialPath: "/", colorLabel: "red", note: "no secrets here")
    try store.save([fav])
    let data = try Data(contentsOf: url)
    let objects = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    let keys = objects.flatMap { $0.keys.map { $0.lowercased() } }
    #expect(!keys.contains("password"))
    #expect(!keys.contains("passphrase"))
}

@Test func portDefaultsToTwentyTwo() {
    let fav = Favorite(id: UUID(), name: "n", host: "h", username: "u", auth: .password,
                       privateKeyPath: nil, initialPath: "/", colorLabel: nil, note: "")
    #expect(fav.port == 22)
}

@Test func test_favoriteWithJumpHost_roundTrips() throws {
    let url = tmpURL()
    let store = FavoritesStore(fileURL: url)
    let fav = Favorite(id: UUID(), name: "inner", host: "10.20.0.5", port: 22,
                       username: "qiangxu", auth: .privateKey, privateKeyPath: "~/.ssh/id_ed25519",
                       initialPath: "/srv", colorLabel: nil, note: "",
                       jumpHost: "192.168.3.180", jumpPort: 2222)
    try store.save([fav])
    let loaded = try store.load()
    #expect(loaded == [fav])
    #expect(loaded.first?.jumpHost == "192.168.3.180")
    #expect(loaded.first?.jumpPort == 2222)
}

@Test func test_decodeLegacyJSON_withoutJumpFields_defaultsToDirect() throws {
    let legacy = """
    {
      "id": "6F1C2B3A-1111-4A2B-9C3D-0123456789AB",
      "name": "old",
      "host": "10.0.0.180",
      "port": 22,
      "username": "qiangxu",
      "auth": "privateKey",
      "privateKeyPath": "~/.ssh/id_ed25519",
      "initialPath": "/home/qiangxu",
      "colorLabel": null,
      "note": ""
    }
    """
    let fav = try JSONDecoder().decode(Favorite.self, from: Data(legacy.utf8))
    #expect(fav.jumpHost == nil)
    #expect(fav.jumpPort == 22)
    #expect(fav.host == "10.0.0.180")
}

@Test func test_favoriteWithBookmarks_roundTrips() throws {
    let url = tmpURL()
    let store = FavoritesStore(fileURL: url)
    let fav = Favorite(id: UUID(), name: "srv", host: "10.0.0.9", port: 22,
                       username: "qiangxu", auth: .privateKey, privateKeyPath: "~/.ssh/id_ed25519",
                       initialPath: "/home/qiangxu", colorLabel: nil, note: "",
                       bookmarks: [DirBookmark(name: "project", path: "/var/www/project"),
                                   DirBookmark(name: "logs", path: "/home/qiangxu/logs")])
    try store.save([fav])
    let loaded = try store.load()
    #expect(loaded == [fav])
    #expect(loaded.first?.bookmarks.map(\.path) == ["/var/www/project", "/home/qiangxu/logs"])
}

@Test func test_decodeLegacyJSON_withoutBookmarks_defaultsToEmpty() throws {
    let legacy = """
    {
      "id": "6F1C2B3A-1111-4A2B-9C3D-0123456789AB",
      "name": "old", "host": "10.0.0.180", "port": 22, "username": "qiangxu",
      "auth": "privateKey", "privateKeyPath": "~/.ssh/id_ed25519",
      "initialPath": "/home/qiangxu", "colorLabel": null, "note": ""
    }
    """
    let fav = try JSONDecoder().decode(Favorite.self, from: Data(legacy.utf8))
    #expect(fav.bookmarks == [])
}

@Test func saveCreatesParentDirectory() throws {
    let url = tmpURL()
    #expect(!FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
    try FavoritesStore(fileURL: url).save([])
    #expect(FileManager.default.fileExists(atPath: url.path))
}
