import Foundation

/// Errors thrown when reading a credential token from a file.
public enum BurnBarTokenFileError: Error, LocalizedError {
    case fileNotFound(path: String)
    case unreadable(path: String, encoding: String)
    case emptyOrWhitespace(path: String)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "Token file not found at path '\(path)'."
        case .unreadable(let path, let encoding):
            return "Token file at '\(path)' could not be decoded as \(encoding)."
        case .emptyOrWhitespace(let path):
            return "Token file at '\(path)' is empty or whitespace-only."
        }
    }
}

/// Reads a credential token from a file, trimming leading/trailing whitespace
/// and newlines. Used by `--gateway-auth-token-file` and
/// `--socket-auth-token-file` CLI flags to avoid exposing tokens in `ps`
/// output or the daemon's launchd plist arguments.
///
/// - Parameters:
///   - path: Filesystem path to the token file.
/// - Returns: The trimmed token string.
/// - Throws: `BurnBarTokenFileError` if the file is missing, unreadable,
///   or contains only whitespace.
public func readTokenFile(_ path: String) throws -> String {
    let url = URL(fileURLWithPath: path)
    guard let data = try? Data(contentsOf: url) else {
        throw BurnBarTokenFileError.fileNotFound(path: path)
    }
    guard let raw = String(data: data, encoding: .utf8) else {
        throw BurnBarTokenFileError.unreadable(path: path, encoding: "UTF-8")
    }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        throw BurnBarTokenFileError.emptyOrWhitespace(path: path)
    }
    return trimmed
}
