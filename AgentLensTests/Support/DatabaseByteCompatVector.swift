import Foundation
import GRDB
import CryptoKit
@testable import OpenBurnBar

/// Portable DB **byte-compat de-risk kit** shared by the macOS generator/validator
/// (`VAL-P0-DB-009`) and the future Windows open-side check (`VAL-P0-DB-010`).
///
/// The Windows port (R2, the crown-jewel kill-risk) reuses the *same* encrypted
/// SQLite file the Mac writes today. Byte-compat holds only **within a SQLCipher
/// major version**, and the Mac currently sets the cipher/kdf/page parameters
/// **implicitly** (they are never written in source — see
/// `DatabaseEncryptionService.makeConfiguration`). This kit turns those implicit
/// defaults into a *pinned, machine-checked* contract and freezes the FTS5
/// tokenizer/ranking behavior into a committed vector so the Windows side has a
/// concrete oracle to diff against.
///
/// This type owns the reproducible, cross-platform pieces:
///   * the fixed non-secret fixture passphrase,
///   * the canonical seed corpus,
///   * the schema-hash algorithm (over `sqlite_master`),
///   * the FTS5 `bm25()`/`snippet()` query set (mirrors production
///     `ConversationStore.searchConversationsFTS`), and
///   * the SQLCipher parameter reader + the pinned expected values.
///
/// The `XCTestCase` (`DatabaseByteCompatVectorTests`) drives temp-dir I/O,
/// fixture (re)generation, and assertions on top of these primitives.
enum DatabaseByteCompatVector {

    // MARK: - Fixture passphrase (NON-SECRET, committed)

    /// Fixed passphrase used to key the committed fixture. This is a **test
    /// fixture key, not a production secret** — it exists so both the Mac
    /// validator and the Windows open-side check can open the *same* committed
    /// encrypted file. It is documented in `decisions/sqlcipher-params.md` and
    /// the fixture `README.md`.
    ///
    /// Only the base64 alphabet plus `-` are used so it passes
    /// `DatabaseEncryptionService.validateEncryptionKey` unchanged.
    static let fixturePassphrase = "OBB-WinPort-DBByteCompat-Fixture-Key-v53-000="

    // MARK: - Schema endpoint

    /// The last registered migration identifier the fixture is migrated to.
    /// Kept in one place so a future migration bump fails the test loudly and
    /// forces a conscious fixture/vector refresh.
    static let expectedSchemaEndpoint = "v67_agent_memory_inbox"

    // MARK: - Pinned SQLCipher parameters (SQLCipher.swift 4.16.0 defaults)

    /// The currently-implicit SQLCipher parameters, pinned as **explicit**
    /// expectations. Traced to `Vendor/GRDB-SQLCipher` → `SQLCipher.swift`
    /// exact `4.16.0` (the SQLCipher 4 compatibility profile). See
    /// `decisions/sqlcipher-params.md` for the full trace and rationale.
    enum PinnedParams {
        /// SQLCipher 4 default page size.
        static let cipherPageSize = 4096
        /// SQLCipher 4 default PBKDF2 work factor.
        static let kdfIter = 256_000
        /// SQLCipher 4 default per-page HMAC.
        static let hmacAlgorithm = "HMAC_SHA512"
        /// SQLCipher 4 default key-derivation function.
        static let kdfAlgorithm = "PBKDF2_HMAC_SHA512"
        /// SQLCipher 4 default cipher-compatibility profile. `cipher_compatibility`
        /// is a write-only PRAGMA (it cannot be read back), so it is asserted
        /// indirectly through the four readable parameters above, which together
        /// *are* the "compatibility = 4" profile.
        static let cipherCompatibility = 4
    }

    // MARK: - Canonical seed corpus

    /// One conversation row of the deterministic FTS corpus. `conversations`
    /// triggers (`conversations_ai`) mirror `inferredTaskTitle` (FTS column 0)
    /// and `fullText` (FTS column 1) into the standalone `conversations_fts`
    /// table, so seeding the base table is enough to exercise the index.
    struct CorpusConversation {
        let id: String
        let provider: String
        let sessionId: String
        let projectName: String
        let inferredTaskTitle: String
        let fullText: String
    }

    /// A fixed timestamp for every seeded row so nothing in the fixture depends
    /// on wall-clock time.
    static let corpusIndexedAt = "2026-01-01 00:00:00.000"

