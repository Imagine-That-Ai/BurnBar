import Foundation
import GRDB

public protocol OpenBurnBarDatabaseSecretStore: Sendable {
    func databasePassphrase() throws -> String
}

public enum OpenBurnBarDatabaseSecretError: Error, Equatable, CustomStringConvertible {
    case missingSecret
    case unavailable(String)

    public var description: String {
        switch self {
        case .missingSecret:
            return "No SQLCipher passphrase is available from SecretStore, headless env, or systemd credentials."
        case let .unavailable(reason):
            return "SecretStore unavailable: \(reason)"
        }
    }
}

public enum OpenBurnBarDatabaseOpenError: Error, Equatable, CustomStringConvertible {
    case codecUnavailable
    case invalidPassphrase
    case migrationFailed(restoredFromBackup: Bool, details: String)
    case plaintextFallbackRefused
    case wrongKeyOrCorrupt
    case secretUnavailable(String)

    public var description: String {
        switch self {
        case .codecUnavailable:
            return "SQLCipher codec is not active; refusing plaintext fallback."
        case .invalidPassphrase:
            return "SQLCipher passphrase contains unsupported characters."
        case let .migrationFailed(restoredFromBackup, details):
            return "Database migration failed (restoredFromBackup=\(restoredFromBackup)): \(details)"
        case .plaintextFallbackRefused:
            return "High-value OpenBurnBar state cannot open as plaintext."
        case .wrongKeyOrCorrupt:
            return "Encrypted database could not be opened with the supplied key, or it is corrupt."
        case let .secretUnavailable(reason):
            return "No usable database secret is available: \(reason)"
        }
    }
}

public struct OpenBurnBarHeadlessSecretStore: OpenBurnBarDatabaseSecretStore {
    public var environment: [String: String]
    public var fileReader: @Sendable (String) throws -> String

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileReader: @escaping @Sendable (String) throws -> String = { path in
            try String(contentsOfFile: path, encoding: .utf8)
        }
    ) {
        self.environment = environment
        self.fileReader = fileReader
    }

    public func databasePassphrase() throws -> String {
        if let passphrase = environment["OPENBURNBAR_DB_PASSPHRASE"]?.trimmedNonEmpty {
            return passphrase
        }
        if let credentialsDirectory = environment["CREDENTIALS_DIRECTORY"]?.trimmedNonEmpty {
            let path = URL(fileURLWithPath: credentialsDirectory)
                .appendingPathComponent("openburnbar-db-passphrase")
                .path
            let secret = try fileReader(path).trimmingCharacters(in: .whitespacesAndNewlines)
            if let passphrase = secret.trimmedNonEmpty {
                return passphrase
            }
        }
        throw OpenBurnBarDatabaseSecretError.missingSecret
    }
}

public struct OpenBurnBarStaticSecretStore: OpenBurnBarDatabaseSecretStore {
    public var passphrase: String?
    public var failure: OpenBurnBarDatabaseSecretError?

    public init(passphrase: String? = nil, failure: OpenBurnBarDatabaseSecretError? = nil) {
        self.passphrase = passphrase
        self.failure = failure
    }

    public func databasePassphrase() throws -> String {
        if let failure {
            throw failure
        }
        guard let passphrase = passphrase?.trimmedNonEmpty else {
            throw OpenBurnBarDatabaseSecretError.missingSecret
        }
        return passphrase
    }
}

public struct OpenBurnBarDatabaseOpenOptions: Sendable {
    public var secretStore: any OpenBurnBarDatabaseSecretStore
    public var role: OpenBurnBarDatabaseWriterRole
    public var failIfCodecUnavailable: Bool
    var codecAvailabilityOverride: Bool?
    var beforeMigration: (@Sendable () throws -> Void)?

    public init(
        secretStore: any OpenBurnBarDatabaseSecretStore = OpenBurnBarHeadlessSecretStore(),
        role: OpenBurnBarDatabaseWriterRole = .linuxEngine,
        failIfCodecUnavailable: Bool = true
    ) {
        self.secretStore = secretStore
        self.role = role
        self.failIfCodecUnavailable = failIfCodecUnavailable
        self.codecAvailabilityOverride = nil
        self.beforeMigration = nil
    }

