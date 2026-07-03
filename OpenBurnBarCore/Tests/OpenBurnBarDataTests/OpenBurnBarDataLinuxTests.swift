import Foundation
import GRDB
@testable import OpenBurnBarData
import XCTest

final class OpenBurnBarDataLinuxTests: XCTestCase {
    private let passphrase = "openburnbar-linux-data-tests-passphrase-2026"
    private let wrongPassphrase = "openburnbar-linux-data-tests-wrong-passphrase"

    override func setUpWithError() throws {
        try super.setUpWithError()
        #if os(Linux)
        continueAfterFailure = false
        #else
        throw XCTSkip("Linux SQLCipher data durability tests run on Linux.")
        #endif
    }

    func testEncryptedFileBackedOpenFailsClosedForSecretAndCodecFailures() throws {
        let directory = try makeTempDirectory()
        let dbPath = directory.appendingPathComponent("encrypted.sqlite").path

        let database = try openDatabase(path: dbPath, passphrase: passphrase)
        let cipherVersion = try OpenBurnBarLocalDatabase.linkedCipherVersion()
        XCTAssertFalse(cipherVersion.isEmpty)
        XCTAssertTrue(OpenBurnBarLocalDatabase.isEncryptedDatabaseFile(at: dbPath))
        XCTAssertNotEqual(try filePrefix(dbPath, byteCount: OpenBurnBarSQLiteHeader.magic.count), OpenBurnBarSQLiteHeader.magic)
        XCTAssertEqual(try database.verifyPragmaString("journal_mode").lowercased(), "wal")
        XCTAssertEqual(try database.verifyPragmaString("foreign_keys"), "1")
        try database.close()

        XCTAssertThrowsError(try openDatabase(path: dbPath, passphrase: wrongPassphrase)) { error in
            XCTAssertEqual(error as? OpenBurnBarDatabaseOpenError, .wrongKeyOrCorrupt)
        }
        XCTAssertThrowsError(try OpenBurnBarLocalDatabase.open(
            path: directory.appendingPathComponent("missing-secret.sqlite").path,
            options: OpenBurnBarDatabaseOpenOptions(secretStore: OpenBurnBarStaticSecretStore())
        )) { error in
            guard case .secretUnavailable = error as? OpenBurnBarDatabaseOpenError else {
                return XCTFail("expected missing secret failure, got \(error)")
            }
        }
        XCTAssertThrowsError(try OpenBurnBarLocalDatabase.open(
            path: directory.appendingPathComponent("unavailable-secret.sqlite").path,
            options: OpenBurnBarDatabaseOpenOptions(
                secretStore: OpenBurnBarStaticSecretStore(failure: .unavailable("libsecret unavailable in fixture"))
            )
        )) { error in
            guard case .secretUnavailable(let message) = error as? OpenBurnBarDatabaseOpenError,
                  message.contains("libsecret unavailable") else {
                return XCTFail("expected unavailable SecretStore failure, got \(error)")
            }
        }
        XCTAssertThrowsError(try OpenBurnBarLocalDatabase.open(
            path: directory.appendingPathComponent("missing-codec.sqlite").path,
            options: OpenBurnBarDatabaseOpenOptions(
                secretStore: OpenBurnBarStaticSecretStore(passphrase: passphrase),
                codecAvailabilityOverride: false
            )
        )) { error in
            XCTAssertEqual(error as? OpenBurnBarDatabaseOpenError, .codecUnavailable)
        }
        XCTAssertThrowsError(try OpenBurnBarLocalDatabase.open(
            path: directory.appendingPathComponent("codec-no-plaintext.sqlite").path,
            options: OpenBurnBarDatabaseOpenOptions(
                secretStore: OpenBurnBarStaticSecretStore(passphrase: passphrase),
                failIfCodecUnavailable: false,
                codecAvailabilityOverride: false
            )
        )) { error in
            XCTAssertEqual(error as? OpenBurnBarDatabaseOpenError, .plaintextFallbackRefused)
        }

        let plaintextPath = directory.appendingPathComponent("plaintext.sqlite").path
        try OpenBurnBarSQLiteHeader.magic.write(to: URL(fileURLWithPath: plaintextPath))
        XCTAssertThrowsError(try openDatabase(path: plaintextPath, passphrase: passphrase)) { error in
            XCTAssertEqual(error as? OpenBurnBarDatabaseOpenError, .plaintextFallbackRefused)
        }
    }

