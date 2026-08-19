import XCTest
import GRDB
@testable import OpenBurnBar

/// Marker so `Bundle(for:)` resolves the `OpenBurnBarTests` resource bundle,
/// where the committed DB-compat fixture + vector are copied (they live under
/// `AgentLensTests/Fixtures/DBByteCompat`, which `project.yml` bundles as test
/// resources).
private final class DBByteCompatBundleMarker {}

/// End-to-end validator for the **DB byte-compat de-risk kit** (`VAL-P0-DB-009`).
///
/// The Windows port (R2 — the crown-jewel kill-risk) reuses the encrypted
/// SQLite file the Mac writes today. This test:
///
///   1. Migrates a fresh DB through the **live** `OpenBurnBarDatabase` migrator
///      to the live endpoint inside a real SQLCipher-keyed `DatabaseQueue` (the production
///      keying path, `DatabaseEncryptionService.makeConfiguration`).
///   2. Proves the currently-**implicit** SQLCipher parameters resolve to the
///      pinned SQLCipher-4.16.0 defaults (`cipher_page_size=4096`,
///      `kdf_iter=256000`, HMAC-SHA512, PBKDF2-HMAC-SHA512).
///   3. Freezes the **schema hash** (SHA-256 over `sqlite_master`) and proves it
///      is stable across a second independent regeneration.
///   4. Freezes a deterministic **FTS5 `bm25()`/`snippet()` vector** (porter
///      unicode61 stemming, case-folding, multi-column indexing, rank order).
///   5. Validates the **committed fixture + vector** (bundled resources): opens
///      the real committed encrypted file, reproduces the schema hash + FTS
///      vector, and confirms the file is genuinely encrypted.
///
/// ### Generation / bundling workflow (macOS)
/// App-hosted XCTest can lack the Documents-folder TCC grant, so the test never
/// writes into the repo. It writes freshly generated artifacts to a writable
/// output dir (temp, overridable via `OPENBURNBAR_DB_COMPAT_OUT` /
/// `TEST_RUNNER_OPENBURNBAR_DB_COMPAT_OUT`). To (re)generate the committed kit:
///
///   1. `TEST_RUNNER_OPENBURNBAR_DB_COMPAT_OUT=/tmp/obb-db-compat-out \`
///      `  scripts/test-openburnbar-app.sh -only-testing:AgentLensTests/DatabaseByteCompatVectorTests`
///   2. Copy `/tmp/obb-db-compat-out/*` into `AgentLensTests/Fixtures/DBByteCompat/`.
///   3. Regenerate the Xcode project (`xcodegen generate`) so the resources bundle.
///   4. Re-run the test — the committed-fixture assertions must pass. Missing
///      bundled resources are a hard failure because this kit now commits them.
///
/// Non-goal: opening the fixture **on Windows** — that is `VAL-P0-DB-010`
/// (the R2 kill-risk), deliberately out of scope here.
@MainActor
final class DatabaseByteCompatVectorTests: XCTestCase {

    private let fixtureBaseName = "openburnbar-db-compat-v64"
    private let vectorBaseName = "openburnbar-db-compat-vector"
    private let paramsBaseName = "openburnbar-db-compat-params-observed"

    // MARK: - Pinned SQLCipher params (the explicit contract)

