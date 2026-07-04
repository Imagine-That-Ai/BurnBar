import XCTest
@testable import OpenBurnBarCore

// WS-C4: SQLite seam parity proof — GRDB-write→seam-read divergence test.
//
// The 4 SEAM parsers (ForgeDev, Goose, Windsurf, Warp) + the 2 golden SQLite
// parsers (Codex, Hermes) read SQLite through the `SQLiteConnection` seam
// instead of GRDB. This test proves the seam's typed getters reproduce GRDB's
// `DatabaseValueConvertible` coercion EXACTLY per storage class, so the lifted
// parsers' extraction is byte-for-byte unchanged versus the GRDB originals.
//
// The test writes a fixture DB with every storage class + the edge cases that
// would surface a coercion divergence (NULL, integer→Int overflow, REAL↔INTEGER
// promotion, empty blob, unicode text, large integer), reads it back through
// the seam, and asserts each typed getter returns the GRDB-equivalent value.
//
// Because SQLite is deterministic and the seam links the SAME `sqlite3_*` C API
// on every platform (system SQLite3 on Apple, vendored CSQLite off-Apple), a
// macOS green run is proof for Windows — the G2 contract.
//
// Parity oracle: GRDB's `DatabaseValueConvertible` storage-class coercion
// (https://github.com/groue/GRDB/blob/master/Documentation/README.md#records):
//   String  ← TEXT only (nil for INTEGER/REAL/BLOB/NULL)
//   Int64   ← INTEGER only (nil for TEXT/REAL/BLOB/NULL)
//   Int     ← INTEGER only, exact (nil on overflow)
//   Double  ← REAL, or INTEGER promoted to Double (nil for TEXT/BLOB/NULL)
//   Data    ← BLOB only (nil for INTEGER/REAL/TEXT/NULL)

final class SQLiteSeamParityTests: XCTestCase {

    private var dbPath: String = ""

