import Foundation
import GRDB

public struct OpenBurnBarProviderParserOutput: Equatable, Sendable {
    public var id: String
    public var provider: String
    public var sessionID: String
    public var projectName: String
    public var model: String
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheCreationTokens: Int
    public var cacheReadTokens: Int
    public var reasoningTokens: Int
    public var cost: Double
    public var startTime: Date
    public var endTime: Date
    public var createdAt: Date
    public var usageSource: String
    public var sourceDeviceID: String?
    public var sourceDeviceName: String?
    public var isRemote: Bool
    public var providerID: String?
    public var providerAccountID: String?
    public var providerAccountLabel: String?
    public var providerAccountSource: String?
    public var provenanceMethod: String
    public var provenanceConfidence: String
    public var estimatorVersion: String
    public var parentRequestID: String?

    public init(
        id: String,
        provider: String,
        sessionID: String,
        projectName: String,
        model: String,
        inputTokens: Int,
        outputTokens: Int,
        cacheCreationTokens: Int,
        cacheReadTokens: Int,
        reasoningTokens: Int = 0,
        cost: Double,
        startTime: Date,
        endTime: Date,
        createdAt: Date,
        usageSource: String = "provider_log",
        sourceDeviceID: String?,
        sourceDeviceName: String?,
        isRemote: Bool = false,
        providerID: String?,
        providerAccountID: String?,
        providerAccountLabel: String?,
        providerAccountSource: String?,
        provenanceMethod: String = "provider_log",
        provenanceConfidence: String = "exact",
        estimatorVersion: String = "",
        parentRequestID: String? = nil
    ) {
        self.id = id
        self.provider = provider
        self.sessionID = sessionID
        self.projectName = projectName
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
        self.reasoningTokens = reasoningTokens
        self.cost = cost
        self.startTime = startTime
        self.endTime = endTime
        self.createdAt = createdAt
        self.usageSource = usageSource
        self.sourceDeviceID = sourceDeviceID
        self.sourceDeviceName = sourceDeviceName
        self.isRemote = isRemote
        self.providerID = providerID
        self.providerAccountID = providerAccountID
        self.providerAccountLabel = providerAccountLabel
        self.providerAccountSource = providerAccountSource
        self.provenanceMethod = provenanceMethod
        self.provenanceConfidence = provenanceConfidence
        self.estimatorVersion = estimatorVersion
        self.parentRequestID = parentRequestID
    }

    var totalTokens: Int {
        inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens + reasoningTokens
    }
}

public struct OpenBurnBarParserCheckpointUpdate: Equatable, Sendable {
    public var provider: String
    public var checkpointToken: String
    public var lastProcessedFilePath: String?
    public var lastProcessedAt: Date
    public var version: Int

    public init(
        provider: String,
        checkpointToken: String,
        lastProcessedFilePath: String?,
        lastProcessedAt: Date,
        version: Int = 1
    ) {
        self.provider = provider
        self.checkpointToken = checkpointToken
        self.lastProcessedFilePath = lastProcessedFilePath
        self.lastProcessedAt = lastProcessedAt
        self.version = version
    }
}

public struct OpenBurnBarRemoteSyncWatermarkUpdate: Equatable, Sendable {
    public var accountUID: String
    public var collectionKind: String
    public var lastSyncedAt: Date
    public var lastProcessedRemoteUpdateAt: Date?
    public var version: Int

    public init(
        accountUID: String,
        collectionKind: String,
        lastSyncedAt: Date,
        lastProcessedRemoteUpdateAt: Date?,
        version: Int = 1
    ) {
        self.accountUID = accountUID
        self.collectionKind = collectionKind
        self.lastSyncedAt = lastSyncedAt
        self.lastProcessedRemoteUpdateAt = lastProcessedRemoteUpdateAt
        self.version = version
    }
}

public struct OpenBurnBarBackfillCursorUpdate: Equatable, Sendable {
    public var provider: String
    public var lastProcessedWindowUpperBound: Date?
    public var earliestSourceDate: Date?
    public var updatedAt: Date
    public var version: Int

    public init(
        provider: String,
        lastProcessedWindowUpperBound: Date?,
        earliestSourceDate: Date?,
        updatedAt: Date,
        version: Int = 1
    ) {
        self.provider = provider
        self.lastProcessedWindowUpperBound = lastProcessedWindowUpperBound
        self.earliestSourceDate = earliestSourceDate
        self.updatedAt = updatedAt
        self.version = version
    }
}

