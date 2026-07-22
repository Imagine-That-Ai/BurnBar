import Foundation
import OpenBurnBarKernel

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

    /// Canonicalize filesystem dates to the manifest's millisecond precision.
    /// `ParserCheckpointStore` persists the resulting payload numerically so an
    /// unchanged file compares bit-for-bit after a database round trip.
    private static func normalizedCheckpointDate(_ date: Date?) -> Date? {
        guard let date else { return nil }
        let milliseconds = (date.timeIntervalSince1970 * 1_000).rounded()
        return Date(timeIntervalSince1970: milliseconds / 1_000)
    }

    public static func capture(
        for file: URL,
        attributes: [FileAttributeKey: Any]?,
        fallbackModificationDate: Date? = nil
    ) -> ParserDiscoveredFile {
        ParserDiscoveredFile(
            path: file.standardizedFileURL.path,
            fileSizeBytes: (attributes?[.size] as? NSNumber)?.int64Value,
            modificationDate: normalizedCheckpointDate(
                attributes?[.modificationDate] as? Date ?? fallbackModificationDate
            ),
            creationDate: normalizedCheckpointDate(attributes?[.creationDate] as? Date),
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

    public func wasKnownAtCheckpoint(_ file: ParserDiscoveredFile) -> Bool {
        knownFilesByPath[file.path] == file
    }

    /// Marks an input whose content was admitted during this pass. These files
    /// may be persisted after a budget-limited partial pass once their parsed
    /// conversations have committed, allowing the next pass to make progress.
    public func recordAdmitted(_ file: ParserDiscoveredFile) {
        state.withLock { $0.admittedFilesByPath[file.path] = file }
    }

    /// Removes an admitted identity when the parser later discovers that the
    /// corresponding content could not be read successfully.
    public func recordDeferred(_ file: ParserDiscoveredFile) {
        recordDeferred(path: file.path)
    }

    public func recordDeferred(path: String) {
        state.withLock { _ = $0.admittedFilesByPath.removeValue(forKey: path) }
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
