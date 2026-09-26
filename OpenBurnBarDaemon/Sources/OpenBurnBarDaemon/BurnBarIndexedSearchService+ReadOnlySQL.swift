import Foundation
import OpenBurnBarEngine
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

extension BurnBarIndexedSearchService {
    // MARK: - Read-only SQL (daemon.search.sql)

    /// Hard ceilings for the read-only SQL surface. Callers may ask for fewer
    /// rows, never more; the byte cap bounds the response envelope so a
    /// SELECT over `fullText` cannot balloon one socket reply.
    private static let readOnlySQLDefaultMaxRows = 200
    private static let readOnlySQLHardMaxRows = 2_000
    private static let readOnlySQLMaxResponseBytes = 4 << 20
    private static let readOnlySQLMaxStatementBytes = 64 << 10
    /// Progress-handler budget: the handler fires every `stride` VM ops and
    /// interrupts after `ticks` firings (~50M ops) so a pathological recursive
    /// CTE cannot pin the daemon's database queue.
    private static let readOnlySQLProgressStride: Int32 = 100_000
    private static let readOnlySQLProgressTicks = 500

    enum ReadOnlySQLError: Error, LocalizedError, Equatable {
        case unavailable
        case emptyStatement
        case statementTooLarge
        case multipleStatements
        case notASelect
        case notReadOnly
        case interrupted

        var errorDescription: String? {
            switch self {
            case .unavailable: return "The indexed store is not open."
            case .emptyStatement: return "SQL statement is empty."
            case .statementTooLarge: return "SQL statement exceeds the 64KB limit."
            case .multipleStatements: return "Exactly one SQL statement is allowed."
            case .notASelect: return "Only SELECT (or WITH … SELECT) statements are allowed."
            case .notReadOnly: return "Statement is not read-only."
            case .interrupted: return "Query exceeded the execution budget and was interrupted."
            }
        }
    }

    private final class ReadOnlySQLProgressBox {
        var remainingTicks: Int
        init(remainingTicks: Int) { self.remainingTicks = remainingTicks }
    }