public struct OpenBurnBarProviderParserIngestionBatch: Equatable, Sendable {
    public var rows: [OpenBurnBarProviderParserOutput]
    public var checkpoint: OpenBurnBarParserCheckpointUpdate
    public var remoteWatermark: OpenBurnBarRemoteSyncWatermarkUpdate?
    public var backfillCursor: OpenBurnBarBackfillCursorUpdate?
    public var privacyCacheKey: String?
    public var retainPrivateCacheContent: Bool

    public init(
        rows: [OpenBurnBarProviderParserOutput],
        checkpoint: OpenBurnBarParserCheckpointUpdate,
        remoteWatermark: OpenBurnBarRemoteSyncWatermarkUpdate?,
        backfillCursor: OpenBurnBarBackfillCursorUpdate?,
        privacyCacheKey: String?,
        retainPrivateCacheContent: Bool
    ) {
        self.rows = rows
        self.checkpoint = checkpoint
        self.remoteWatermark = remoteWatermark
        self.backfillCursor = backfillCursor
        self.privacyCacheKey = privacyCacheKey
        self.retainPrivateCacheContent = retainPrivateCacheContent
    }
}

public enum OpenBurnBarProviderParserIngestionFailureStage: String, Error, Equatable, Sendable {
    case beforeUsageWrites
    case afterUsageWritesBeforeCheckpoint
    case afterCheckpointBeforeWatermark
    case afterWatermarkBeforeCache
}

public extension OpenBurnBarLocalDatabase {
    func ingestProviderParserBatch(
        _ batch: OpenBurnBarProviderParserIngestionBatch,
        failAt failureStage: OpenBurnBarProviderParserIngestionFailureStage? = nil
    ) throws {
        try pool.writeInTransaction { db in
            if failureStage == .beforeUsageWrites {
                throw OpenBurnBarProviderParserIngestionFailureStage.beforeUsageWrites
            }

            for row in batch.rows {
                try insertProviderParserOutput(row, into: db)
            }
            if failureStage == .afterUsageWritesBeforeCheckpoint {
                throw OpenBurnBarProviderParserIngestionFailureStage.afterUsageWritesBeforeCheckpoint
            }

            try upsertParserCheckpoint(batch.checkpoint, into: db)
            if failureStage == .afterCheckpointBeforeWatermark {
                throw OpenBurnBarProviderParserIngestionFailureStage.afterCheckpointBeforeWatermark
            }

            if let remoteWatermark = batch.remoteWatermark {
                try upsertRemoteWatermark(remoteWatermark, into: db)
            }
            if let backfillCursor = batch.backfillCursor {
                try upsertBackfillCursor(backfillCursor, into: db)
            }
            if failureStage == .afterWatermarkBeforeCache {
                throw OpenBurnBarProviderParserIngestionFailureStage.afterWatermarkBeforeCache
            }

            if let cacheKey = batch.privacyCacheKey {
                try updatePrivacyCache(
                    key: cacheKey,
                    retainPrivateCacheContent: batch.retainPrivateCacheContent,
                    rowCount: batch.rows.count,
                    updatedAt: batch.checkpoint.lastProcessedAt,
                    in: db
                )
            }
            return .commit
        }
    }

    private func insertProviderParserOutput(
        _ row: OpenBurnBarProviderParserOutput,
        into db: Database
    ) throws {
        try db.execute(
            sql: """
            INSERT INTO token_usage (
                id, provider, sessionId, projectName, model, inputTokens,
                outputTokens, cacheCreationTokens, cacheReadTokens, totalTokens,
                cost, startTime, endTime, createdAt, syncedAt, sourceDeviceId,
                sourceDeviceName, isRemote, reasoningTokens, usageSource,
                provenanceMethod, provenanceConfidence, estimatorVersion,
                providerID, providerAccountID, providerAccountLabel,
                providerAccountSource, parentRequestID
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                provider = excluded.provider,
                sessionId = excluded.sessionId,
                projectName = excluded.projectName,
                model = excluded.model,
                inputTokens = excluded.inputTokens,
                outputTokens = excluded.outputTokens,
                cacheCreationTokens = excluded.cacheCreationTokens,
                cacheReadTokens = excluded.cacheReadTokens,
                totalTokens = excluded.totalTokens,
                cost = excluded.cost,
                startTime = excluded.startTime,
                endTime = excluded.endTime,
                sourceDeviceId = excluded.sourceDeviceId,
                sourceDeviceName = excluded.sourceDeviceName,
                isRemote = excluded.isRemote,
                reasoningTokens = excluded.reasoningTokens,
                usageSource = excluded.usageSource,
                provenanceMethod = excluded.provenanceMethod,
                provenanceConfidence = excluded.provenanceConfidence,
                estimatorVersion = excluded.estimatorVersion,
                providerID = excluded.providerID,
                providerAccountID = excluded.providerAccountID,
                providerAccountLabel = excluded.providerAccountLabel,
                providerAccountSource = excluded.providerAccountSource,
                parentRequestID = excluded.parentRequestID,
                syncedAt = NULL
            """,
            arguments: [
                row.id,
                row.provider,
                row.sessionID,
                row.projectName,
                row.model,
                row.inputTokens,
                row.outputTokens,
                row.cacheCreationTokens,
                row.cacheReadTokens,
                row.totalTokens,
                row.cost,
                row.startTime,
                row.endTime,
                row.createdAt,
                nil,
                row.sourceDeviceID,
                row.sourceDeviceName,
                row.isRemote ? 1 : 0,
                row.reasoningTokens,
                row.usageSource,
                row.provenanceMethod,
                row.provenanceConfidence,
                row.estimatorVersion,
                row.providerID,
                row.providerAccountID,
                row.providerAccountLabel,
                row.providerAccountSource,
                row.parentRequestID
            ]
        )
    }