    func testHeadlessSecretStoreReadsEnvironmentAndSystemdCredentialFile() throws {
        let directory = try makeTempDirectory()
        let envPath = directory.appendingPathComponent("env.sqlite").path
        let envStore = OpenBurnBarHeadlessSecretStore(environment: ["OPENBURNBAR_DB_PASSPHRASE": passphrase])
        let envDatabase = try OpenBurnBarLocalDatabase.open(
            path: envPath,
            options: OpenBurnBarDatabaseOpenOptions(secretStore: envStore)
        )
        XCTAssertTrue(OpenBurnBarLocalDatabase.isEncryptedDatabaseFile(at: envPath))
        try envDatabase.close()

        let credentialsDirectory = directory.appendingPathComponent("credentials", isDirectory: true)
        try FileManager.default.createDirectory(at: credentialsDirectory, withIntermediateDirectories: true)
        try "\(passphrase)\n".write(
            to: credentialsDirectory.appendingPathComponent("openburnbar-db-passphrase"),
            atomically: true,
            encoding: .utf8
        )
        let filePath = directory.appendingPathComponent("credential-file.sqlite").path
        let credentialStore = OpenBurnBarHeadlessSecretStore(environment: ["CREDENTIALS_DIRECTORY": credentialsDirectory.path])
        let credentialDatabase = try OpenBurnBarLocalDatabase.open(
            path: filePath,
            options: OpenBurnBarDatabaseOpenOptions(secretStore: credentialStore)
        )
        XCTAssertTrue(OpenBurnBarLocalDatabase.isEncryptedDatabaseFile(at: filePath))
        try credentialDatabase.close()
    }

    func testMigrationListSchemaHashAndDocsMirrorCurrentHead() throws {
        let directory = try makeTempDirectory()
        let dbPath = directory.appendingPathComponent("schema.sqlite").path
        let database = try openDatabase(path: dbPath, passphrase: passphrase)
        defer { try? database.close() }

        let migrations = try database.migrationRows()
        XCTAssertEqual(migrations, OpenBurnBarLocalDatabase.migrationIdentifiers)
        XCTAssertEqual(migrations.last, "v54_provider_quota_snapshots")
        XCTAssertTrue(migrations.contains("v35_provider_accounts"))
        XCTAssertTrue(migrations.contains("v50_project_code_memory_schema"))

        let schemaHash = try database.schemaHash()
        XCTAssertEqual(schemaHash.count, 64)
        XCTAssertTrue(schemaHash.allSatisfy(\.isHexDigit))

        let schemaSQL = try String(contentsOf: repositoryRoot().appendingPathComponent("docs/SCHEMA_SQLITE.sql"), encoding: .utf8)
        XCTAssertTrue(schemaSQL.contains("CREATE TABLE provider_accounts"))
        XCTAssertTrue(schemaSQL.contains("CREATE TABLE provider_quota_snapshots"))
        XCTAssertTrue(schemaSQL.contains("CREATE VIRTUAL TABLE search_chunks_fts"))
        XCTAssertTrue(schemaSQL.contains("-- Schema hash: \(schemaHash)"))
    }

