import Foundation
import GRDB
import OpenBurnBarCore

// MARK: - ProjectionStore

/// Projection jobs, embedding models/versions, chunk embeddings, and retrieval health.
final class ProjectionStore {
    private let dbQueue: DatabaseQueue

    init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    // MARK: - Projection Jobs

    func enqueueProjectionJob(_ job: ProjectionJobRecord) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO projection_jobs (
                    id, jobType, sourceKind, sourceID, sourceVersionID, status, priority, attempts,
                    maxAttempts, payloadJSON, lastErrorCode, lastErrorMessage, scheduledAt, availableAt,
                    startedAt, completedAt, leaseOwner, leaseExpiresAt, createdAt, updatedAt
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    jobType = excluded.jobType,
                    sourceKind = excluded.sourceKind,
                    sourceID = excluded.sourceID,
                    sourceVersionID = excluded.sourceVersionID,
                    status = excluded.status,
                    priority = excluded.priority,
                    attempts = excluded.attempts,
                    maxAttempts = excluded.maxAttempts,
                    payloadJSON = excluded.payloadJSON,
                    lastErrorCode = excluded.lastErrorCode,
                    lastErrorMessage = excluded.lastErrorMessage,
                    scheduledAt = excluded.scheduledAt,
                    availableAt = excluded.availableAt,
                    startedAt = excluded.startedAt,
                    completedAt = excluded.completedAt,
                    leaseOwner = excluded.leaseOwner,
                    leaseExpiresAt = excluded.leaseExpiresAt,
                    updatedAt = excluded.updatedAt
                WHERE projection_jobs.status IN ('queued', 'failed', 'canceled')
                """,
                arguments: [
                    job.id,
                    job.jobType.rawValue,
                    job.sourceKind?.rawValue,
                    job.sourceID,
                    job.sourceVersionID,
                    job.status.rawValue,
                    job.priority,
                    job.attempts,
                    job.maxAttempts,
                    job.payloadJSON,
                    job.lastErrorCode,
                    job.lastErrorMessage,
                    job.scheduledAt,
                    job.availableAt,
                    job.startedAt,
                    job.completedAt,
                    job.leaseOwner,
                    job.leaseExpiresAt,
                    job.createdAt,
                    job.updatedAt
                ]
            )
        }
    }

    func fetchProjectionJobs(statuses: [ProjectionJobStatus], limit: Int) throws -> [ProjectionJobRecord] {
        guard statuses.isEmpty == false else { return [] }
        let placeholders = statuses.map { _ in "?" }.joined(separator: ", ")
        var args: [any DatabaseValueConvertible] = statuses.map { $0.rawValue }
        args.append(limit)
        return try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM projection_jobs
                WHERE status IN (\(placeholders))
                ORDER BY priority ASC, availableAt ASC, createdAt ASC
                LIMIT ?
                """,
                arguments: StatementArguments(args)
            )
            return rows.compactMap(Self.projectionJob(from:))
        }
    }

    func countProjectionJobs(statuses: [ProjectionJobStatus]?) throws -> Int {
        let normalizedStatuses = statuses ?? ProjectionJobStatus.allCases
        guard normalizedStatuses.isEmpty == false else { return 0 }
        let placeholders = normalizedStatuses.map { _ in "?" }.joined(separator: ", ")
        let args: [any DatabaseValueConvertible] = normalizedStatuses.map(\.rawValue)

        return try dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*)
                FROM projection_jobs
                WHERE status IN (\(placeholders))
                """,
                arguments: StatementArguments(args)
            ) ?? 0
        }
    }

    func hasProjectionJobs(
        statuses: [ProjectionJobStatus],
        jobTypes: [ProjectionJobType]
    ) throws -> Bool {
        guard statuses.isEmpty == false, jobTypes.isEmpty == false else { return false }
        let statusPlaceholders = statuses.map { _ in "?" }.joined(separator: ", ")
        let jobTypePlaceholders = jobTypes.map { _ in "?" }.joined(separator: ", ")
        let args: [any DatabaseValueConvertible] = statuses.map(\.rawValue) + jobTypes.map(\.rawValue)

        return try dbQueue.read { db in
            (try Int.fetchOne(
                db,
                sql: """
                SELECT 1
                FROM projection_jobs
                WHERE status IN (\(statusPlaceholders))
                  AND jobType IN (\(jobTypePlaceholders))
                LIMIT 1
                """,
                arguments: StatementArguments(args)
            )) != nil
        }
    }

    /// Drops redundant queued/failed/canceled conversation projection jobs, keeping only
    /// the newest entry per `(sourceID, jobType)` so large stale backlogs do not monopolize sweeps.
    func compactConversationProjectionBacklog() throws -> Int {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                DELETE FROM projection_jobs
                WHERE sourceKind = ?
                  AND status IN (?, ?, ?)
                  AND rowid NOT IN (
                      SELECT MAX(rowid)
                      FROM projection_jobs
                      WHERE sourceKind = ?
                        AND status IN (?, ?, ?)
                      GROUP BY sourceID, jobType
                  )
                """,
                arguments: [
                    SearchSourceKind.conversation.rawValue,
                    ProjectionJobStatus.queued.rawValue,
                    ProjectionJobStatus.failed.rawValue,
                    ProjectionJobStatus.canceled.rawValue,
                    SearchSourceKind.conversation.rawValue,
                    ProjectionJobStatus.queued.rawValue,
                    ProjectionJobStatus.failed.rawValue,
                    ProjectionJobStatus.canceled.rawValue,
                ]
            )
            return try Int.fetchOne(db, sql: "SELECT changes()") ?? 0
        }
    }

    func leaseNextJob(leaseOwner: String, leaseExpiresAt: Date, now: Date) throws -> ProjectionJobRecord? {
        try dbQueue.write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT * FROM projection_jobs
                WHERE (
                    (
                        status IN (?, ?)
                        AND availableAt <= ?
                    )
                    OR (
                        status IN (?, ?)
                        AND leaseExpiresAt IS NOT NULL
                        AND leaseExpiresAt <= ?
                    )
                )
                AND attempts < maxAttempts
                ORDER BY priority ASC, availableAt ASC, createdAt ASC
                LIMIT 1
                """,
                arguments: [
                    ProjectionJobStatus.queued.rawValue,
                    ProjectionJobStatus.failed.rawValue,
                    now,
                    ProjectionJobStatus.leased.rawValue,
                    ProjectionJobStatus.running.rawValue,
                    now
                ]
            ) else {
                return nil
            }

            guard let job = Self.projectionJob(from: row) else { return nil }
            try db.execute(
                sql: """
                UPDATE projection_jobs
                SET status = ?, leaseOwner = ?, leaseExpiresAt = ?, startedAt = COALESCE(startedAt, ?), updatedAt = ?
                WHERE id = ?
                """,
                arguments: [
                    ProjectionJobStatus.running.rawValue,
                    leaseOwner,
                    leaseExpiresAt,
                    now,
                    now,
                    job.id
                ]
            )
            return try Row.fetchOne(
                db,
                sql: "SELECT * FROM projection_jobs WHERE id = ?",
                arguments: [job.id]
            ).flatMap(Self.projectionJob(from:))
        }
    }

    func markJobLeased(id: String, leaseOwner: String, leaseExpiresAt: Date, updatedAt: Date) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE projection_jobs
                SET status = ?, leaseOwner = ?, leaseExpiresAt = ?, startedAt = COALESCE(startedAt, ?), updatedAt = ?
                WHERE id = ?
                """,
                arguments: [ProjectionJobStatus.leased.rawValue, leaseOwner, leaseExpiresAt, updatedAt, updatedAt, id]
            )
        }
    }

    func markJobCompleted(id: String, completedAt: Date) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE projection_jobs
                SET status = ?, completedAt = ?, leaseOwner = NULL, leaseExpiresAt = NULL,
                    lastErrorCode = NULL, lastErrorMessage = NULL, updatedAt = ?
                WHERE id = ?
                """,
                arguments: [ProjectionJobStatus.completed.rawValue, completedAt, completedAt, id]
            )
        }
    }

    func markJobFailed(
        id: String,
        errorCode: String?,
        errorMessage: String?,
        retryAt: Date?,
        updatedAt: Date
    ) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE projection_jobs
                SET status = ?, attempts = attempts + 1, leaseOwner = NULL, leaseExpiresAt = NULL,
                    lastErrorCode = ?, lastErrorMessage = ?, availableAt = COALESCE(?, availableAt), updatedAt = ?
                WHERE id = ?
                """,
                arguments: [ProjectionJobStatus.failed.rawValue, errorCode, errorMessage, retryAt, updatedAt, id]
            )
        }
    }

    func markJobCanceled(
        id: String,
        errorCode: String?,
        errorMessage: String?,
        updatedAt: Date
    ) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE projection_jobs
                SET status = ?, leaseOwner = NULL, leaseExpiresAt = NULL,
                    lastErrorCode = ?, lastErrorMessage = ?, updatedAt = ?
                WHERE id = ?
                """,
                arguments: [ProjectionJobStatus.canceled.rawValue, errorCode, errorMessage, updatedAt, id]
            )
        }
    }

    // MARK: - Embedding Models

    func upsertEmbeddingModel(_ model: EmbeddingModelRecord) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO embedding_models (
                    id, provider, modelName, dimensions, distanceMetric, createdAt, updatedAt
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    provider = excluded.provider,
                    modelName = excluded.modelName,
                    dimensions = excluded.dimensions,
                    distanceMetric = excluded.distanceMetric,
                    updatedAt = excluded.updatedAt
                """,
                arguments: [
                    model.id,
                    model.provider,
                    model.modelName,
                    model.dimensions,
                    model.distanceMetric.rawValue,
                    model.createdAt,
                    model.updatedAt
                ]
            )
        }
    }

    func fetchEmbeddingModels() throws -> [EmbeddingModelRecord] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM embedding_models
                ORDER BY provider ASC, modelName ASC
                """
            )
            return rows.compactMap(Self.embeddingModel(from:))
        }
    }

    func countEmbeddingModels() throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM embedding_models") ?? 0
        }
    }

    // MARK: - Embedding Versions

    func upsertEmbeddingVersion(_ version: EmbeddingVersionRecord) throws {
        try dbQueue.write { db in
            if version.isActive {
                try db.execute(
                    sql: "UPDATE embedding_versions SET isActive = 0, updatedAt = ? WHERE modelID = ?",
                    arguments: [version.updatedAt, version.modelID]
                )
            }

            try db.execute(
                sql: """
                INSERT INTO embedding_versions (
                    id, modelID, versionTag, chunkerVersion, normalizationVersion,
                    promptVersion, isActive, createdAt, updatedAt
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    modelID = excluded.modelID,
                    versionTag = excluded.versionTag,
                    chunkerVersion = excluded.chunkerVersion,
                    normalizationVersion = excluded.normalizationVersion,
                    promptVersion = excluded.promptVersion,
                    isActive = excluded.isActive,
                    updatedAt = excluded.updatedAt
                """,
                arguments: [
                    version.id,
                    version.modelID,
                    version.versionTag,
                    version.chunkerVersion,
                    version.normalizationVersion,
                    version.promptVersion,
                    version.isActive,
                    version.createdAt,
                    version.updatedAt
                ]
            )
        }
    }

    func fetchEmbeddingVersions(modelID: String?) throws -> [EmbeddingVersionRecord] {
        try dbQueue.read { db in
            let rows: [Row]
            if let modelID {
                rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT * FROM embedding_versions
                    WHERE modelID = ?
                    ORDER BY isActive DESC, createdAt DESC
                    """,
                    arguments: [modelID]
                )
            } else {
                rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT * FROM embedding_versions
                    ORDER BY modelID ASC, isActive DESC, createdAt DESC
                    """
                )
            }
            return rows.compactMap(Self.embeddingVersion(from:))
        }
    }

    func countEmbeddingVersions(modelID: String?) throws -> Int {
        try dbQueue.read { db in
            if let modelID {
                return try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM embedding_versions WHERE modelID = ?",
                    arguments: [modelID]
                ) ?? 0
            }

            return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM embedding_versions") ?? 0
        }
    }

    // MARK: - Chunk Embeddings

    func upsertChunkEmbedding(_ embedding: ChunkEmbeddingRecord) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO chunk_embeddings (
                    chunkID, embeddingVersionID, vectorBlob, createdAt, updatedAt
                ) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(chunkID, embeddingVersionID) DO UPDATE SET
                    vectorBlob = excluded.vectorBlob,
                    updatedAt = excluded.updatedAt
                """,
                arguments: [
                    embedding.chunkID,
                    embedding.embeddingVersionID,
                    embedding.vectorBlob,
                    embedding.createdAt,
                    embedding.updatedAt
                ]
            )
        }
    }

    func fetchChunkEmbeddings(chunkID: String?) throws -> [ChunkEmbeddingRecord] {
        try dbQueue.read { db in
            let rows: [Row]
            if let chunkID {
                rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT * FROM chunk_embeddings
                    WHERE chunkID = ?
                    ORDER BY embeddingVersionID ASC
                    """,
                    arguments: [chunkID]
                )
            } else {
                rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT * FROM chunk_embeddings
                    ORDER BY chunkID ASC, embeddingVersionID ASC
                    """
                )
            }
            return rows.compactMap(Self.chunkEmbedding(from:))
        }
    }

    func fetchChunkEmbeddings(embeddingVersionID: String) throws -> [ChunkEmbeddingRecord] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM chunk_embeddings
                WHERE embeddingVersionID = ?
                ORDER BY chunkID ASC
                """,
                arguments: [embeddingVersionID]
            )
            return rows.compactMap(Self.chunkEmbedding(from:))
        }
    }

    func countChunkEmbeddings(
        chunkID: String?,
        embeddingVersionID: String?
    ) throws -> Int {
        var clauses: [String] = []
        var args: [any DatabaseValueConvertible] = []

        if let chunkID, chunkID.isEmpty == false {
            clauses.append("chunkID = ?")
            args.append(chunkID)
        }
        if let embeddingVersionID, embeddingVersionID.isEmpty == false {
            clauses.append("embeddingVersionID = ?")
            args.append(embeddingVersionID)
        }

        let whereSQL = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        return try dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*)
                FROM chunk_embeddings
                \(whereSQL)
                """,
                arguments: StatementArguments(args)
            ) ?? 0
        }
    }

    func countChunkEmbeddings(
        documentID: String,
        embeddingVersionID: String?
    ) throws -> Int {
        var clauses: [String] = ["c.documentID = ?"]
        var args: [any DatabaseValueConvertible] = [documentID]

        if let embeddingVersionID, embeddingVersionID.isEmpty == false {
            clauses.append("e.embeddingVersionID = ?")
            args.append(embeddingVersionID)
        }

        return try dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*)
                FROM chunk_embeddings AS e
                JOIN search_chunks AS c ON c.id = e.chunkID
                WHERE \(clauses.joined(separator: " AND "))
                """,
                arguments: StatementArguments(args)
            ) ?? 0
        }
    }

    // MARK: - Retrieval Health

    func upsertRetrievalHealth(_ health: RetrievalHealthRecord) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO retrieval_health (
                    subsystem, status, errorCode, errorMessage, detailsJSON, observedAt, updatedAt
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(subsystem) DO UPDATE SET
                    status = excluded.status,
                    errorCode = excluded.errorCode,
                    errorMessage = excluded.errorMessage,
                    detailsJSON = excluded.detailsJSON,
                    observedAt = excluded.observedAt,
                    updatedAt = excluded.updatedAt
                """,
                arguments: [
                    health.subsystem.rawValue,
                    health.status.rawValue,
                    health.errorCode,
                    health.errorMessage,
                    health.detailsJSON,
                    health.observedAt,
                    health.updatedAt
                ]
            )
        }
    }

    func fetchRetrievalHealth() throws -> [RetrievalHealthRecord] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM retrieval_health
                ORDER BY subsystem ASC
                """
            )
            return rows.compactMap(Self.retrievalHealth(from:))
        }
    }

    // MARK: - Schema Inventory

    func schemaInventory() throws -> LocalSearchSchemaInventory {
        let expectedTables = [
            "controller_runtime_cache",
            "search_documents",
            "search_chunks",
            "search_chunks_fts",
            "search_documents_fts",
            "projection_jobs",
            "embedding_models",
            "embedding_versions",
            "chunk_embeddings",
            "retrieval_health",
            "artifact_permissions",
            "audit_events",
            "operating_action_history",
        ]
        let expectedIndexes = [
            "controller_runtime_cache_updated_idx",
            "search_documents_source_lookup_idx",
            "search_documents_project_provider_idx",
            "search_chunks_unique_document_ordinal_idx",
            "search_chunks_document_offset_idx",
            "search_chunks_source_lookup_idx",
            "projection_jobs_poll_idx",
            "projection_jobs_source_lookup_idx",
            "embedding_models_provider_model_idx",
            "embedding_versions_identity_idx",
            "embedding_versions_active_idx",
            "chunk_embeddings_version_lookup_idx",
            "artifact_permissions_principal_lookup_idx",
            "artifact_permissions_source_lookup_idx",
            "audit_events_source_time_idx",
            "audit_events_scope_time_idx",
            "audit_events_action_time_idx",
            "operating_action_history_project_time_idx",
            "operating_action_history_kind_time_idx",
            "operating_action_history_mission_time_idx",
        ]

        return try dbQueue.read { db in
            let tables = try String.fetchAll(
                db,
                sql: """
                SELECT name
                FROM sqlite_master
                WHERE type = 'table' AND name IN (\(OpenBurnBarDatabase.sqlPlaceholders(count: expectedTables.count)))
                ORDER BY name ASC
                """,
                arguments: StatementArguments(expectedTables)
            )
            let indexes = try String.fetchAll(
                db,
                sql: """
                SELECT name
                FROM sqlite_master
                WHERE type = 'index' AND name IN (\(OpenBurnBarDatabase.sqlPlaceholders(count: expectedIndexes.count)))
                ORDER BY name ASC
                """,
                arguments: StatementArguments(expectedIndexes)
            )
            return LocalSearchSchemaInventory(tables: tables, indexes: indexes)
        }
    }

    // MARK: - Row Decoding

    static func projectionJob(from row: Row) -> ProjectionJobRecord? {
        guard
            let id = row["id"] as? String,
            let jobTypeRaw = row["jobType"] as? String,
            let jobType = ProjectionJobType(rawValue: jobTypeRaw),
            let statusRaw = row["status"] as? String,
            let status = ProjectionJobStatus(rawValue: statusRaw)
        else {
            return nil
        }

        let priority = (row["priority"] as? Int) ?? Int(row["priority"] as? Int64 ?? 0)
        let attempts = (row["attempts"] as? Int) ?? Int(row["attempts"] as? Int64 ?? 0)
        let maxAttempts = (row["maxAttempts"] as? Int) ?? Int(row["maxAttempts"] as? Int64 ?? 0)
        let scheduledAt = OpenBurnBarDatabase.parseDateValue(row["scheduledAt"]) ?? Date()
        let availableAt = OpenBurnBarDatabase.parseDateValue(row["availableAt"]) ?? scheduledAt
        let createdAt = OpenBurnBarDatabase.parseDateValue(row["createdAt"]) ?? scheduledAt
        let updatedAt = OpenBurnBarDatabase.parseDateValue(row["updatedAt"]) ?? createdAt
        let sourceKind = (row["sourceKind"] as? String).flatMap(SearchSourceKind.init(rawValue:))

        return ProjectionJobRecord(
            id: id,
            jobType: jobType,
            sourceKind: sourceKind,
            sourceID: row["sourceID"] as? String,
            sourceVersionID: (row["sourceVersionID"] as? String) ?? "",
            status: status,
            priority: priority,
            attempts: attempts,
            maxAttempts: maxAttempts,
            payloadJSON: row["payloadJSON"] as? String,
            lastErrorCode: row["lastErrorCode"] as? String,
            lastErrorMessage: row["lastErrorMessage"] as? String,
            scheduledAt: scheduledAt,
            availableAt: availableAt,
            startedAt: OpenBurnBarDatabase.parseDateValue(row["startedAt"]),
            completedAt: OpenBurnBarDatabase.parseDateValue(row["completedAt"]),
            leaseOwner: row["leaseOwner"] as? String,
            leaseExpiresAt: OpenBurnBarDatabase.parseDateValue(row["leaseExpiresAt"]),
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    static func embeddingModel(from row: Row) -> EmbeddingModelRecord? {
        guard
            let id = row["id"] as? String,
            let provider = row["provider"] as? String,
            let modelName = row["modelName"] as? String,
            let distanceMetricRaw = row["distanceMetric"] as? String,
            let distanceMetric = EmbeddingDistanceMetric(rawValue: distanceMetricRaw)
        else {
            return nil
        }
        let dimensions = (row["dimensions"] as? Int) ?? Int(row["dimensions"] as? Int64 ?? 0)
        let createdAt = OpenBurnBarDatabase.parseDateValue(row["createdAt"]) ?? Date()
        let updatedAt = OpenBurnBarDatabase.parseDateValue(row["updatedAt"]) ?? createdAt
        return EmbeddingModelRecord(
            id: id,
            provider: provider,
            modelName: modelName,
            dimensions: dimensions,
            distanceMetric: distanceMetric,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    static func embeddingVersion(from row: Row) -> EmbeddingVersionRecord? {
        guard
            let id = row["id"] as? String,
            let modelID = row["modelID"] as? String,
            let versionTag = row["versionTag"] as? String,
            let chunkerVersion = row["chunkerVersion"] as? String,
            let normalizationVersion = row["normalizationVersion"] as? String,
            let promptVersion = row["promptVersion"] as? String
        else {
            return nil
        }
        let isActiveRaw: Bool
        if let boolValue = row["isActive"] as? Bool {
            isActiveRaw = boolValue
        } else if let intValue = row["isActive"] as? Int {
            isActiveRaw = intValue == 1
        } else if let int64Value = row["isActive"] as? Int64 {
            isActiveRaw = int64Value == 1
        } else {
            isActiveRaw = false
        }
        let createdAt = OpenBurnBarDatabase.parseDateValue(row["createdAt"]) ?? Date()
        let updatedAt = OpenBurnBarDatabase.parseDateValue(row["updatedAt"]) ?? createdAt
        return EmbeddingVersionRecord(
            id: id,
            modelID: modelID,
            versionTag: versionTag,
            chunkerVersion: chunkerVersion,
            normalizationVersion: normalizationVersion,
            promptVersion: promptVersion,
            isActive: isActiveRaw,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    static func chunkEmbedding(from row: Row) -> ChunkEmbeddingRecord? {
        guard
            let chunkID = row["chunkID"] as? String,
            let embeddingVersionID = row["embeddingVersionID"] as? String,
            let vectorBlob = row["vectorBlob"] as? Data
        else {
            return nil
        }
        let createdAt = OpenBurnBarDatabase.parseDateValue(row["createdAt"]) ?? Date()
        let updatedAt = OpenBurnBarDatabase.parseDateValue(row["updatedAt"]) ?? createdAt
        return ChunkEmbeddingRecord(
            chunkID: chunkID,
            embeddingVersionID: embeddingVersionID,
            vectorBlob: vectorBlob,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    static func retrievalHealth(from row: Row) -> RetrievalHealthRecord? {
        guard
            let subsystemRaw = row["subsystem"] as? String,
            let subsystem = RetrievalSubsystem(rawValue: subsystemRaw),
            let statusRaw = row["status"] as? String,
            let status = RetrievalHealthStatus(rawValue: statusRaw)
        else {
            return nil
        }
        let observedAt = OpenBurnBarDatabase.parseDateValue(row["observedAt"]) ?? Date()
        let updatedAt = OpenBurnBarDatabase.parseDateValue(row["updatedAt"]) ?? observedAt
        return RetrievalHealthRecord(
            subsystem: subsystem,
            status: status,
            errorCode: row["errorCode"] as? String,
            errorMessage: row["errorMessage"] as? String,
            detailsJSON: row["detailsJSON"] as? String,
            observedAt: observedAt,
            updatedAt: updatedAt
        )
    }
}