    /// The canonical corpus. Carefully chosen so FTS5 behavior is unambiguous
    /// across platforms:
    ///   * `beta` carries the term "run"/"running" **four** times → its `bm25()`
    ///     is decisively better than `alpha`'s single "runs", pinning result
    ///     ordering, not just membership;
    ///   * `alpha` proves porter stemming (`runs` → `run`);
    ///   * `beta` proves porter stemming (`shoes` → `shoe`, `running` → `run`);
    ///   * `gamma` proves title-column (col 0) indexing and case-folding.
    static let corpus: [CorpusConversation] = [
        CorpusConversation(
            id: "conv-alpha-fox",
            provider: "Codex",
            sessionId: "s-alpha",
            projectName: "ByteCompat",
            inferredTaskTitle: "Alpha Fox Notes",
            fullText: "the quick brown fox runs across the yard"
        ),
        CorpusConversation(
            id: "conv-beta-run",
            provider: "Claude Code",
            sessionId: "s-beta",
            projectName: "ByteCompat",
            inferredTaskTitle: "Beta Running Log",
            fullText: "running shoes and running gear make running feel like a real run"
        ),
        CorpusConversation(
            id: "conv-gamma-db",
            provider: "Codex",
            sessionId: "s-gamma",
            projectName: "ByteCompat",
            inferredTaskTitle: "Gamma Crypto",
            fullText: "database encryption keeps your data safe at rest"
        ),
    ]

    // MARK: - Canonical FTS query set

    /// A single FTS5 `MATCH` probe of the committed vector.
    struct FTSQuery {
        let label: String
        /// The raw FTS5 `MATCH` string.
        let match: String
    }

    /// The queries frozen into the vector. Each mirrors the production query
    /// shape (`bm25()` ranking + `snippet(conversations_fts, 1, …)` + porter
    /// unicode61). Together they pin stemming, case-folding, multi-column
    /// indexing, and rank ordering.
    static let ftsQueries: [FTSQuery] = [
        FTSQuery(label: "porter-stem-run", match: "run"),        // beta (4×) then alpha (1×)
        FTSQuery(label: "case-fold-title", match: "GAMMA"),      // title col, uppercase query
        FTSQuery(label: "fulltext-database", match: "database"), // fullText col
        FTSQuery(label: "porter-stem-shoe", match: "shoe"),      // shoes → shoe
    ]

    // MARK: - Committed vector shape

    struct FTSRowVector: Codable, Equatable {
        /// `conversations.id` of the matched row.
        let conversationID: String
        /// `snippet(conversations_fts, 1, '<b>', '</b>', '…', 10)` output.
        let snippet: String
    }

    struct FTSQueryVector: Codable, Equatable {
        let label: String
        let match: String
        /// Matched rows in `ORDER BY bm25 ASC` order (most relevant first).
        let orderedRows: [FTSRowVector]
    }

    /// The full committed DB-compat vector. `VAL-P0-DB-010` (Windows) opens the
    /// committed fixture and must reproduce this object exactly.
    struct Vector: Codable, Equatable {
        /// Trace/label of the SQLCipher version the fixture was produced with.
        let sqlcipherPin: String
        /// Last migration identifier reached (`expectedSchemaEndpoint`).
        let schemaEndpoint: String
        /// Number of registered migrations (fails loudly on a schema bump).
        let migrationCount: Int
        /// SHA-256 over the normalized `sqlite_master` DDL — the schema hash.
        let schemaHashSHA256: String
        /// The frozen FTS5 result set.
        let ftsQueries: [FTSQueryVector]
    }

    // MARK: - Encrypted-queue construction (live migrator)

    /// Open a SQLCipher-keyed `DatabaseQueue` at `path` using the **production**
    /// keying path (`DatabaseEncryptionService.makeConfiguration`) and run the
    /// **live** `OpenBurnBarDatabase` migrator to the current endpoint.
    ///
    /// A `DatabaseQueue` (single connection, rollback-journal mode) is used on
    /// purpose so the committed fixture is a single self-contained file with no
    /// `-wal`/`-shm` sidecars. The SQLCipher parameters we pin
    /// (`cipher_page_size`, `kdf_iter`, HMAC/KDF algorithms) are independent of
    /// journal mode, so the fixture stays byte-representative of production.
    static func makeMigratedEncryptedQueue(at path: String, passphrase: String) throws -> DatabaseQueue {
        let config = try DatabaseEncryptionService.makeConfiguration(encryptionKey: passphrase)
        let queue = try DatabaseQueue(path: path, configuration: config)
        let database = OpenBurnBarDatabase(databaseQueue: queue)
        try database.runMigrations()
        return queue
    }

    // MARK: - Seeding

