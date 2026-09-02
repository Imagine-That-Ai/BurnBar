import Foundation
import OpenBurnBarEngine
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

extension BurnBarProjectCodeMemoryStore {
    func groupedCounts(_ sql: String, _ binds: [SQLiteBind]) throws -> [String: Int] {
        var result: [String: Int] = [:]
        for row in try queryRows(sql, binds) {
            result[row.string(0)] = Int(row.int64(1))
        }
        return result
    }

    func projectStorageByteCount(projectID: String) throws -> Int {
        let sourceBytes = try fetchInt(
            "SELECT COALESCE(SUM(byte_count), 0) FROM code_artifacts WHERE project_id = ?",
            [.text(projectID)]
        )
        let chunkTextBytes = try fetchInt(
            """
            SELECT COALESCE(SUM(length(CAST(c.text AS BLOB))), 0)
            FROM search_chunks c
            JOIN code_artifacts a ON a.id = c.sourceID
            WHERE c.sourceKind = ? AND a.project_id = ?
            """,
            [.text(Self.codeSourceKind), .text(projectID)]
        )
        let ftsMetadataBytes = projectID.utf8.count + Self.codeProvider.utf8.count
        let ftsMirrorBytes = try fetchInt(
            """
            SELECT COALESCE(SUM(
                length(CAST(c.text AS BLOB))
                + length(CAST(COALESCE(c.sectionPath, '') AS BLOB))
                + ?
            ), 0)
            FROM search_chunks c
            JOIN code_artifacts a ON a.id = c.sourceID
            WHERE c.sourceKind = ? AND a.project_id = ?
            """,
            [.int(ftsMetadataBytes), .text(Self.codeSourceKind), .text(projectID)]
        )
        let legacyVectorBytes = try fetchInt(
            """
            SELECT COALESCE(SUM(length(e.vectorBlob)), 0)
            FROM chunk_embeddings e
            JOIN search_chunks c ON c.id = e.chunkID
            JOIN code_artifacts a ON a.id = c.sourceID
            WHERE c.sourceKind = ? AND a.project_id = ?
            """,
            [.text(Self.codeSourceKind), .text(projectID)]
        )
        let codeVectorBytes = try fetchInt(
            """
            SELECT COALESCE(SUM(length(CAST(e.vector AS BLOB))), 0)
            FROM code_chunk_embeddings e
            JOIN search_chunks c ON c.id = e.chunk_id
            JOIN code_artifacts a ON a.id = c.sourceID
            WHERE c.sourceKind = ? AND a.project_id = ?
            """,
            [.text(Self.codeSourceKind), .text(projectID)]
        )
        return sourceBytes + chunkTextBytes + ftsMirrorBytes + legacyVectorBytes + codeVectorBytes
    }

    func projectRepoMap(projectID: String, topFiles: [BurnBarProjectCodeExploreFile]) throws -> BurnBarProjectCodeRepoMap {
        let languages = try queryRows(
            """
            SELECT COALESCE(lang, 'unknown') AS lang, COUNT(*) AS file_count, COALESCE(SUM(byte_count), 0) AS byte_count
            FROM code_artifacts
            WHERE project_id = ?
            GROUP BY COALESCE(lang, 'unknown')
            ORDER BY file_count DESC, lang ASC
            """,
            [.text(projectID)]
        ).map {
            BurnBarProjectCodeRepoLanguage(
                lang: $0.string(0),
                fileCount: Int($0.int64(1)),
                byteCount: Int($0.int64(2))
            )
        }
        return BurnBarProjectCodeRepoMap(
            artifactCount: try fetchInt("SELECT COUNT(*) FROM code_artifacts WHERE project_id = ?", [.text(projectID)]),
            symbolCount: try fetchInt("SELECT COUNT(*) FROM code_symbols WHERE project_id = ?", [.text(projectID)]),
            languages: languages,
            topFiles: topFiles
        )
    }

