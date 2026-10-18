/// POSIX remote path helpers for SFTP.
///
/// Paths are plain `/`-separated strings. No percent-encoding is applied,
/// because SFTP carries paths as raw byte strings.
public enum RemotePath {
    /// Joins a single name onto a directory path.
    public static func join(_ base: String, _ name: String) -> String {
        base.hasSuffix("/") ? base + name : base + "/" + name
    }

    /// Returns the parent directory. The parent of `/` is `/`.
    public static func parent(_ path: String) -> String {
        let trimmed = trimTrailingSlashes(path)
        guard let slash = trimmed.lastIndex(of: "/"), slash != trimmed.startIndex else {
            return "/"
        }
        return String(trimmed[..<slash])
    }

    /// Returns the last path component.
    public static func name(of path: String) -> String {
        let trimmed = trimTrailingSlashes(path)
        guard let slash = trimmed.lastIndex(of: "/") else {
            return String(trimmed)
        }
        return String(trimmed[trimmed.index(after: slash)...])
    }

    private static func trimTrailingSlashes(_ path: String) -> Substring {
        var trimmed = Substring(path)
        while trimmed.count > 1 && trimmed.hasSuffix("/") {
            trimmed = trimmed.dropLast()
        }
        return trimmed
    }
}