    init(
        secretStore: any OpenBurnBarDatabaseSecretStore,
        role: OpenBurnBarDatabaseWriterRole = .linuxEngine,
        failIfCodecUnavailable: Bool = true,
        codecAvailabilityOverride: Bool? = nil,
        beforeMigration: (@Sendable () throws -> Void)? = nil
    ) {
        self.secretStore = secretStore
        self.role = role
        self.failIfCodecUnavailable = failIfCodecUnavailable
        self.codecAvailabilityOverride = codecAvailabilityOverride
        self.beforeMigration = beforeMigration
    }
}

public enum OpenBurnBarDatabaseWriterRole: String, Sendable {
    case linuxEngine = "linux_engine"
}

public struct OpenBurnBarDatabaseOwnershipDecision: Equatable, Sendable {
    public let soleWriterRole: OpenBurnBarDatabaseWriterRole
    public let concurrencyMechanism: String
    public let protectedConsumers: [String]

    public static let linuxEngineSoleWriter = OpenBurnBarDatabaseOwnershipDecision(
        soleWriterRole: .linuxEngine,
        concurrencyMechanism: "One Linux engine/daemon process owns the DatabasePool writer; shell, parser, cloud sync, and project-memory consumers use daemon RPC or read-only snapshots. WAL permits concurrent readers, but migrations and writes are serialized through this owner.",
        protectedConsumers: ["shell", "daemon", "parsers", "cloud_sync", "project_memory"]
    )
}

// Wraps a non-Sendable database handle; all access is internally synchronized.
// sendable-allowlist: database-handle-wrapper
public final class OpenBurnBarLocalDatabase: @unchecked Sendable {
    public static let ownershipDecision = OpenBurnBarDatabaseOwnershipDecision.linuxEngineSoleWriter

    let pool: DatabasePool
    private let database: OpenBurnBarDatabase
    private let passphrase: String

    private init(pool: DatabasePool, passphrase: String) {
        self.pool = pool
        self.passphrase = passphrase
        self.database = OpenBurnBarDatabase(
            databaseQueue: pool,
            migrationBackupConfigurationBuilder: {
                try Self.encryptedConfiguration(passphrase: passphrase)
            }
        )
    }

    public static var latestMigrationIdentifier: String {
        OpenBurnBarDatabase.latestMigrationIdentifier
    }

    public static var migrationIdentifiers: [String] {
        OpenBurnBarDatabase.migrator.migrations
    }

    public static func open(path: String, options: OpenBurnBarDatabaseOpenOptions) throws -> OpenBurnBarLocalDatabase {
        let passphrase: String
        do {
            passphrase = try options.secretStore.databasePassphrase()
        } catch {
            throw OpenBurnBarDatabaseOpenError.secretUnavailable(String(describing: error))
        }

        guard isSafePassphrase(passphrase) else {
            throw OpenBurnBarDatabaseOpenError.invalidPassphrase
        }
        let codecAvailable = options.codecAvailabilityOverride ?? isStorageEngineAvailable()
        guard codecAvailable else {
            if options.failIfCodecUnavailable {
                throw OpenBurnBarDatabaseOpenError.codecUnavailable
            }
            throw OpenBurnBarDatabaseOpenError.plaintextFallbackRefused
        }
        if FileManager.default.fileExists(atPath: path), isEncryptedDatabaseFile(at: path) == false {
            throw OpenBurnBarDatabaseOpenError.plaintextFallbackRefused
        }

        do {
            let pool = try DatabasePool(path: path, configuration: encryptedConfiguration(passphrase: passphrase))
            let local = OpenBurnBarLocalDatabase(pool: pool, passphrase: passphrase)
            try OpenBurnBarDatabase.configureWALMode(pool)
            try local.database.runMigrationsSafely(beforeMigration: options.beforeMigration)
            try local.verifyIntegrity()
            return local
        } catch let error as OpenBurnBarDatabaseOpenError {
            throw error
        } catch let error as OpenBurnBarDatabase.OpenBurnBarDatabaseError {
            switch error {
            case let .migrationFailed(restoredFromBackup, underlying):
                throw OpenBurnBarDatabaseOpenError.migrationFailed(
                    restoredFromBackup: restoredFromBackup,
                    details: String(describing: underlying)
                )
            case let .integrityCheckFailed(details):
                throw OpenBurnBarDatabaseOpenError.migrationFailed(
                    restoredFromBackup: false,
                    details: "integrity_check=\(details)"
                )
            case let .backupFailed(underlying):
                throw OpenBurnBarDatabaseOpenError.migrationFailed(
                    restoredFromBackup: false,
                    details: "backup=\(underlying)"
                )
            }
        } catch {
            throw OpenBurnBarDatabaseOpenError.wrongKeyOrCorrupt
        }
    }

