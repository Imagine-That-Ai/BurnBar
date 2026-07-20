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

public actor BurnBarUsageRecorder {
    static let maximumIdentifierBytes = 256
    static let maximumProjectNameBytes = 256
    static let maximumFutureSkew: TimeInterval = 15
    static let earliestRecordedAt = Date(timeIntervalSince1970: 946_684_800)

    private let fileURL: URL
    private let logger: BurnBarDaemonLogger
    private let now: @Sendable () -> Date
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    private var cachedRecords: [BurnBarUsageRecord]?
    private var recordedKeys: Set<String>?

    public init(
        fileURL: URL = BurnBarDaemonPaths.defaultUsageLedgerURL,
        logger: BurnBarDaemonLogger = BurnBarDaemonLogger(category: "usage-recorder"),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.fileURL = fileURL
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

        guard !state.keys.contains(normalizedKey) else {
            logger.debug(
                "usage_record_skipped_duplicate",
                metadata: ["idempotency_key": normalizedKey]
            )
            return BurnBarUsageRecordResult(record: record, inserted: false)
        }

        try append(record)
        state.keys.insert(normalizedKey)
        state.records.append(record)
        recordedKeys = state.keys
        cachedRecords = state.records

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

    private func loadStateIfNeeded() throws -> (records: [BurnBarUsageRecord], keys: Set<String>) {
        if let cachedRecords, let recordedKeys {
            return (cachedRecords, recordedKeys)
        }

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            let state: ([BurnBarUsageRecord], Set<String>) = ([], [])
            cachedRecords = state.0
            recordedKeys = state.1
            return state
        }

        let fileContents = try String(contentsOf: fileURL, encoding: .utf8)
        let lines = fileContents.split(whereSeparator: \.isNewline)
        let records = try lines.map { line in
            try decoder.decode(BurnBarUsageRecord.self, from: Data(line.utf8))
        }
        let keys = Set(records.map(\.idempotencyKey))

        cachedRecords = records
        recordedKeys = keys

        return (records, keys)
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