    /// The currently-implicit SQLCipher parameters must resolve to the pinned
    /// SQLCipher-4.16.0 defaults on a real keyed connection. This is the machine
    /// check behind `decisions/sqlcipher-params.md`.
    func test_pinnedSQLCipherParams_areExplicitAndMatch_4_16_0() throws {
        let dbPath = try makeTempDir().appendingPathComponent("params.sqlcipher").path
        let queue = try DatabaseByteCompatVector.makeMigratedEncryptedQueue(
            at: dbPath,
            passphrase: DatabaseByteCompatVector.fixturePassphrase
        )
        let params = try queue.read { db in try DatabaseByteCompatVector.readSQLCipherParams(db) }
        let map = Dictionary(uniqueKeysWithValues: params.map { ($0.name, $0.value) })

        // SQLCipher must genuinely be active (this would catch the historical
        // "PRAGMA key is a silent no-op / plaintext" build regression).
        let cipherVersion = map["cipher_version"] ?? ""
        XCTAssertTrue(
            cipherVersion.hasPrefix("4."),
            "cipher_version must be a SQLCipher 4.x string; got '\(cipherVersion)'"
        )

        XCTAssertEqual(
            map["cipher_page_size"], String(DatabaseByteCompatVector.PinnedParams.cipherPageSize),
            "cipher_page_size drifted from the pinned SQLCipher-4 default"
        )
        XCTAssertEqual(
            map["kdf_iter"], String(DatabaseByteCompatVector.PinnedParams.kdfIter),
            "kdf_iter drifted from the pinned SQLCipher-4 default"
        )
        XCTAssertEqual(
            map["cipher_hmac_algorithm"], DatabaseByteCompatVector.PinnedParams.hmacAlgorithm,
            "cipher_hmac_algorithm drifted from the pinned SQLCipher-4 default"
        )
        XCTAssertEqual(
            map["cipher_kdf_algorithm"], DatabaseByteCompatVector.PinnedParams.kdfAlgorithm,
            "cipher_kdf_algorithm drifted from the pinned SQLCipher-4 default"
        )
    }

    // MARK: - Migrator endpoint sanity

    /// The kit is pinned to the current endpoint. A future migration bump must fail
    /// this loudly and force a conscious fixture/vector refresh.
    func test_liveMigrator_endpointMatchesCommittedVector() throws {
        XCTAssertEqual(
            OpenBurnBarDatabase.latestMigrationIdentifier,
            DatabaseByteCompatVector.expectedSchemaEndpoint,
            "Migrator endpoint changed — regenerate the DB-compat fixture + vector."
        )
        XCTAssertGreaterThanOrEqual(
            OpenBurnBarDatabase.migrator.migrations.count, 59,
            "Expected at least 59 registered migrations (v1..v58 + v51a interstitial)."
        )
    }

    // MARK: - Generate + validate the full vector end-to-end

    func test_dbByteCompatVector_generateValidateAndOpenCommittedFixture() throws {
        let outputDir = try outputDirectory()
        let candidateFixture = outputDir.appendingPathComponent("\(fixtureBaseName).sqlcipher")

        // (1) Fresh generation #1 → also the candidate committed fixture file.
        let genA = try generate(at: candidateFixture.path)

        // (2) Independent generation #2 (different temp file → different salt) to
        //     prove the schema hash and FTS vector are stable across regen.
        let secondPath = outputDir.appendingPathComponent("regen-2.sqlcipher").path
        let genB = try generate(at: secondPath)

        XCTAssertEqual(
            genA.schemaHash, genB.schemaHash,
            "Schema hash is not stable across regeneration — the fixture would be non-reproducible."
        )
        XCTAssertEqual(
            genA.fts, genB.fts,
            "FTS5 bm25()/snippet() result set is not deterministic across regeneration."
        )
        XCTAssertEqual(genA.migrationCount, genB.migrationCount)

        // (3) The candidate fixture file must be genuinely encrypted (no plaintext
        //     SQLite magic header).
        try assertFileIsEncrypted(at: candidateFixture)

        // (4) Sanity on the FTS vector semantics (independent of the committed
        //     copy) so a wrong vector is caught even on a bootstrap run.
        assertVectorSemantics(genA.fts)

        // (5) Build the vector object and persist candidate artifacts to the
        //     writable output dir (never the repo — TCC-safe).
        let vector = DatabaseByteCompatVector.Vector(
            sqlcipherPin: "SQLCipher.swift 4.16.0 (Vendor/GRDB-SQLCipher)",
            schemaEndpoint: DatabaseByteCompatVector.expectedSchemaEndpoint,
            migrationCount: genA.migrationCount,
            schemaHashSHA256: genA.schemaHash,
            ftsQueries: genA.fts
        )
        try writeCandidateArtifacts(vector: vector, params: genA.params, to: outputDir)
        print("[db-compat] Candidate artifacts written to \(outputDir.path)")

        // (6) Validate against the COMMITTED (bundled) fixture + vector.
        let committedVectorURL = try requireBundledResource(
            resource: vectorBaseName,
            ext: "json",
            outputDir: outputDir
        )
        let committedFixtureURL = try requireBundledResource(
            resource: fixtureBaseName,
            ext: "sqlcipher",
            outputDir: outputDir
        )

        let committedVector = try JSONDecoder().decode(
            DatabaseByteCompatVector.Vector.self,
            from: Data(contentsOf: committedVectorURL)
        )

        // Freshly generated schema/FTS must match what is committed (catches a
        // stale committed fixture after a schema change).
        XCTAssertEqual(
            vector, committedVector,
            "Freshly generated vector diverged from the committed vector — regenerate the fixture kit."
        )

        // Open the REAL committed encrypted fixture and reproduce the vector.
        try assertFileIsEncrypted(at: committedFixtureURL)
        let opened = try openAndMeasure(fixtureURL: committedFixtureURL)
        XCTAssertEqual(
            opened.schemaHash, committedVector.schemaHashSHA256,
            "Committed fixture schema hash != committed vector — the artifact is inconsistent."
        )
        XCTAssertEqual(
            opened.fts, committedVector.ftsQueries,
            "Committed fixture FTS result set != committed vector — the artifact is inconsistent."
        )
    }

