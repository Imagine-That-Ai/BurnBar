import Foundation

// MARK: - Cross-Platform Autorelease Pool

/// Runs `body` inside an autorelease pool on Darwin and directly on
/// non-Darwin platforms (Linux/Windows), where the Swift runtime has no
/// autorelease pool to drain.
///
/// Log parsers iterate millions of JSONL lines inside dispatch blocks that
/// never drain, and per-line `JSONSerialization` object graphs are
/// autoreleased on Darwin. Wrapping each line keeps the Darwin footprint
/// bounded; on Linux/Windows the closure runs inline (there is no autorelease
/// pool, and the runtime does not accumulate autoreleased backing storage the
/// way the Objective-C runtime does). Generic return and `rethrows` semantics
/// are preserved so the helper is a drop-in for every call shape.
@inlinable
public func parserAutoReleasePool<Result>(
    _ body: () throws -> Result
) rethrows -> Result {
    #if canImport(Darwin)
    return try autoreleasepool(invoking: body)
    #else
    return try body()
    #endif
}

// MARK: - Parser Scan Support

/// Digest helpers shared by the incremental JSONL scanners (Codex rollouts,
/// Claude Code transcripts).
///
/// FNV-1a 64 is used for file-rewrite detection and usage-key dedupe sets.
/// These are integrity heuristics on trusted local files, not security
/// boundaries — collision odds at the observed set sizes are negligible, and
/// the failure mode of a head-digest collision is one redundant full re-scan.
/// Applies the incremental boundary and the shared byte/memory governor before
/// a parser opens a content-bearing file. Metadata-only directory enumeration
/// remains uncharged; every admitted file is accounted exactly once by its
/// caller before the first content read.
struct ParserFileReadGate {
    let options: LogParseOptions
    let fileManager: FileManager

    init(options: LogParseOptions, fileManager: FileManager = .default) {
        self.options = options
        self.fileManager = fileManager
    }

    func shouldRead(_ file: URL, fallbackModificationDate: Date? = nil) throws -> Bool {
        try options.resourceGovernor?.checkpoint()

        let attributes = try? fileManager.attributesOfItem(atPath: file.path)
        let modificationDate = attributes?[.modificationDate] as? Date ?? fallbackModificationDate
        if let boundary = options.minimumFileModificationDate {
            guard let modificationDate else {
                options.resourceGovernor?.recordDeferredFile()
                return false
            }
            guard modificationDate >= boundary else { return false }
        }

        guard let governor = options.resourceGovernor else { return true }
        guard let size = attributes?[.size] as? NSNumber else {
            governor.recordDeferredFile()
            return false
        }
        return governor.admitFile(estimatedBytes: max(0, size.int64Value))
    }

    /// Atomically admits the files needed to parse one logical session. This
    /// avoids consuming the budget on a sidecar and then deferring its primary
    /// transcript forever on every subsequent pass.
    func shouldRead(_ files: [URL]) throws -> Bool {
        guard !files.isEmpty else { return true }
        try options.resourceGovernor?.checkpoint()

        var totalBytes: Int64 = 0
        for file in files {
            let attributes = try? fileManager.attributesOfItem(atPath: file.path)
            if let boundary = options.minimumFileModificationDate {
                guard let modificationDate = attributes?[.modificationDate] as? Date else {
                    options.resourceGovernor?.recordDeferredFile()
                    return false
                }
                guard modificationDate >= boundary else { return false }
            }

            if options.resourceGovernor != nil {
                guard let size = attributes?[.size] as? NSNumber else {
                    options.resourceGovernor?.recordDeferredFile()
                    return false
                }
                let (sum, overflow) = totalBytes.addingReportingOverflow(max(0, size.int64Value))
                guard !overflow else {
                    options.resourceGovernor?.recordDeferredFile()
                    return false
                }
                totalBytes = sum
            }
        }

        guard let governor = options.resourceGovernor else { return true }
        return governor.admitFile(estimatedBytes: totalBytes)
    }
}

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
        // Pool the autoreleased NSData-backed read (see BufferedLineReader).
        return parserAutoReleasePool {
            fnv1a64Hex(handle.readData(ofLength: length))
        }
    }
}