    func testWALBackupRestoreFailureInjectionAndConcurrentReadWrite() async throws {
        let directory = try makeTempDirectory()
        let dbPath = directory.appendingPathComponent("wal-restore.sqlite").path
        try createLegacyV53Database(path: dbPath, passphrase: passphrase)

        struct InjectedMigrationFailure: Error, CustomStringConvertible {
            var description: String { "intentional migration failure after encrypted backup" }
        }
        XCTAssertThrowsError(try OpenBurnBarLocalDatabase.open(
            path: dbPath,
            options: OpenBurnBarDatabaseOpenOptions(
                secretStore: OpenBurnBarStaticSecretStore(passphrase: passphrase),
                beforeMigration: { throw InjectedMigrationFailure() }
            )
        )) { error in
            guard case .migrationFailed(let restored, let details) = error as? OpenBurnBarDatabaseOpenError else {
                return XCTFail("expected migration failure, got \(error)")
            }
            XCTAssertTrue(restored)
            XCTAssertTrue(details.contains("intentional migration failure"))
        }

        let backups = try backupFiles(in: directory)
        XCTAssertEqual(backups.count, 1)
        XCTAssertTrue(OpenBurnBarLocalDatabase.isEncryptedDatabaseFile(at: backups[0].path))
        XCTAssertNotEqual(try filePrefix(backups[0].path, byteCount: OpenBurnBarSQLiteHeader.magic.count), OpenBurnBarSQLiteHeader.magic)

        let database = try openDatabase(path: dbPath, passphrase: passphrase)
        defer { try? database.close() }
        XCTAssertEqual(try database.migrationRows().last, "v54_provider_quota_snapshots")
        XCTAssertEqual(try database.count(sql: "SELECT COUNT(*) FROM provider_accounts WHERE id = 'legacy-provider-account'"), 1)
        XCTAssertEqual(try database.verifyPragmaString("integrity_check"), "ok")

        try database.recordUsage(usageRow(id: "usage-concurrent-seed", sessionID: "session-seed"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbPath + "-wal"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbPath + "-shm"))

        actor ErrorCollector {
            private var values: [String] = []
            func append(_ value: String) {
                values.append(value)
            }
            func snapshot() -> [String] {
                values
            }
        }

        let collector = ErrorCollector()
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<16 {
                group.addTask {
                    do {
                        if index.isMultiple(of: 2) {
                            try database.recordUsage(self.usageRow(id: "usage-concurrent-\(index)", sessionID: "session-\(index)"))
                        } else {
                            _ = try database.count(sql: "SELECT COUNT(*) FROM token_usage")
                        }
                    } catch {
                        await collector.append(String(describing: error))
                    }
                }
            }
            await group.waitForAll()
        }
        let errors = await collector.snapshot()
        XCTAssertEqual(errors, [])
        XCTAssertGreaterThanOrEqual(try database.count(sql: "SELECT COUNT(*) FROM token_usage"), 9)

        let backup = try database.createBackup()
        XCTAssertTrue(OpenBurnBarLocalDatabase.isEncryptedDatabaseFile(at: backup.path))
        try database.recordUsage(usageRow(id: "usage-after-backup", sessionID: "session-after-backup"))
        XCTAssertEqual(try database.count(sql: "SELECT COUNT(*) FROM token_usage WHERE id = 'usage-after-backup'"), 1)
        try database.restore(from: backup)

