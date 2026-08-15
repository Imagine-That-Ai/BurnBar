import Foundation

// MARK: - Read-only SQLite reader seam (Foundation-only surface)
//
// Windows-port Phase-2 (G2 parser lift, `docs/WINDOWS_PORT_MASTER_PLAN.md`).
//
// The two SQLite-backed golden parsers (Codex + Hermes) read a **plain,
// unencrypted** SQLite database (Codex: `~/.codex/state_5.sqlite` `threads`
// table; Hermes: `state.db` `sessions`/`messages`). On the macOS app they did this
// through GRDB (`DatabaseQueue` + `Row.fetchAll`), but GRDB (via GRDB-SQLCipher) is
// pruned from the Foundation-only Engine subset that compiles off-Apple, so the
// parsers could not be lifted while importing it.
//
// This seam replaces the GRDB reads with a tiny, backend-agnostic surface. The one
// backend (`SQLiteConnection`) speaks the raw `sqlite3_*` C API — **the same API
// `WindsurfParser` already uses on Apple** — linking the system `SQLite3` module on
// Apple and the vendored `CSQLite` amalgamation off-Apple (`#if canImport`). Because
// SQLite is deterministic, the macOS run of the G2 harness exercises the *exact*
// reader code Windows runs (only the linked libsqlite3 binary differs), so
// byte-identity on macOS is a proof for Windows — not just an assumption.
//
// The typed getters below reproduce GRDB's `DatabaseValueConvertible` coercion
// EXACTLY (per storage class), so the lifted parsers' extraction logic is
// byte-for-byte unchanged versus the GRDB-generated golden.

/// A bound statement argument. Mirrors the SQLite storage classes the lifted
/// parsers bind (only `.text` is used today — Hermes' per-session message query).
public enum SQLiteArgument: Sendable, Equatable {
    case text(String)
    case int(Int64)
    case double(Double)
    case blob([UInt8])
    case null
}

/// One column value, captured at `step` time, keyed by its SQLite storage class.
public enum SQLiteValue: Sendable, Equatable {
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob([UInt8])
    case null
}

/// A single result row: column name → captured value. The typed accessors
/// reproduce GRDB's `DatabaseValueConvertible` coercion for the corresponding
/// Swift type so the lifted parsers behave identically to their GRDB originals.
public struct SQLiteRow: Sendable, Equatable {
    private let columns: [String: SQLiteValue]

    public init(columns: [String: SQLiteValue]) {
        self.columns = columns
    }

    public func value(_ column: String) -> SQLiteValue? { columns[column] }

    /// GRDB `String.fromDatabaseValue`: succeeds only for the TEXT storage class.
    public func string(_ column: String) -> String? {
        if case .text(let text)? = columns[column] { return text }
        return nil
    }

    /// GRDB `Int64.fromDatabaseValue`: succeeds only for the INTEGER storage class.
    public func int64(_ column: String) -> Int64? {
        if case .integer(let value)? = columns[column] { return value }
        return nil
    }

    /// GRDB `Int.fromDatabaseValue`: only INTEGER, exact (nil on overflow).
    public func int(_ column: String) -> Int? {
        if case .integer(let value)? = columns[column] { return Int(exactly: value) }
        return nil
    }

    /// GRDB `Double.fromDatabaseValue`: REAL, or INTEGER promoted to Double.
    public func double(_ column: String) -> Double? {
        switch columns[column] {
        case .real(let value)?: return value
        case .integer(let value)?: return Double(value)
        default: return nil
        }
    }

    /// GRDB `Data.fromDatabaseValue`: only the BLOB storage class.
    public func blob(_ column: String) -> [UInt8]? {
        if case .blob(let bytes)? = columns[column] { return bytes }
        return nil
    }

    /// TEXT values in column-iteration order. Used by EXPLAIN QUERY PLAN
    /// readers when the `detail` name is absent on a given SQLite build.
    public func allTextValues() -> [String] {
        columns.values.compactMap { value in
            if case .text(let text) = value { return text }
            return nil
        }
    }
}

/// A read-only, plain-SQLite reader. One concrete backend (`SQLiteConnection`)
/// implements it over the raw `sqlite3_*` C API; the convenience `sqlite_master`
/// / `PRAGMA table_info` helpers below are the exact reads the lifted parsers do.
public protocol SQLiteReading: AnyObject {
    /// Run a SELECT/PRAGMA, binding `arguments` positionally (`?` placeholders),
    /// and materialize every row.
    func query(_ sql: String, arguments: [SQLiteArgument]) throws -> [SQLiteRow]
    /// Release the underlying handle. Safe to call more than once.
    func close()
}

extension SQLiteReading {
    public func query(_ sql: String) throws -> [SQLiteRow] {
        try query(sql, arguments: [])
    }

    /// `SELECT name FROM sqlite_master WHERE type='table'` → the table names.
    public func tableNames() throws -> Set<String> {
        let rows = try query("SELECT name FROM sqlite_master WHERE type='table'")
        return Set(rows.compactMap { $0.string("name") })
    }

    /// `PRAGMA table_info(<table>)` → the declared column names, in order.
    public func columnNames(ofTable table: String) throws -> [String] {
        let rows = try query("PRAGMA table_info(\(table))")
        return rows.compactMap { $0.string("name") }
    }
}

public struct SQLiteError: Error, CustomStringConvertible, Sendable {
    public let code: Int32
    public let message: String
    public init(code: Int32, message: String) {
        self.code = code
        self.message = message
    }
    public var description: String { "SQLiteError(code: \(code), message: \(message))" }
}
