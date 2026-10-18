import Foundation

public enum HostKeyDecision: Equatable {
    case unknown(fingerprint: String)
    case match
    case changed(fingerprint: String)
}

/// OpenSSH-compatible known_hosts file with trust-on-first-use decisions.
public struct KnownHostsStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// `~/Library/Application Support/Ferry/known_hosts`.
    public static func defaultFileURL() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return support.appendingPathComponent("Ferry", isDirectory: true)
            .appendingPathComponent("known_hosts")
    }

    /// Any recorded key for this host:port that differs from the presented one yields `.changed`
    /// (including a different key type), never `.match` or `.unknown`.
    public func decision(host: String, port: Int, keyType: String, blob: Data) throws -> HostKeyDecision {
        let fingerprint = sha256Fingerprint(keyType: keyType, blob: blob)
        let pattern = Self.hostPattern(host: host, port: port)
        var sawHost = false
        for line in try readLines() {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard fields.count >= 3, !fields[0].hasPrefix("#") else { continue }
            guard fields[0].split(separator: ",").contains(where: { $0 == pattern }) else { continue }
            sawHost = true
            if fields[1] == keyType, Data(base64Encoded: fields[2]) == blob { return .match }
        }
        return sawHost ? .changed(fingerprint: fingerprint) : .unknown(fingerprint: fingerprint)
    }

    /// Appends a record; creates the file and parent directory if missing.
    public func trust(host: String, port: Int, keyType: String, blob: Data) throws {
        let line = "\(Self.hostPattern(host: host, port: port)) \(keyType) \(blob.base64EncodedString())\n"
        let fm = FileManager.default
        try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var existing = Data()
        if fm.fileExists(atPath: fileURL.path) { existing = try Data(contentsOf: fileURL) }
        if let last = existing.last, last != UInt8(ascii: "\n") { existing.append(UInt8(ascii: "\n")) }
        existing.append(Data(line.utf8))
        try existing.write(to: fileURL, options: .atomic)
    }

    /// Forgets a host:port so the next connection prompts again. Only lines naming this exact
    /// host:port are touched (host compared case-insensitively); a comma-separated host list keeps
    /// its other patterns. All other lines are written back byte-for-byte. Missing file is a no-op.
    public func remove(host: String, port: Int) throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let target = Self.hostPattern(host: host, port: port).lowercased()
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        var changed = false
        var out: [String] = []
        for line in text.components(separatedBy: "\n") {
            guard let range = line.range(of: "^[^ \t]+", options: .regularExpression),
                  !line.hasPrefix("#") else { out.append(line); continue }
            let patterns = line[range].split(separator: ",", omittingEmptySubsequences: false)
            let kept = patterns.filter { $0.lowercased() != target }
            if kept.count == patterns.count { out.append(line); continue }
            changed = true
            if kept.isEmpty { continue }
            out.append(kept.joined(separator: ",") + line[range.upperBound...])
        }
        guard changed else { return }
        try out.joined(separator: "\n").write(to: fileURL, atomically: true, encoding: .utf8)
    }

    private static func hostPattern(host: String, port: Int) -> String {
        port == 22 ? host : "[\(host)]:\(port)"
    }

    private func readLines() throws -> [String] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        return try String(contentsOf: fileURL, encoding: .utf8).components(separatedBy: .newlines)
    }
}
