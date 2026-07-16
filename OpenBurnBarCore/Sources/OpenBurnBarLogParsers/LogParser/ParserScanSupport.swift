import Foundation

// MARK: - Parser Scan Support

enum ParserAutoreleasePool {
    @inline(__always)
    static func run<Result>(_ body: () throws -> Result) rethrows -> Result {
        #if canImport(ObjectiveC)
        return try autoreleasepool(invoking: body)
        #else
        return try body()
        #endif
    }
}

/// Digest helpers shared by the incremental JSONL scanners (Codex rollouts,
/// Claude Code transcripts).
///
/// FNV-1a 64 is used for file-rewrite detection and usage-key dedupe sets.
/// These are integrity heuristics on trusted local files, not security
/// boundaries — collision odds at the observed set sizes are negligible, and
/// the failure mode of a head-digest collision is one redundant full re-scan.
enum ParserScanDigest {
    static func fnv1a64(_ data: Data) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    static func fnv1a64(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    static func fnv1a64Hex(_ data: Data) -> String {
        String(format: "%016llx", fnv1a64(data))
    }

    /// Digest of the file's first `length` bytes. Leaves the handle's offset
    /// at `length` — callers must seek afterwards.
    static func headDigestHex(handle: FileHandle, length: Int) -> String {
        guard length > 0 else { return fnv1a64Hex(Data()) }
        try? handle.seek(toOffset: 0) // try?-ok(seek 0 before head read)
        // Pool the NSData-backed read on Objective-C platforms.
        return ParserAutoreleasePool.run {
            fnv1a64Hex(handle.readData(ofLength: length))
        }
    }
}