    public func close() throws {
        try pool.close()
    }

    public func verifyIntegrity() throws {
        let result = try pool.write { db in
            try String.fetchOne(db, sql: "PRAGMA integrity_check") ?? "unknown"
        }
        guard result == "ok" else {
            throw OpenBurnBarDatabase.OpenBurnBarDatabaseError.integrityCheckFailed(details: result)
        }
    }

    public func migrationRows() throws -> [String] {
        try pool.read { db in
            try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid")
        }
    }

    public func schemaHash() throws -> String {
        let schema = try pool.read { db in
            try String.fetchAll(
                db,
                sql: """
                SELECT type || ':' || name || ':' || COALESCE(tbl_name, '') || ':' || COALESCE(sql, '')
                FROM sqlite_master
                WHERE name NOT LIKE 'sqlite_%'
                ORDER BY type, name, tbl_name, sql
                """
            ).joined(separator: "\n")
        }
        return OpenBurnBarSchemaHasher.sha256Hex(Data(schema.utf8))
    }

    public func createBackup() throws -> URL {
        guard let url = try database.createBackupIfNeeded() else {
            throw OpenBurnBarDatabase.OpenBurnBarDatabaseError.backupFailed(underlying: CocoaError(.fileNoSuchFile))
        }
        return url
    }

    public func restore(from backupURL: URL) throws {
        try database.restoreDatabaseFromBackup(backupURL: backupURL)
    }

    public func rawRows(sql: String) throws -> [[String: String]] {
        try pool.read { db in
            try Row.fetchAll(db, sql: sql).map { row in
                Dictionary(uniqueKeysWithValues: row.columnNames.map { name in
                    let value = row[name]
                    return (name, String(describing: value ?? "NULL"))
                })
            }
        }
    }

