@testable import Citadel
import Crypto
import Foundation
import NIO
import NIOSSH

/// In-process SSH (and optionally SFTP) server on 127.0.0.1 for integration tests.
/// Backed by Citadel's `SSHServer`; generates a fresh Ed25519 host key per instance.
final class LoopbackSSHServer: @unchecked Sendable {
    private let username: String
    private let password: String
    private let authorizedKey: NIOSSHPublicKey?
    private let sftpDelegate: SFTPDelegate?
    private let hostPrivateKey = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey())
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private var server: SSHServer?

    /// The server's own host key, for asserting fingerprints.
    var hostKey: NIOSSHPublicKey { hostPrivateKey.publicKey }

    init(
        username: String,
        password: String,
        authorizedEd25519PublicKey: NIOSSHPublicKey?,
        sftpDelegate: SFTPDelegate? = nil
    ) {
        self.username = username
        self.password = password
        self.authorizedKey = authorizedEd25519PublicKey
        self.sftpDelegate = sftpDelegate
    }

    /// Starts listening on an OS-assigned loopback port and returns it.
    func start() async throws -> Int {
        var methods: NIOSSHAvailableUserAuthenticationMethods = .password
        if authorizedKey != nil { methods.insert(.publicKey) }
        let expectedUser = username, expectedPassword = password, expectedKey = authorizedKey
        let auth = LoopbackAuthDelegate(methods: methods) { request, promise in
            guard request.username == expectedUser else { return promise.succeed(.failure) }
            switch request.request {
            case .password(let p) where p.password == expectedPassword:
                promise.succeed(.success)
            case .publicKey(let k) where expectedKey != nil && k.publicKey == expectedKey:
                promise.succeed(.success)
            default:
                promise.succeed(.failure)
            }
        }
        let server = try await SSHServer.host(
            host: "127.0.0.1",
            port: 0,
            hostKeys: [hostPrivateKey],
            authenticationDelegate: auth,
            group: group
        )
        if let sftpDelegate { server.enableSFTP(withDelegate: sftpDelegate) }
        self.server = server
        guard let port = server.channel.localAddress?.port else {
            throw LoopbackError.noPort
        }
        return port
    }

    func stop() async {
        try? await server?.close()
        server = nil
        try? await group.shutdownGracefully()
    }

    enum LoopbackError: Error { case noPort }
}

private final class LoopbackAuthDelegate: NIOSSHServerUserAuthenticationDelegate {
    let supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods
    let handle: @Sendable (NIOSSHUserAuthenticationRequest, EventLoopPromise<NIOSSHUserAuthenticationOutcome>) -> Void

    init(
        methods: NIOSSHAvailableUserAuthenticationMethods,
        handle: @escaping @Sendable (NIOSSHUserAuthenticationRequest, EventLoopPromise<NIOSSHUserAuthenticationOutcome>) -> Void
    ) {
        self.supportedAuthenticationMethods = methods
        self.handle = handle
    }

    func requestReceived(
        request: NIOSSHUserAuthenticationRequest,
        responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>
    ) {
        handle(request, responsePromise)
    }
}

/// Minimal read-only SFTP delegate: one fixed directory listing ("/" containing hello.txt).
/// Just enough to prove the loopback server can carry the SFTP subsystem.
enum StubError: Error { case unsupported }

struct StubSFTPDelegate: SFTPDelegate {
    private struct Dir: SFTPDirectoryHandle {
        func listFiles(context: SSHContext) async throws -> [SFTPFileListing] {
            [SFTPFileListing(path: [
                SFTPPathComponent(filename: "hello.txt", longname: "-rw-r--r-- 1 u u 5 Jan 1 00:00 hello.txt", attributes: SFTPFileAttributes()),
            ])]
        }
    }

    func fileAttributes(atPath path: String, context: SSHContext) async throws -> SFTPFileAttributes { SFTPFileAttributes() }
    func openFile(_ filePath: String, withAttributes: SFTPFileAttributes, flags: SFTPOpenFileFlags, context: SSHContext) async throws -> SFTPFileHandle { throw StubError.unsupported }
    func removeFile(_ filePath: String, context: SSHContext) async throws -> SFTPStatusCode { .permissionDenied }
    func createDirectory(_ filePath: String, withAttributes: SFTPFileAttributes, context: SSHContext) async throws -> SFTPStatusCode { .permissionDenied }
    func removeDirectory(_ filePath: String, context: SSHContext) async throws -> SFTPStatusCode { .permissionDenied }
    func realPath(for canonicalUrl: String, context: SSHContext) async throws -> [SFTPPathComponent] {
        [SFTPPathComponent(filename: "/", longname: "/", attributes: SFTPFileAttributes())]
    }
    func openDirectory(atPath path: String, context: SSHContext) async throws -> SFTPDirectoryHandle { Dir() }
    func setFileAttributes(to attributes: SFTPFileAttributes, atPath path: String, context: SSHContext) async throws -> SFTPStatusCode { .permissionDenied }
    func addSymlink(linkPath: String, targetPath: String, context: SSHContext) async throws -> SFTPStatusCode { .permissionDenied }
    func readSymlink(atPath path: String, context: SSHContext) async throws -> [SFTPPathComponent] { throw StubError.unsupported }
    func rename(oldPath: String, newPath: String, flags: UInt32, context: SSHContext) async throws -> SFTPStatusCode { .permissionDenied }
}
