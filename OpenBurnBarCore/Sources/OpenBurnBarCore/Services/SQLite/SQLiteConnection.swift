// The one SQLite backend for the read-only reader seam. It speaks the raw
// `sqlite3_*` C API — the same API `AgentLens/Services/LogParser/WindsurfParser.swift`
// uses on Apple — linking whichever SQLite is present:
//   • Apple (macOS/iOS): the system `SQLite3` module (`#if canImport(SQLite3)`), so
//     the 8.8 MB vendored amalgamation is never compiled on Apple builds.
//   • Off-Apple (Windows/Linux): the vendored `OpenBurnBarCoreCSQLite`
//     amalgamation target, since the Swift Windows SDK ships no system SQLite.
// Both expose identical `sqlite3_*` symbols, so the Swift logic below is the SAME
// on every platform — the macOS G2 run therefore exercises the exact reader code
// the Windows CI leg runs.
#if canImport(SQLite3)
import SQLite3
#elseif canImport(OpenBurnBarCoreCSQLite)
import OpenBurnBarCoreCSQLite
#else
#error("No SQLite backend available: neither the system SQLite3 module (Apple) nor the vendored OpenBurnBarCoreCSQLite target (off-Apple) is importable.")
#endif
import Foundation

// `SQLITE_TRANSIENT` is a C macro (`(sqlite3_destructor_type)-1`) that is not
// imported into Swift; it tells SQLite to copy bound text/blob immediately. This
// is the standard Swift idiom for it.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A plain (unencrypted) SQLite connection over the raw C API. Opened read-only
/// for the lifted parsers; a create/read-write open + `execute` path exists for
/// fixture builders (the G2 harness lays out Codex `state_5.sqlite`).
public final class SQLiteConnection: SQLiteReading {
    private var db: OpaquePointer?

    private init(db: OpaquePointer) {
        self.db = db
    }

    deinit {
        close()
    }

    /// Open an existing database read-only (the production parser path). Matches
    /// GRDB `Configuration.readonly = true` + `DatabaseQueue(path:)`.
    public static func openReadOnly(path: String) throws -> SQLiteConnection {
        try open(path: path, flags: SQLITE_OPEN_READONLY)
    }

    /// Open (creating if needed) read-write. Used only by fixture builders/tests.
    public static func openForWriting(creatingAt path: String) throws -> SQLiteConnection {
        try open(path: path, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
    }

    private static func open(path: String, flags: Int32) throws -> SQLiteConnection {
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(path, &handle, flags, nil)
        guard rc == SQLITE_OK, let handle else {
            let message: String
            if let handle {
                message = String(cString: sqlite3_errmsg(handle))
                sqlite3_close_v2(handle)
            } else {
                message = "unable to open database at \(path)"
            }
            throw SQLiteError(code: rc, message: message)
        }
        return SQLiteConnection(db: handle)
    }

    public func close() {
        if let db {
            sqlite3_close_v2(db)
            self.db = nil
        }
    }

    // MARK: - Read

    public func query(_ sql: String, arguments: [SQLiteArgument]) throws -> [SQLiteRow] {
        guard let db else {
            throw SQLiteError(code: SQLITE_MISUSE, message: "query on a closed connection")
        }

        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard prepareResult == SQLITE_OK, let statement else {
            let message = String(cString: sqlite3_errmsg(db))
            if let statement { sqlite3_finalize(statement) }
            throw SQLiteError(code: prepareResult, message: "\(message) [sql: \(sql)]")
        }
        defer { sqlite3_finalize(statement) }

        try bind(arguments, to: statement)

        var rows: [SQLiteRow] = []
        while true {
            let stepResult = sqlite3_step(statement)
            if stepResult == SQLITE_ROW {
                rows.append(readRow(statement))
            } else if stepResult == SQLITE_DONE {
                break
            } else {
                throw SQLiteError(code: stepResult, message: String(cString: sqlite3_errmsg(db)))
            }
        }
        return rows
    }

    // MARK: - Write (fixture builders only)

    /// Execute a statement that returns no rows (CREATE TABLE / INSERT / …),
    /// binding `arguments` positionally.
    public func execute(_ sql: String, arguments: [SQLiteArgument] = []) throws {
        guard let db else {
            throw SQLiteError(code: SQLITE_MISUSE, message: "execute on a closed connection")
        }

        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard prepareResult == SQLITE_OK, let statement else {
            let message = String(cString: sqlite3_errmsg(db))
            if let statement { sqlite3_finalize(statement) }
            throw SQLiteError(code: prepareResult, message: "\(message) [sql: \(sql)]")
        }
        defer { sqlite3_finalize(statement) }

        try bind(arguments, to: statement)

        let stepResult = sqlite3_step(statement)
        guard stepResult == SQLITE_DONE || stepResult == SQLITE_ROW else {
            throw SQLiteError(code: stepResult, message: String(cString: sqlite3_errmsg(db)))
        }
    }

    // MARK: - Internals

    private func bind(_ arguments: [SQLiteArgument], to statement: OpaquePointer) throws {
        for (offset, argument) in arguments.enumerated() {
            let index = Int32(offset + 1) // SQLite bind indices are 1-based.
            let rc: Int32
            switch argument {
            case .text(let text):
                rc = sqlite3_bind_text(statement, index, text, -1, SQLITE_TRANSIENT)
            case .int(let value):
                rc = sqlite3_bind_int64(statement, index, value)
            case .double(let value):
                rc = sqlite3_bind_double(statement, index, value)
            case .blob(let bytes):
                rc = bytes.withUnsafeBytes { buffer in
                    sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(buffer.count), SQLITE_TRANSIENT)
                }
            case .null:
                rc = sqlite3_bind_null(statement, index)
            }
            if rc != SQLITE_OK {
                let db = self.db
                let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "bind failed"
                throw SQLiteError(code: rc, message: message)
            }
        }
    }

    private func readRow(_ statement: OpaquePointer) -> SQLiteRow {
        let columnCount = sqlite3_column_count(statement)
        var columns: [String: SQLiteValue] = [:]
        columns.reserveCapacity(Int(columnCount))
        for index in 0..<columnCount {
            guard let namePointer = sqlite3_column_name(statement, index) else { continue }
            let name = String(cString: namePointer)
            columns[name] = readValue(statement, index)
        }
        return SQLiteRow(columns: columns)
    }

    private func readValue(_ statement: OpaquePointer, _ index: Int32) -> SQLiteValue {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_INTEGER:
            return .integer(sqlite3_column_int64(statement, index))
        case SQLITE_FLOAT:
            return .real(sqlite3_column_double(statement, index))
        case SQLITE_TEXT:
            if let textPointer = sqlite3_column_text(statement, index) {
                return .text(String(cString: textPointer))
            }
            return .null
        case SQLITE_BLOB:
            if let blobPointer = sqlite3_column_blob(statement, index) {
                let count = Int(sqlite3_column_bytes(statement, index))
                let buffer = UnsafeRawBufferPointer(start: blobPointer, count: count)
                return .blob([UInt8](buffer))
            }
            return .blob([])
        default: // SQLITE_NULL
            return .null
        }
    }
}
