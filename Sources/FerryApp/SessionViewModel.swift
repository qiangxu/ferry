import FerryKit
import Foundation
import SwiftUI

public enum SessionState: Equatable {
    case disconnected
    case connecting
    case connected
    case failed(String)
}

/// UI state for the single active SFTP session.
@MainActor
public final class SessionViewModel: ObservableObject {
    public typealias Connector = @Sendable (
        _ host: String, _ port: Int, _ username: String,
        _ auth: AuthInput, _ validator: HostKeyValidating
    ) async throws -> SFTPSession

    @Published public private(set) var currentPath: String = "/"
    @Published public private(set) var entries: [RemoteEntry] = []
    @Published public private(set) var state: SessionState = .disconnected

    private var session: SFTPSession?
    private var generation = 0

    private let knownHosts: KnownHostsStore
    private let cache: CachePaths
    private let opener: FileOpening
    private let passwordProvider: @Sendable (UUID) -> String?
    private let confirmHostKey: @Sendable (_ host: String, _ port: Int, _ fingerprint: String) async -> Bool
    private let connector: Connector

    public init(
        knownHosts: KnownHostsStore,
        cache: CachePaths,
        opener: FileOpening = WorkspaceFileOpener(),
        passwordProvider: @escaping @Sendable (UUID) -> String?,
        confirmHostKey: @escaping @Sendable (_ host: String, _ port: Int, _ fingerprint: String) async -> Bool,
        connector: @escaping Connector = { host, port, user, auth, validator in
            try await SFTPSession.connect(
                host: host, port: port, username: user, auth: auth, validator: validator
            )
        }
    ) {
        self.knownHosts = knownHosts
        self.cache = cache
        self.opener = opener
        self.passwordProvider = passwordProvider
        self.confirmHostKey = confirmHostKey
        self.connector = connector
    }

    public func connect(_ favorite: Favorite) async {
        generation += 1
        let myGeneration = generation

        if let old = session {
            session = nil
            await old.disconnect()
        }
        entries = []
        state = .connecting

        let auth: AuthInput
        switch favorite.auth {
        case .password:
            guard let password = passwordProvider(favorite.id) else {
                state = .failed("No saved password for this favorite.")
                return
            }
            auth = .password(password)
        case .privateKey:
            guard let path = favorite.privateKeyPath, !path.isEmpty else {
                state = .failed("No private key path configured.")
                return
            }
            auth = .ed25519(privateKeyPEMPath: path)
        }

        let validator = TOFUHostKeyValidator(store: knownHosts, confirm: confirmHostKey)
        do {
            let newSession = try await connector(
                favorite.host, favorite.port, favorite.username, auth, validator
            )
            if myGeneration != generation {
                // A newer connect superseded this one while we were waiting.
                await newSession.disconnect()
                return
            }
            session = newSession
            let path: String
            let listed: [RemoteEntry]
            if favorite.initialPath.isEmpty {
                // Blank path means "land in HOME": realpath("."), then fall back.
                var candidates: [String] = []
                if let home = try? await newSession.homeDirectory(), !home.isEmpty {
                    candidates.append(home)
                }
                candidates += [".", "/"]
                var resolved: (String, [RemoteEntry])?
                var lastError: Error = SFTPError.io("could not list initial directory")
                for candidate in candidates {
                    do {
                        resolved = (candidate, try await newSession.list(candidate))
                        break
                    } catch {
                        lastError = error
                    }
                }
                guard let resolved else { throw lastError }
                (path, listed) = resolved
            } else {
                path = favorite.initialPath
                listed = try await newSession.list(path)
            }
            guard myGeneration == generation else { return }
            currentPath = path
            entries = listed
            state = .connected
        } catch {
            guard myGeneration == generation else { return }
            if let stale = session {
                session = nil
                await stale.disconnect()
            }
            state = .failed(Self.describe(error))
        }
    }

    public func navigate(to path: String) async {
        guard let session else { return }
        let myGeneration = generation
        do {
            let listed = try await session.list(path)
            guard myGeneration == generation else { return }
            currentPath = path
            entries = listed
        } catch {
            guard myGeneration == generation else { return }
            state = .failed(Self.describe(error))
        }
    }

    public func goUp() async {
        let parent = RemotePath.parent(currentPath)
        guard parent != currentPath else { return }
        await navigate(to: parent)
    }

    public func open(_ entry: RemoteEntry) async {
        if entry.isDirectory {
            await navigate(to: entry.path)
            return
        }
        guard let session else { return }
        let coordinator = FileOpenCoordinator(session: session, cache: cache, opener: opener)
        do {
            try await coordinator.open(entry)
        } catch {
            state = .failed(Self.describe(error))
        }
    }

    public func upload(_ localURL: URL) async {
        guard let session else { return }
        let myGeneration = generation
        let remote = RemotePath.join(currentPath, localURL.lastPathComponent)
        do {
            try await session.upload(localURL, to: remote)
            guard myGeneration == generation else { return }
            await navigate(to: currentPath)
        } catch {
            guard myGeneration == generation else { return }
            state = .failed(Self.describe(error))
        }
    }

    public func disconnect() async {
        generation += 1
        if let old = session {
            session = nil
            await old.disconnect()
        }
        entries = []
        state = .disconnected
    }

    static func describe(_ error: Error) -> String {
        switch error as? SFTPError {
        case .connectionFailed: return "Connection failed."
        case .authenticationFailed: return "Authentication failed."
        case .jumpConnectionFailed: return "Connection to the jump host failed."
        case .jumpAuthenticationFailed: return "Authentication to the jump host failed."
        case .hostKeyChanged(let fp): return "Host key changed (\(fp)). Possible man-in-the-middle."
        case .hostKeyRejected: return "Host key rejected."
        case .timeout: return "Connection timed out."
        case .io(let message): return message
        case nil: return String(describing: error)
        }
    }
}
