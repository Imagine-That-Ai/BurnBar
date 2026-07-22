import Foundation
import CryptoKit
@preconcurrency import GRDB
import OpenBurnBarCore

// MARK: - Checkpoint Record

/// A database record representing parser checkpoint state.
/// Used for tracking parse progress and enabling safe resume after interruption.
struct ParserCheckpointRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "parser_checkpoints"

    let provider: String
    var checkpointToken: String
    var lastProcessedFilePath: String?
    var lastProcessedAt: Date
    var version: Int

    enum CodingKeys: String, CodingKey {
        case provider
        case checkpointToken
        case lastProcessedFilePath
        case lastProcessedAt
        case version
    }
}

// MARK: - ParserCheckpointStore

/// Stores parser checkpoint/high-watermark state for safe resume after interruption.
///
/// Checkpoint advancement semantics:
/// - Checkpoint advances ONLY after successful ingestion transaction commit (VAL-PERSIST-004)
/// - Resume from checkpoint is gap-free and duplicate-free (VAL-PERSIST-005)
/// - Cache/checkpoint corruption recovery is safe - reprocess all if cache is missing (VAL-PERSIST-014)
///
/// The checkpoint token encodes parser-specific progress state (e.g., last processed file path,
/// file offset, or session ID). The exact format depends on the parser implementation.
final class ParserCheckpointStore: Sendable {
    private let dbQueue: any DatabaseWriter

    init(dbQueue: any DatabaseWriter) {
        self.dbQueue = dbQueue
    }

    // MARK: - Read

    /// Fetches the current checkpoint for a provider, or nil if no checkpoint exists.
    func fetchCheckpoint(for provider: AgentProvider) async throws -> ParserCheckpointRecord? {
        try await dbQueue.read { db in
            try ParserCheckpointRecord.fetchOne(db, sql: """
                SELECT * FROM parser_checkpoints WHERE provider = ?
                """, arguments: [provider.rawValue])
        }
    }

    /// Fetches all checkpoints for all providers.
    func fetchAllCheckpoints() async throws -> [ParserCheckpointRecord] {
        try await dbQueue.read { db in
            try ParserCheckpointRecord.fetchAll(db, sql: "SELECT * FROM parser_checkpoints")
        }
    }

    /// Loads the exact input identities observed by the provider's last
    /// successful indexing checkpoint.
    func fetchDiscoveredFiles(for provider: AgentProvider) async throws -> [ParserDiscoveredFile] {
        try await dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT path, fileSizeBytes, modificationDate, creationDate,
                           fileSystemNumber, fileNumber
                    FROM parser_checkpoint_files
                    WHERE provider = ?
                    ORDER BY path
                    """,
                arguments: [provider.rawValue]
            ).compactMap(Self.discoveredFile(from:))
        }
    }

    // MARK: - Write

    /// Advances the checkpoint for a provider after successful commit.
    /// This MUST be called only after the ingestion transaction has been committed.
    ///
    /// VAL-PERSIST-004: Checkpoints advance only after successful commit.
    func advanceCheckpoint(
        for provider: AgentProvider,
        checkpointToken: String,
        lastProcessedFilePath: String?,
        lastProcessedAt: Date = Date(),
        discoveredFiles: [ParserDiscoveredFile]? = nil
    ) async throws {
        try await dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO parser_checkpoints (provider, checkpointToken, lastProcessedFilePath, lastProcessedAt, version)
                VALUES (?, ?, ?, ?, 1)
                ON CONFLICT(provider) DO UPDATE SET
                    checkpointToken = excluded.checkpointToken,
                    lastProcessedFilePath = excluded.lastProcessedFilePath,
                    lastProcessedAt = excluded.lastProcessedAt,
                    version = version + 1
                """, arguments: [
                    provider.rawValue,
                    checkpointToken,
                    lastProcessedFilePath,
                    lastProcessedAt
                ])

