import Citadel
import Foundation
import NIO

/// An `SFTPDelegate` backed by a real temporary directory on disk.
///
/// Remote POSIX paths are canonicalized and mapped under `root`. Enough of the
/// protocol is implemented to drive list / download / upload integration tests
/// against an actual filesystem, including real file handles for read and write.
struct TempDirSFTPDelegate: SFTPDelegate {
    let root: URL

    init(root: URL) {
        self.root = root
    }

    // MARK: Path mapping

    /// Canonicalizes a remote path into an absolute, slash-normalized form.
    /// Idempotent, so the client's `realpath` fixed-point loop terminates.
    fileprivate func canonical(_ remotePath: String) -> String {
        if remotePath.isEmpty || remotePath == "." { return "/" }
        var components: [String] = []
        for part in remotePath.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".":
                continue
            case "..":
                if !components.isEmpty { components.removeLast() }
            default:
                components.append(String(part))
            }
        }
        return "/" + components.joined(separator: "/")
    }

    fileprivate func localURL(_ remotePath: String) -> URL {
        let canonicalPath = canonical(remotePath)
        guard canonicalPath != "/" else { return root }
        var url = root
        for part in canonicalPath.split(separator: "/", omittingEmptySubsequences: true) {
            url.appendPathComponent(String(part))
        }
        return url
    }

    fileprivate func attributes(for url: URL) -> SFTPFileAttributes {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)

        var size: UInt64 = 0
        var modified = Date(timeIntervalSince1970: 0)
        if exists, let diskAttributes = try? fileManager.attributesOfItem(atPath: url.path) {
            if let number = diskAttributes[.size] as? NSNumber { size = number.uint64Value }
            if let date = diskAttributes[.modificationDate] as? Date { modified = date }
        }

        var attributes = SFTPFileAttributes()
        attributes.size = isDirectory.boolValue ? 0 : size
        // Carry the POSIX file-type bits in `permissions` so the client can tell
        // directories from regular files, matching how real SFTP servers report.
        attributes.permissions = isDirectory.boolValue ? (0o040000 | 0o755) : (0o100000 | 0o644)
        attributes.accessModificationTime = .init(accessTime: modified, modificationTime: modified)
        return attributes
    }

    fileprivate func longname(for url: URL, name: String) -> String {
        var isDirectory: ObjCBool = false
        _ = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        let typeChar = isDirectory.boolValue ? "d" : "-"
        let permissions = isDirectory.boolValue ? "rwxr-xr-x" : "rw-r--r--"
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)??.intValue ?? 0
        return "\(typeChar)\(permissions) 1 ferry ferry \(size) Jan 1 00:00 \(name)"
    }

    // MARK: SFTPDelegate

    func fileAttributes(atPath path: String, context: SSHContext) async throws -> SFTPFileAttributes {
        attributes(for: localURL(path))
    }

    func openFile(
        _ filePath: String,
        withAttributes: SFTPFileAttributes,
        flags: SFTPOpenFileFlags,
        context: SSHContext
    ) async throws -> SFTPFileHandle {
        let url = localURL(filePath)
        if flags.contains(.write) || flags.contains(.append) {
            let fileManager = FileManager.default
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if flags.contains(.truncate) || !fileManager.fileExists(atPath: url.path) {
                fileManager.createFile(atPath: url.path, contents: Data())
            }
            return try TempFileHandle(writingTo: url)
        } else {
            return try TempFileHandle(readingFrom: url)
        }
    }

    func removeFile(_ filePath: String, context: SSHContext) async throws -> SFTPStatusCode {
        do { try FileManager.default.removeItem(at: localURL(filePath)); return .ok }
        catch { return .failure }
    }

    func createDirectory(
        _ filePath: String,
        withAttributes: SFTPFileAttributes,
        context: SSHContext
    ) async throws -> SFTPStatusCode {
        do {
            try FileManager.default.createDirectory(
                at: localURL(filePath),
                withIntermediateDirectories: true
            )
            return .ok
        } catch { return .failure }
    }

    func removeDirectory(_ filePath: String, context: SSHContext) async throws -> SFTPStatusCode {
        do { try FileManager.default.removeItem(at: localURL(filePath)); return .ok }
        catch { return .failure }
    }

    func realPath(for canonicalUrl: String, context: SSHContext) async throws -> [SFTPPathComponent] {
        let canonicalPath = canonical(canonicalUrl)
        return [SFTPPathComponent(
            filename: canonicalPath,
            longname: canonicalPath,
            attributes: attributes(for: localURL(canonicalPath))
        )]
    }

    func openDirectory(atPath path: String, context: SSHContext) async throws -> SFTPDirectoryHandle {
        TempDirectoryHandle(url: localURL(path), delegate: self)
    }

    func setFileAttributes(
        to attributes: SFTPFileAttributes,
        atPath path: String,
        context: SSHContext
    ) async throws -> SFTPStatusCode {
        .ok
    }

    func addSymlink(
        linkPath: String,
        targetPath: String,
        context: SSHContext
    ) async throws -> SFTPStatusCode {
        .unsupportedOperation
    }

    func readSymlink(atPath path: String, context: SSHContext) async throws -> [SFTPPathComponent] {
        throw TempDirSFTPError.unsupported
    }

    func rename(
        oldPath: String,
        newPath: String,
        flags: UInt32,
        context: SSHContext
    ) async throws -> SFTPStatusCode {
        do { try FileManager.default.moveItem(at: localURL(oldPath), to: localURL(newPath)); return .ok }
        catch { return .failure }
    }
}