    func querySymbols(_ sql: String, _ binds: [SQLiteBind]) throws -> [SQLiteSymbolRow] {
        try queryRows(sql, binds).map {
            SQLiteSymbolRow(
                id: $0.string(0),
                artifactID: $0.string(1),
                filePath: $0.string(2),
                name: $0.string(3),
                kind: $0.string(4),
                range: Self.decodeRange($0.string(5)),
                confidenceTier: $0.string(6),
                blobSHA: $0.optionalString(7) ?? "",
                tierEvidenceJSON: $0.optionalString(8)
            )
        }
    }

    func ensureColumn(table: String, column: String, definition: String) throws {
        let columns = try queryRows("PRAGMA table_info(\(table))", [])
            .compactMap { $0.optionalString(1) }
        guard columns.contains(column) == false else { return }
        try execute("ALTER TABLE \(table) ADD COLUMN \(column) \(definition)", [])
    }

    func sqliteCompactionDecision() throws -> SQLiteCompactionDecision {
        let pageCount = try fetchInt("PRAGMA page_count", [])
        let freelistCount = try fetchInt("PRAGMA freelist_count", [])
        let pageSize = try fetchInt("PRAGMA page_size", [])
        return SQLiteCompactionDecision(
            shouldCompact: Self.shouldCompactSQLite(
                freelistCount: freelistCount,
                pageCount: pageCount,
                pageSize: pageSize
            ),
            pageCount: pageCount,
            freelistCount: freelistCount,
            pageSize: pageSize
        )
    }

    func runIncrementalVacuum(maxPages: Int) throws {
        let pages = max(1, min(maxPages, 1_024))
        try execute("PRAGMA incremental_vacuum(\(pages))", [])
    }

