import OpenBurnBarEngine
import Foundation

public struct BurnBarUsageRecord: Codable, Hashable, Sendable {
    public let idempotencyKey: String
    public let event: BurnBarUsageEvent

    public init(idempotencyKey: String, event: BurnBarUsageEvent) {
        self.idempotencyKey = idempotencyKey
        self.event = event
    }
}

public struct BurnBarUsageRecordResult: Hashable, Sendable {
    public let record: BurnBarUsageRecord
    public let inserted: Bool

    public init(record: BurnBarUsageRecord, inserted: Bool) {
        self.record = record
        self.inserted = inserted
    }
}

enum BurnBarUsageValidationError: Error, Equatable, LocalizedError {
    case invalidField(String, String)

    var errorDescription: String? {
        switch self {
        case .invalidField(let field, let reason):
            return "Invalid usage event: \(field) \(reason)."
        }
    }
}

enum BurnBarUsageLedgerError: Error, Equatable, LocalizedError {
    case conflictingIdempotencyKey(String)
    case aggregateOverflow(String)

    var errorDescription: String? {
        switch self {
        case .conflictingIdempotencyKey(let key):
            return "Usage ledger contains conflicting events for idempotency key \(key)."
        case .aggregateOverflow(let field):
            return "Usage projection exceeds the supported range for \(field)."
        }
    }
}