    /// Execute one read-only SELECT on the daemon's keyed handle.
    ///
    /// Enforcement is layered, innermost first:
    /// 1. `sqlite3_stmt_readonly` — structural: the prepared program writes
    ///    nothing, regardless of how the text was spelled.
    /// 2. A SELECT/WITH prefix gate — keeps connection-state statements
    ///    (PRAGMA and friends) off a surface that exists purely to read rows.
    /// 3. Single-statement, size, row, byte, and VM-step ceilings.
    func readOnlySQL(_ request: BurnBarSearchSQLRequest) throws -> BurnBarSearchSQLResult {
        try databaseSync {
            guard let db else { throw ReadOnlySQLError.unavailable }

            let sql = request.sql.trimmingCharacters(in: .whitespacesAndNewlines)
            guard sql.isEmpty == false else { throw ReadOnlySQLError.emptyStatement }
            guard sql.utf8.count <= Self.readOnlySQLMaxStatementBytes else {
                throw ReadOnlySQLError.statementTooLarge
            }
            let leadingKeyword = sql.prefix(while: { $0.isLetter }).lowercased()
            guard leadingKeyword == "select" || leadingKeyword == "with" else {
                throw ReadOnlySQLError.notASelect
            }

            // The tail pointer aims into the C string's own buffer, so it must be
            // consumed inside `withCString` — the bridged buffer dies at the brace.
            var statement: OpaquePointer?
            var hasTrailingStatement = false
            let rc = sql.withCString { cString -> Int32 in
                var tail: UnsafePointer<CChar>?
                let code = sqlite3_prepare_v2(db, cString, -1, &statement, &tail)
                if code == SQLITE_OK, let tail {
                    hasTrailingStatement = String(cString: tail)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty == false
                }
                return code
            }
            guard rc == SQLITE_OK, let statement else {
                throw sqliteError(db: db, code: rc, context: "prepare_readonly_sql")
            }
            defer { sqlite3_finalize(statement) }

            if hasTrailingStatement {
                throw ReadOnlySQLError.multipleStatements
            }
            guard sqlite3_stmt_readonly(statement) != 0 else {
                throw ReadOnlySQLError.notReadOnly
            }

            for (index, value) in request.args.enumerated() {
                let position = Int32(index + 1)
                let bindRC: Int32
                switch value {
                case .null:
                    bindRC = sqlite3_bind_null(statement, position)
                case .integer(let integer):
                    bindRC = sqlite3_bind_int64(statement, position, integer)
                case .real(let real):
                    bindRC = sqlite3_bind_double(statement, position, real)
                case .text(let text):
                    bindRC = sqlite3_bind_text(statement, position, text, -1, SQLITE_TRANSIENT)
                case .blob(let data):
                    bindRC = data.withUnsafeBytes { bytes in
                        sqlite3_bind_blob(statement, position, bytes.baseAddress, Int32(bytes.count), SQLITE_TRANSIENT)
                    }
                }
                guard bindRC == SQLITE_OK else {
                    throw sqliteError(db: db, code: bindRC, context: "bind_readonly_sql")
                }
            }

            let requestedRows = request.maxRows ?? Self.readOnlySQLDefaultMaxRows
            let rowCap = max(1, min(requestedRows, Self.readOnlySQLHardMaxRows))

            let progressBox = ReadOnlySQLProgressBox(remainingTicks: Self.readOnlySQLProgressTicks)
            let progressContext = Unmanaged.passUnretained(progressBox).toOpaque()
            sqlite3_progress_handler(db, Self.readOnlySQLProgressStride, { context in
                guard let context else { return 0 }
                let box = Unmanaged<ReadOnlySQLProgressBox>.fromOpaque(context).takeUnretainedValue()
                box.remainingTicks -= 1
                return box.remainingTicks <= 0 ? 1 : 0
            }, progressContext)
            defer { sqlite3_progress_handler(db, 0, nil, nil) }

            let columnCount = Int(sqlite3_column_count(statement))
            var columns: [String] = []
            columns.reserveCapacity(columnCount)
            for index in 0..<columnCount {
                if let name = sqlite3_column_name(statement, Int32(index)) {
                    columns.append(String(cString: name))
                } else {
                    columns.append("column_\(index)")
                }
            }

            var rows: [[BurnBarSQLValue]] = []
            var truncated = false
            var approximateBytes = 0

            stepLoop: while true {
                let stepRC = sqlite3_step(statement)
                switch stepRC {
                case SQLITE_ROW:
                    if rows.count >= rowCap {
                        truncated = true
                        break stepLoop
                    }
                    var row: [BurnBarSQLValue] = []
                    row.reserveCapacity(columnCount)
                    for index in 0..<columnCount {
                        let column = Int32(index)
                        switch sqlite3_column_type(statement, column) {
                        case SQLITE_INTEGER:
                            row.append(.integer(sqlite3_column_int64(statement, column)))
                            approximateBytes += 8
                        case SQLITE_FLOAT:
                            row.append(.real(sqlite3_column_double(statement, column)))
                            approximateBytes += 8
                        case SQLITE_TEXT:
                            // Size FIRST, copy second. `sqlite3_column_bytes` is O(1)
                            // here, while a single cell can dwarf the whole response
                            // budget (a large `fullText`, `SELECT randomblob(...)`).
                            // Materializing before the check made the advertised cap
                            // bound only the RESPONSE, not the allocation — one
                            // read-only query could exhaust daemon memory.
                            let textBytes = Int(sqlite3_column_bytes(statement, column))
                            if approximateBytes + textBytes > Self.readOnlySQLMaxResponseBytes {
                                truncated = true
                                break stepLoop
                            }
                            let text = sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
                            approximateBytes += text.utf8.count
                            row.append(.text(text))
                        case SQLITE_BLOB:
                            let byteCount = Int(sqlite3_column_bytes(statement, column))
                            // Blobs are base64'd on the wire, so budget the ENCODED size.
                            let encodedBytes = (byteCount * 4) / 3
                            if approximateBytes + encodedBytes > Self.readOnlySQLMaxResponseBytes {
                                truncated = true
                                break stepLoop
                            }
                            let data: Data
                            if byteCount > 0, let bytes = sqlite3_column_blob(statement, column) {
                                data = Data(bytes: bytes, count: byteCount)
                            } else {
                                data = Data()
                            }
                            approximateBytes += encodedBytes
                            row.append(.blob(data))
                        default:
                            row.append(.null)
                        }
                    }
                    rows.append(row)
                    if approximateBytes >= Self.readOnlySQLMaxResponseBytes {
                        truncated = true
                        break stepLoop
                    }
                case SQLITE_DONE:
                    break stepLoop
                case SQLITE_INTERRUPT:
                    throw ReadOnlySQLError.interrupted
                default:
                    if sqlite3_errcode(db) == SQLITE_INTERRUPT {
                        throw ReadOnlySQLError.interrupted
                    }
                    throw sqliteError(db: db, code: stepRC, context: "step_readonly_sql")
                }
            }

            return BurnBarSearchSQLResult(columns: columns, rows: rows, truncated: truncated)
        }
    }

