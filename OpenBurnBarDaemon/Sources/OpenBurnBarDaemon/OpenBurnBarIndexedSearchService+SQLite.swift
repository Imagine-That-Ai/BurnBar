import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

// Raw SQLite statement plumbing, split out of
// OpenBurnBarIndexedSearchService.swift, which the Swift file-size
// budget holds shrink-only. Shared by the service, its read-only SQL
// surface, and the vector-snapshot app lane.

extension BurnBarIndexedSearchService {
// MARK: - SQLite Utilities

    /// Internal for the vector-snapshot app lane (`BurnBarIndexedSearchService+VectorSnapshotAppLane.swift`).
    enum SQLiteBindValue {
        case text(String)
        case int(Int64)
        case null
    }

    /// Internal for the vector-snapshot app lane (`BurnBarIndexedSearchService+VectorSnapshotAppLane.swift`).
    func prepareStatement(sql: String) throws -> OpaquePointer? {
        guard let db else { return nil }
        var statement: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard rc == SQLITE_OK else {
            throw sqliteError(db: db, code: rc, context: "prepare")
        }
        return statement
    }

    /// Internal for the vector-snapshot app lane (`BurnBarIndexedSearchService+VectorSnapshotAppLane.swift`).
    func bind(_ args: [SQLiteBindValue], to statement: OpaquePointer) throws {
        for (index, arg) in args.enumerated() {
            let position = Int32(index + 1)
            let rc: Int32
            switch arg {
            case .text(let value):
                rc = sqlite3_bind_text(statement, position, value, -1, SQLITE_TRANSIENT)
            case .int(let value):
                rc = sqlite3_bind_int64(statement, position, value)
            case .null:
                rc = sqlite3_bind_null(statement, position)
            }
            guard rc == SQLITE_OK else {
                throw sqliteError(db: db, code: rc, context: "bind")
            }
        }
    }

}