public actor BurnBarUsageRecorder {
    static let maximumIdentifierBytes = 256
    static let maximumProjectNameBytes = 256
    static let maximumFutureSkew: TimeInterval = 15
    static let earliestRecordedAt = Date(timeIntervalSince1970: 946_684_800)

    private let fileURL: URL
    private let projectionFileURL: URL
    private let logger: BurnBarDaemonLogger
    private let now: @Sendable () -> Date
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    private var cachedRecords: [BurnBarUsageRecord]?
    private var recordsByKey: [String: BurnBarUsageRecord]?
    private var cachedProjection: BurnBarUsageProjection?

    public init(
        fileURL: URL = BurnBarDaemonPaths.defaultUsageLedgerURL,
        projectionFileURL: URL? = nil,
        logger: BurnBarDaemonLogger = BurnBarDaemonLogger(category: "usage-recorder"),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.fileURL = fileURL
        self.projectionFileURL = projectionFileURL
            ?? fileURL.deletingLastPathComponent().appendingPathComponent("usage-projection.json")
        self.logger = logger
        self.now = now
    }

    public func record(
        _ event: BurnBarUsageEvent,
        idempotencyKey: String
    ) throws -> BurnBarUsageRecordResult {
        let normalizedKey = try Self.validatedIdentifier(idempotencyKey, field: "idempotencyKey")
        try validate(event)

        var state = try loadStateIfNeeded()
        let record = BurnBarUsageRecord(idempotencyKey: normalizedKey, event: event)

        if let existing = state.recordsByKey[normalizedKey] {
            guard existing.event == event else {
                throw BurnBarUsageLedgerError.conflictingIdempotencyKey(normalizedKey)
            }
            logger.debug(
                "usage_record_skipped_duplicate",
                metadata: ["idempotency_key": normalizedKey]
            )
            return BurnBarUsageRecordResult(record: existing, inserted: false)
        }

        try append(record)
        state.recordsByKey[normalizedKey] = record
        state.records.append(record)
        recordsByKey = state.recordsByKey
        cachedRecords = state.records
        // The projection is a derived cache. Invalidate it in O(1) and rebuild
        // only when a projection consumer asks; recounting the whole ledger on
        // every imported row would make a batch import quadratic.
        cachedProjection = nil

        logger.notice(
            "usage_record_inserted",
            metadata: [
                "idempotency_key": normalizedKey,
                "provider_id": event.providerID,
                "model_id": event.modelID
            ]
        )

        return BurnBarUsageRecordResult(record: record, inserted: true)
    }

    public func records() throws -> [BurnBarUsageRecord] {
        try loadStateIfNeeded().records
    }

    public func recentUsage(limit: Int) throws -> [BurnBarUsageEvent] {
        Array(
            try records()
                .map(\.event)
                .sorted { $0.recordedAt > $1.recordedAt }
                .prefix(max(0, limit))
        )
    }

    /// Returns the daemon-owned, durable projection of the canonical ledger.
    /// A stale or tampered projection is rebuilt before it is returned.
    public func projection() throws -> BurnBarUsageProjection {
        if let cachedProjection {
            return cachedProjection
        }
        let records = try loadStateIfNeeded().records
        let fingerprint = try ledgerFingerprint(records)

        let persisted = try? loadPersistedProjection()
        if let persisted,
           try projectionMatchesLedger(persisted, records: records, fingerprint: fingerprint) {
            cachedProjection = persisted
            return persisted
        }

        return try rebuildProjection(
            records: records,
            fingerprint: fingerprint,
            previousGeneration: persisted?.generation
        )
    }

    /// Rebuilds all derived totals from the append-only source ledger. Source
    /// events remain untouched, and generation advances even when inputs did
    /// not change so callers can prove a recount actually ran.
    public func recountProjection() throws -> BurnBarUsageProjection {
        let records = try loadStateIfNeeded().records
        let fingerprint = try ledgerFingerprint(records)
        let persisted = cachedProjection ?? (try? loadPersistedProjection())
        return try rebuildProjection(
            records: records,
            fingerprint: fingerprint,
            previousGeneration: persisted?.generation
        )
    }

    private func loadStateIfNeeded() throws -> (
        records: [BurnBarUsageRecord],
        recordsByKey: [String: BurnBarUsageRecord]
    ) {
        if let cachedRecords, let recordsByKey {
            return (cachedRecords, recordsByKey)
        }

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            let state: ([BurnBarUsageRecord], [String: BurnBarUsageRecord]) = ([], [:])
            cachedRecords = state.0
            recordsByKey = state.1
            return state
        }

        let fileContents = try String(contentsOf: fileURL, encoding: .utf8)
        let lines = fileContents.split(whereSeparator: \.isNewline)
        var records: [BurnBarUsageRecord] = []
        var indexed: [String: BurnBarUsageRecord] = [:]
        for line in lines {
            let record = try decoder.decode(BurnBarUsageRecord.self, from: Data(line.utf8))
            let key = try Self.validatedIdentifier(record.idempotencyKey, field: "idempotencyKey")
            try validate(record.event)
            if let existing = indexed[key] {
                guard existing == record else {
                    throw BurnBarUsageLedgerError.conflictingIdempotencyKey(key)
                }
                continue
            }
            indexed[key] = record
            records.append(record)
        }

        cachedRecords = records
        recordsByKey = indexed

        return (records, indexed)
    }

    private func ledgerFingerprint(_ records: [BurnBarUsageRecord]) throws -> String {
        let canonicalEncoder = JSONEncoder()
        canonicalEncoder.outputFormatting = [.sortedKeys]
        var data = Data()
        for record in records {
            data.append(try canonicalEncoder.encode(record))
            data.append(0x0A)
        }
        return PlatformCrypto.sha256Hex(data)
    }

    private func loadPersistedProjection() throws -> BurnBarUsageProjection {
        try decoder.decode(BurnBarUsageProjection.self, from: Data(contentsOf: projectionFileURL))
    }

    private func projectionMatchesLedger(
        _ projection: BurnBarUsageProjection,
        records: [BurnBarUsageRecord],
        fingerprint: String
    ) throws -> Bool {
        guard projection.schemaVersion == 1,
              projection.generation > 0,
              projection.ledgerSHA256 == fingerprint else {
            return false
        }
        let expected = try makeProjection(
            records: records,
            fingerprint: fingerprint,
            generation: projection.generation,
            generatedAt: projection.generatedAt
        )
        return expected == projection
    }

    private func rebuildProjection(
        records: [BurnBarUsageRecord],
        fingerprint: String,
        previousGeneration: Int?
    ) throws -> BurnBarUsageProjection {
        let nextGeneration: Int
        if let previousGeneration {
            let incremented = previousGeneration.addingReportingOverflow(1)
            guard !incremented.overflow else {
                throw BurnBarUsageLedgerError.aggregateOverflow("generation")
            }
            nextGeneration = incremented.partialValue
        } else {
            nextGeneration = 1
        }
        let projection = try makeProjection(
            records: records,
            fingerprint: fingerprint,
            generation: nextGeneration,
            generatedAt: now()
        )
        try persistProjection(projection)
        cachedProjection = projection
        return projection
    }

    private func makeProjection(
        records: [BurnBarUsageRecord],
        fingerprint: String,
        generation: Int,
        generatedAt: Date
    ) throws -> BurnBarUsageProjection {
        struct BucketKey: Hashable, Comparable {
            let dayUTC: String
            let providerID: String
            let modelID: String

            static func < (lhs: BucketKey, rhs: BucketKey) -> Bool {
                (lhs.dayUTC, lhs.providerID, lhs.modelID)
                    < (rhs.dayUTC, rhs.providerID, rhs.modelID)
            }
        }
        struct MutableBucket {
            var totals = MutableTotals()
            var exactEventCount = 0
            var estimatedEventCount = 0
            var unknownEventCount = 0
            var firstRecordedAt: Date
            var lastRecordedAt: Date
        }

        var totals = MutableTotals()
        var buckets: [BucketKey: MutableBucket] = [:]
        for record in records {
            let event = record.event
            try totals.add(event)
            let key = BucketKey(
                dayUTC: Self.utcDay(event.recordedAt),
                providerID: event.providerID,
                modelID: event.modelID
            )
            var bucket = buckets[key] ?? MutableBucket(
                firstRecordedAt: event.recordedAt,
                lastRecordedAt: event.recordedAt
            )
            try bucket.totals.add(event)
            switch event.confidence {
            case .exact, .derivedExact:
                try Self.increment(&bucket.exactEventCount, field: "exactEventCount")
            case .highConfidenceEstimate, .lowConfidenceEstimate:
                try Self.increment(&bucket.estimatedEventCount, field: "estimatedEventCount")
            case .unknown:
                try Self.increment(&bucket.unknownEventCount, field: "unknownEventCount")
            }
            bucket.firstRecordedAt = min(bucket.firstRecordedAt, event.recordedAt)
            bucket.lastRecordedAt = max(bucket.lastRecordedAt, event.recordedAt)
            buckets[key] = bucket
        }

        let projectedBuckets = try buckets.keys.sorted().map { key in
            guard let bucket = buckets[key] else {
                throw BurnBarUsageLedgerError.aggregateOverflow("bucket lookup")
            }
            return BurnBarUsageProjectionBucket(
                dayUTC: key.dayUTC,
                providerID: key.providerID,
                modelID: key.modelID,
                totals: bucket.totals.value,
                exactEventCount: bucket.exactEventCount,
                estimatedEventCount: bucket.estimatedEventCount,
                unknownEventCount: bucket.unknownEventCount,
                firstRecordedAt: bucket.firstRecordedAt,
                lastRecordedAt: bucket.lastRecordedAt
            )
        }
        return BurnBarUsageProjection(
            generation: generation,
            generatedAt: generatedAt,
            ledgerSHA256: fingerprint,
            totals: totals.value,
            buckets: projectedBuckets
        )
    }

    private func persistProjection(_ projection: BurnBarUsageProjection) throws {
        let directoryURL = projectionFileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let projectionEncoder = JSONEncoder()
        projectionEncoder.outputFormatting = [.sortedKeys]
        try projectionEncoder.encode(projection).write(to: projectionFileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: projectionFileURL.path
        )
    }

    private static func utcDay(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    private static func increment(_ value: inout Int, field: String) throws {
        let incremented = value.addingReportingOverflow(1)
        guard !incremented.overflow else {
            throw BurnBarUsageLedgerError.aggregateOverflow(field)
        }
        value = incremented.partialValue
    }

    private func append(_ record: BurnBarUsageRecord) throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let encodedRecord = try encoder.encode(record) + Data([0x0A])
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let handle = try FileHandle(forWritingTo: fileURL)
            defer {
                try? handle.close()
            }
            try handle.seekToEnd()
            try handle.write(contentsOf: encodedRecord)
        } else {
            try encodedRecord.write(to: fileURL, options: .atomic)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    private func validate(_ event: BurnBarUsageEvent) throws {
        _ = try Self.validatedIdentifier(event.providerID, field: "providerID")
        _ = try Self.validatedIdentifier(event.modelID, field: "modelID")
        if let runID = event.runID?.rawValue {
            _ = try Self.validatedIdentifier(runID, field: "runID")
        }
        if let sessionID = event.sessionID {
            _ = try Self.validatedIdentifier(sessionID, field: "sessionID")
        }
        if let parentRequestID = event.parentRequestID {
            _ = try Self.validatedIdentifier(parentRequestID, field: "parentRequestID")
        }
        if let projectName = event.projectName {
            _ = try Self.validatedText(
                projectName,
                field: "projectName",
                maximumBytes: Self.maximumProjectNameBytes
            )
        }

        let tokenFields = [
            ("inputTokens", event.inputTokens),
            ("outputTokens", event.outputTokens),
            ("cacheCreationTokens", event.cacheCreationTokens),
            ("cacheReadTokens", event.cacheReadTokens),
            ("reasoningTokens", event.reasoningTokens)
        ]
        for (field, value) in tokenFields where value < 0 {
            throw BurnBarUsageValidationError.invalidField(field, "must be nonnegative")
        }

        var totalTokens = 0
        for (_, value) in tokenFields {
            let addition = totalTokens.addingReportingOverflow(value)
            guard !addition.overflow else {
                throw BurnBarUsageValidationError.invalidField("token counts", "exceed the supported integer range")
            }
            totalTokens = addition.partialValue
        }

        guard event.cost.isFinite, event.cost >= 0 else {
            throw BurnBarUsageValidationError.invalidField("cost", "must be finite and nonnegative")
        }
        let timestamp = event.recordedAt.timeIntervalSince1970
        let latestRecordedAt = now().addingTimeInterval(Self.maximumFutureSkew)
        guard timestamp.isFinite,
              event.recordedAt >= Self.earliestRecordedAt,
              event.recordedAt <= latestRecordedAt else {
            throw BurnBarUsageValidationError.invalidField(
                "recordedAt",
                "must be on or after 2000 and no more than 15 seconds in the future"
            )
        }
    }

    private static func validatedIdentifier(_ raw: String, field: String) throws -> String {
        try validatedText(raw, field: field, maximumBytes: maximumIdentifierBytes)
    }

    private static func validatedText(_ raw: String, field: String, maximumBytes: Int) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed == raw else {
            throw BurnBarUsageValidationError.invalidField(field, "must be nonblank and trimmed")
        }
        guard raw.utf8.count <= maximumBytes else {
            throw BurnBarUsageValidationError.invalidField(
                field,
                "must not exceed \(maximumBytes) UTF-8 bytes"
            )
        }
        guard !raw.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw BurnBarUsageValidationError.invalidField(field, "must not contain control characters")
        }
        return raw
    }
}