    /// Whether the `conversations` table carries the v47 `deletedAt` tombstone
    /// column. Probed once and cached so tombstone-aware reads stay cheap and
    /// remain safe against a transiently pre-migration schema.
    var conversationsHaveDeletedAtColumn: Bool {
        if let cached = cachedConversationsHaveDeletedAtColumn { return cached }
        var found = false
        if let statement = try? prepareStatement(sql: "PRAGMA table_info(conversations)") {
            defer { sqlite3_finalize(statement) }
            while sqlite3_step(statement) == SQLITE_ROW {
                if stringColumn(statement, index: 1) == "deletedAt" {
                    found = true
                    break
                }
            }
        }
        cachedConversationsHaveDeletedAtColumn = found
        return found
    }

    func stringColumn(_ statement: OpaquePointer, index: Int32) -> String? {
        guard let cString = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: cString)
    }

    func dataColumn(_ statement: OpaquePointer, index: Int32) -> Data? {
        guard let blobPtr = sqlite3_column_blob(statement, index) else { return nil }
        let blobSize = sqlite3_column_bytes(statement, index)
        return Data(bytes: blobPtr, count: Int(blobSize))
    }

    func parseSQLiteDate(_ string: String?) -> Date? {
        guard let string, string.isEmpty == false else { return nil }
        if let date = Self.sqliteDateFormatter.date(from: string) {
            return date
        }
        return ThreadSafeISO8601DateFormatter.parse(string)
    }

    func vectorSnapshotRecord(from statement: OpaquePointer) -> DaemonVectorIndexSnapshotRecord? {
        guard
            let embeddingVersionID = stringColumn(statement, index: 0),
            let backendID = stringColumn(statement, index: 1),
            let state = stringColumn(statement, index: 2),
            let fingerprint = stringColumn(statement, index: 3),
            let distanceMetricRaw = stringColumn(statement, index: 5),
            let distanceMetric = BurnBarEmbeddingDistanceMetric(rawValue: distanceMetricRaw),
            let backendVersion = stringColumn(statement, index: 9)
        else {
            return nil
        }

        return DaemonVectorIndexSnapshotRecord(
            embeddingVersionID: embeddingVersionID,
            backendID: backendID,
            state: state,
            fingerprint: fingerprint,
            dimensions: Int(sqlite3_column_int64(statement, 4)),
            distanceMetric: distanceMetric,
            vectorCount: Int(sqlite3_column_int64(statement, 6)),
            storageRelativePath: stringColumn(statement, index: 7),
            fileBytes: sqlite3_column_int64(statement, 8),
            backendVersion: backendVersion,
            errorCode: stringColumn(statement, index: 10),
            errorMessage: stringColumn(statement, index: 11),
            createdAt: parseSQLiteDate(stringColumn(statement, index: 12)) ?? Date(),
            updatedAt: parseSQLiteDate(stringColumn(statement, index: 13)) ?? Date(),
            lastBuiltAt: parseSQLiteDate(stringColumn(statement, index: 14))
        )
    }

    /// Internal for the vector-snapshot app lane (`BurnBarIndexedSearchService+VectorSnapshotAppLane.swift`).
    static func sqliteTimestamp(_ date: Date) -> String {
        sqliteDateFormatter.string(from: date)
    }

    private static let sqliteDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    /// Internal for the vector-snapshot app lane (`BurnBarIndexedSearchService+VectorSnapshotAppLane.swift`).
    func sqliteError(db: OpaquePointer?, code: Int32, context: String) -> NSError {
        let message = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "sqlite error"
        return NSError(
            domain: "BurnBarIndexedSearchService",
            code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: "\(context) failed (\(code)): \(message)"]
        )
    }
}
