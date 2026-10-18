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

@Test func saveCreatesParentDirectory() throws {
    let url = tmpURL()
    #expect(!FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
    try FavoritesStore(fileURL: url).save([])
    #expect(FileManager.default.fileExists(atPath: url.path))
}