    // MARK: - FTS vector semantics

    /// Assert the deterministic, cross-platform-relevant FTS behaviors directly,
    /// so a wrong committed vector cannot silently define wrong "expected"
    /// behavior.
    private func assertVectorSemantics(_ queries: [DatabaseByteCompatVector.FTSQueryVector]) {
        func rows(_ label: String) -> [DatabaseByteCompatVector.FTSRowVector] {
            queries.first { $0.label == label }?.orderedRows ?? []
        }

        // Porter stemming: "run" matches "runs" (alpha) and "running"/"run" (beta).
        // beta has 4 occurrences → decisively better bm25 → ranks first.
        let runRows = rows("porter-stem-run")
        XCTAssertEqual(
            runRows.map(\.conversationID), ["conv-beta-run", "conv-alpha-fox"],
            "porter-stem-run must return beta then alpha by bm25; gamma must be absent"
        )

        // Case-folding on the title column (col 0): uppercase "GAMMA" matches
        // "Gamma Crypto".
        XCTAssertEqual(
            rows("case-fold-title").map(\.conversationID), ["conv-gamma-db"],
            "case-fold-title must match gamma via the inferredTaskTitle column"
        )

        // Full-text column match + snippet markup on the matched term.
        let dbRows = rows("fulltext-database")
        XCTAssertEqual(dbRows.map(\.conversationID), ["conv-gamma-db"])
        XCTAssertEqual(
            dbRows.first?.snippet, "<b>database</b> encryption keeps your data safe at rest",
            "snippet() must wrap the matched term and preserve original casing/text"
        )

        // Porter stemming: "shoe" matches "shoes" (beta only).
        XCTAssertEqual(
            rows("porter-stem-shoe").map(\.conversationID), ["conv-beta-run"],
            "porter-stem-shoe must match beta (shoes → shoe)"
        )
    }

    // MARK: - Generation

    private struct Generated {
        let schemaHash: String
        let migrationCount: Int
        let fts: [DatabaseByteCompatVector.FTSQueryVector]
        let params: [DatabaseByteCompatVector.ObservedParam]
    }

    /// Migrate a fresh keyed DB to the live endpoint, seed the corpus, and measure the schema
    /// hash + FTS vector + SQLCipher params. The `DatabaseQueue` is released when
    /// this returns, closing the connection so the file can be copied.
    private func generate(at dbPath: String) throws -> Generated {
        removeDatabaseFiles(at: dbPath)
        let queue = try DatabaseByteCompatVector.makeMigratedEncryptedQueue(
            at: dbPath,
            passphrase: DatabaseByteCompatVector.fixturePassphrase
        )
        try queue.write { db in try DatabaseByteCompatVector.seedCorpus(db) }
        let measured = try queue.read { db -> (String, [DatabaseByteCompatVector.FTSQueryVector], [DatabaseByteCompatVector.ObservedParam]) in
            (
                try DatabaseByteCompatVector.computeSchemaHash(db),
                try DatabaseByteCompatVector.runFTSQueries(db),
                try DatabaseByteCompatVector.readSQLCipherParams(db)
            )
        }
        return Generated(
            schemaHash: measured.0,
            migrationCount: OpenBurnBarDatabase.migrator.migrations.count,
            fts: measured.1,
            params: measured.2
        )
    }

