import Foundation
import SQLite3
#if os(Linux)
import OpenBurnBarLinuxSecurity
#endif
@testable import OpenBurnBarDaemon
import XCTest

/// RR-1 (daemon side): the daemon keys the shared SQLite with the app's Keychain
/// key and migrates an existing plaintext file once. Wave 2.4 fail-closed,
/// like the app: missing codec or key means REFUSE to open — there is no
/// stock-SQLite compatibility mode. Refusal is driven through injected probes
/// so these tests pin the fail-closed contract on EVERY build (no
/// codec-stripped binary required); the live-codec round-trip still runs
/// behind `requireCodec()`.
final class BurnBarDaemonDatabaseCipherTests: XCTestCase {
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private static let testEncryptionKey = "daemon-test-" + String(repeating: "a", count: 32)

    func test_releaseDaemonSigningSharesAppDesignatedRequirementWithoutRestrictedEntitlements() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let project = try String(
            contentsOf: repositoryRoot.appendingPathComponent("project.yml"),
            encoding: .utf8
        )
        let targetStart = try XCTUnwrap(project.range(of: "  OpenBurnBarDaemonExecutable:\n"))
        let remaining = project[targetStart.upperBound...]
        let targetEnd = try XCTUnwrap(remaining.range(of: "\n  OpenBurnBarPrivilegedInputExecution:"))
        let target = String(remaining[..<targetEnd.lowerBound])