    public func upsertProviderAccount(_ account: OpenBurnBarProviderAccountRow) throws {
        try pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO provider_accounts (
                    id, providerID, label, identityHint, status, credentialKind,
                    storageScope, redactedLabel, sourceDeviceID, linkedSwitcherProfileID,
                    isDefault, sortKey, lastValidatedAt, lastRefreshAt, lastErrorCode,
                    schemaVersion, createdAt, updatedAt
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    providerID = excluded.providerID,
                    label = excluded.label,
                    identityHint = excluded.identityHint,
                    status = excluded.status,
                    credentialKind = excluded.credentialKind,
                    storageScope = excluded.storageScope,
                    redactedLabel = excluded.redactedLabel,
                    sourceDeviceID = excluded.sourceDeviceID,
                    linkedSwitcherProfileID = excluded.linkedSwitcherProfileID,
                    isDefault = excluded.isDefault,
                    sortKey = excluded.sortKey,
                    lastValidatedAt = excluded.lastValidatedAt,
                    lastRefreshAt = excluded.lastRefreshAt,
                    lastErrorCode = excluded.lastErrorCode,
                    schemaVersion = excluded.schemaVersion,
                    updatedAt = excluded.updatedAt
                """,
                arguments: account.databaseArguments
            )
        }
    }

    public func recordUsage(_ usage: OpenBurnBarUsageRow) throws {
        try pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO token_usage (
                    id, provider, sessionId, projectName, model, inputTokens,
                    outputTokens, cacheCreationTokens, cacheReadTokens, totalTokens,
                    cost, startTime, endTime, createdAt,
                    executionSourceID, executionSourceName, executionSourceKind,
                    executionSourceConfidence, providerID,
                    providerAccountID, providerAccountLabel, providerAccountSource,
                    usageSource, billingKind
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: usage.databaseArguments
            )
        }
    }

    public func upsertQuotaSnapshot(_ snapshot: OpenBurnBarQuotaSnapshotRow) throws {
        try pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO provider_quota_snapshots (
                    id, providerID, providerName, source, sourceID, sourceLabel,
                    period, quotaLimit, used, remaining, resetAt, planName,
                    rawJSON, fetchedAt, createdAt, updatedAt
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    providerName = excluded.providerName,
                    source = excluded.source,
                    sourceID = excluded.sourceID,
                    sourceLabel = excluded.sourceLabel,
                    period = excluded.period,
                    quotaLimit = excluded.quotaLimit,
                    used = excluded.used,
                    remaining = excluded.remaining,
                    resetAt = excluded.resetAt,
                    planName = excluded.planName,
                    rawJSON = excluded.rawJSON,
                    fetchedAt = excluded.fetchedAt,
                    updatedAt = excluded.updatedAt
                """,
                arguments: snapshot.databaseArguments
            )
        }
    }

    public func indexSearchFixture(_ fixture: OpenBurnBarSearchFixture) throws {
        try pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO search_documents (
                    id, sourceKind, sourceID, sourceVersionID, provider, projectName,
                    title, subtitle, bodyPreview, sourceUpdatedAt, indexedAt,
                    contentHash, createdAt, updatedAt
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    title = excluded.title,
                    bodyPreview = excluded.bodyPreview,
                    indexedAt = excluded.indexedAt
                """,
                arguments: fixture.documentArguments
            )
            for chunk in fixture.chunks {
                try db.execute(
                    sql: """
                    INSERT INTO search_chunks (
                        id, documentID, sourceKind, sourceID, sourceVersionID, ordinal,
                        startOffset, endOffset, messageStartOffset, messageEndOffset,
                        sectionPath, text, createdAt, updatedAt
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: chunk.chunkArguments(documentID: fixture.documentID)
                )
                try db.execute(
                    sql: """
                    INSERT INTO search_chunks_fts (chunkID, documentID, title, chunkText, projectName, provider)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        chunk.id,
                        fixture.documentID,
                        fixture.title,
                        chunk.text,
                        fixture.projectName,
                        fixture.provider
                    ]
                )
            }
            try db.execute(
                sql: """
                INSERT INTO embedding_models (id, provider, modelName, dimensions, distanceMetric, createdAt, updatedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO NOTHING
                """,
                arguments: [
                    fixture.embeddingModelID,
                    "fixture",
                    "fixture-embedding",
                    fixture.embeddingDimension,
                    "cosine",
                    fixture.now,
                    fixture.now
                ]
            )
            try db.execute(
                sql: """
                INSERT INTO embedding_versions (
                    id, modelID, versionTag, chunkerVersion, normalizationVersion,
                    promptVersion, isActive, createdAt, updatedAt
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO NOTHING
                """,
                arguments: [
                    fixture.embeddingVersionID,
                    fixture.embeddingModelID,
                    "fixture-v1",
                    "fixture-chunker-v1",
                    "fixture-l2-v1",
                    "fixture-prompt-v1",
                    true,
                    fixture.now,
                    fixture.now
                ]
            )
            for chunk in fixture.chunks {
                try db.execute(
                    sql: """
                    INSERT INTO chunk_embeddings (chunkID, embeddingVersionID, vectorBlob, createdAt, updatedAt)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        chunk.id,
                        fixture.embeddingVersionID,
                        chunk.vectorBlob,
                        fixture.now,
                        fixture.now
                    ]
                )
            }
            try db.execute(
                sql: """
                INSERT INTO vector_index_snapshots (
                    embeddingVersionID, backendID, state, fingerprint, dimensions,
                    distanceMetric, vectorCount, storageRelativePath, fileBytes,
                    backendVersion, errorCode, errorMessage, createdAt, updatedAt, lastBuiltAt
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(embeddingVersionID, backendID) DO UPDATE SET
                    fingerprint = excluded.fingerprint,
                    vectorCount = excluded.vectorCount,
                    state = excluded.state,
                    fileBytes = excluded.fileBytes,
                    updatedAt = excluded.updatedAt,
                    lastBuiltAt = excluded.lastBuiltAt
                """,
                arguments: [
                    fixture.embeddingVersionID,
                    fixture.vectorBackendID,
                    "ready",
                    fixture.vectorFingerprint,
                    fixture.embeddingDimension,
                    "cosine",
                    fixture.chunks.count,
                    fixture.snapshotPath,
                    fixture.vectorMetadataJSON.utf8.count,
                    "fixture-backend-v1",
                    nil,
                    nil,
                    fixture.now,
                    fixture.now,
                    fixture.now
                ]
            )
        }
    }

    public func lexicalSearch(_ query: String, limit: Int = 10) throws -> [OpenBurnBarSearchHit] {
        try pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT
                    search_chunks_fts.chunkID AS chunkID,
                    search_chunks_fts.documentID AS documentID,
                    bm25(search_chunks_fts) AS rank,
                    snippet(search_chunks_fts, 3, '<b>', '</b>', '…', 12) AS snippet,
                    c.text AS text
                FROM search_chunks_fts
                JOIN search_chunks AS c ON c.id = search_chunks_fts.chunkID
                WHERE search_chunks_fts MATCH ?
                ORDER BY rank ASC, search_chunks_fts.chunkID ASC
                LIMIT ?
                """,
                arguments: [query, limit]
            ).map { row in
                let rank: Double = row["rank"] ?? 0
                return OpenBurnBarSearchHit(
                    chunkID: row["chunkID"] as? String ?? "",
                    documentID: row["documentID"] as? String ?? "",
                    rank: rank,
                    snippet: row["snippet"] as? String ?? "",
                    text: row["text"] as? String ?? ""
                )
            }
        }
    }

    public func vectorSnapshotMetadata() throws -> [String: String] {
        let rows = try rawRows(
            sql: """
            SELECT
                embeddingVersionID,
                backendID,
                fingerprint,
                dimensions,
                distanceMetric,
                vectorCount,
                storageRelativePath,
                fileBytes,
                backendVersion,
                state
            FROM vector_index_snapshots
            ORDER BY embeddingVersionID, backendID
            """
        )
        return Dictionary(uniqueKeysWithValues: rows.enumerated().map { index, row in
            ("snapshot-\(index)", row.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "|"))
        })
    }

    public static func isCipherAvailable() -> Bool {
        (try? linkedCipherVersion()) != nil
    }

    public static func isStorageEngineAvailable() -> Bool {
        guard isCipherAvailable() else { return false }
        return (try? linkedStorageEngineSupportsFTS5()) == true
    }

    public static func linkedCipherVersion() throws -> String {
        let passphrase = "openburnbar-cipher-probe"
        let queue = try DatabaseQueue(path: ":memory:", configuration: try encryptedConfiguration(passphrase: passphrase))
        defer { try? queue.close() }
        guard let version = try queue.read({ db in try String.fetchOne(db, sql: "PRAGMA cipher_version") }),
              version.isEmpty == false else {
            throw OpenBurnBarDatabaseOpenError.codecUnavailable
        }
        return version
    }

    public static func linkedStorageEngineSupportsFTS5() throws -> Bool {
        let passphrase = "openburnbar-fts-probe"
        let queue = try DatabaseQueue(path: ":memory:", configuration: try encryptedConfiguration(passphrase: passphrase))
        defer { try? queue.close() }
        return try queue.read { db in
            let compileOptions = try String.fetchAll(db, sql: "PRAGMA compile_options")
            if compileOptions.contains("ENABLE_FTS5") {
                return true
            }
            do {
                try db.execute(sql: "CREATE VIRTUAL TABLE openburnbar_fts5_probe USING fts5(content)")
                try db.execute(sql: "DROP TABLE openburnbar_fts5_probe")
                return true
            } catch {
                return false
            }
        }
    }

    public static func linkedStorageCompileOptions() throws -> [String] {
        let passphrase = "openburnbar-compile-options-probe"
        let queue = try DatabaseQueue(path: ":memory:", configuration: try encryptedConfiguration(passphrase: passphrase))
        defer { try? queue.close() }
        return try queue.read { db in
            try String.fetchAll(db, sql: "PRAGMA compile_options")
        }
    }

    public static func isEncryptedDatabaseFile(at path: String) -> Bool {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              data.count >= OpenBurnBarSQLiteHeader.magic.count else {
            return false
        }
        return data.prefix(OpenBurnBarSQLiteHeader.magic.count) != OpenBurnBarSQLiteHeader.magic
    }

    static func encryptedConfiguration(passphrase: String) throws -> Configuration {
        guard isSafePassphrase(passphrase) else {
            throw OpenBurnBarDatabaseOpenError.invalidPassphrase
        }
        var config = Configuration()
        OpenBurnBarDatabase.applyPoolTuning(&config)
        config.prepareDatabase { db in
            try db.usePassphrase(passphrase)
            let version = try String.fetchOne(db, sql: "PRAGMA cipher_version")
            guard version?.isEmpty == false else {
                throw OpenBurnBarDatabaseOpenError.codecUnavailable
            }
            if db.configuration.readonly == false {
                try db.execute(sql: "PRAGMA foreign_keys = ON")
                try db.execute(sql: "PRAGMA journal_mode = WAL")
                try db.execute(sql: "PRAGMA wal_autocheckpoint = 1000")
                try db.execute(sql: "PRAGMA synchronous = NORMAL")
            }
        }
        return config
    }

    static func isSafePassphrase(_ passphrase: String) -> Bool {
        guard passphrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return false
        }
        return passphrase.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 0x20 && scalar.value != 0x27 && scalar.value != 0x5C
        }
    }
}

public struct OpenBurnBarProviderAccountRow: Equatable, Sendable {
    public var id: String
    public var providerID: String
    public var label: String
    public var identityHint: String?
    public var status: String
    public var credentialKind: String
    public var storageScope: String
    public var redactedLabel: String
    public var sourceDeviceID: String?
    public var linkedSwitcherProfileID: String?
    public var isDefault: Bool
    public var sortKey: Double
    public var lastValidatedAt: Date?
    public var lastRefreshAt: Date?
    public var lastErrorCode: String?
    public var schemaVersion: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String,
        providerID: String,
        label: String,
        identityHint: String?,
        status: String,
        credentialKind: String,
        storageScope: String,
        redactedLabel: String,
        sourceDeviceID: String?,
        linkedSwitcherProfileID: String?,
        isDefault: Bool,
        sortKey: Double,
        lastValidatedAt: Date?,
        lastRefreshAt: Date?,
        lastErrorCode: String?,
        schemaVersion: Int = 1,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.providerID = providerID
        self.label = label
        self.identityHint = identityHint
        self.status = status
        self.credentialKind = credentialKind
        self.storageScope = storageScope
        self.redactedLabel = redactedLabel
        self.sourceDeviceID = sourceDeviceID
        self.linkedSwitcherProfileID = linkedSwitcherProfileID
        self.isDefault = isDefault
        self.sortKey = sortKey
        self.lastValidatedAt = lastValidatedAt
        self.lastRefreshAt = lastRefreshAt
        self.lastErrorCode = lastErrorCode
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var databaseArguments: StatementArguments {
        [
            id, providerID, label, identityHint, status, credentialKind,
            storageScope, redactedLabel, sourceDeviceID, linkedSwitcherProfileID,
            isDefault, sortKey, lastValidatedAt, lastRefreshAt, lastErrorCode,
            schemaVersion, createdAt, updatedAt
        ]
    }
}

public struct OpenBurnBarUsageRow: Equatable, Sendable {
    public var id: String
    public var provider: String
    public var sessionID: String
    public var projectName: String
    public var model: String
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheCreationTokens: Int
    public var cacheReadTokens: Int
    public var totalTokens: Int
    public var cost: Double
    public var startTime: Date
    public var endTime: Date
    public var createdAt: Date
    public var executionSourceID: String
    public var executionSourceName: String
    public var executionSourceKind: String
    public var executionSourceConfidence: String
    public var providerID: String
    public var providerAccountID: String
    public var providerAccountLabel: String
    public var providerAccountSource: String

    /// How BurnBar ingested this row (a `UsageSource` raw value). Defaults to the
    /// `token_usage` schema default, so a caller that never set it writes exactly
    /// what the column would have defaulted to before this field existed.
    public var usageSource: String

    /// Billing provenance (`api` / `subscription` / `unknown`) — v60. `nil` means
    /// "classify me at write time" and the seam derives it from `provider` +
    /// `usageSource` via `OpenBurnBarBillingProvenance.classify`, the same stamp
    /// the macOS `UsageStore.upsertUsage` and the Windows write seam apply. Set it
    /// explicitly only when the caller already knows the kind from its ingest route.
    public var billingKind: String?

    /// The kind actually persisted: the stamped value, else the classifier's.
    public var effectiveBillingKind: String {
        billingKind ?? OpenBurnBarBillingProvenance.classify(
            provider: provider,
            usageSource: usageSource
        )
    }

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
        totalTokens: Int,
        cost: Double,
        startTime: Date,
        endTime: Date,
        createdAt: Date,
        executionSourceID: String = "unknown",
        executionSourceName: String = "Unknown",
        executionSourceKind: String = "unknown",
        executionSourceConfidence: String = "unknown",
        providerID: String,
        providerAccountID: String,
        providerAccountLabel: String,
        providerAccountSource: String,
        usageSource: String = "unknown",
        billingKind: String? = nil
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
        self.totalTokens = totalTokens
        self.cost = cost
        self.startTime = startTime
        self.endTime = endTime
        self.createdAt = createdAt
        self.executionSourceID = executionSourceID
        self.executionSourceName = executionSourceName
        self.executionSourceKind = executionSourceKind
        self.executionSourceConfidence = executionSourceConfidence
        self.providerID = providerID
        self.providerAccountID = providerAccountID
        self.providerAccountLabel = providerAccountLabel
        self.providerAccountSource = providerAccountSource
        self.usageSource = usageSource
        self.billingKind = billingKind
    }

    var databaseArguments: StatementArguments {
        [
            id, provider, sessionID, projectName, model, inputTokens,
            outputTokens, cacheCreationTokens, cacheReadTokens, totalTokens,
            cost, startTime, endTime, createdAt,
            executionSourceID, executionSourceName, executionSourceKind,
            executionSourceConfidence, providerID,
            providerAccountID, providerAccountLabel, providerAccountSource,
            usageSource, effectiveBillingKind
        ]
    }
}

public struct OpenBurnBarQuotaSnapshotRow: Equatable, Sendable {
    public var id: String
    public var providerID: String
    public var providerName: String
    public var source: String
    public var sourceID: String
    public var sourceLabel: String
    public var period: String
    public var quotaLimit: Double?
    public var used: Double?
    public var remaining: Double?
    public var resetAt: Date?
    public var planName: String?
    public var rawJSON: String
    public var fetchedAt: Date
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String,
        providerID: String,
        providerName: String,
        source: String,
        sourceID: String,
        sourceLabel: String,
        period: String,
        quotaLimit: Double?,
        used: Double?,
        remaining: Double?,
        resetAt: Date?,
        planName: String?,
        rawJSON: String,
        fetchedAt: Date,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.providerID = providerID
        self.providerName = providerName
        self.source = source
        self.sourceID = sourceID
        self.sourceLabel = sourceLabel
        self.period = period
        self.quotaLimit = quotaLimit
        self.used = used
        self.remaining = remaining
        self.resetAt = resetAt
        self.planName = planName
        self.rawJSON = rawJSON
        self.fetchedAt = fetchedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var databaseArguments: StatementArguments {
        [
            id, providerID, providerName, source, sourceID, sourceLabel,
            period, quotaLimit, used, remaining, resetAt, planName,
            rawJSON, fetchedAt, createdAt, updatedAt
        ]
    }
}

public struct OpenBurnBarSearchFixture: Equatable, Sendable {
    public var documentID: String
    public var sourceID: String
    public var projectName: String
    public var provider: String
    public var title: String
    public var bodyPreview: String
    public var chunks: [OpenBurnBarSearchFixtureChunk]
    public var embeddingModelID: String
    public var embeddingVersionID: String
    public var embeddingDimension: Int
    public var vectorBackendID: String
    public var snapshotPath: String
    public var vectorMetadataJSON: String
    public var now: Date

    public init(
        documentID: String,
        sourceID: String,
        projectName: String,
        provider: String,
        title: String,
        bodyPreview: String,
        chunks: [OpenBurnBarSearchFixtureChunk],
        embeddingModelID: String,
        embeddingVersionID: String,
        embeddingDimension: Int,
        vectorBackendID: String,
        snapshotPath: String,
        vectorMetadataJSON: String,
        now: Date
    ) {
        self.documentID = documentID
        self.sourceID = sourceID
        self.projectName = projectName
        self.provider = provider
        self.title = title
        self.bodyPreview = bodyPreview
        self.chunks = chunks
        self.embeddingModelID = embeddingModelID
        self.embeddingVersionID = embeddingVersionID
        self.embeddingDimension = embeddingDimension
        self.vectorBackendID = vectorBackendID
        self.snapshotPath = snapshotPath
        self.vectorMetadataJSON = vectorMetadataJSON
        self.now = now
    }

    var documentArguments: StatementArguments {
        [
            documentID,
            "conversation",
            sourceID,
            "",
            provider,
            projectName,
            title,
            nil,
            bodyPreview,
            now,
            now,
            documentContentHash,
            now,
            now
        ]
    }

    var documentContentHash: String {
        OpenBurnBarSchemaHasher.sha256Hex(Data("\(documentID)|\(title)|\(bodyPreview)".utf8))
    }

    var vectorFingerprint: String {
        OpenBurnBarSchemaHasher.sha256Hex(Data(vectorMetadataJSON.utf8))
    }
}

public struct OpenBurnBarSearchFixtureChunk: Equatable, Sendable {
    public var id: String
    public var sourceID: String
    public var ordinal: Int
    public var sectionPath: String
    public var text: String
    public var tokenCount: Int
    public var vectorBlob: Data

    public init(id: String, sourceID: String, ordinal: Int, sectionPath: String, text: String, tokenCount: Int, vectorBlob: Data) {
        self.id = id
        self.sourceID = sourceID
        self.ordinal = ordinal
        self.sectionPath = sectionPath
        self.text = text
        self.tokenCount = tokenCount
        self.vectorBlob = vectorBlob
    }

    func chunkArguments(documentID: String) -> StatementArguments {
        [
            id,
            documentID,
            "conversation",
            sourceID,
            "",
            ordinal,
            0,
            text.utf8.count,
            nil,
            nil,
            sectionPath,
            text,
            Date(timeIntervalSince1970: 1_800_000_000),
            Date(timeIntervalSince1970: 1_800_000_000)
        ]
    }
}

public struct OpenBurnBarSearchHit: Equatable, Sendable {
    public let chunkID: String
    public let documentID: String
    public let rank: Double
    public let snippet: String
    public let text: String
}

enum OpenBurnBarSQLiteHeader {
    static let magic = Data("SQLite format 3\u{0}".utf8)
}

extension String {
    var trimmedNonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

// MARK: - Billing provenance
//
// Folded into this file rather than given its own, because `OpenBurnBarData` is
// at its 20-file ceiling (budgets/core-target-membership-baseline.json) and that
// ratchet is shrink-only. This is the classifier's only production consumer, so
// co-locating it costs nothing in navigability. It cannot live beside the v60
// migration it mirrors: that file is byte-identical to its AgentLens twin and
// the migrator-parity ratchet fails the build if the two drift.

/// Write-time billing provenance for `token_usage` rows — real per-token API
/// dollars (`api`) vs the imputed list-price value of work that ran inside a flat
/// subscription plan (`subscription`).
///
/// This is the storage-layer peer of `BurnBarBillingProvenance` in
/// OpenBurnBarKernel. It is deliberately a separate, string-keyed mirror rather
/// than a re-export: `OpenBurnBarData` depends only on GRDB so it stays buildable
/// inside the Linux/daemon boundary build, where the Kernel's `AgentProvider` and
/// `UsageSource` enums are not linked. The three surfaces that can decide a row's
/// billing kind — this classifier, the Kernel classifier, and the v60 SQL backfill
/// (`OpenBurnBarDatabase.billingKindBackfillSQL`) — must agree on every input, so
/// `OpenBurnBarBillingProvenanceTests` executes that exact SQL against every
/// combination this classifier distinguishes and asserts the answers match.
///
/// `unknown` is the honest bucket, never a silent fold into either side: an
/// `unknown` can be reclassified later, a wrong guess could not be undone.
public enum OpenBurnBarBillingProvenance {
    /// Real per-token dollars billed against an API key.
    public static let api = "api"

    /// Imputed list-price value of work covered by a flat plan.
    public static let subscription = "subscription"

    /// Not classifiable without guessing — the schema default.
    public static let unknown = "unknown"

    /// Harnesses whose parsed sessions are overwhelmingly plan-billed. Mirror of
    /// the backfill's first `provider_log` arm (`AgentProvider` raw values).
    static let subscriptionFirstProviders: Set<String> = [
        "Claude Code", "Codex", "Copilot", "Cursor", "Cursor Agent",
        "Factory", "Junie", "Windsurf", "Warp"
    ]

    /// Bring-your-own-key harnesses: parsed sessions bill against the user's own
    /// API key. Mirror of the backfill's second `provider_log` arm.
    static let apiKeyFirstProviders: Set<String> = [
        "Aider", "Hermes", "DeepSeek", "OpenAI", "xAI"
    ]

    /// The billing kind for a row ingested from `usageSource` for `provider`.
    /// Billing-API and daemon-gateway ingest are real dollars by construction (the
    /// daemon gateway only ever dials key-backed provider slots), so the provider
    /// name is consulted only for parsed harness logs — exactly as the SQL `CASE`
    /// does, including for provider names this build has never heard of.
    public static func classify(provider: String, usageSource: String) -> String {
        if usageSource == "billing_api" || usageSource == "daemon" { return api }
        guard usageSource == "provider_log" else { return unknown }
        if subscriptionFirstProviders.contains(provider) { return subscription }
        return apiKeyFirstProviders.contains(provider) ? api : unknown
    }
}