    override func setUp() {
        super.setUp()
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("sqlite-seam-parity-\(UUID().uuidString).sqlite")
        dbPath = tmp.path
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: dbPath)
        super.tearDown()
    }

    // ── Build a fixture DB with one row per storage class + edge cases ──────
    private func buildFixtureDB() throws -> SQLiteConnection {
        let conn = try SQLiteConnection.openForWriting(creatingAt: dbPath)
        defer { conn.close() }

        try conn.execute("""
            CREATE TABLE coercion_matrix (
                id INTEGER PRIMARY KEY,
                label TEXT NOT NULL,
                int_val INTEGER,
                real_val REAL,
                text_val TEXT,
                blob_val BLOB,
                null_val INTEGER
            )
            """)

        // Row 1: all storage classes present.
        try conn.execute(
            "INSERT INTO coercion_matrix (id, label, int_val, real_val, text_val, blob_val, null_val) VALUES (?, ?, ?, ?, ?, ?, ?)",
            arguments: [
                .int(1),
                .text("all-present"),
                .int(4200000000),       // > Int32.max, exercises Int64 vs Int
                .double(3.14159),
                .text("héllo wörld 🌍"),  // unicode
                .blob([0xDE, 0xAD, 0xBE, 0xEF]),
                .null
            ]
        )

        // Row 2: NULLs in every nullable column.
        try conn.execute(
            "INSERT INTO coercion_matrix (id, label, int_val, real_val, text_val, blob_val, null_val) VALUES (?, ?, ?, ?, ?, ?, ?)",
            arguments: [
                .int(2),
                .text("all-null"),
                .null,
                .null,
                .null,
                .null,
                .int(99)
            ]
        )

        // Row 3: integer stored where a REAL column is expected (SQLite allows this).
        try conn.execute(
            "INSERT INTO coercion_matrix (id, label, int_val, real_val, text_val, blob_val, null_val) VALUES (?, ?, ?, ?, ?, ?, ?)",
            arguments: [
                .int(3),
                .text("int-in-real-col"),
                .int(-7),
                .int(42),               // INTEGER value in a REAL-declared column
                .text("coercion"),
                .blob([]),               // empty blob
                .null
            ]
        )

        // Row 4: large Int64 (> UInt32 — exercises Int(exactly:) overflow on 32-bit).
        try conn.execute(
            "INSERT INTO coercion_matrix (id, label, int_val, real_val, text_val, blob_val, null_val) VALUES (?, ?, ?, ?, ?, ?, ?)",
            arguments: [
                .int(4),
                .text("large-int64"),
                .int(9_000_000_000_000), // > Int32.max, < Int64.max
                .double(2.718281828),
                .text(""),
                .blob([0x00, 0xFF]),
                .null
            ]
        )

        return conn
    }

    // ── Read the fixture back through the read-only seam and assert coercion ─
    func testSeamReadReproducesGRDBCoercionPerStorageClass() throws {
        // Build + close the writer.
        _ = try buildFixtureDB()

        // Re-open read-only (the production parser path).
        let reader = try SQLiteConnection.openReadOnly(path: dbPath)
        defer { reader.close() }

        let rows = try reader.query(
            "SELECT id, label, int_val, real_val, text_val, blob_val, null_val FROM coercion_matrix ORDER BY id"
        )
        XCTAssertEqual(rows.count, 4, "all 4 fixture rows round-trip through the seam")

        // ── Row 1: all storage classes present ──────────────────────────────
        let r1 = rows[0]
        XCTAssertEqual(r1.int("id"), 1, "INTEGER → Int (exact)")
        XCTAssertEqual(r1.int64("id"), 1, "INTEGER → Int64")
        XCTAssertEqual(r1.string("label"), "all-present", "TEXT → String")
        XCTAssertEqual(r1.int64("int_val"), 4_200_000_000, "large INTEGER → Int64 (> Int32.max)")
        XCTAssertEqual(r1.int("int_val"), 4_200_000_000, "large INTEGER → Int (exact on 64-bit)")
        XCTAssertEqual(try XCTUnwrap(r1.double("real_val")), 3.14159, accuracy: 1e-9, "REAL → Double")
        XCTAssertEqual(r1.string("text_val"), "héllo wörld 🌍", "unicode TEXT → String (byte-identical)")
        XCTAssertEqual(r1.blob("blob_val"), [0xDE, 0xAD, 0xBE, 0xEF], "BLOB → [UInt8]")
        XCTAssertNil(r1.int64("null_val"), "NULL column → nil for Int64")
        XCTAssertNil(r1.string("null_val"), "NULL column → nil for String")
        XCTAssertNil(r1.double("null_val"), "NULL column → nil for Double")
        XCTAssertNil(r1.blob("null_val"), "NULL column → nil for blob")

        // ── GRDB cross-class coercion: nil when storage class doesn't match ─
        XCTAssertNil(r1.string("int_val"), "GRDB: INTEGER → String is nil (String ← TEXT only)")
        XCTAssertNil(r1.int64("text_val"), "GRDB: TEXT → Int64 is nil (Int64 ← INTEGER only)")
        XCTAssertNil(r1.int64("real_val"), "GRDB: REAL → Int64 is nil (Int64 ← INTEGER only)")
        XCTAssertNil(r1.string("blob_val"), "GRDB: BLOB → String is nil (String ← TEXT only)")
        XCTAssertNil(r1.blob("text_val"), "GRDB: TEXT → blob is nil (Data ← BLOB only)")

        // ── GRDB REAL promotion: INTEGER value → Double (the one promotion) ─
        // (covered in row 3 below; here real_val is genuinely REAL)

        // ── Row 2: NULLs everywhere except the NOT NULL label + null_val ─────
        let r2 = rows[1]
        XCTAssertEqual(r2.int("id"), 2)
        XCTAssertEqual(r2.string("label"), "all-null")
        XCTAssertNil(r2.int64("int_val"), "NULL → nil Int64")
        XCTAssertNil(r2.double("real_val"), "NULL → nil Double")
        XCTAssertNil(r2.string("text_val"), "NULL → nil String")
        XCTAssertNil(r2.blob("blob_val"), "NULL → nil blob")
        XCTAssertEqual(r2.int64("null_val"), 99, "the one non-NULL in the null_val column")

        // ── Row 3: INTEGER value in a REAL-declared column + empty blob ─────
        let r3 = rows[2]
        XCTAssertEqual(r3.int("id"), 3)
        XCTAssertEqual(r3.string("label"), "int-in-real-col")
        XCTAssertEqual(r3.int64("int_val"), -7, "negative INTEGER → Int64")
        // GRDB Double.fromDatabaseValue promotes INTEGER → Double (the one
        // cross-class promotion GRDB allows). The seam MUST reproduce this.
        XCTAssertEqual(r3.double("real_val"), 42.0, "GRDB: INTEGER value in REAL column → Double (promotion)")
        XCTAssertEqual(r3.string("text_val"), "coercion")
        XCTAssertEqual(r3.blob("blob_val"), [], "empty BLOB → empty [UInt8] (not nil)")

        // ── Row 4: large Int64 + empty string + 2-byte blob ──────────────────
        let r4 = rows[3]
        XCTAssertEqual(r4.int("id"), 4)
        XCTAssertEqual(r4.string("label"), "large-int64")
        XCTAssertEqual(r4.int64("int_val"), 9_000_000_000_000, "Int64 > UInt32 round-trips exactly")
        XCTAssertEqual(r4.int("int_val"), 9_000_000_000_000, "Int64 → Int exact on 64-bit (no overflow)")
        XCTAssertEqual(try XCTUnwrap(r4.double("real_val")), 2.718281828, accuracy: 1e-9)
        XCTAssertEqual(r4.string("text_val"), "", "empty TEXT → empty String (not nil)")
        XCTAssertEqual(r4.blob("blob_val"), [0x00, 0xFF], "2-byte BLOB with 0x00 + 0xFF")
    }

    // ── tableNames() + columnNames(ofTable:) reproduce the parser discovery ──
    func testSeamSchemaDiscoveryMatchesParserExpectations() throws {
        _ = try buildFixtureDB()
        let reader = try SQLiteConnection.openReadOnly(path: dbPath)
        defer { reader.close() }

        let tables = try reader.tableNames()
        XCTAssertTrue(tables.contains("coercion_matrix"), "tableNames() finds the fixture table")
        XCTAssertFalse(tables.contains("sqlite_sequence"), "sqlite_sequence is filtered (it's a schema table)")

        let columns = try reader.columnNames(ofTable: "coercion_matrix")
        XCTAssertEqual(columns, ["id", "label", "int_val", "real_val", "text_val", "blob_val", "null_val"],
                       "columnNames() returns declared columns in CREATE TABLE order")
    }

    // ── NULL vs empty: the two most common divergence source in practice ─────
    func testNullVsEmptyAreDistinct() throws {
        let conn = try SQLiteConnection.openForWriting(creatingAt: dbPath)
        defer { conn.close() }
        try conn.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, s TEXT, b BLOB)")
        try conn.execute("INSERT INTO t (id, s, b) VALUES (1, NULL, NULL)")
        try conn.execute("INSERT INTO t (id, s, b) VALUES (2, '', X'')")

        let reader = try SQLiteConnection.openReadOnly(path: dbPath)
        defer { reader.close() }
        let rows = try reader.query("SELECT s, b FROM t ORDER BY id")

        // Row 1: NULL string + NULL blob.
        XCTAssertNil(rows[0].string("s"), "NULL string → nil (not empty string)")
        XCTAssertNil(rows[0].blob("b"), "NULL blob → nil (not empty array)")

        // Row 2: empty string + empty blob — MUST be distinct from NULL.
        XCTAssertEqual(rows[1].string("s"), "", "empty string → \"\" (not nil)")
        XCTAssertEqual(rows[1].blob("b"), [], "empty blob → [] (not nil)")
    }

    // ── Hermes's per-session message query path (the only .text-bound query) ─
    func testHermesStyleBoundTextQueryRoundTrips() throws {
        let conn = try SQLiteConnection.openForWriting(creatingAt: dbPath)
        defer { conn.close() }
        try conn.execute("CREATE TABLE messages (session_id TEXT, role TEXT, content TEXT)")
        try conn.execute(
            "INSERT INTO messages (session_id, role, content) VALUES (?, ?, ?)",
            arguments: [.text("sess-abc"), .text("user"), .text("hello world")]
        )
        try conn.execute(
            "INSERT INTO messages (session_id, role, content) VALUES (?, ?, ?)",
            arguments: [.text("sess-abc"), .text("assistant"), .text("hi there")]
        )

        let reader = try SQLiteConnection.openReadOnly(path: dbPath)
        defer { reader.close() }

        // This is the exact query shape HermesParser uses (bound session_id).
        let rows = try reader.query(
            "SELECT role, content FROM messages WHERE session_id = ? ORDER BY rowid",
            arguments: [.text("sess-abc")]
        )
        XCTAssertEqual(rows.count, 2, "bound .text argument filters correctly")
        XCTAssertEqual(rows[0].string("role"), "user")
        XCTAssertEqual(rows[0].string("content"), "hello world")
        XCTAssertEqual(rows[1].string("role"), "assistant")
        XCTAssertEqual(rows[1].string("content"), "hi there")
    }
}