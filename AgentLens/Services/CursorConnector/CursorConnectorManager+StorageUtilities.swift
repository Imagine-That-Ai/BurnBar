import CryptoKit
import Foundation
import SQLite3

extension CursorConnectorManager {
    func ensureLogFile(at url: URL) throws -> URL {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: Data())
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }

    static func cursorStateDBURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    }

    static func sqliteDB(path: String) throws -> OpaquePointer {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK, let db else {
            throw NSError(domain: "CursorConnector", code: 10, userInfo: [NSLocalizedDescriptionKey: "Could not open Cursor state database"])
        }
        return db
    }

    static func readSQLiteValue(db: OpaquePointer, key: String, allowMissing: Bool = false) throws -> String {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT value FROM ItemTable WHERE key = ?", -1, &statement, nil) == SQLITE_OK else {
            throw NSError(domain: "CursorConnector", code: 11, userInfo: [NSLocalizedDescriptionKey: "Could not prepare Cursor read"])
        }
        sqlite3_bind_text(statement, 1, (key as NSString).utf8String, -1, nil)
        let step = sqlite3_step(statement)
        if step == SQLITE_ROW, let cString = sqlite3_column_text(statement, 0) {
            return String(cString: cString)
        }
        if allowMissing { return "" }
        throw NSError(domain: "CursorConnector", code: 12, userInfo: [NSLocalizedDescriptionKey: "Cursor setting \(key) was not found"])
    }

    static func writeSQLiteValue(db: OpaquePointer, key: String, value: String) throws {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = "INSERT OR REPLACE INTO ItemTable (key, value) VALUES (?, ?)"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw NSError(domain: "CursorConnector", code: 13, userInfo: [NSLocalizedDescriptionKey: "Could not prepare Cursor write"])
        }
        sqlite3_bind_text(statement, 1, (key as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 2, (value as NSString).utf8String, -1, nil)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw NSError(domain: "CursorConnector", code: 14, userInfo: [NSLocalizedDescriptionKey: "Could not write Cursor setting \(key)"])
        }
    }

    static func deterministicUUID(for value: String) -> UUID {
        let digest = Insecure.MD5.hash(data: Data(value.utf8))
        let bytes = Array(digest)
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5],
            bytes[6], bytes[7],
            bytes[8], bytes[9],
            bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

}
