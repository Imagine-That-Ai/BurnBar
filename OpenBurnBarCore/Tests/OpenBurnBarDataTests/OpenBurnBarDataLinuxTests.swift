import Foundation
import GRDB
@testable import OpenBurnBarData
import XCTest

public final class OpenBurnBarDataLinuxTests: XCTestCase {
    private let passphrase = "openburnbar-linux-data-tests-passphrase-2026"
    private let wrongPassphrase = "openburnbar-linux-data-tests-wrong-passphrase"

    override public func setUpWithError() throws {
        try super.setUpWithError()
        #if os(Linux)
        continueAfterFailure = false
        #else
        throw XCTSkip("Linux SQLCipher data durability tests run on Linux.")
        #endif
    }

    public func testEncryptedFileBackedOpenFailsClosedForSecretAndCodecFailures() throws {
        let directory = try makeTempDirectory()
        let dbPath = directory.appendingPathComponent("encrypted.sqlite").path

        let database = try openDatabase(path: dbPath, passphrase: passphrase)
        let cipherVersion = try OpenBurnBarLocalDatabase.linkedCipherVersion()
        let compileOptions = try OpenBurnBarLocalDatabase.linkedStorageCompileOptions()
        let ownership = OpenBurnBarLocalDatabase.ownershipDecision
        XCTAssertFalse(cipherVersion.isEmpty)
        XCTAssertTrue(compileOptions.contains("ENABLE_FTS5"))
        XCTAssertEqual(ownership.soleWriterRole, .linuxEngine)
        XCTAssertTrue(ownership.protectedConsumers.contains("shell"))
        XCTAssertTrue(ownership.protectedConsumers.contains("cloud_sync"))
        XCTAssertTrue(ownership.concurrencyMechanism.contains("read-only snapshots"))
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

    public func testHeadlessSecretStoreReadsEnvironmentAndSystemdCredentialFile() throws {
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

    public func testMigrationListSchemaHashAndDocsMirrorCurrentHead() throws {
        let directory = try makeTempDirectory()
        let dbPath = directory.appendingPathComponent("schema.sqlite").path
        let database = try openDatabase(path: dbPath, passphrase: passphrase)
        defer { try? database.close() }

        let migrations = try database.migrationRows()
        XCTAssertEqual(migrations, OpenBurnBarLocalDatabase.migrationIdentifiers)
        XCTAssertEqual(migrations.last, "v64_token_usage_start_time_index")
        XCTAssertTrue(migrations.contains("v35_provider_accounts"))
        XCTAssertTrue(migrations.contains("v50_project_code_memory_schema"))

        let schemaHash = try database.schemaHash()
        XCTAssertEqual(schemaHash.count, 64)
        XCTAssertTrue(schemaHash.allSatisfy(\.isHexDigit))

        let schemaSQL = try String(contentsOf: repositoryRoot().appendingPathComponent("docs/SCHEMA_SQLITE.sql"), encoding: .utf8)
        XCTAssertTrue(schemaSQL.contains("CREATE TABLE provider_accounts"))
        XCTAssertTrue(schemaSQL.contains("CREATE TABLE provider_quota_snapshots"))
        XCTAssertTrue(schemaSQL.contains("CREATE VIRTUAL TABLE search_chunks_fts"))
        XCTAssertTrue(
            schemaSQL.contains("-- Schema hash: \(schemaHash)"),
            "docs/SCHEMA_SQLITE.sql schema hash is stale; expected \(schemaHash)"
        )
    }

    public func testWALBackupRestoreFailureInjectionAndConcurrentReadWrite() throws {
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
        let firstBackup = try XCTUnwrap(backups.first)
        XCTAssertTrue(OpenBurnBarLocalDatabase.isEncryptedDatabaseFile(at: firstBackup.path))
        XCTAssertNotEqual(try filePrefix(firstBackup.path, byteCount: OpenBurnBarSQLiteHeader.magic.count), OpenBurnBarSQLiteHeader.magic)

        let database = try openDatabase(path: dbPath, passphrase: passphrase)
        defer { try? database.close() }
        XCTAssertEqual(try database.migrationRows().last, "v64_token_usage_start_time_index")
        XCTAssertEqual(try database.count(sql: "SELECT COUNT(*) FROM provider_accounts WHERE id = 'legacy-provider-account'"), 1)
        XCTAssertEqual(try database.verifyPragmaString("integrity_check"), "ok")

        try database.recordUsage(usageRow(id: "usage-concurrent-seed", sessionID: "session-seed"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbPath + "-wal"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbPath + "-shm"))

        let group = DispatchGroup()
        let errorSink = LockedStringArray()
        for index in 0..<16 {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    if index.isMultiple(of: 2) {
                        try database.recordUsage(self.usageRow(id: "usage-concurrent-\(index)", sessionID: "session-\(index)"))
                    } else {
                        _ = try database.count(sql: "SELECT COUNT(*) FROM token_usage")
                    }
                } catch {
                    errorSink.append(String(describing: error))
                }
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(errorSink.values, [])
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

    public func testSearchFTSVectorFixtureParity() throws {
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

    public func testProviderAccountQuotaAndUsageRowsAreDurableAndRedacted() throws {
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
        XCTAssertFalse(redactedSupportBundle.contains("alberto@example.com"))
        XCTAssertFalse(redactedSupportBundle.contains("Claude Max Alberto"))

        let reopenedPath = directory.appendingPathComponent("provider-quota.sqlite").path
        try database.close()
        let reopened = try openDatabase(path: reopenedPath, passphrase: passphrase)
        defer { try? reopened.close() }
        XCTAssertEqual(try reopened.count(sql: "SELECT COUNT(*) FROM provider_accounts"), 1)
        XCTAssertEqual(try reopened.count(sql: "SELECT COUNT(*) FROM provider_quota_snapshots"), 1)
        XCTAssertEqual(try reopened.count(sql: "SELECT COUNT(*) FROM token_usage"), 1)
    }

    /// v60 billing provenance through the Linux write seam. `recordUsage` used to
    /// omit `billingKind` entirely, so every Linux-written row sat at the
    /// `'unknown'` schema default forever and the api-vs-plan split was empty on
    /// Linux even though the column existed. Proven here — inside the suite the
    /// Linux swift-test manifest actually runs — that a stamped kind and a derived
    /// kind both reach the encrypted file and survive a reopen.
    /// `OpenBurnBarBillingProvenanceTests` proves the classifier itself agrees with
    /// the migration's own backfill SQL for every provider/usageSource combination.
    public func testUsageRowsPersistBillingProvenanceAcrossReopen() throws {
        let directory = try makeTempDirectory()
        let path = directory.appendingPathComponent("billing-provenance.sqlite").path
        let database = try openDatabase(path: path, passphrase: passphrase)

        // Derived at write time from provider + usageSource…
        var planRow = usageRow(id: "usage-plan", sessionID: "session-plan")
        planRow.usageSource = "provider_log"
        try database.recordUsage(planRow)

        // …and an explicit stamp, which must win over the derivation.
        var stampedRow = usageRow(id: "usage-stamped", sessionID: "session-stamped")
        stampedRow.usageSource = "provider_log"
        stampedRow.billingKind = OpenBurnBarBillingProvenance.api
        stampedRow.providerAccountID = "acct-stamped"
        try database.recordUsage(stampedRow)

        try database.close()

        let reopened = try openDatabase(path: path, passphrase: passphrase)
        defer { try? reopened.close() }
        XCTAssertEqual(
            try reopened.count(sql: "SELECT COUNT(*) FROM token_usage WHERE id = 'usage-plan' AND billingKind = 'subscription'"),
            1
        )
        XCTAssertEqual(
            try reopened.count(sql: "SELECT COUNT(*) FROM token_usage WHERE id = 'usage-stamped' AND billingKind = 'api'"),
            1
        )
        XCTAssertEqual(
            try reopened.count(sql: "SELECT COUNT(*) FROM token_usage WHERE billingKind = 'unknown'"),
            0,
            "the Linux write seam must stamp provenance, not leave rows at the column default"
        )
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

private final class LockedStringArray: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ value: String) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private extension OpenBurnBarLocalDatabase {
    func verifyPragmaString(_ name: String) throws -> String {
        try pool.write { db in
            try String.fetchOne(db, sql: "PRAGMA \(name)") ?? ""
        }
    }

    func count(sql: String) throws -> Int {
        try pool.read { db in
            try Int.fetchOne(db, sql: sql) ?? 0
        }
    }
}