enum TempDirSFTPError: Error { case unsupported }

/// Lists a directory's contents as SFTP path components (one listing message
/// carrying every entry, which the server drains into a single readdir reply).
private struct TempDirectoryHandle: SFTPDirectoryHandle {
    let url: URL
    let delegate: TempDirSFTPDelegate

    func listFiles(context: SSHContext) async throws -> [SFTPFileListing] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: []
        )) ?? []

        let components = entries
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { entry in
                SFTPPathComponent(
                    filename: entry.lastPathComponent,
                    longname: delegate.longname(for: entry, name: entry.lastPathComponent),
                    attributes: delegate.attributes(for: entry)
                )
            }

        return [SFTPFileListing(path: components)]
    }
}

/// A real file-backed SFTP file handle supporting positional read and write.
private final class TempFileHandle: SFTPFileHandle, @unchecked Sendable {
    private let fileHandle: FileHandle
    private let url: URL

    init(readingFrom url: URL) throws {
        self.url = url
        self.fileHandle = try FileHandle(forReadingFrom: url)
    }

    init(writingTo url: URL) throws {
        self.url = url
        self.fileHandle = try FileHandle(forWritingTo: url)
    }

    func read(at offset: UInt64, length: UInt32) async throws -> ByteBuffer {
        try fileHandle.seek(toOffset: offset)
        let data = try fileHandle.read(upToCount: Int(length)) ?? Data()
        return ByteBuffer(bytes: data)
    }

    func write(_ data: ByteBuffer, atOffset offset: UInt64) async throws -> SFTPStatusCode {
        do {
            try fileHandle.seek(toOffset: offset)
            try fileHandle.write(contentsOf: Data(data.readableBytesView))
            return .ok
        } catch {
            return .failure
        }
    }

    func close() async throws -> SFTPStatusCode {
        do { try fileHandle.close(); return .ok }
        catch { return .failure }
    }

    func readFileAttributes() async throws -> SFTPFileAttributes {
        var attributes = SFTPFileAttributes()
        let diskAttributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        attributes.size = (diskAttributes?[.size] as? NSNumber)?.uint64Value ?? 0
        attributes.permissions = 0o100000 | 0o644
        if let modified = diskAttributes?[.modificationDate] as? Date {
            attributes.accessModificationTime = .init(accessTime: modified, modificationTime: modified)
        }
        return attributes
    }

    func setFileAttributes(to attributes: SFTPFileAttributes) async throws {}
}