    private func upsertParserCheckpoint(
        _ checkpoint: OpenBurnBarParserCheckpointUpdate,
        into db: Database
    ) throws {
        try db.execute(
            sql: """
            INSERT INTO parser_checkpoints (
                provider, checkpointToken, lastProcessedFilePath, lastProcessedAt, version
            ) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(provider) DO UPDATE SET
                checkpointToken = excluded.checkpointToken,
                lastProcessedFilePath = excluded.lastProcessedFilePath,
                lastProcessedAt = excluded.lastProcessedAt,
                version = excluded.version
            """,
            arguments: [
                checkpoint.provider,
                checkpoint.checkpointToken,
                checkpoint.lastProcessedFilePath,
                checkpoint.lastProcessedAt,
                checkpoint.version
            ]
        )
    }

    private func upsertRemoteWatermark(
        _ watermark: OpenBurnBarRemoteSyncWatermarkUpdate,
        into db: Database
    ) throws {
        try db.execute(
            sql: """
            INSERT INTO remote_sync_watermarks (
                accountUid, collectionKind, lastSyncedAt, lastProcessedRemoteUpdateAt, version
            ) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(accountUid, collectionKind) DO UPDATE SET
                lastSyncedAt = excluded.lastSyncedAt,
                lastProcessedRemoteUpdateAt = excluded.lastProcessedRemoteUpdateAt,
                version = excluded.version
            """,
            arguments: [
                watermark.accountUID,
                watermark.collectionKind,
                watermark.lastSyncedAt,
                watermark.lastProcessedRemoteUpdateAt,
                watermark.version
            ]
        )
    }

    private func upsertBackfillCursor(
        _ cursor: OpenBurnBarBackfillCursorUpdate,
        into db: Database
    ) throws {
        try db.execute(
            sql: """
            INSERT INTO backfill_cursors (
                provider, lastProcessedWindowUpperBound, earliestSourceDate, updatedAt, version
            ) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(provider) DO UPDATE SET
                lastProcessedWindowUpperBound = excluded.lastProcessedWindowUpperBound,
                earliestSourceDate = excluded.earliestSourceDate,
                updatedAt = excluded.updatedAt,
                version = excluded.version
            """,
            arguments: [
                cursor.provider,
                cursor.lastProcessedWindowUpperBound,
                cursor.earliestSourceDate,
                cursor.updatedAt,
                cursor.version
            ]
        )
    }

    private func updatePrivacyCache(
        key: String,
        retainPrivateCacheContent: Bool,
        rowCount: Int,
        updatedAt: Date,
        in db: Database
    ) throws {
        if retainPrivateCacheContent {
            let payload = #"{"privateContentRetained":false,"bodyRedacted":"[redacted]","rowCount":\#(rowCount)}"#
            try db.execute(
                sql: """
                INSERT INTO controller_runtime_cache (cacheKey, payloadJSON, updatedAt)
                VALUES (?, ?, ?)
                ON CONFLICT(cacheKey) DO UPDATE SET
                    payloadJSON = excluded.payloadJSON,
                    updatedAt = excluded.updatedAt
                """,
                arguments: [key, payload, updatedAt]
            )
        } else {
            try db.execute(
                sql: "DELETE FROM controller_runtime_cache WHERE cacheKey = ?",
                arguments: [key]
            )
        }
    }
}
