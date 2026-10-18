import Citadel
import Crypto
import Foundation
import NIO
import NIOConcurrencyHelpers
import NIOSSH

/// How to authenticate to the SFTP server.
public enum AuthInput: Sendable {
    case password(String)
    /// Path to an unencrypted OpenSSH ed25519 private key (PEM text).
    case ed25519(privateKeyPEMPath: String)
}

/// A live SFTP connection: connect, list, download, upload, disconnect.
///
/// Host-key validation runs through the injected `HostKeyValidating` before the
/// connection is accepted; a rejected key aborts `connect` and no session is
/// returned.
public actor SFTPSession {
    private let client: SSHClient
    private let sftp: SFTPClient
    /// The host this session connected to (used e.g. for cache keys).
    public nonisolated let host: String

    private init(host: String, client: SSHClient, sftp: SFTPClient) {
        self.host = host
        self.client = client
        self.sftp = sftp
    }

    public static func connect(
        host: String,
        port: Int,
        username: String,
        auth: AuthInput,
        validator: HostKeyValidating
    ) async throws -> SFTPSession {
        let authMethod = try makeAuthMethod(username: username, auth: auth)

        // The validator fails the NIOSSH completion promise on rejection, but
        // NIOSSH may surface its own channel error from `connect`. Capture the
        // real reason here so we can rethrow it verbatim.
        let errorBox = NIOLockedValueBox<Error?>(nil)
        let delegate = PolicyHostKeyDelegate(
            host: host, port: port, validator: validator, errorBox: errorBox
        )

        let client: SSHClient
        do {
            client = try await SSHClient.connect(
                host: host,
                port: port,
                authenticationMethod: authMethod,
                hostKeyValidator: .custom(delegate),
                reconnect: .never
            )
        } catch {
            if let captured = errorBox.withLockedValue({ $0 }) {
                throw captured
            }
            throw mapConnectError(error)
        }

        do {
            let sftp = try await client.openSFTP()
            return SFTPSession(host: host, client: client, sftp: sftp)
        } catch {
            try? await client.close()
            throw SFTPError.io("failed to open SFTP subsystem: \(error)")
        }
    }

    public func list(_ path: String) async throws -> [RemoteEntry] {
        let names: [SFTPMessage.Name]
        do {
            names = try await sftp.listDirectory(atPath: path)
        } catch {
            throw SFTPError.io("list failed: \(error)")
        }

        var entries: [RemoteEntry] = []
        for name in names {
            for component in name.components {
                let filename = component.filename
                if filename == "." || filename == ".." { continue }

                let attributes = component.attributes
                let isDirectory: Bool
                if let permissions = attributes.permissions {
                    isDirectory = (permissions & 0o170000) == 0o040000
                } else {
                    isDirectory = component.longname.hasPrefix("d")
                }
                let size = Int64(attributes.size ?? 0)
                let modified = attributes.accessModificationTime?.modificationTime
                    ?? Date(timeIntervalSince1970: 0)

                entries.append(RemoteEntry(
                    name: filename,
                    path: RemotePath.join(path, filename),
                    isDirectory: isDirectory,
                    size: size,
                    modified: modified
                ))
            }
        }
        return entries
    }

    public func download(_ remotePath: String, to localURL: URL) async throws {
        do {
            let file = try await sftp.openFile(filePath: remotePath, flags: .read)
            do {
                let buffer = try await file.readAll()
                try await file.close()
                let data = Data(buffer.readableBytesView)
                try data.write(to: localURL, options: .atomic)
            } catch {
                try? await file.close()
                throw error
            }
        } catch let error as SFTPError {
            throw error
        } catch {
            throw SFTPError.io("download failed: \(error)")
        }
    }

    public func upload(_ localURL: URL, to remotePath: String) async throws {
        let data: Data
        do {
            data = try Data(contentsOf: localURL)
        } catch {
            throw SFTPError.io("cannot read local file: \(error)")
        }

        do {
            let file = try await sftp.openFile(
                filePath: remotePath,
                flags: [.write, .create, .truncate]
            )
            do {
                try await file.write(ByteBuffer(bytes: data))
                try await file.close()
            } catch {
                try? await file.close()
                throw error
            }
        } catch let error as SFTPError {
            throw error
        } catch {
            throw SFTPError.io("upload failed: \(error)")
        }
    }

    public func disconnect() async {
        try? await sftp.close()
        try? await client.close()
    }

    // MARK: - Helpers

    private static func makeAuthMethod(
        username: String,
        auth: AuthInput
    ) throws -> SSHAuthenticationMethod {
        switch auth {
        case .password(let password):
            return .passwordBased(username: username, password: password)
        case .ed25519(let path):
            let pem: String
            do {
                pem = try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
            } catch {
                throw SFTPError.io("cannot read private key at \(path): \(error)")
            }
            let key: Curve25519.Signing.PrivateKey
            do {
                key = try Curve25519.Signing.PrivateKey(sshEd25519: pem)
            } catch {
                throw SFTPError.io("invalid ed25519 private key: \(error)")
            }
            return .ed25519(username: username, privateKey: key)
        }
    }

    private static func mapConnectError(_ error: Error) -> SFTPError {
        switch error {
        case let error as SSHClientError:
            switch error {
            case .allAuthenticationOptionsFailed,
                 .unsupportedPasswordAuthentication,
                 .unsupportedPrivateKeyAuthentication,
                 .unsupportedHostBasedAuthentication:
                return .authenticationFailed
            case .channelCreationFailed:
                return .connectionFailed
            }
        case is AuthenticationFailed:
            return .authenticationFailed
        default:
            let description = String(describing: error).lowercased()
            if description.contains("auth") { return .authenticationFailed }
            if description.contains("timeout") { return .timeout }
            return .connectionFailed
        }
    }
}

/// Bridges `HostKeyValidating` to NIOSSH's synchronous validation callback,
/// fulfilling the completion promise asynchronously once the (possibly
/// interactive) validator resolves.
private final class PolicyHostKeyDelegate: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let host: String
    private let port: Int
    private let validator: HostKeyValidating
    private let errorBox: NIOLockedValueBox<Error?>

    init(
        host: String,
        port: Int,
        validator: HostKeyValidating,
        errorBox: NIOLockedValueBox<Error?>
    ) {
        self.host = host
        self.port = port
        self.validator = validator
        self.errorBox = errorBox
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        var buffer = ByteBufferAllocator().buffer(capacity: 256)
        hostKey.write(to: &buffer)
        let blob = Data(buffer.readableBytesView)
        let keyType = Self.keyType(fromBlob: blob)

        let host = self.host
        let port = self.port
        let validator = self.validator
        let errorBox = self.errorBox

        Task {
            do {
                try await validator.validate(host: host, port: port, keyType: keyType, blob: blob)
                validationCompletePromise.succeed(())
            } catch {
                errorBox.withLockedValue { $0 = error }
                validationCompletePromise.fail(error)
            }
        }
    }

    /// Extracts the leading SSH wire-format type string (e.g. `ssh-ed25519`)
    /// from a public key blob: a 4-byte big-endian length followed by that many
    /// bytes of ASCII.
    static func keyType(fromBlob blob: Data) -> String {
        let bytes = [UInt8](blob)
        guard bytes.count >= 4 else { return "" }
        let length = (Int(bytes[0]) << 24) | (Int(bytes[1]) << 16) | (Int(bytes[2]) << 8) | Int(bytes[3])
        guard length > 0, bytes.count >= 4 + length else { return "" }
        return String(decoding: bytes[4 ..< (4 + length)], as: UTF8.self)
    }
}
