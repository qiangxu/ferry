import Foundation

/// Reads and writes the favorites list as a JSON file.
public struct FavoritesStore {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// `~/Library/Application Support/Ferry/favorites.json`.
    public static func defaultFileURL() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return support
            .appendingPathComponent("Ferry", isDirectory: true)
            .appendingPathComponent("favorites.json")
    }

    /// Returns an empty list when the file does not exist yet.
    public func load() throws -> [Favorite] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode([Favorite].self, from: data)
    }

    /// Writes the full list, creating the parent directory if needed.
    public func save(_ favorites: [Favorite]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(favorites)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }
}