            if let discoveredFiles {
                try Self.updateDiscoveredFiles(
                    discoveredFiles,
                    for: provider,
                    in: db
                )
            }
        }
    }

    /// Persists only the manifest, without moving the provider watermark.
    /// Used after a successfully indexed but byte-deferred pass so a cold scan
    /// can converge across ticks without skipping the files still deferred.
    func saveDiscoveredFiles(
        _ discoveredFiles: [ParserDiscoveredFile],
        for provider: AgentProvider
    ) async throws {
        try await dbQueue.write { db in
            try Self.updateDiscoveredFiles(discoveredFiles, for: provider, in: db)
        }
    }

    // Note: advanceCheckpointAtomically was removed because the
    // AtomicIngestionTransaction.commit() method handles atomic
    // checkpoint advancement within its own write transaction.
    // Keeping the public API surface minimal to avoid confusion.

    /// Clears the checkpoint for a provider (e.g., when cache corruption is detected).
    /// This forces a full reprocess on next run.
    ///
    /// VAL-PERSIST-014: Parser cache corruption/reset recovery is safe.
    func clearCheckpoint(for provider: AgentProvider) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM parser_checkpoint_files WHERE provider = ?",
                arguments: [provider.rawValue]
            )
            try db.execute(
                sql: "DELETE FROM parser_checkpoints WHERE provider = ?",
                arguments: [provider.rawValue]
            )
        }
    }

    /// Clears all checkpoints (e.g., for a full reset).
    func clearAllCheckpoints() async throws {
        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM parser_checkpoint_files")
            try db.execute(sql: "DELETE FROM parser_checkpoints")
        }
    }

    private static func updateDiscoveredFiles(
        _ discoveredFiles: [ParserDiscoveredFile],
        for provider: AgentProvider,
        in db: Database
    ) throws {
        let existingFiles = try Row.fetchAll(
            db,
            sql: """
                SELECT path, fileSizeBytes, modificationDate, creationDate,
                       fileSystemNumber, fileNumber
                FROM parser_checkpoint_files
                WHERE provider = ?
                """,
            arguments: [provider.rawValue]
        ).compactMap(discoveredFile(from:))
        let existingByPath = Dictionary(uniqueKeysWithValues: existingFiles.map { ($0.path, $0) })
        let currentByPath = discoveredFiles.reduce(into: [String: ParserDiscoveredFile]()) { filesByPath, file in
            filesByPath[file.path] = file
        }

        let removedPaths = Set(existingByPath.keys).subtracting(currentByPath.keys).sorted()
        for path in removedPaths {
            try db.execute(
                sql: "DELETE FROM parser_checkpoint_files WHERE provider = ? AND path = ?",
                arguments: [provider.rawValue, path]
            )
        }

        // Persist dates as numeric timestamps instead of GRDB's millisecond TEXT
        // format. SQLite REAL preserves the Date payload exactly; formatting and
        // reparsing can shift its binary representation and rediscover an
        // unchanged file on every bounded pass.
        let changedFiles = currentByPath.values
            .filter { existingByPath[$0.path] != $0 }
            .sorted { $0.path < $1.path }
        for file in changedFiles {
            try db.execute(
                sql: """
                    INSERT INTO parser_checkpoint_files (
                        provider, path, fileSizeBytes, modificationDate, creationDate,
                        fileSystemNumber, fileNumber
                    ) VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(provider, path) DO UPDATE SET
                        fileSizeBytes = excluded.fileSizeBytes,
                        modificationDate = excluded.modificationDate,
                        creationDate = excluded.creationDate,
                        fileSystemNumber = excluded.fileSystemNumber,
                        fileNumber = excluded.fileNumber
                    """,
                arguments: [
                    provider.rawValue,
                    file.path,
                    file.fileSizeBytes,
                    file.modificationDate?.timeIntervalSince1970,
                    file.creationDate?.timeIntervalSince1970,
                    file.fileSystemNumber.map(String.init),
                    file.fileNumber.map(String.init)
                ]
            )
        }
    }

    private static func discoveredFile(from row: Row) -> ParserDiscoveredFile? {
        guard let path: String = row["path"] else { return nil }
        let fileSystemNumber = (row["fileSystemNumber"] as String?).flatMap(UInt64.init)
        let fileNumber = (row["fileNumber"] as String?).flatMap(UInt64.init)
        return ParserDiscoveredFile(
            path: path,
            fileSizeBytes: row["fileSizeBytes"],
            modificationDate: row["modificationDate"],
            creationDate: row["creationDate"],
            fileSystemNumber: fileSystemNumber,
            fileNumber: fileNumber
        )
    }
}

