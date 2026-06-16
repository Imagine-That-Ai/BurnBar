import Foundation

// MARK: - Parser Input Limits (DoS hardening)

/// Shared, pre-flight resource bounds for local log parsers.
///
/// Several provider parsers read entire on-disk files with `Data(contentsOf:)`
/// (or `FileHandle.readDataToEndOfFile()`) and recurse over decoded JSON without
/// a bound. A maliciously huge or deeply-nested file dropped into a watched
/// directory (`~/.claude`, `~/.codex`, `~/.gemini`, `~/.cursor`, `~/.openclaw`,
/// …) can therefore exhaust memory or blow the stack before any parsing logic
/// runs. These limits add a cheap pre-flight `stat()` check before the read and
/// a recursion-depth ceiling for the JSON flatten walk.
enum ParserInputLimits {
    /// Maximum on-disk size (bytes) a parser will read into memory in one shot.
    ///
    /// 64 MiB comfortably exceeds any legitimate single session/log file we have
    /// observed (multi-megabyte at the extreme) while bounding worst-case memory
    /// for one file. Files above this are skipped rather than read.
    static let maxFileSizeBytes: UInt64 = 64 * 1024 * 1024

    /// Maximum nesting depth the recursive JSON object flatten will descend.
    ///
    /// Real session transcripts nest a handful of levels deep; 64 leaves ample
    /// headroom for legitimate documents while preventing unbounded recursion
    /// (and stack exhaustion) on adversarially nested arrays/objects.
    static let maxJSONDepth = 64

    /// Typed error thrown when a candidate file exceeds `maxFileSizeBytes`.
    struct FileTooLarge: Error {
        let path: String
        let sizeBytes: UInt64
        let limitBytes: UInt64
    }

    /// Reads a file's contents only after a pre-flight size check.
    ///
    /// Throws `FileTooLarge` when the file is larger than `maxFileSizeBytes`, so
    /// the call site never allocates the full buffer for an oversized file.
    /// Other read/stat failures propagate as their underlying `Error`.
    ///
    /// - Parameters:
    ///   - path: Absolute filesystem path to read.
    ///   - fileManager: Injected for testability; defaults to `.default`.
    /// - Returns: The file contents, guaranteed at most `maxFileSizeBytes`.
    static func guardedContents(
        ofFile path: String,
        fileManager: FileManager = .default
    ) throws -> Data {
        let size = (try fileManager.attributesOfItem(atPath: path)[.size] as? NSNumber)?.uint64Value ?? 0
        guard size <= maxFileSizeBytes else {
            throw FileTooLarge(path: path, sizeBytes: size, limitBytes: maxFileSizeBytes)
        }
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }

    /// Optional-returning convenience that matches the `try? … else { return nil }`
    /// skip convention used by most parsers: returns `nil` when the file is
    /// missing, unreadable, or exceeds `maxFileSizeBytes`.
    static func boundedContents(
        of url: URL,
        fileManager: FileManager = .default
    ) -> Data? {
        try? guardedContents(ofFile: url.path, fileManager: fileManager)
    }

    /// Returns `true` while `depth` is still within `maxJSONDepth`, i.e. the
    /// recursive walk may descend one more level.
    static func depthWithinLimit(_ depth: Int) -> Bool {
        depth < maxJSONDepth
    }
}
