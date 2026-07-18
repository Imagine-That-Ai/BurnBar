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
import OpenBurnBarKernel

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
public enum ParserDeferredReason: String, Sendable {
    case byteBudget
    case metadataUnavailable
    case byteCountOverflow
    case contentReadFailed
}

public struct ParserPassMetricSnapshot: Sendable, Equatable {
    public let candidateCount: Int
    public let metadataStatCount: Int
    public let contentReadCount: Int
    public let contentReadBytes: Int64
    public let deferredFileCount: Int
    public let byteBudgetDeferredCount: Int
    public let metadataUnavailableDeferredCount: Int
    public let byteCountOverflowDeferredCount: Int
    public let contentReadFailedDeferredCount: Int
    public let elapsedMilliseconds: Double
}

/// Lock-backed, allocation-free counters for one parser pass. The recorder
/// never accepts paths or content, so production telemetry cannot leak either.
public final class ParserPassMetrics: Sendable {
    private struct State: Sendable {
        var candidateCount = 0
        var metadataStatCount = 0
        var contentReadCount = 0
        var contentReadBytes: Int64 = 0
        var byteBudgetDeferredCount = 0
        var metadataUnavailableDeferredCount = 0
        var byteCountOverflowDeferredCount = 0
        var contentReadFailedDeferredCount = 0
    }

    private let startedAt = ContinuousClock.now
    private let state = Locked(State())

    public init() {}

    public func recordCandidate(count: Int = 1) {
        guard count > 0 else { return }
        state.withLock { $0.candidateCount += count }
    }

    public func recordMetadataStat(count: Int = 1) {
        guard count > 0 else { return }
        state.withLock { $0.metadataStatCount += count }
    }

    public func recordContentRead(count: Int = 1, bytes: Int64) {
        guard count > 0 else { return }
        state.withLock { state in
            state.contentReadCount += count
            state.contentReadBytes += max(0, bytes)
        }
    }

    public func recordDeferred(_ reason: ParserDeferredReason) {
        state.withLock { state in
            switch reason {
            case .byteBudget:
                state.byteBudgetDeferredCount += 1
            case .metadataUnavailable:
                state.metadataUnavailableDeferredCount += 1
            case .byteCountOverflow:
                state.byteCountOverflowDeferredCount += 1
            case .contentReadFailed:
                state.contentReadFailedDeferredCount += 1
            }
        }
    }

    public func snapshot() -> ParserPassMetricSnapshot {
        let counters = state.withLock { $0 }
        let elapsed = startedAt.duration(to: ContinuousClock.now).components
        let elapsedMilliseconds = Double(elapsed.seconds) * 1_000
            + Double(elapsed.attoseconds) / 1_000_000_000_000_000
        let deferredFileCount = counters.byteBudgetDeferredCount
            + counters.metadataUnavailableDeferredCount
            + counters.byteCountOverflowDeferredCount
            + counters.contentReadFailedDeferredCount
        return ParserPassMetricSnapshot(
            candidateCount: counters.candidateCount,
            metadataStatCount: counters.metadataStatCount,
            contentReadCount: counters.contentReadCount,
            contentReadBytes: counters.contentReadBytes,
            deferredFileCount: deferredFileCount,
            byteBudgetDeferredCount: counters.byteBudgetDeferredCount,
            metadataUnavailableDeferredCount: counters.metadataUnavailableDeferredCount,
            byteCountOverflowDeferredCount: counters.byteCountOverflowDeferredCount,
            contentReadFailedDeferredCount: counters.contentReadFailedDeferredCount,
            elapsedMilliseconds: elapsedMilliseconds
        )
    }
}

public struct ParserFileReadGate {
    public let options: LogParseOptions
    public let fileManager: FileManager

    public init(options: LogParseOptions, fileManager: FileManager = .default) {
        self.options = options
        self.fileManager = fileManager
    }

    public func shouldRead(_ file: URL, fallbackModificationDate: Date? = nil) throws -> Bool {
        try options.resourceGovernor?.checkpoint()
        options.metrics?.recordCandidate()
        options.metrics?.recordMetadataStat()

        let attributes = try? fileManager.attributesOfItem(atPath: file.path)
        let modificationDate = attributes?[.modificationDate] as? Date ?? fallbackModificationDate
        if let boundary = options.minimumFileModificationDate {
            guard let modificationDate else {
                recordDeferred(.metadataUnavailable)
                return false
            }
            guard modificationDate >= boundary else { return false }
        }

        let size = (attributes?[.size] as? NSNumber)?.int64Value
        guard let governor = options.resourceGovernor else {
            options.metrics?.recordContentRead(bytes: max(0, size ?? 0))
            return true
        }
        guard let size else {
            recordDeferred(.metadataUnavailable)
            return false
        }
        let admittedBytes = max(0, size)
        guard governor.admitFile(estimatedBytes: admittedBytes) else {
            options.metrics?.recordDeferred(.byteBudget)
            return false
        }
        options.metrics?.recordContentRead(bytes: admittedBytes)
        return true
    }

    /// Atomically admits the files needed to parse one logical session. This
    /// avoids consuming the budget on a sidecar and then deferring its primary
    /// transcript forever on every subsequent pass. A session crosses the
    /// modification boundary when any of its inputs changed; older sidecars do
    /// not suppress a newer primary transcript.
    public func shouldRead(_ files: [URL], candidateAlreadyRecorded: Bool = false) throws -> Bool {
        guard !files.isEmpty else { return true }
        try options.resourceGovernor?.checkpoint()
        if !candidateAlreadyRecorded {
            options.metrics?.recordCandidate()
        }

        var totalBytes: Int64 = 0
        var boundaryPassed = options.minimumFileModificationDate == nil
        for file in files {
            options.metrics?.recordMetadataStat()
            let attributes = try? fileManager.attributesOfItem(atPath: file.path)
            if let boundary = options.minimumFileModificationDate {
                guard let modificationDate = attributes?[.modificationDate] as? Date else {
                    recordDeferred(.metadataUnavailable)
                    return false
                }
                if modificationDate >= boundary {
                    boundaryPassed = true
                }
            }

            if options.resourceGovernor != nil {
                guard let size = attributes?[.size] as? NSNumber else {
                    recordDeferred(.metadataUnavailable)
                    return false
                }
                let (sum, overflow) = totalBytes.addingReportingOverflow(max(0, size.int64Value))
                guard !overflow else {
                    recordDeferred(.byteCountOverflow)
                    return false
                }
                totalBytes = sum
            }
        }

        guard boundaryPassed else { return false }
        guard let governor = options.resourceGovernor else {
            options.metrics?.recordContentRead(count: files.count, bytes: totalBytes)
            return true
        }
        guard governor.admitFile(estimatedBytes: totalBytes) else {
            options.metrics?.recordDeferred(.byteBudget)
            return false
        }
        options.metrics?.recordContentRead(count: files.count, bytes: totalBytes)
        return true
    }

    private func recordDeferred(_ reason: ParserDeferredReason) {
        options.resourceGovernor?.recordDeferredFile()
        options.metrics?.recordDeferred(reason)
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