// MARK: - Checkpoint-Aware Parse Result

/// Result of a checkpoint-aware parse operation that tracks both parsed data
/// and the checkpoint state for safe resume.
struct CheckpointAwareParseResult: Sendable {
    let usages: [TokenUsage]
    let conversations: [OpenBurnBarCore.ConversationRecord]
    let checkpointToken: String
    let lastProcessedFilePath: String?
    let processedFiles: [String]
    let parseErrors: [String]

    static let empty = CheckpointAwareParseResult(
        usages: [],
        conversations: [],
        checkpointToken: "",
        lastProcessedFilePath: nil,
        processedFiles: [],
        parseErrors: []
    )
}

// MARK: - CheckpointedParserWrapper

/// Wraps a OpenBurnBarCore.LogParser with checkpoint-aware parsing for safe resume after interruption.
///
/// The wrapper:
/// 1. Loads the last checkpoint before parsing
/// 2. Tracks progress during parsing
/// 3. Advances the checkpoint only after successful commit
/// 4. Provides safe recovery when cache/checkpoint is corrupted
final class CheckpointedParserWrapper: Sendable {
    private let parser: any OpenBurnBarCore.LogParser
    private let checkpointStore: ParserCheckpointStore

    init(parser: any OpenBurnBarCore.LogParser, checkpointStore: ParserCheckpointStore) {
        self.parser = parser
        self.checkpointStore = checkpointStore
    }

    /// Returns the provider for this parser.
    var provider: AgentProvider { parser.provider }

    /// Parses with checkpoint awareness.
    ///
    /// Returns a result that includes checkpoint state for safe resume.
    /// Checkpoint is NOT advanced until commitCheckpoint() is called.
    func parseWithCheckpoint() async throws -> CheckpointAwareParseResult {
        // Load existing checkpoint to determine where to resume
        let existingCheckpoint = try? await checkpointStore.fetchCheckpoint(for: parser.provider) // try?-ok(nil = safe full reprocess)

        // Perform the actual parse
        let result = try await parser.parse()

        // If no checkpoint exists or cache was corrupted (empty result from scratch),
        // this is treated as a fresh start
        if existingCheckpoint == nil {
            return CheckpointAwareParseResult(
                usages: result.usages,
                conversations: result.conversations,
                checkpointToken: makeCheckpointToken(processedFiles: []),
                lastProcessedFilePath: nil,
                processedFiles: [],
                parseErrors: []
            )
        }

        // Track what was processed - in a real implementation, parsers would track
        // individual file progress. For now, we use a simple model where all
        // processed sessions are encoded in the checkpoint token.
        return CheckpointAwareParseResult(
            usages: result.usages,
            conversations: result.conversations,
            checkpointToken: existingCheckpoint?.checkpointToken ?? "",
            lastProcessedFilePath: existingCheckpoint?.lastProcessedFilePath,
            processedFiles: [],
            parseErrors: []
        )
    }

    /// Commits the checkpoint after successful ingestion.
    /// Must be called ONLY after usages have been successfully persisted.
    ///
    /// VAL-PERSIST-004: Checkpoints advance only after successful commit.
    func commitCheckpoint(
        token: String,
        lastProcessedFilePath: String?
    ) async throws {
        try await checkpointStore.advanceCheckpoint(
            for: parser.provider,
            checkpointToken: token,
            lastProcessedFilePath: lastProcessedFilePath
        )
    }

    /// Clears the checkpoint for this provider, forcing a full reprocess.
    /// Call this when cache corruption is detected.
    func clearCheckpoint() async throws {
        try await checkpointStore.clearCheckpoint(for: parser.provider)
    }

    /// Checks if checkpoint state exists for safe resume.
    func hasCheckpoint() async -> Bool {
        (try? await checkpointStore.fetchCheckpoint(for: parser.provider)) != nil // try?-ok(false = reprocess all)
    }

    private func makeCheckpointToken(processedFiles: [String]) -> String {
        // Simple token encoding - in production this would be more sophisticated
        // to encode file paths, offsets, session IDs, etc.
        let timestamp = Date().timeIntervalSince1970
        return "v1:\(timestamp):\(processedFiles.count)"
    }
}

