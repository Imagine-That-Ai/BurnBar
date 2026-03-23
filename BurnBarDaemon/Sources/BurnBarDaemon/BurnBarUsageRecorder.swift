import BurnBarCore
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

public actor BurnBarUsageRecorder {
    private let fileURL: URL
    private let logger: BurnBarDaemonLogger
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    private var cachedRecords: [BurnBarUsageRecord]?
    private var recordedKeys: Set<String>?

    public init(
        fileURL: URL = BurnBarDaemonPaths.defaultUsageLedgerURL,
        logger: BurnBarDaemonLogger = BurnBarDaemonLogger(category: "usage-recorder")
    ) {
        self.fileURL = fileURL
        self.logger = logger
    }

    public func record(
        _ event: BurnBarUsageEvent,
        idempotencyKey: String
    ) throws -> BurnBarUsageRecordResult {
        let normalizedKey = idempotencyKey.trimmingCharacters(in: .whitespacesAndNewlines)
        precondition(!normalizedKey.isEmpty, "Usage idempotency keys must not be empty.")

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
    }
}