    func execute(_ sql: String, _ binds: [SQLiteBind]) throws {
        guard let db else { throw BurnBarProjectCodeMemoryStoreError.sqlite("SQLite database is closed.") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw sqliteError()
        }
        defer { sqlite3_finalize(statement) }
        try bind(binds, to: statement)
        let rc = sqlite3_step(statement)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw sqliteError()
        }
    }

    func queryRows(_ sql: String, _ binds: [SQLiteBind]) throws -> [SQLiteRow] {
        guard let db else { throw BurnBarProjectCodeMemoryStoreError.sqlite("SQLite database is closed.") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw sqliteError()
        }
        defer { sqlite3_finalize(statement) }
        try bind(binds, to: statement)
        var rows: [SQLiteRow] = []
        while true {
            let rc = sqlite3_step(statement)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw sqliteError() }
            let count = sqlite3_column_count(statement)
            var values: [String?] = []
            var blobs: [Data?] = []
            for index in 0..<count {
                if sqlite3_column_type(statement, index) == SQLITE_NULL {
                    values.append(nil)
                    blobs.append(nil)
                } else if sqlite3_column_type(statement, index) == SQLITE_BLOB {
                    let byteCount = Int(sqlite3_column_bytes(statement, index))
                    let data = sqlite3_column_blob(statement, index).map { Data(bytes: $0, count: byteCount) } ?? Data()
                    values.append(nil)
                    blobs.append(data)
                } else if let text = sqlite3_column_text(statement, index) {
                    values.append(String(cString: text))
                    blobs.append(nil)
                } else {
                    values.append(nil)
                    blobs.append(nil)
                }
            }
            rows.append(SQLiteRow(values: values, blobs: blobs))
        }
        return rows
    }

    func fetchInt(_ sql: String, _ binds: [SQLiteBind]) throws -> Int {
        Int(try queryRows(sql, binds).first?.int64(0) ?? 0)
    }

    func bind(_ binds: [SQLiteBind], to statement: OpaquePointer) throws {
        for (idx, value) in binds.enumerated() {
            let position = Int32(idx + 1)
            let rc: Int32
            switch value {
            case .text(let string):
                rc = sqlite3_bind_text(statement, position, string, -1, projectCodeMemorySQLiteTransient)
            case .int(let int):
                rc = sqlite3_bind_int64(statement, position, sqlite3_int64(int))
            case .int64(let int):
                rc = sqlite3_bind_int64(statement, position, sqlite3_int64(int))
            case .double(let double):
                rc = sqlite3_bind_double(statement, position, double)
            case .blob(let data):
                rc = data.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(statement, position, bytes.baseAddress, Int32(bytes.count), projectCodeMemorySQLiteTransient)
                }
            case .null:
                rc = sqlite3_bind_null(statement, position)
            }
            guard rc == SQLITE_OK else { throw sqliteError() }
        }
    }

    func sqliteError() -> BurnBarProjectCodeMemoryStoreError {
        let message = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown sqlite error"
        return .sqlite(message)
    }

    func encodeJSONString<T: Encodable>(_ value: T) throws -> String {
        String(data: try jsonEncoder.encode(value), encoding: .utf8) ?? "null"
    }

    func decodeStringArray(_ json: String) -> [String] {
        (try? jsonDecoder.decode([String].self, from: Data(json.utf8))) ?? []
    }

    static func publicSymbol(_ row: SQLiteSymbolRow) -> BurnBarProjectCodeSymbol {
        BurnBarProjectCodeSymbol(
            symbolID: row.id,
            name: row.name,
            kind: row.kind,
            filePath: row.filePath,
            range: row.range,
            confidenceTier: row.confidenceTier,
            tierEvidence: decodeTierEvidence(row.tierEvidenceJSON)
        )
    }

    static func decodeTierEvidence(_ json: String?) -> BurnBarProjectCodeTierEvidence? {
        guard let json, json.isEmpty == false else { return nil }
        return try? JSONDecoder().decode(BurnBarProjectCodeTierEvidence.self, from: Data(json.utf8))
    }

    static func legacyProjectID(for root: URL) -> String {
        let canonical = root.resolvingSymlinksInPath().standardizedFileURL.path
        return "proj_" + String(sha256Hex(canonical).prefix(16))
    }

    static func longLegacyProjectID(for root: URL) -> String {
        let canonical = root.resolvingSymlinksInPath().standardizedFileURL.path
        return "proj_" + String(sha256Hex(canonical).prefix(32))
    }

    static func projectID(forFingerprint fingerprint: String, fallbackProjectID: String) -> String {
        guard fingerprint.hasPrefix("path:") == false else { return fallbackProjectID }
        return "proj_" + String(sha256Hex("v2:\(fingerprint)").prefix(32))
    }

    static func projectIdentityFingerprint(root: URL) -> String {
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let canonicalPath = canonicalRoot.path
        guard gitOutput(root: canonicalRoot, arguments: ["rev-parse", "--is-inside-work-tree"]) == "true" else {
            return "path:\(canonicalPath)"
        }

        var stableParts: [String] = []
        if let origin = gitOutput(root: canonicalRoot, arguments: ["config", "--get", "remote.origin.url"]) {
            stableParts.append("origin:\(origin)")
        } else if let remotes = gitOutput(root: canonicalRoot, arguments: ["remote", "-v"]), remotes.isEmpty == false {
            stableParts.append("remotes:\(sha256Hex(remotes))")
        }
        if let rootCommit = gitOutput(root: canonicalRoot, arguments: ["rev-list", "--max-parents=0", "HEAD"])?
            .components(separatedBy: .newlines)
            .first?
            .nonEmpty {
            stableParts.append("root:\(rootCommit)")
        }

        guard stableParts.isEmpty == false else { return "path:\(canonicalPath)" }
        return "git:" + stableParts.sorted().joined(separator: "|")
    }

    static func normalizedStorageBudgetBytes(_ requested: Int?) -> Int {
        max(1, min(requested ?? defaultProjectStorageBudgetBytes, maximumProjectStorageBudgetBytes))
    }
}
