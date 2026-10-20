import FerryKit
import Foundation
import SwiftUI

/// Asks the user to confirm an unknown host key via a SwiftUI alert.
@MainActor
public final class HostKeyPrompter: ObservableObject {
    public struct Request {
        let host: String
        let port: Int
        let fingerprint: String
        let continuation: CheckedContinuation<Bool, Never>
    }

    @Published var request: Request?

    nonisolated public init() {}

    func ask(host: String, port: Int, fingerprint: String) async -> Bool {
        await withCheckedContinuation { cont in
            // A superseded prompt must not hang its connect forever: reject it first.
            request?.continuation.resume(returning: false)
            request = Request(host: host, port: port, fingerprint: fingerprint, continuation: cont)
        }
    }

    func resolve(_ accepted: Bool) {
        request?.continuation.resume(returning: accepted)
        request = nil
    }
}

/// Composition root: wires stores and the session view model with default locations.
@MainActor
public final class AppModel: ObservableObject {
    public static let keychainService = "com.ferry.sftp"

    public let session: SessionViewModel
    public let prompter: HostKeyPrompter
    public let credentials = CredentialStore(service: AppModel.keychainService)
    public let favoritesStore: FavoritesStore

    @Published public var favorites: [Favorite] = []
    @Published public var errorMessage: String?

    public init() {
        let prompter = HostKeyPrompter()
        self.prompter = prompter
        let creds = CredentialStore(service: AppModel.keychainService)
        let support = FileManager.default.temporaryDirectory
        let favURL = (try? FavoritesStore.defaultFileURL()) ?? support.appendingPathComponent("favorites.json")
        let khURL = (try? KnownHostsStore.defaultFileURL()) ?? support.appendingPathComponent("known_hosts")
        let cacheRoot = (try? CachePaths.defaultRoot()) ?? support.appendingPathComponent("FerryCache")
        favoritesStore = FavoritesStore(fileURL: favURL)
        session = SessionViewModel(
            knownHosts: KnownHostsStore(fileURL: khURL),
            cache: CachePaths(root: cacheRoot),
            passwordProvider: { id in (try? creds.password(for: id)) ?? nil },
            confirmHostKey: { host, port, fingerprint in await prompter.ask(host: host, port: port, fingerprint: fingerprint) }
        )
        reload()
    }

    public func reload() {
        do { favorites = try favoritesStore.load() } catch { errorMessage = "Cannot load favorites: \(error)" }
    }

    /// Saves metadata to the favorites file and the password (if any) to Keychain.
    public func save(_ favorite: Favorite, password: String?) -> Bool {
        do {
            if favorite.auth == .password, let password, !password.isEmpty {
                try credentials.setPassword(password, for: favorite.id)
            } else if favorite.auth == .privateKey {
                // Switching away from password auth: don't leave a stale secret in Keychain.
                try? credentials.removePassword(for: favorite.id)
            }
            var list = try favoritesStore.load()
            if let i = list.firstIndex(where: { $0.id == favorite.id }) {
                list[i] = favorite
            } else {
                list.append(favorite)
            }
            try favoritesStore.save(list)
            favorites = list
            return true
        } catch {
            errorMessage = "Save failed: \(error)"
            return false
        }
    }

    /// Appends the current directory as a second-level bookmark under a connection.
    public func addBookmark(to favoriteID: UUID, name: String, path: String) {
        mutateFavorite(favoriteID) { $0.bookmarks.append(DirBookmark(name: name, path: path)) }
    }

    public func renameBookmark(_ bookmarkID: UUID, in favoriteID: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        mutateFavorite(favoriteID) { fav in
            if let i = fav.bookmarks.firstIndex(where: { $0.id == bookmarkID }) { fav.bookmarks[i].name = trimmed }
        }
    }

    public func removeBookmark(_ bookmarkID: UUID, from favoriteID: UUID) {
        mutateFavorite(favoriteID) { $0.bookmarks.removeAll { $0.id == bookmarkID } }
    }

    /// Loads the list from disk, applies `transform` to one favorite, and saves — so a
    /// bookmark edit never clobbers other fields a concurrent save may have written.
    private func mutateFavorite(_ id: UUID, _ transform: (inout Favorite) -> Void) {
        do {
            var list = try favoritesStore.load()
            guard let i = list.firstIndex(where: { $0.id == id }) else { return }
            transform(&list[i])
            try favoritesStore.save(list)
            favorites = list
        } catch {
            errorMessage = "Save failed: \(error)"
        }
    }

    public func remove(_ favorite: Favorite) {
        do {
            try? credentials.removePassword(for: favorite.id)
            let list = try favoritesStore.load().filter { $0.id != favorite.id }
            try favoritesStore.save(list)
            favorites = list
        } catch {
            errorMessage = "Delete failed: \(error)"
        }
    }
}