private struct MutableTotals {
    var eventCount = 0
    var inputTokens = 0
    var outputTokens = 0
    var cacheCreationTokens = 0
    var cacheReadTokens = 0
    var reasoningTokens = 0
    var totalTokens = 0
    var cost = 0.0

    mutating func add(_ event: BurnBarUsageEvent) throws {
        try add(1, to: &eventCount, field: "eventCount")
        try add(event.inputTokens, to: &inputTokens, field: "inputTokens")
        try add(event.outputTokens, to: &outputTokens, field: "outputTokens")
        try add(event.cacheCreationTokens, to: &cacheCreationTokens, field: "cacheCreationTokens")
        try add(event.cacheReadTokens, to: &cacheReadTokens, field: "cacheReadTokens")
        try add(event.reasoningTokens, to: &reasoningTokens, field: "reasoningTokens")

        var eventTotal = 0
        for value in [
            event.inputTokens,
            event.outputTokens,
            event.cacheCreationTokens,
            event.cacheReadTokens,
            event.reasoningTokens
        ] {
            try add(value, to: &eventTotal, field: "event.totalTokens")
        }
        try add(eventTotal, to: &totalTokens, field: "totalTokens")

        let nextCost = cost + event.cost
        guard nextCost.isFinite else {
            throw BurnBarUsageLedgerError.aggregateOverflow("cost")
        }
        cost = nextCost
    }

    var value: BurnBarUsageProjectionTotals {
        BurnBarUsageProjectionTotals(
            eventCount: eventCount,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheCreationTokens: cacheCreationTokens,
            cacheReadTokens: cacheReadTokens,
            reasoningTokens: reasoningTokens,
            totalTokens: totalTokens,
            cost: cost
        )
    }

    private func add(_ increment: Int, to value: inout Int, field: String) throws {
        let result = value.addingReportingOverflow(increment)
        guard !result.overflow else {
            throw BurnBarUsageLedgerError.aggregateOverflow(field)
        }
        value = result.partialValue
    }
}