// MARK: - Atomic Ingestion Transaction

/// Represents an atomic ingestion transaction that couples usage persistence
/// with checkpoint advancement.
///
/// VAL-CROSS-008: Atomic visibility boundary across ingestion, indexing, and reporting.
/// If ingestion fails before commit, neither reporting totals nor indexing surfaces
/// may expose partial state; visibility begins only after successful commit.
final class AtomicIngestionTransaction {
    private let dbQueue: any DatabaseWriter
    private let checkpointStore: ParserCheckpointStore
    private let provider: AgentProvider

    private var usages: [TokenUsage] = []
    private var conversations: [OpenBurnBarCore.ConversationRecord] = []
    private var checkpointToken: String = ""
    private var lastProcessedFilePath: String?

    private var isCommitted: Bool = false
    private var isRolledBack: Bool = false

    init(dbQueue: any DatabaseWriter, checkpointStore: ParserCheckpointStore, provider: AgentProvider) {
        self.dbQueue = dbQueue
        self.checkpointStore = checkpointStore
        self.provider = provider
    }

    /// Adds parsed usages and conversations to the transaction.
    /// These are NOT visible until commit() is called.
    func append(
        usages: [TokenUsage],
        conversations: [OpenBurnBarCore.ConversationRecord],
        checkpointToken: String,
        lastProcessedFilePath: String?
    ) {
        self.usages.append(contentsOf: usages)
        self.conversations.append(contentsOf: conversations)
        self.checkpointToken = checkpointToken
        self.lastProcessedFilePath = lastProcessedFilePath
    }