    /// Insert the canonical corpus. FTS triggers populate `conversations_fts`.
    static func seedCorpus(_ db: Database) throws {
        for row in corpus {
            try db.execute(
                sql: """
                INSERT INTO conversations
                    (id, provider, sessionId, projectName, inferredTaskTitle, fullText, indexedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    row.id, row.provider, row.sessionId, row.projectName,
                    row.inferredTaskTitle, row.fullText, corpusIndexedAt,
                ]
            )
        }
    }

    // MARK: - Schema hash

    /// SHA-256 over the normalized, ordered `sqlite_master` DDL of the current
    /// database. This is the **schema hash** the vector pins.
    ///
    /// Only rows with non-null `sql` are hashed (this drops SQLite-internal
    /// auto-indexes, whose `sql` is `NULL`) and `sqlite_%` internal names are
    /// excluded. Every remaining `CREATE …` statement — including the FTS5
    /// shadow tables — is the verbatim text the migrator (or the FTS5 extension)
    /// issued, so the same migrator on Mac and Windows yields the same bytes and
    /// therefore the same hash. Only outer whitespace is trimmed so a genuine
    /// DDL difference still changes the hash.
    static func computeSchemaHash(_ db: Database) throws -> String {
        let statements = try Row.fetchAll(
            db,
            sql: """
            SELECT sql FROM sqlite_master
            WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite_%'
            ORDER BY type, name
            """
        ).compactMap { ($0["sql"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }

        let canonical = statements.joined(separator: "\n")
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - FTS query execution

    /// Run the canonical FTS query set against an already-migrated, already-seeded
    /// database, returning the observed vector. Mirrors production:
    /// `bm25(conversations_fts)` ranking, `snippet(conversations_fts, 1, …)`,
    /// `ORDER BY rank ASC`, `deletedAt IS NULL`.
    static func runFTSQueries(_ db: Database) throws -> [FTSQueryVector] {
        try ftsQueries.map { query in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT c.id AS id,
                       bm25(conversations_fts) AS rank,
                       snippet(conversations_fts, 1, '<b>', '</b>', '…', 10) AS snip
                FROM conversations_fts
                JOIN conversations AS c ON c.rowid = conversations_fts.rowid
                WHERE conversations_fts MATCH ? AND c.deletedAt IS NULL
                ORDER BY rank ASC
                """,
                arguments: [query.match]
            )
            let orderedRows = rows.map { row in
                FTSRowVector(
                    conversationID: row["id"] as? String ?? "",
                    snippet: row["snip"] as? String ?? ""
                )
            }
            return FTSQueryVector(label: query.label, match: query.match, orderedRows: orderedRows)
        }
    }

    // MARK: - SQLCipher parameter readout

    /// One observed SQLCipher parameter (name → string value), preserving order.
    struct ObservedParam: Codable, Equatable {
        let name: String
        let value: String
    }

    /// Read the live SQLCipher parameters from a keyed connection. Used both to
    /// assert the pinned values and to write the `sqlcipher-params-observed.json`
    /// evidence file. `cipher_compatibility` is intentionally absent — it is a
    /// write-only PRAGMA.
    static func readSQLCipherParams(_ db: Database) throws -> [ObservedParam] {
        func str(_ name: String) -> String {
            // `try?` on a throwing `String?` fetch yields `String??`; flatten to
            // `String?` before defaulting so this returns a plain `String`.
            guard let value = (try? String.fetchOne(db, sql: "PRAGMA \(name)")) ?? nil else {
                return "<unavailable>"
            }
            return value
        }
        func int(_ name: String) -> String {
            guard let value = (try? Int.fetchOne(db, sql: "PRAGMA \(name)")) ?? nil else {
                return "<unavailable>"
            }
            return String(value)
        }
        return [
            ObservedParam(name: "cipher_version", value: str("cipher_version")),
            ObservedParam(name: "cipher_provider", value: str("cipher_provider")),
            ObservedParam(name: "cipher_provider_version", value: str("cipher_provider_version")),
            ObservedParam(name: "cipher_page_size", value: int("cipher_page_size")),
            ObservedParam(name: "kdf_iter", value: int("kdf_iter")),
            ObservedParam(name: "cipher_default_kdf_iter", value: int("cipher_default_kdf_iter")),
            ObservedParam(name: "cipher_hmac_algorithm", value: str("cipher_hmac_algorithm")),
            ObservedParam(name: "cipher_kdf_algorithm", value: str("cipher_kdf_algorithm")),
        ]
    }
}