        XCTAssertTrue(
            target.contains("OTHER_CODE_SIGN_FLAGS: --identifier com.openburnbar.app --options runtime,library"),
            "The daemon must share the app designated requirement so the ordinary Keychain ACL admits both."
        )
        XCTAssertFalse(
            target.contains("CODE_SIGN_ENTITLEMENTS"),
            "A restricted entitlement on the bare daemon is invalid and causes a pre-main SIGKILL."
        )
    }

    // MARK: - Plaintext vs Encrypted File Detection (no key required)

    func test_plaintextDetection_onFreshSQLiteFile() throws {
        let path = try makePlaintextDatabase(rows: ["alpha", "beta"])
        defer { try? FileManager.default.removeItem(atPath: path) }

        XCTAssertTrue(BurnBarDaemonDatabaseCipher.isPlaintextDatabaseFile(at: path))
        XCTAssertFalse(BurnBarDaemonDatabaseCipher.isEncryptedDatabaseFile(at: path))
    }

    func test_detection_onMissingFile_isNeitherPlaintextNorEncrypted() {
        let path = NSTemporaryDirectory() + "obb-missing-\(UUID().uuidString).sqlite"
        XCTAssertFalse(BurnBarDaemonDatabaseCipher.isPlaintextDatabaseFile(at: path))
        XCTAssertFalse(BurnBarDaemonDatabaseCipher.isEncryptedDatabaseFile(at: path))
    }

    func test_encryptedDetection_onCiphertextHeader() throws {
        // A file whose first 16 bytes are NOT the SQLite magic looks "encrypted".
        let path = NSTemporaryDirectory() + "obb-cipher-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        try Data([0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
                  0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]).write(to: URL(fileURLWithPath: path))
        XCTAssertTrue(BurnBarDaemonDatabaseCipher.isEncryptedDatabaseFile(at: path))
        XCTAssertFalse(BurnBarDaemonDatabaseCipher.isPlaintextDatabaseFile(at: path))
    }

    // MARK: - Fail-closed refusal contract (runs on every build)

    func test_applyKeyIfAvailable_refusesWithoutCodec() throws {
        // Without a codec the open throws instead of silently serving
        // disclosed-plaintext. Injected probe: no codec-stripped binary needed.
        let path = try makePlaintextDatabase(rows: ["row1"])
        defer { try? FileManager.default.removeItem(atPath: path) }

        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        defer { sqlite3_close(handle) }
        XCTAssertThrowsError(
            try BurnBarDaemonDatabaseCipher.applyKeyIfAvailable(to: handle!, codecAvailable: false)
        ) { error in
            guard case BurnBarDaemonDatabaseCipherError.codecUnavailable = error else {
                return XCTFail("expected codecUnavailable, got \(error)")
            }
        }
    }

    func test_migratePlaintextDatabaseIfNeeded_refusesWithoutCodec() throws {
        let path = try makePlaintextDatabase(rows: ["keep-me"])
        defer { try? FileManager.default.removeItem(atPath: path) }

        let logger = BurnBarDaemonLogger(category: "cipher-test")
        XCTAssertThrowsError(
            try BurnBarDaemonDatabaseCipher.migratePlaintextDatabaseIfNeeded(
                at: path,
                logger: logger,
                codecAvailable: false
            )
        ) { error in
            guard case BurnBarDaemonDatabaseCipherError.codecUnavailable = error else {
                return XCTFail("expected codecUnavailable, got \(error)")
            }
        }
        XCTAssertTrue(
            BurnBarDaemonDatabaseCipher.isPlaintextDatabaseFile(at: path),
            "refused migration must leave the file untouched"
        )
    }

    func test_migratePlaintextDatabaseIfNeeded_missingFileStaysNoOpWithoutCodec() throws {
        // Refusal applies to databases that exist: a missing file is still a
        // silent no-op (first-run creation path), even without a codec.
        let path = NSTemporaryDirectory() + "obb-missing-\(UUID().uuidString).sqlite"
        let logger = BurnBarDaemonLogger(category: "cipher-test")
        let migrated = try BurnBarDaemonDatabaseCipher.migratePlaintextDatabaseIfNeeded(
            at: path,
            logger: logger,
            codecAvailable: false
        )
        XCTAssertFalse(migrated)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func test_runPlaintextMigration_withoutKeyLeavesPlaintextInPlace() throws {
        // No resolvable key: the file stays plaintext with a loud log (no
        // throw — first-run and locked-secret-store operation keep working),
        // to be migrated once a key appears. Resolved key is injected so the
        // test never depends on the ambient secret store.
        let path = try makePlaintextDatabase(rows: ["keep-me"])
        defer { try? FileManager.default.removeItem(atPath: path) }

        let logger = BurnBarDaemonLogger(category: "cipher-test")
        let migrated = try BurnBarDaemonDatabaseCipher.runPlaintextMigration(
            at: path,
            logger: logger,
            resolvedKey: nil
        )
        XCTAssertFalse(migrated)
        XCTAssertTrue(BurnBarDaemonDatabaseCipher.isPlaintextDatabaseFile(at: path))

        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        defer { sqlite3_close(handle) }
        XCTAssertEqual(try readAllRows(handle!), ["keep-me"])
    }

    func test_applyResolvedKey_refusesEncryptedFileWithoutKey() throws {
        // Ciphertext with no key is a typed refusal, not a late opaque
        // "file is not a database" on the first read.
        try requireCodec()

        let path = try makePlaintextDatabase(rows: ["secret-row"])
        defer { try? FileManager.default.removeItem(atPath: path) }
        let logger = BurnBarDaemonLogger(category: "cipher-test")
        XCTAssertTrue(try BurnBarDaemonDatabaseCipher.runPlaintextMigration(
            at: path,
            logger: logger,
            resolvedKey: Self.testEncryptionKey
        ))

        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        defer { sqlite3_close(handle) }
        XCTAssertThrowsError(try BurnBarDaemonDatabaseCipher.applyResolvedKey(nil, to: handle!)) { error in
            guard case BurnBarDaemonDatabaseCipherError.missingKeyForEncryptedDatabase(let refused) = error else {
                return XCTFail("expected missingKeyForEncryptedDatabase, got \(error)")
            }
            // sqlite3 reports the resolved path (/private/var/…); the fixture
            // path may use the /var/… symlink spelling of the same file.
            XCTAssertEqual(
                URL(fileURLWithPath: refused).resolvingSymlinksInPath().path,
                URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            )
        }
    }

    func test_applyResolvedKey_withoutKeyLeavesPlaintextReadable() throws {
        // Plaintext with no key stays readable (first-run creation, legacy
        // disclosed-plaintext with a genuinely unresolvable key). Runs on
        // every build: no codec interaction on this path.
        let path = try makePlaintextDatabase(rows: ["row1"])
        defer { try? FileManager.default.removeItem(atPath: path) }

        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        defer { sqlite3_close(handle) }
        XCTAssertNoThrow(try BurnBarDaemonDatabaseCipher.applyResolvedKey(nil, to: handle!))
        XCTAssertEqual(try readAllRows(handle!), ["row1"])
    }

    func test_grdbKeyingDecision() throws {
        // The shared GRDB prepareDatabase decision, exhaustively: no codec
        // always refuses; ciphertext without a key refuses; everything else
        // follows the key.
        let plaintext = try makePlaintextDatabase(rows: ["row1"])
        defer { try? FileManager.default.removeItem(atPath: plaintext) }
        let ciphertext = NSTemporaryDirectory() + "obb-cipher-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: ciphertext) }
        try Data([0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
                  0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]).write(to: URL(fileURLWithPath: ciphertext))
        let missing = NSTemporaryDirectory() + "obb-missing-\(UUID().uuidString).sqlite"

        // No codec ⇒ refuse, even with a key in hand.
        assertRefusesCodecUnavailable(BurnBarDaemonDatabaseCipher.grdbKeyingDecision(
            databasePath: plaintext, resolvedKey: Self.testEncryptionKey, codecAvailable: false
        ))
        assertRefusesCodecUnavailable(BurnBarDaemonDatabaseCipher.grdbKeyingDecision(
            databasePath: missing, resolvedKey: nil, codecAvailable: false
        ))

        // Codec + key ⇒ apply.
        guard case .applyKey(let applied) = BurnBarDaemonDatabaseCipher.grdbKeyingDecision(
            databasePath: plaintext, resolvedKey: Self.testEncryptionKey, codecAvailable: true
        ) else {
            XCTFail("expected applyKey")
            return
        }
        XCTAssertEqual(applied, Self.testEncryptionKey)

        // Codec, no key, ciphertext ⇒ refuse with the path.
        guard case .refuse(let refusal) = BurnBarDaemonDatabaseCipher.grdbKeyingDecision(
            databasePath: ciphertext, resolvedKey: nil, codecAvailable: true
        ) else {
            XCTFail("expected refuse for ciphertext without a key")
            return
        }
        guard case BurnBarDaemonDatabaseCipherError.missingKeyForEncryptedDatabase(let refused) = refusal else {
            XCTFail("expected missingKeyForEncryptedDatabase, got \(refusal)")
            return
        }
        XCTAssertEqual(refused, ciphertext)

        // Codec, no key, plaintext or missing ⇒ open.
        guard case .openPlaintext = BurnBarDaemonDatabaseCipher.grdbKeyingDecision(
            databasePath: plaintext, resolvedKey: nil, codecAvailable: true
        ) else {
            XCTFail("expected openPlaintext for a plaintext file without a key")
            return
        }
        guard case .openPlaintext = BurnBarDaemonDatabaseCipher.grdbKeyingDecision(
            databasePath: missing, resolvedKey: nil, codecAvailable: true
        ) else {
            XCTFail("expected openPlaintext for a missing file without a key")
            return
        }
    }

    private func assertRefusesCodecUnavailable(
        _ decision: BurnBarDaemonDatabaseCipher.GRDBKeyingDecision,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .refuse(let error) = decision else {
            XCTFail("expected refuse, got \(decision)", file: file, line: line)
            return
        }
        guard case BurnBarDaemonDatabaseCipherError.codecUnavailable = error else {
            XCTFail("expected codecUnavailable, got \(error)", file: file, line: line)
            return
        }
    }

    func test_requireCodecForStartup() throws {
        // Forced-absent always throws; forced-present always passes; and the
        // live gate agrees with the live probe on every build (no skips — a
        // stock build must prove it refuses, not skip the proof).
        XCTAssertNoThrow(try BurnBarDaemonDatabaseCipher.requireCodecForStartup(codecAvailable: true))
        XCTAssertThrowsError(try BurnBarDaemonDatabaseCipher.requireCodecForStartup(codecAvailable: false)) { error in
            guard case BurnBarDaemonDatabaseCipherError.codecUnavailable = error else {
                return XCTFail("expected codecUnavailable, got \(error)")
            }
        }
        if BurnBarDaemonDatabaseCipher.isCipherAvailable() {
            XCTAssertNoThrow(try BurnBarDaemonDatabaseCipher.requireCodecForStartup())
        } else {
            XCTAssertThrowsError(try BurnBarDaemonDatabaseCipher.requireCodecForStartup())
        }
    }

    func test_startupCodecProbe_forceNoCodecOverride() throws {
        #if DEBUG
        // DEBUG-only test hatch (compiled out of release, like the
        // peer-codesig opt-out): forces the startup probe absent so the
        // "daemon without codec exits with an error" proof can execute.
        setenv("OPENBURNBAR_DAEMON_FORCE_NO_CODEC", "1", 1)
        defer { unsetenv("OPENBURNBAR_DAEMON_FORCE_NO_CODEC") }
        XCTAssertFalse(BurnBarDaemonDatabaseCipher.startupCodecProbe())
        XCTAssertThrowsError(try BurnBarDaemonDatabaseCipher.requireCodecForStartup())
        #else
        // Release builds never read the override: the probe is the probe.
        XCTAssertEqual(
            BurnBarDaemonDatabaseCipher.startupCodecProbe(),
            BurnBarDaemonDatabaseCipher.isCipherAvailable()
        )
        #endif
    }

    func test_applyKey_rejectsKeyWithUnsafeCharacters() {
        // Charset validation happens before any PRAGMA runs, so it is observable
        // even on a stock build: a key with a quote can never be interpolated.
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(":memory:", &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil), SQLITE_OK)
        defer { sqlite3_close(handle) }
        XCTAssertThrowsError(try BurnBarDaemonDatabaseCipher.applyKey("abc' OR '1'='1", to: handle!)) { error in
            guard case BurnBarDaemonDatabaseCipherError.keyApplicationFailed = error else {
                return XCTFail("expected keyApplicationFailed, got \(error)")
            }
        }
    }

    // MARK: - Real keyed open + migration (codec-present flag)
    //
    // The daemon package links SQLCipher, so these run live. Set
    // DAEMON_SQLCIPHER_PRESENT=1 to demand the assertions below pass (the
    // codec-proof lane); otherwise the test self-checks via isCipherAvailable.

    func test_keyedOpen_roundTripsThroughCodec_whenPresent() throws {
        try requireCodec()

        // A plaintext open of an encrypted DB must FAIL; a keyed open must succeed.
        let path = try makePlaintextDatabase(rows: ["secret-row"])
        defer { try? FileManager.default.removeItem(atPath: path) }

        let logger = BurnBarDaemonLogger(category: "cipher-test")
        XCTAssertTrue(try BurnBarDaemonDatabaseCipher.migratePlaintextDatabaseIfNeeded(
            at: path,
            logger: logger,
            key: Self.testEncryptionKey
        ))
        XCTAssertTrue(BurnBarDaemonDatabaseCipher.isEncryptedDatabaseFile(at: path), "file must be encrypted after migration")

        // Keyed open reads the original rows back.
        var keyed: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(path, &keyed, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        defer { sqlite3_close(keyed) }
        try BurnBarDaemonDatabaseCipher.applyKeyIfAvailable(to: keyed!, key: Self.testEncryptionKey)
        XCTAssertEqual(try readAllRows(keyed!), ["secret-row"])

        // A keyless plaintext open must NOT be able to read the table.
        var keyless: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(path, &keyless, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        defer { sqlite3_close(keyless) }
        XCTAssertThrowsError(try readAllRows(keyless!), "keyless open must fail on an encrypted DB")
    }

#if os(Linux)
    func test_ensureKeyIfNeeded_provisionsAndReadsBackKeyForNewProfile() throws {
        try requireCodec()
        let path = NSTemporaryDirectory() + "obb-new-profile-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }

        let backend = MutableSecretBackend()
        let custodian = LinuxSecretCustodian(backends: [backend])
        let key = try XCTUnwrap(
            BurnBarDaemonDatabaseCipher.ensureKeyIfNeeded(at: path, secretStore: custodian)
        )

        XCTAssertEqual(key, backend.secret)
        XCTAssertEqual(Data(base64Encoded: key)?.count, 32)
        let reused = try BurnBarDaemonDatabaseCipher.ensureKeyIfNeeded(
            at: path,
            secretStore: custodian
        )
        XCTAssertEqual(reused, key, "an existing key must be reused, never rotated")
    }

    private final class MutableSecretBackend: LinuxSecretStoreBackend, @unchecked Sendable {
        let backendName = "test-secret-service"
        let trustLevel: LinuxSecretTrustLevel = .secretService
        let supportsMutations = true
        var secret: String?

        func readSecret(
            id: String,
            secretClass: LinuxHighValueSecretClass
        ) throws -> LinuxSecretRecord? {
            guard let secret else { return nil }
            return LinuxSecretRecord(
                secret: secret,
                metadata: LinuxSecretMetadata(
                    id: id,
                    secretClass: secretClass,
                    trustLevel: trustLevel,
                    backend: backendName,
                    createdAtMillis: 1,
                    note: "test"
                )
            )
        }

        func storeSecret(
            _ value: String,
            id: String,
            secretClass: LinuxHighValueSecretClass
        ) throws -> LinuxSecretMetadata {
            secret = value
            return LinuxSecretMetadata(
                id: id,
                secretClass: secretClass,
                trustLevel: trustLevel,
                backend: backendName,
                createdAtMillis: 1,
                note: "test"
            )
        }

        func deleteSecret(id: String, secretClass: LinuxHighValueSecretClass) throws {
            secret = nil
        }

        func healthCheck() throws {}
    }
#endif

    private func requireCodec() throws {
        if ProcessInfo.processInfo.environment["DAEMON_SQLCIPHER_PRESENT"] == "1" {
            XCTAssertTrue(
                BurnBarDaemonDatabaseCipher.isCipherAvailable(),
                "DAEMON_SQLCIPHER_PRESENT=1 but the linked SQLite has no codec"
            )
            return
        }
        try XCTSkipUnless(
            BurnBarDaemonDatabaseCipher.isCipherAvailable(),
            "SQLCipher codec not linked; set DAEMON_SQLCIPHER_PRESENT=1 once it is"
        )
    }

    // MARK: - Orphaned Migration Artifact Sweep

    /// A migration process that dies mid-export (SIGKILL, force quit, shutdown)
    /// strands its `<db>.sqlcipher-migrating-<UUID>` temp database (plus
    /// `-wal`/`-shm`/`-journal` sidecars) forever — one real machine accumulated
    /// 9.4 GB of them. The sweep must delete every artifact matching the prefix.
    func test_orphanSweep_deletesOrphanTempDatabasesAndSidecars() throws {
        let directory = try makeOrphanSweepDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let dbPath = directory + "/openburnbar.sqlite"

        let orphanA = dbPath + ".sqlcipher-migrating-" + UUID().uuidString
        let orphanB = dbPath + ".sqlcipher-migrating-" + UUID().uuidString
        let orphanPaths = [orphanA, orphanA + "-journal", orphanA + "-wal", orphanA + "-shm", orphanB]
        for orphanPath in orphanPaths {
            try Data("orphaned migration payload".utf8).write(to: URL(fileURLWithPath: orphanPath))
        }

        BurnBarDaemonDatabaseCipher.removeOrphanedMigrationArtifacts(
            forDatabaseAt: dbPath,
            logger: BurnBarDaemonLogger(category: "cipher-test")
        )

        for orphanPath in orphanPaths {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: orphanPath),
                "Sweep must delete orphaned migration artifact at \(orphanPath)"
            )
        }
    }

    /// The sweep must be strictly name-scoped: the live database, its own
    /// `-wal`/`-shm` sidecars, another database's migration temp files, and
    /// near-miss names must all survive untouched.
    func test_orphanSweep_leavesLiveDatabaseAndUnrelatedFilesUntouched() throws {
        let directory = try makeOrphanSweepDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let dbPath = directory + "/openburnbar.sqlite"

        let liveDatabaseContent = Data("live database bytes".utf8)
        try liveDatabaseContent.write(to: URL(fileURLWithPath: dbPath))
        let keeperPaths = [
            dbPath + "-wal",
            dbPath + "-shm",
            // Another database's orphan: prefix must match THIS db's file name only.
            directory + "/other.sqlite.sqlcipher-migrating-\(UUID().uuidString)",
            // Near-misses: wrong leading character / missing trailing dash.
            directory + "/xopenburnbar.sqlite.sqlcipher-migrating-\(UUID().uuidString)",
            dbPath + ".sqlcipher-migratingNOT",
            dbPath + ".backup"
        ]
        for keeperPath in keeperPaths {
            try Data("keep me".utf8).write(to: URL(fileURLWithPath: keeperPath))
        }
        let orphanPath = dbPath + ".sqlcipher-migrating-" + UUID().uuidString
        try Data("orphaned migration payload".utf8).write(to: URL(fileURLWithPath: orphanPath))

        BurnBarDaemonDatabaseCipher.removeOrphanedMigrationArtifacts(
            forDatabaseAt: dbPath,
            logger: BurnBarDaemonLogger(category: "cipher-test")
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanPath), "Sweep must delete the orphan")
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: dbPath)),
            liveDatabaseContent,
            "Sweep must never touch the live database"
        )
        for keeperPath in keeperPaths {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: keeperPath),
                "Sweep must not delete unrelated file at \(keeperPath)"
            )
        }
    }

    /// A database path whose parent directory does not exist (fresh install
    /// before the shared app-support directory is provisioned) must be a
    /// silent no-op.
    func test_orphanSweep_toleratesMissingDirectory() {
        let missingPath = NSTemporaryDirectory() + "obb-sweep-missing-\(UUID().uuidString)/nested/openburnbar.sqlite"
        BurnBarDaemonDatabaseCipher.removeOrphanedMigrationArtifacts(
            forDatabaseAt: missingPath,
            logger: BurnBarDaemonLogger(category: "cipher-test")
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingPath))
    }

    /// Entering the migration check must reclaim orphans even when no migration
    /// runs (here: the primary database file does not exist yet). Holds on both
    /// stock-SQLite and codec-present builds.
    func test_migratePlaintextDatabaseIfNeeded_sweepsOrphansAtEntry() throws {
        let directory = try makeOrphanSweepDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let dbPath = directory + "/openburnbar.sqlite"
        let orphanPath = dbPath + ".sqlcipher-migrating-" + UUID().uuidString
        try Data("orphaned migration payload".utf8).write(to: URL(fileURLWithPath: orphanPath))

        let logger = BurnBarDaemonLogger(category: "cipher-test")
        let migrated = try BurnBarDaemonDatabaseCipher.migratePlaintextDatabaseIfNeeded(
            at: dbPath,
            logger: logger,
            key: Self.testEncryptionKey
        )

        XCTAssertFalse(migrated, "No primary database file exists, so no migration should run")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: orphanPath),
            "Checking migration must sweep orphaned temp databases from prior crashed migrations"
        )
    }

    private func makeOrphanSweepDirectory() throws -> String {
        let directory = NSTemporaryDirectory() + "obb-orphan-sweep-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: - Helpers

    private func makePlaintextDatabase(rows: [String]) throws -> String {
        let path = NSTemporaryDirectory() + "obb-plain-\(UUID().uuidString).sqlite"
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let handle else {
            throw POSIXError(.EIO)
        }
        defer { sqlite3_close(handle) }
        XCTAssertEqual(sqlite3_exec(handle, "CREATE TABLE t(v TEXT)", nil, nil, nil), SQLITE_OK)
        for row in rows {
            var stmt: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(handle, "INSERT INTO t(v) VALUES (?)", -1, &stmt, nil), SQLITE_OK)
            sqlite3_bind_text(stmt, 1, row, -1, transient)
            XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)
            sqlite3_finalize(stmt)
        }
        return path
    }

    private func readAllRows(_ handle: OpaquePointer) throws -> [String] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT v FROM t ORDER BY v", -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw POSIXError(.EIO)
        }
        defer { sqlite3_finalize(stmt) }
        var rows: [String] = []
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_ROW {
                if let cString = sqlite3_column_text(stmt, 0) {
                    rows.append(String(cString: cString))
                }
            } else if step == SQLITE_DONE {
                break
            } else {
                throw POSIXError(.EIO)
            }
        }
        return rows
    }
}