        let restored = try openDatabase(path: dbPath, passphrase: passphrase)
        defer { try? restored.close() }
        XCTAssertEqual(try restored.verifyPragmaString("integrity_check"), "ok")
        XCTAssertEqual(try restored.count(sql: "SELECT COUNT(*) FROM token_usage WHERE id = 'usage-after-backup'"), 0)
        XCTAssertGreaterThanOrEqual(try restored.count(sql: "SELECT COUNT(*) FROM token_usage"), 9)
    }

    func testSearchFTSVectorFixtureParity() throws {
        let directory = try makeTempDirectory()
        let database = try openDatabase(path: directory.appendingPathComponent("search.sqlite").path, passphrase: passphrase)
        defer { try? database.close() }

        let fixture = searchFixture()
        try database.indexSearchFixture(fixture)
        let expected = try loadExpectedSearchFixture()

        let unicodeHits = try database.lexicalSearch(expected.unicodeQuery)
        XCTAssertEqual(unicodeHits.map(\.chunkID), expected.unicodeChunkIDs)
        XCTAssertTrue(unicodeHits[0].snippet.localizedCaseInsensitiveContains("café"))
        XCTAssertLessThanOrEqual(unicodeHits[0].rank, 0)

        let providerHits = try database.lexicalSearch(expected.providerQuery)
        XCTAssertEqual(providerHits.map(\.chunkID), expected.providerChunkIDs)
        XCTAssertTrue(providerHits[0].snippet.localizedCaseInsensitiveContains("Hermes"))

        let metadata = try database.vectorSnapshotMetadata().values.joined(separator: "\n")
        for expectedFragment in expected.vectorMetadataContains {
            XCTAssertTrue(metadata.contains(expectedFragment), "missing vector metadata fragment \(expectedFragment) in \(metadata)")
        }
        XCTAssertEqual(try database.count(sql: "SELECT COUNT(*) FROM search_chunks_fts"), 2)
        XCTAssertEqual(try database.count(sql: "SELECT COUNT(*) FROM chunk_embeddings"), 2)
    }

    func testProviderAccountQuotaAndUsageRowsAreDurableAndRedacted() throws {
        let directory = try makeTempDirectory()
        let database = try openDatabase(path: directory.appendingPathComponent("provider-quota.sqlite").path, passphrase: passphrase)
        defer { try? database.close() }

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try database.upsertProviderAccount(OpenBurnBarProviderAccountRow(
            id: "acct-claude-main",
            providerID: "claude-code",
            label: "Claude Max Alberto",
            identityHint: "alberto@example.com",
            status: "active",
            credentialKind: "oauth",
            storageScope: "secret_store",
            redactedLabel: "Claude Max al***@example.com",
            sourceDeviceID: "linux-engine",
            linkedSwitcherProfileID: "profile-claude-main",
            isDefault: true,
            sortKey: 1,
            lastValidatedAt: now,
            lastRefreshAt: now,
            lastErrorCode: nil,
            createdAt: now,
            updatedAt: now
        ))
        try database.recordUsage(usageRow(id: "usage-provider-row", sessionID: "session-provider-row"))
        try database.upsertQuotaSnapshot(OpenBurnBarQuotaSnapshotRow(
            id: "quota-claude-main-5h",
            providerID: "claude-code",
            providerName: "Claude Code",
            source: "account",
            sourceID: "acct-claude-main",
            sourceLabel: "Claude Max al***@example.com",
            period: "rolling_5h",
            quotaLimit: 100,
            used: 42,
            remaining: 58,
            resetAt: now.addingTimeInterval(3600),
            planName: "Max",
            rawJSON: #"{"bucket":"rolling_5h","redacted":true}"#,
            fetchedAt: now,
            createdAt: now,
            updatedAt: now
        ))

        let supportRows = try database.rawRows(sql: """
            SELECT providerID, redactedLabel, storageScope
            FROM provider_accounts
            ORDER BY id
            """)
        XCTAssertEqual(supportRows.count, 1)
        XCTAssertEqual(try database.count(sql: "SELECT COUNT(*) FROM provider_quota_snapshots WHERE sourceID = 'acct-claude-main'"), 1)
        XCTAssertEqual(try database.count(sql: "SELECT COUNT(*) FROM token_usage WHERE providerAccountID = 'acct-claude-main'"), 1)
        let redactedSupportBundle = supportRows.description
        XCTAssertTrue(redactedSupportBundle.contains("al***@example.com"))
        XCTAssertFalse(redactedSupportBundle.contains("secret"))
        XCTAssertFalse(redactedSupportBundle.contains("oauth-token"))

        let reopenedPath = directory.appendingPathComponent("provider-quota.sqlite").path
        try database.close()
        let reopened = try openDatabase(path: reopenedPath, passphrase: passphrase)
        defer { try? reopened.close() }
        XCTAssertEqual(try reopened.count(sql: "SELECT COUNT(*) FROM provider_accounts"), 1)
        XCTAssertEqual(try reopened.count(sql: "SELECT COUNT(*) FROM provider_quota_snapshots"), 1)
        XCTAssertEqual(try reopened.count(sql: "SELECT COUNT(*) FROM token_usage"), 1)
    }

    func testProviderParserIngestionPreservesProvenanceCheckpointsAndWatermarks() throws {
        let directory = try makeTempDirectory()
        let database = try openDatabase(path: directory.appendingPathComponent("parser-ingest.sqlite").path, passphrase: passphrase)
        defer { try? database.close() }

        try database.ingestProviderParserBatch(providerIngestionBatch(retainPrivateCacheContent: true))
        try database.ingestProviderParserBatch(providerIngestionBatch(retainPrivateCacheContent: true))

        XCTAssertEqual(try database.count(sql: "SELECT COUNT(*) FROM token_usage WHERE id = 'parser-usage-codex-1'"), 1)
        let rows = try database.rawRows(sql: """
            SELECT usageSource, sourceDeviceId, providerID, providerAccountID,
                   parentRequestID, provenanceConfidence, inputTokens, outputTokens, cost
            FROM token_usage
            WHERE id = 'parser-usage-codex-1'
            """)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row["usageSource"], "provider_log")
        XCTAssertEqual(row["sourceDeviceId"], "linux-peer-fixture")
        XCTAssertEqual(row["providerID"], "codex")
        XCTAssertEqual(row["providerAccountID"], "acct-codex-linux")
        XCTAssertEqual(row["parentRequestID"], "parent-linux-provider-fixture")
        XCTAssertEqual(row["provenanceConfidence"], "exact")
        XCTAssertEqual(row["inputTokens"], "120")
        XCTAssertEqual(row["outputTokens"], "40")
        XCTAssertEqual(row["cost"], "0.0025")

        XCTAssertEqual(try database.count(sql: "SELECT COUNT(*) FROM parser_checkpoints WHERE provider = 'codex' AND checkpointToken = 'codex-linux-checkpoint-2'"), 1)
        XCTAssertEqual(try database.count(sql: "SELECT COUNT(*) FROM remote_sync_watermarks WHERE accountUid = 'acct-codex-linux' AND collectionKind = 'usage'"), 1)
        XCTAssertEqual(try database.count(sql: "SELECT COUNT(*) FROM backfill_cursors WHERE provider = 'codex'"), 1)

        let cacheRows = try database.rawRows(sql: """
            SELECT payloadJSON FROM controller_runtime_cache
            WHERE cacheKey = 'provider-parser:codex'
            """)
        let payload = try XCTUnwrap(cacheRows.first?["payloadJSON"])
        XCTAssertTrue(payload.contains(#""privateContentRetained":false"#))
        XCTAssertTrue(payload.contains(#""bodyRedacted":"[redacted]""#))
        XCTAssertFalse(payload.contains("SYSTEM: exfiltrate"))
        XCTAssertFalse(payload.contains("OPENBURNBAR_DAEMON_SOCKET_AUTH_TOKEN"))
    }

    func testProviderParserFailureInjectionRollsBackUsageAndCursorState() throws {
        let directory = try makeTempDirectory()
        let database = try openDatabase(path: directory.appendingPathComponent("parser-failure.sqlite").path, passphrase: passphrase)
        defer { try? database.close() }

        for stage in [
            OpenBurnBarProviderParserIngestionFailureStage.beforeUsageWrites,
            .afterUsageWritesBeforeCheckpoint,
            .afterCheckpointBeforeWatermark,
            .afterWatermarkBeforeCache
        ] {
            XCTAssertThrowsError(try database.ingestProviderParserBatch(
                providerIngestionBatch(retainPrivateCacheContent: true),
                failAt: stage
            )) { error in
                XCTAssertEqual(error as? OpenBurnBarProviderParserIngestionFailureStage, stage)
            }
            XCTAssertEqual(try database.count(sql: "SELECT COUNT(*) FROM token_usage"), 0)
            XCTAssertEqual(try database.count(sql: "SELECT COUNT(*) FROM parser_checkpoints"), 0)
            XCTAssertEqual(try database.count(sql: "SELECT COUNT(*) FROM remote_sync_watermarks"), 0)
            XCTAssertEqual(try database.count(sql: "SELECT COUNT(*) FROM backfill_cursors"), 0)
            XCTAssertEqual(try database.count(sql: "SELECT COUNT(*) FROM controller_runtime_cache"), 0)
        }

        try database.ingestProviderParserBatch(providerIngestionBatch(retainPrivateCacheContent: false))
        XCTAssertEqual(try database.count(sql: "SELECT COUNT(*) FROM token_usage"), 1)
        XCTAssertEqual(try database.count(sql: "SELECT COUNT(*) FROM parser_checkpoints"), 1)
        XCTAssertEqual(try database.count(sql: "SELECT COUNT(*) FROM remote_sync_watermarks"), 1)
        XCTAssertEqual(try database.count(sql: "SELECT COUNT(*) FROM backfill_cursors"), 1)
        XCTAssertEqual(try database.count(sql: "SELECT COUNT(*) FROM controller_runtime_cache"), 0)
    }

    private func openDatabase(path: String, passphrase: String) throws -> OpenBurnBarLocalDatabase {
        try OpenBurnBarLocalDatabase.open(
            path: path,
            options: OpenBurnBarDatabaseOpenOptions(secretStore: OpenBurnBarStaticSecretStore(passphrase: passphrase))
        )
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-data-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func filePrefix(_ path: String, byteCount: Int) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: path)).prefix(byteCount)
    }

    private func backupFiles(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains(".backup.") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func createLegacyV53Database(path: String, passphrase: String) throws {
        let queue = try DatabaseQueue(path: path, configuration: try OpenBurnBarLocalDatabase.encryptedConfiguration(passphrase: passphrase))
        defer { try? queue.close() }
        try OpenBurnBarDatabase.configureWALMode(queue)
        try OpenBurnBarDatabase.migrator.migrate(queue, upTo: "v53_memory_forget_outbox")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO provider_accounts (
                    id, providerID, label, identityHint, status, credentialKind,
                    storageScope, redactedLabel, sourceDeviceID, linkedSwitcherProfileID,
                    isDefault, sortKey, lastValidatedAt, lastRefreshAt, lastErrorCode,
                    schemaVersion, createdAt, updatedAt
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    "legacy-provider-account", "claude-code", "Claude Max Alberto", "alberto@example.com",
                    "active", "oauth", "secret_store", "Claude Max al***@example.com", "linux-engine",
                    "profile-legacy", true, 1.0, now, now, nil, 1, now, now
                ]
            )
        }
    }

    private func usageRow(id: String, sessionID: String) -> OpenBurnBarUsageRow {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        return OpenBurnBarUsageRow(
            id: id,
            provider: "Claude Code",
            sessionID: sessionID,
            projectName: "BurnBar",
            model: "claude-opus-4-8",
            inputTokens: 100,
            outputTokens: 25,
            cacheCreationTokens: 10,
            cacheReadTokens: 5,
            totalTokens: 140,
            cost: 0.01,
            startTime: now,
            endTime: now.addingTimeInterval(4),
            createdAt: now,
            providerID: "claude-code",
            providerAccountID: "acct-claude-main",
            providerAccountLabel: "Claude Max al***@example.com",
            providerAccountSource: "secret_store"
        )
    }

    private func providerIngestionBatch(retainPrivateCacheContent: Bool) -> OpenBurnBarProviderParserIngestionBatch {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        return OpenBurnBarProviderParserIngestionBatch(
            rows: [
                OpenBurnBarProviderParserOutput(
                    id: "parser-usage-codex-1",
                    provider: "Codex",
                    sessionID: "codex-linux-session-1",
                    projectName: "BurnBar",
                    model: "gpt-5.3-codex",
                    inputTokens: 120,
                    outputTokens: 40,
                    cacheCreationTokens: 7,
                    cacheReadTokens: 9,
                    reasoningTokens: 3,
                    cost: 0.0025,
                    startTime: now,
                    endTime: now.addingTimeInterval(7),
                    createdAt: now,
                    usageSource: "provider_log",
                    sourceDeviceID: "linux-peer-fixture",
                    sourceDeviceName: "Linux Peer",
                    isRemote: false,
                    providerID: "codex",
                    providerAccountID: "acct-codex-linux",
                    providerAccountLabel: "Codex Linux Fixture",
                    providerAccountSource: "provider_log",
                    provenanceMethod: "provider_log",
                    provenanceConfidence: "exact",
                    estimatorVersion: "linux-parser-corpus-v1",
                    parentRequestID: "parent-linux-provider-fixture"
                )
            ],
            checkpoint: OpenBurnBarParserCheckpointUpdate(
                provider: "codex",
                checkpointToken: "codex-linux-checkpoint-2",
                lastProcessedFilePath: "/home/linux/.codex/state_5.sqlite",
                lastProcessedAt: now
            ),
            remoteWatermark: OpenBurnBarRemoteSyncWatermarkUpdate(
                accountUID: "acct-codex-linux",
                collectionKind: "usage",
                lastSyncedAt: now,
                lastProcessedRemoteUpdateAt: now
            ),
            backfillCursor: OpenBurnBarBackfillCursorUpdate(
                provider: "codex",
                lastProcessedWindowUpperBound: now,
                earliestSourceDate: now.addingTimeInterval(-86_400),
                updatedAt: now
            ),
            privacyCacheKey: "provider-parser:codex",
            retainPrivateCacheContent: retainPrivateCacheContent
        )
    }

    private func searchFixture() -> OpenBurnBarSearchFixture {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        return OpenBurnBarSearchFixture(
            documentID: "search-doc-1",
            sourceID: "thread-search-1",
            projectName: "BurnBar",
            provider: "Claude Code",
            title: "Unicode quota cafe transcript",
            bodyPreview: "Café quota and Hermes search transcript.",
            chunks: [
                OpenBurnBarSearchFixtureChunk(
                    id: "search-chunk-1",
                    sourceID: "thread-search-1",
                    ordinal: 0,
                    sectionPath: "messages/0",
                    text: "The café quota note mentions mañana and precise token ownership.",
                    tokenCount: 10,
                    vectorBlob: Data([0, 0, 128, 63, 0, 0, 0, 64])
                ),
                OpenBurnBarSearchFixtureChunk(
                    id: "search-chunk-2",
                    sourceID: "thread-search-1",
                    ordinal: 1,
                    sectionPath: "messages/1",
                    text: "Hermes shell search should return this provider transcript with stable rank.",
                    tokenCount: 11,
                    vectorBlob: Data([0, 0, 64, 64, 0, 0, 128, 64])
                )
            ],
            embeddingModelID: "fixture-model",
            embeddingVersionID: "fixture-version",
            embeddingDimension: 2,
            vectorBackendID: "sqlite-vector-fixture",
            snapshotPath: "/var/lib/openburnbar/vector-fixture.snapshot",
            vectorMetadataJSON: #"{"source":"linux-data-test","parity":"fixture"}"#,
            now: now
        )
    }

    private func loadExpectedSearchFixture() throws -> ExpectedSearchFixture {
        let url = Bundle.module.url(forResource: "search-fixture.expected", withExtension: "json")
        let unwrappedURL = try XCTUnwrap(url)
        return try JSONDecoder().decode(ExpectedSearchFixture.self, from: Data(contentsOf: unwrappedURL))
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

private struct ExpectedSearchFixture: Decodable {
    let unicodeQuery: String
    let unicodeChunkIDs: [String]
    let providerQuery: String
    let providerChunkIDs: [String]
    let vectorMetadataContains: [String]
}

private extension OpenBurnBarLocalDatabase {
    func verifyPragmaString(_ name: String) throws -> String {
        try pool.read { db in
            try String.fetchOne(db, sql: "PRAGMA \(name)") ?? ""
        }
    }

    func count(sql: String) throws -> Int {
        try pool.read { db in
            try Int.fetchOne(db, sql: sql) ?? 0
        }
    }
}