    /// Open a committed encrypted fixture (copied out of the read-only bundle)
    /// and reproduce the schema hash + FTS vector.
    private func openAndMeasure(fixtureURL: URL) throws -> (schemaHash: String, fts: [DatabaseByteCompatVector.FTSQueryVector]) {
        let workingCopy = try makeTempDir().appendingPathComponent("committed-open.sqlcipher")
        try FileManager.default.copyItem(at: fixtureURL, to: workingCopy)
        let config = try DatabaseEncryptionService.makeConfiguration(
            encryptionKey: DatabaseByteCompatVector.fixturePassphrase
        )
        let queue = try DatabaseQueue(path: workingCopy.path, configuration: config)
        return try queue.read { db in
            (
                try DatabaseByteCompatVector.computeSchemaHash(db),
                try DatabaseByteCompatVector.runFTSQueries(db)
            )
        }
    }

    // MARK: - Artifact persistence (writable output dir only)

    private func writeCandidateArtifacts(
        vector: DatabaseByteCompatVector.Vector,
        params: [DatabaseByteCompatVector.ObservedParam],
        to outputDir: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(vector).write(
            to: outputDir.appendingPathComponent("\(vectorBaseName).json"), options: .atomic
        )
        try encoder.encode(params).write(
            to: outputDir.appendingPathComponent("\(paramsBaseName).json"), options: .atomic
        )
    }

    // MARK: - Encryption check

    private func assertFileIsEncrypted(at url: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 16) ?? Data()
        let plaintextMagic = Data("SQLite format 3\u{0}".utf8)
        XCTAssertNotEqual(
            header, plaintextMagic,
            "Fixture starts with the plaintext SQLite magic header — it is NOT encrypted.",
            file: file, line: line
        )
        XCTAssertEqual(header.count, 16, "Fixture is too small to be a real database.", file: file, line: line)
    }

    // MARK: - Paths

    private func outputDirectory() throws -> URL {
        let env = ProcessInfo.processInfo.environment
        let raw = env["OPENBURNBAR_DB_COMPAT_OUT"] ?? env["TEST_RUNNER_OPENBURNBAR_DB_COMPAT_OUT"]
        let dir: URL
        if let raw, !raw.isEmpty {
            dir = URL(fileURLWithPath: raw, isDirectory: true)
        } else {
            dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("openburnbar-db-compat-out", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("obb-db-compat-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func removeDatabaseFiles(at path: String) {
        for suffix in ["", "-wal", "-shm", "-journal"] {
            try? FileManager.default.removeItem(atPath: path + suffix)
        }
    }

    private func bundledURL(resource: String, ext: String) -> URL? {
        let bundle = Bundle(for: DBByteCompatBundleMarker.self)
        return bundle.url(forResource: resource, withExtension: ext)
            ?? bundle.url(forResource: resource, withExtension: ext, subdirectory: "DBByteCompat")
            ?? bundle.url(forResource: resource, withExtension: ext, subdirectory: "Fixtures/DBByteCompat")
    }

    private func requireBundledResource(resource: String, ext: String, outputDir: URL) throws -> URL {
        if let url = bundledURL(resource: resource, ext: ext) {
            return url
        }

        XCTFail(
            "Required DB-compat fixture resource \(resource).\(ext) is missing from the test bundle. "
            + "Copy \(outputDir.path)/* into AgentLensTests/Fixtures/DBByteCompat/, regenerate the project, "
            + "and re-run."
        )
        throw CocoaError(.fileNoSuchFile)
    }
}