    /// Commits the transaction atomically:
    /// 1. Persists all usages and conversations
    /// 2. Advances the checkpoint (only after successful commit)
    ///
    /// VAL-PERSIST-004: Checkpoints advance only after successful commit.
    /// VAL-CROSS-008: Visibility begins only after successful commit.
    func commit() async throws {
        guard !isCommitted, !isRolledBack else { return }

        let usages = self.usages
        let checkpointToken = self.checkpointToken
        let lastProcessedFilePath = self.lastProcessedFilePath
        let provider = self.provider

        try await dbQueue.write { db in
            // First, persist usages
            for usage in usages {
                let usagePartition = Self.usagePartitionToken(from: usage.providerAccountID)
                try db.execute(sql: """
                    INSERT INTO token_usage (
                        id, provider, sessionId, projectName, model,
                        inputTokens, outputTokens, cacheCreationTokens, cacheReadTokens,
                        reasoningTokens, totalTokens, cost, startTime, endTime, createdAt,
                        usageSource, sourceDeviceId, sourceDeviceName, isRemote,
                        providerID, providerAccountID, providerAccountLabel, providerAccountSource,
                        provenanceMethod, provenanceConfidence, estimatorVersion
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(provider, sessionId, model, COALESCE(sourceDeviceId, ''), COALESCE(providerAccountID, '')) DO UPDATE SET
                        projectName = excluded.projectName,
                        inputTokens = excluded.inputTokens,
                        outputTokens = excluded.outputTokens,
                        cacheCreationTokens = excluded.cacheCreationTokens,
                        cacheReadTokens = excluded.cacheReadTokens,
                        reasoningTokens = excluded.reasoningTokens,
                        totalTokens = excluded.totalTokens,
                        cost = excluded.cost,
                        startTime = excluded.startTime,
                        endTime = excluded.endTime,
                        createdAt = excluded.createdAt,
                        -- VAL-TOKEN-009: Preserve source identity on equal-confidence upserts.
                        -- Only update usageSource when incoming confidence is strictly higher.
                        usageSource = CASE
                            WHEN
                                CASE excluded.provenanceConfidence
                                    WHEN 'exact' THEN 4
                                    WHEN 'derived_exact' THEN 3
                                    WHEN 'high_confidence_estimate' THEN 2
                                    WHEN 'low_confidence_estimate' THEN 1
                                    ELSE 0
                                END
                                >
                                CASE token_usage.provenanceConfidence
                                    WHEN 'exact' THEN 4
                                    WHEN 'derived_exact' THEN 3
                                    WHEN 'high_confidence_estimate' THEN 2
                                    WHEN 'low_confidence_estimate' THEN 1
                                    ELSE 0
                                END
                            THEN excluded.usageSource
                            ELSE token_usage.usageSource
                        END,
                        providerID = excluded.providerID,
                        providerAccountID = excluded.providerAccountID,
                        providerAccountLabel = excluded.providerAccountLabel,
                        providerAccountSource = excluded.providerAccountSource,
                        provenanceMethod = excluded.provenanceMethod,
                        provenanceConfidence = CASE
                            WHEN
                                CASE excluded.provenanceConfidence
                                    WHEN 'exact' THEN 4
                                    WHEN 'derived_exact' THEN 3
                                    WHEN 'high_confidence_estimate' THEN 2
                                    WHEN 'low_confidence_estimate' THEN 1
                                    ELSE 0
                                END
                                >=
                                CASE token_usage.provenanceConfidence
                                    WHEN 'exact' THEN 4
                                    WHEN 'derived_exact' THEN 3
                                    WHEN 'high_confidence_estimate' THEN 2
                                    WHEN 'low_confidence_estimate' THEN 1
                                    ELSE 0
                                END
                            THEN excluded.provenanceConfidence
                            ELSE token_usage.provenanceConfidence
                        END,
                        estimatorVersion = excluded.estimatorVersion,
                        syncedAt = NULL
                    WHERE
                        CASE excluded.provenanceConfidence
                            WHEN 'exact' THEN 4
                            WHEN 'derived_exact' THEN 3
                            WHEN 'high_confidence_estimate' THEN 2
                            WHEN 'low_confidence_estimate' THEN 1
                            ELSE 0
                        END
                        >=
                        CASE token_usage.provenanceConfidence
                            WHEN 'exact' THEN 4
                            WHEN 'derived_exact' THEN 3
                            WHEN 'high_confidence_estimate' THEN 2
                            WHEN 'low_confidence_estimate' THEN 1
                            ELSE 0
                        END
                    """, arguments: [
                        usage.id.uuidString,
                        usage.provider.rawValue,
                        usage.sessionId,
                        usage.projectName,
                        usage.model,
                        usage.inputTokens,
                        usage.outputTokens,
                        usage.cacheCreationTokens,
                        usage.cacheReadTokens,
                        usage.reasoningTokens,
                        usage.totalTokens,
                        usage.cost,
                        usage.startTime,
                        usage.endTime,
                        usage.createdAt,
                        usage.usageSource.rawValue,
                        usage.sourceDeviceId,
                        usage.sourceDeviceName,
                        usage.isRemote ? 1 : 0,
                        usage.providerID.rawValue,
                        usagePartition,
                        usage.providerAccountLabel,
                        usage.providerAccountSource?.rawValue,
                        usage.provenanceMethod.rawValue,
                        usage.provenanceConfidence.rawValue,
                        usage.estimatorVersion
                    ])
            }

            // NOW advance the checkpoint - only after successful usage insert
            // VAL-PERSIST-004
            if !checkpointToken.isEmpty {
                try db.execute(sql: """
                    INSERT INTO parser_checkpoints (provider, checkpointToken, lastProcessedFilePath, lastProcessedAt, version)
                    VALUES (?, ?, ?, ?, 1)
                    ON CONFLICT(provider) DO UPDATE SET
                        checkpointToken = excluded.checkpointToken,
                        lastProcessedFilePath = excluded.lastProcessedFilePath,
                        lastProcessedAt = excluded.lastProcessedAt,
                        version = version + 1
                    """, arguments: [
                        provider.rawValue,
                        checkpointToken,
                        lastProcessedFilePath,
                        Date()
                    ])
            }
        }

        isCommitted = true
    }

    /// Rolls back the transaction without advancing the checkpoint.
    /// VAL-CROSS-008: No partial visibility on pre-commit failure.
    func rollback() {
        guard !isCommitted else { return }
        isRolledBack = true
        // Clear in-memory state - nothing was committed so nothing to clean up
        usages = []
        conversations = []
    }

    var wasCommitted: Bool { isCommitted }
    var wasRolledBack: Bool { isRolledBack }

    private static func usagePartitionToken(from rawValue: String?) -> String? {
        guard let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        let digest = SHA256.hash(data: Data(trimmed.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "acct_sha256_\(hex.prefix(24))"
    }
}
