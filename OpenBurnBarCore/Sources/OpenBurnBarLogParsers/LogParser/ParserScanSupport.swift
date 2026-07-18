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

/// Stable metadata identity for one parser input. The path distinguishes a
/// restored or copied transcript from files already present at the checkpoint;
/// inode metadata also catches same-path replacement when the filesystem
/// exposes it. Content is never retained.
public struct ParserDiscoveredFile: Codable, Hashable, Sendable {
    public let path: String
    public let fileSizeBytes: Int64?
    public let modificationDate: Date?
    public let creationDate: Date?
    public let fileSystemNumber: UInt64?
    public let fileNumber: UInt64?

    public init(
        path: String,
        fileSizeBytes: Int64?,
        modificationDate: Date?,
        creationDate: Date?,
        fileSystemNumber: UInt64?,
        fileNumber: UInt64?
    ) {
        self.path = path
        self.fileSizeBytes = fileSizeBytes
        self.modificationDate = modificationDate
        self.creationDate = creationDate
        self.fileSystemNumber = fileSystemNumber
        self.fileNumber = fileNumber
    }
    static func capture(
        for file: URL,
        attributes: [FileAttributeKey: Any]?,
        fallbackModificationDate: Date? = nil
    ) -> ParserDiscoveredFile {
        ParserDiscoveredFile(
            path: file.standardizedFileURL.path,
            fileSizeBytes: (attributes?[.size] as? NSNumber)?.int64Value,
            modificationDate: attributes?[.modificationDate] as? Date ?? fallbackModificationDate,
            creationDate: attributes?[.creationDate] as? Date,
            fileSystemNumber: (attributes?[.systemNumber] as? NSNumber)?.uint64Value,
            fileNumber: (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value
        )
    }
}

/// Records the current scan's metadata identities and identifies candidates
/// absent or changed since the last successful checkpoint. Immutable known
/// state plus a lock-backed path map keeps concurrent parser scans safe.
public final class ParserFileDiscoveryTracker: Sendable {
    private struct State: Sendable {
        var observedFilesByPath: [String: ParserDiscoveredFile] = [:]
        var admittedFilesByPath: [String: ParserDiscoveredFile] = [:]
    }

    private let knownFilesByPath: [String: ParserDiscoveredFile]
    private let state = Locked(State())

    public init(knownFiles: [ParserDiscoveredFile] = []) {
        self.knownFilesByPath = knownFiles.reduce(into: [:]) { filesByPath, file in
            filesByPath[file.path] = file
        }
    }

    /// Returns true when the path was absent or its metadata identity changed
    /// since the last successful or partial checkpoint.
    @discardableResult
    public func record(_ file: ParserDiscoveredFile) -> Bool {
        state.withLock { $0.observedFilesByPath[file.path] = file }
        return knownFilesByPath[file.path] != file
    }

    func wasKnownAtCheckpoint(_ file: ParserDiscoveredFile) -> Bool {
        knownFilesByPath[file.path] == file
    }

    /// Marks an input whose content was admitted during this pass. These files
    /// may be persisted after a budget-limited partial pass once their parsed
    /// conversations have committed, allowing the next pass to make progress.
    func recordAdmitted(_ file: ParserDiscoveredFile) {
        state.withLock { $0.admittedFilesByPath[file.path] = file }
    }

    /// Removes an admitted identity when the parser later discovers that the
    /// corresponding content could not be read successfully.
    func recordDeferred(_ file: ParserDiscoveredFile) {
        state.withLock { _ = $0.admittedFilesByPath.removeValue(forKey: file.path) }
    }

    /// Exact identities observed by a complete pass. Missing paths are removed
    /// from the next successful checkpoint manifest.
    public var discoveredFiles: [ParserDiscoveredFile] {
        state.withLock { parserState in
            parserState.observedFilesByPath.values.sorted { $0.path < $1.path }
        }
    }

    /// Safe progress after a deferred pass: retain the prior manifest and merge
    /// only inputs admitted during this pass. Observed-but-deferred identities
    /// remain absent or stale so the next pass retries them.
    public var partialCheckpointFiles: [ParserDiscoveredFile] {
        state.withLock { parserState in
            var filesByPath = knownFilesByPath
            for file in parserState.admittedFilesByPath.values {
                filesByPath[file.path] = file
            }
            return filesByPath.values.sorted { $0.path < $1.path }
        }
    }

    public var hasAdmittedFiles: Bool {
        state.withLock { !$0.admittedFilesByPath.isEmpty }
    }
}

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
        let identity = ParserDiscoveredFile.capture(
            for: file,
            attributes: attributes,
            fallbackModificationDate: fallbackModificationDate
        )
        let isNewlyDiscovered = options.fileDiscoveryTracker?.record(identity) ?? false

        // A tracker identity is stronger than the wall-clock watermark. Exact
        // known inputs were already committed; absent or changed inputs must be
        // admitted even when a copied file preserves an old modification date.
        if options.fileDiscoveryTracker != nil, !isNewlyDiscovered {
            return false
        }
        if options.fileDiscoveryTracker == nil, let boundary = options.minimumFileModificationDate {
            guard let modificationDate else {
                recordDeferred(.metadataUnavailable)
                return false
            }
            guard modificationDate >= boundary else { return false }
        }

        let admitted = try admitFile(withSize: identity.fileSizeBytes)
        if admitted {
            options.fileDiscoveryTracker?.recordAdmitted(identity)
        }
        return admitted
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

        var identities: [ParserDiscoveredFile] = []
        identities.reserveCapacity(files.count)
        var totalBytes: Int64 = 0
        var boundaryPassed = options.fileDiscoveryTracker == nil
            && options.minimumFileModificationDate == nil
        for file in files {
            options.metrics?.recordMetadataStat()
            let attributes = try? fileManager.attributesOfItem(atPath: file.path)
            let identity = ParserDiscoveredFile.capture(
                for: file,
                attributes: attributes
            )
            identities.append(identity)
            let isNewlyDiscovered = options.fileDiscoveryTracker?.record(identity) ?? false
            if isNewlyDiscovered {
                boundaryPassed = true
            }
            if options.fileDiscoveryTracker == nil,
               let boundary = options.minimumFileModificationDate,
               let modificationDate = identity.modificationDate,
               modificationDate >= boundary {
                boundaryPassed = true
            } else if options.fileDiscoveryTracker == nil,
                      options.minimumFileModificationDate != nil,
                      identity.modificationDate == nil {
                recordDeferred(.metadataUnavailable)
                return false
            }

            if options.resourceGovernor != nil {
                guard let size = identity.fileSizeBytes else {
                    recordDeferred(.metadataUnavailable)
                    return false
                }
                let (sum, overflow) = totalBytes.addingReportingOverflow(max(0, size))
                guard !overflow else {
                    recordDeferred(.byteCountOverflow)
                    return false
                }
                totalBytes = sum
            }
        }

        guard boundaryPassed else { return false }
        if let governor = options.resourceGovernor {
            guard governor.admitFile(estimatedBytes: totalBytes) else {
                options.metrics?.recordDeferred(.byteBudget)
                return false
            }
        }
        for identity in identities {
            options.fileDiscoveryTracker?.recordAdmitted(identity)
        }
        options.metrics?.recordContentRead(count: files.count, bytes: totalBytes)
        return true
    }

    private func admitFile(withSize size: Int64?) throws -> Bool {
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
