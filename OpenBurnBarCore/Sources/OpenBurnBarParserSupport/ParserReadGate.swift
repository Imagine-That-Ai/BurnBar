import Foundation

// MARK: - Cross-Platform Autorelease Pool

/// Runs `body` inside an autorelease pool on Darwin and directly on
/// non-Darwin platforms (Linux/Windows), where the Swift runtime has no
/// autorelease pool to drain.
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

// MARK: - Parse Options and Read Gate

public struct LogParseOptions: Sendable {
    public var includeConversationBodies: Bool
    /// When set, parsers may return cached older rows but should not parse
    /// uncached files whose modification date is before this boundary.
    public var minimumFileModificationDate: Date?
    /// Per-pass manifest of file identities already observed by a successful
    /// indexing checkpoint. Parsers use it to admit newly discovered files
    /// even when their preserved modification date predates the watermark.
    public var fileDiscoveryTracker: ParserFileDiscoveryTracker?
    /// Shared per-pass resource accounting: byte budget for new file content
    /// and a process memory ceiling. `nil` leaves direct, non-registry calls
    /// ungoverned. Production registry entries install an unlimited governor
    /// when their caller does not supply stricter limits.
    public var resourceGovernor: ParserResourceGovernor?
    /// Per-parser, path-free scan telemetry. Production registry entries
    /// install a fresh recorder for every parse pass.
    public var metrics: ParserPassMetrics?

    public static let `default` = LogParseOptions(includeConversationBodies: true)

    public init(
        includeConversationBodies: Bool,
        minimumFileModificationDate: Date? = nil,
        fileDiscoveryTracker: ParserFileDiscoveryTracker? = nil,
        resourceGovernor: ParserResourceGovernor? = nil,
        metrics: ParserPassMetrics? = nil
    ) {
        self.includeConversationBodies = includeConversationBodies
        self.minimumFileModificationDate = minimumFileModificationDate
        self.fileDiscoveryTracker = fileDiscoveryTracker
        self.resourceGovernor = resourceGovernor
        self.metrics = metrics
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
    /// modification boundary when any of its inputs changed; older sidecars
    /// do not suppress a newer primary transcript.
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

    /// Rolls back admitted identities when opening or reading their content fails.
    /// Admission accounting remains charged for the attempted read, while each
    /// path stays retryable in both partial and complete checkpoints.
    public func recordContentReadFailure(for file: URL) {
        recordContentReadFailure(for: [file])
    }

    public func recordContentReadFailure(for files: [URL]) {
        guard !files.isEmpty else { return }
        options.resourceGovernor?.recordDeferredFile()
        options.metrics?.recordDeferred(.contentReadFailed)
        discardAdmission(for: files)
    }

    /// Removes checkpoint eligibility without recording an additional deferral.
    /// Use when another already-accounted admission decision invalidates a group.
    public func discardAdmission(for files: [URL]) {
        for file in files {
            options.fileDiscoveryTracker?.recordDeferred(path: file.standardizedFileURL.path)
        }
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

// MARK: - Parser Scan Digest

public enum ParserScanDigest {
    public static func fnv1a64(_ data: Data) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    public static func fnv1a64(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    public static func fnv1a64Hex(_ data: Data) -> String {
        String(format: "%016llx", fnv1a64(data))
    }

    /// Digest of the file's first `length` bytes. Leaves the handle's offset
    /// at `length` — callers must seek afterwards.
    public static func headDigestHex(handle: FileHandle, length: Int) -> String {
        guard length > 0 else { return fnv1a64Hex(Data()) }
        try? handle.seek(toOffset: 0) // try?-ok(seek 0 before head read)
        // Pool the autoreleased NSData-backed read (see BufferedLineReader).
        return parserAutoReleasePool {
            fnv1a64Hex(handle.readData(ofLength: length))
        }
    }
}
