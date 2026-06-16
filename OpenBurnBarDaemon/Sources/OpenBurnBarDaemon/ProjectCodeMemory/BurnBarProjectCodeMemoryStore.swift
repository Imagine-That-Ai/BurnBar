import CryptoKit
import Darwin
import Foundation
import OpenBurnBarCore
import SQLite3

private let projectCodeMemorySQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
private let projectCodeMemoryQueueKey = DispatchSpecificKey<UUID>()

enum BurnBarProjectCodeMemoryStoreError: Error, LocalizedError {
    case emptyText
    case emptyQuery
    case projectPathUnavailable(String)
    case secretRejected(labels: [String])
    case sqlite(String)

    var errorDescription: String? {
        switch self {
        case .emptyText:
            return "Memory text is empty."
        case .emptyQuery:
            return "Query is empty."
        case .projectPathUnavailable(let path):
            return "Project path is not readable: \(path)"
        case .secretRejected(let labels):
            return "Rejected before persistence by the project memory secret scanner: \(labels.joined(separator: ", "))."
        case .sqlite(let message):
            return message
        }
    }
}

// AUDIT(@unchecked Sendable): raw SQLite access is serialized through `dbQueue`.
// sendable-allowlist: sqlite-raw-pointer
final class BurnBarProjectCodeMemoryStore: @unchecked Sendable {
    fileprivate struct SQLiteRow {
        let values: [String?]
    }

    private struct SQLiteSymbolRow {
        let id: String
        let artifactID: String
        let filePath: String
        let name: String
        let kind: String
        let range: BurnBarProjectCodeRange
        let confidenceTier: String
        let blobSHA: String
        let tierEvidenceJSON: String?
    }

    private struct IndexedArtifact {
        let id: String
        let filePath: String
        let blobSHA: String
    }

    // AUDIT(@unchecked Sendable): DispatchSourceTimer callback owns mutable watcher state on its serial queue.
    // sendable-allowlist: foundation-sdk-shim
    private final class ProjectWatcher: @unchecked Sendable {
        let projectID: String
        let projectRoot: URL
        let maxFiles: Int
        let maxFileBytes: Int
        let storageBudgetBytes: Int
        let timer: DispatchSourceTimer
        var lastSignature: String

        init(
            projectID: String,
            projectRoot: URL,
            maxFiles: Int,
            maxFileBytes: Int,
            storageBudgetBytes: Int,
            timer: DispatchSourceTimer,
            lastSignature: String
        ) {
            self.projectID = projectID
            self.projectRoot = projectRoot
            self.maxFiles = maxFiles
            self.maxFileBytes = maxFileBytes
            self.storageBudgetBytes = storageBudgetBytes
            self.timer = timer
            self.lastSignature = lastSignature
        }

        deinit {
            timer.cancel()
        }
    }

    private struct MemoryIndexRow {
        let id: String
        let projectID: String
        let kind: String
        let scope: String
        let confidence: Double
        let bodyReference: String
        let tags: [String]
        let sourcePath: String?
        let updatedAt: String
    }

    private static let agentMemoryPageID = "agent-notes"
    private static let codeSourceKind = "code"
    private static let codeProvider = "local-code"
    static let ignoredDirectories: Set<String> = [
        ".git", ".build", ".swiftpm", ".deriveddata", "DerivedData", "node_modules",
        "build", "dist", ".next", ".gradle", ".idea", ".codex", ".claude"
    ]
    static let indexedExtensions: Set<String> = [
        "swift", "kt", "kts", "java", "ts", "tsx", "js", "jsx", "py", "rs", "go",
        "m", "mm", "h", "hpp", "c", "cc", "cpp", "json", "md", "yml", "yaml"
    ]
    private static let defaultProjectStorageBudgetBytes = 512 * 1_024 * 1_024
    private static let maximumProjectStorageBudgetBytes = 10 * 1_024 * 1_024 * 1_024

    private let db: OpaquePointer?
    private let dbQueue = DispatchQueue(label: "com.openburnbar.daemon.project-code-memory.sqlite")
    private let dbQueueID = UUID()
    private let logger: BurnBarDaemonLogger
    private let databasePath: String
    private let jsonEncoder = JSONEncoder()
    private let jsonDecoder = JSONDecoder()
    private var projectWatchers: [String: ProjectWatcher] = [:]

    init(databasePath: String, logger: BurnBarDaemonLogger) throws {
        self.databasePath = databasePath
        self.logger = logger
        var handle: OpaquePointer?
        let result = sqlite3_open_v2(databasePath, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, let handle else {
            let message = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown sqlite error"
            if let handle { sqlite3_close(handle) }
            throw BurnBarProjectCodeMemoryStoreError.sqlite("Failed to open project code memory SQLite database: \(message)")
        }
        do {
            try BurnBarDaemonDatabaseCipher.applyKeyIfAvailable(to: handle)
        } catch {
            sqlite3_close(handle)
            throw error
        }
        sqlite3_busy_timeout(handle, 5000)
        db = handle
        dbQueue.setSpecific(key: projectCodeMemoryQueueKey, value: dbQueueID)
        try databaseSync {
            try bootstrapSchema()
        }
    }

    deinit {
        projectWatchers.values.forEach { $0.timer.cancel() }
        guard let db else { return }
        _ = databaseSync {
            sqlite3_close(db)
        }
    }

    func remember(_ request: BurnBarProjectMemoryRememberRequest) throws -> BurnBarProjectMemoryRememberResponse {
        let traceID = TraceContextBridge.currentContext().traceID
        let body = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.isEmpty == false else { throw BurnBarProjectCodeMemoryStoreError.emptyText }
        let root = try projectRoot(request.projectPath)
        let projectID = Self.projectID(for: root)
        let labels = Self.secretLabels(in: body)
        if labels.isEmpty == false {
            let hash = try databaseSync {
                try auditEvent(action: "memory.secret_rejected", domain: "memory", projectID: projectID, subjectID: nil, labels: labels)
            }
            logger.warning("project_memory_secret_rejected", metadata: ["project_id": projectID, "audit_hash": hash])
            throw BurnBarProjectCodeMemoryStoreError.secretRejected(labels: labels)
        }

        return try databaseSync {
            let bodyRef = Self.sha256Hex(body)
            let memoryID = "mem_" + String(Self.sha256Hex("\(projectID):\(bodyRef)").prefix(32))
            let now = Self.isoNow()
            let tagsJSON = try encodeJSONString(request.tags)
            try execute("BEGIN IMMEDIATE", [])
            do {
                try upsertProjectMemorySection(
                    projectID: projectID,
                    projectDisplayName: root.lastPathComponent,
                    memoryID: memoryID,
                    body: body,
                    kind: request.kind,
                    scope: request.scope,
                    tags: request.tags,
                    sourcePath: request.sourcePath,
                    now: now
                )
                try execute(
                    """
                    INSERT INTO agent_memories
                        (id, project_id, kind, scope, confidence, body_ref, body_redacted, tags_json, source_path, valid_from, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        kind = excluded.kind,
                        scope = excluded.scope,
                        confidence = excluded.confidence,
                        body_ref = excluded.body_ref,
                        body_redacted = excluded.body_redacted,
                        tags_json = excluded.tags_json,
                        source_path = excluded.source_path,
                        updated_at = excluded.updated_at
                    """,
                    [
                        .text(memoryID), .text(projectID), .text(request.kind), .text(request.scope),
                        .double(request.confidence), .text(bodyRef), .text(Self.memoryBodyReference(memoryID: memoryID, projectID: projectID)),
                        .text(tagsJSON), request.sourcePath.map(SQLiteBind.text) ?? .null, .text(now), .text(now), .text(now)
                    ]
                )
                try execute("DELETE FROM agent_memories_fts WHERE memoryID = ?", [.text(memoryID)])
                let auditHash = try auditEvent(action: "memory.remember", domain: "memory", projectID: projectID, subjectID: memoryID, labels: [])
                try execute("COMMIT", [])
                return BurnBarProjectMemoryRememberResponse(
                    traceID: traceID,
                    projectID: projectID,
                    memoryID: memoryID,
                    auditHash: auditHash
                )
            } catch {
                try? execute("ROLLBACK", [])
                throw error
            }
        }
    }

    func recall(_ request: BurnBarProjectMemoryRecallRequest) throws -> BurnBarProjectMemoryRecallResponse {
        let traceID = TraceContextBridge.currentContext().traceID
        let query = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.isEmpty == false else { throw BurnBarProjectCodeMemoryStoreError.emptyQuery }
        let root = try projectRoot(request.projectPath)
        let projectID = Self.projectID(for: root)
        let limit = max(1, min(request.limit, 100))
        let scope = request.scope.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let tokens = Self.searchTokens(in: query)

        let hits = try databaseSync { () -> [BurnBarProjectMemoryHit] in
            var clauses: [String] = []
            var binds: [SQLiteBind] = []
            if request.includeCrossProject == false {
                clauses.append("m.project_id = ?")
                binds.append(.text(projectID))
            }
            if scope != "all", scope.isEmpty == false {
                clauses.append("m.scope = ?")
                binds.append(.text(scope))
            }
            let whereClause = clauses.isEmpty ? "" : "WHERE \(clauses.joined(separator: " AND "))"
            let sql = """
                SELECT m.id, m.project_id, m.kind, m.scope, m.confidence, m.body_redacted,
                       m.tags_json, m.source_path, m.updated_at
                FROM agent_memories AS m
                \(whereClause)
                ORDER BY m.updated_at DESC
                LIMIT 1000
            """
            let ranked = try queryRows(sql, binds)
                .map { row in
                    MemoryIndexRow(
                        id: row.string(0),
                        projectID: row.string(1),
                        kind: row.string(2),
                        scope: row.string(3),
                        confidence: row.double(4),
                        bodyReference: row.string(5),
                        tags: decodeStringArray(row.string(6)),
                        sourcePath: row.optionalString(7),
                        updatedAt: row.string(8)
                    )
                }
                .compactMap { row -> BurnBarProjectMemoryHit? in
                    guard let body = try projectMemorySectionBody(projectID: row.projectID, memoryID: row.id) else {
                        return nil
                    }
                    let searchable = ([body] + row.tags + [row.sourcePath ?? ""]).joined(separator: " ")
                    guard let rank = Self.memoryRank(tokens: tokens, query: query, searchable: searchable) else {
                        return nil
                    }
                    return BurnBarProjectMemoryHit(
                        memoryID: row.id,
                        projectID: row.projectID,
                        kind: row.kind,
                        scope: row.scope,
                        confidence: row.confidence,
                        bodyRedacted: body,
                        tags: row.tags,
                        sourcePath: row.sourcePath,
                        snippet: Self.memorySnippet(body: body, tokens: tokens, fallbackQuery: query),
                        rank: rank
                    )
                }
                .sorted { ($0.rank ?? 0) < ($1.rank ?? 0) }
            return Array(ranked.prefix(limit))
        }
        return BurnBarProjectMemoryRecallResponse(traceID: traceID, projectID: projectID, hits: hits)
    }

    func forget(_ request: BurnBarProjectMemoryForgetRequest) throws -> BurnBarProjectMemoryForgetResponse {
        let traceID = TraceContextBridge.currentContext().traceID
        let root = try projectRoot(request.projectPath)
        let projectID = Self.projectID(for: root)
        let memoryID = request.memoryID.trimmingCharacters(in: .whitespacesAndNewlines)
        return try databaseSync {
            let rows = try queryRows(
                "SELECT id FROM agent_memories WHERE id = ? AND project_id = ? LIMIT 1",
                [.text(memoryID), .text(projectID)]
            )
            let existed = rows.isEmpty == false
            try execute("BEGIN IMMEDIATE", [])
            do {
                try removeProjectMemorySection(
                    projectID: projectID,
                    projectDisplayName: root.lastPathComponent,
                    memoryID: memoryID,
                    now: Self.isoNow()
                )
                try execute("DELETE FROM agent_memories_fts WHERE memoryID = ?", [.text(memoryID)])
                try execute("DELETE FROM agent_memories WHERE id = ? AND project_id = ?", [.text(memoryID), .text(projectID)])
                let labels = request.requireCloudDelete ? ["local hard delete", "cloud hard delete pending"] : ["local hard delete"]
                let auditHash = try auditEvent(action: "memory.forget", domain: "memory", projectID: projectID, subjectID: memoryID, labels: labels)
                try execute("COMMIT", [])
                return BurnBarProjectMemoryForgetResponse(
                    traceID: traceID,
                    projectID: projectID,
                    memoryID: memoryID,
                    localDeleted: existed,
                    cloudDeletePending: request.requireCloudDelete,
                    auditHash: auditHash
                )
            } catch {
                try? execute("ROLLBACK", [])
                throw error
            }
        }
    }

    func auditTrail(_ request: BurnBarProjectMemoryAuditTrailRequest) throws -> BurnBarProjectMemoryAuditTrailResponse {
        let traceID = TraceContextBridge.currentContext().traceID
        let root = try projectRoot(request.projectPath)
        let projectID = Self.projectID(for: root)
        let limit = max(1, min(request.limit, 200))
        let events = try databaseSync {
            try queryRows(
                """
                SELECT seq, ts, actor, action, domain, project_id, subject_id, labels_json, prev_hash, hash
                FROM memory_audit
                WHERE project_id = ? OR project_id IS NULL
                ORDER BY seq DESC
                LIMIT ?
                """,
                [.text(projectID), .int(limit)]
            ).map { row in
                BurnBarProjectMemoryAuditEvent(
                    seq: row.int64(0),
                    ts: row.string(1),
                    actor: row.string(2),
                    action: row.string(3),
                    domain: row.string(4),
                    projectID: row.optionalString(5),
                    subjectID: row.optionalString(6),
                    labels: decodeStringArray(row.string(7)),
                    prevHash: row.optionalString(8),
                    hash: row.string(9)
                )
            }
        }
        return BurnBarProjectMemoryAuditTrailResponse(traceID: traceID, projectID: projectID, events: events)
    }

    func memoryAnalytics(_ request: BurnBarProjectMemoryAnalyticsRequest) throws -> BurnBarProjectMemoryAnalyticsResponse {
        let traceID = TraceContextBridge.currentContext().traceID
        let root = try projectRoot(request.projectPath)
        let projectID = Self.projectID(for: root)
        return try databaseSync {
            BurnBarProjectMemoryAnalyticsResponse(
                traceID: traceID,
                projectID: projectID,
                total: try fetchInt("SELECT COUNT(*) FROM agent_memories WHERE project_id = ?", [.text(projectID)]),
                byKind: try groupedCounts("SELECT kind, COUNT(*) FROM agent_memories WHERE project_id = ? GROUP BY kind", [.text(projectID)]),
                byScope: try groupedCounts("SELECT scope, COUNT(*) FROM agent_memories WHERE project_id = ? GROUP BY scope", [.text(projectID)]),
                lastAuditHash: try queryRows("SELECT hash FROM memory_audit ORDER BY seq DESC LIMIT 1", []).first?.optionalString(0)
            )
        }
    }

    func indexProject(_ request: BurnBarProjectCodeIndexProjectRequest) throws -> BurnBarProjectCodeIndexProjectResponse {
        let traceID = TraceContextBridge.currentContext().traceID
        let root = try projectRoot(request.projectPath)
        let projectID = Self.projectID(for: root)
        let maxFiles = max(1, min(request.maxFiles, 25_000))
        let maxFileBytes = max(1_024, min(request.maxFileBytes, 10_000_000))
        let storageBudgetBytes = Self.normalizedStorageBudgetBytes(request.storageBudgetBytes)
        let commitSHA = Self.gitCommitSHA(root: root)
        let now = Self.isoNow()
        var indexedFiles = 0
        var chunkCount = 0
        var symbolCount = 0
        var storageByteCount = 0
        var rejectedFiles: [BurnBarProjectCodeRejectedFile] = []
        var artifactsForReferences: [IndexedArtifact] = []

        return try databaseSync {
            try execute("BEGIN IMMEDIATE", [])
            do {
                let docRows = try queryRows(
                    """
                    SELECT d.id FROM search_documents d
                    JOIN code_artifacts a ON a.id = d.sourceID
                    WHERE d.sourceKind = ? AND a.project_id = ?
                    """,
                    [.text(Self.codeSourceKind), .text(projectID)]
                )
                for docID in docRows.map({ $0.string(0) }) {
                    try execute("DELETE FROM search_chunks_fts WHERE documentID = ?", [.text(docID)])
                    try execute("DELETE FROM search_chunks WHERE documentID = ?", [.text(docID)])
                    try execute("DELETE FROM search_documents WHERE id = ?", [.text(docID)])
                }
                try execute("DELETE FROM code_call_edges WHERE project_id = ?", [.text(projectID)])
                try execute("DELETE FROM code_references WHERE project_id = ?", [.text(projectID)])
                try execute("DELETE FROM code_symbols WHERE project_id = ?", [.text(projectID)])
                try execute("DELETE FROM code_artifacts WHERE project_id = ?", [.text(projectID)])

                for fileURL in Self.enumerateIndexableFiles(root: root, maxFiles: maxFiles) {
                    guard let relativePath = Self.relativePath(fileURL, root: root) else { continue }
                    let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
                    let fileSize = (attributes?[.size] as? NSNumber)?.intValue ?? 0
                    guard fileSize <= maxFileBytes else { continue }
                    guard let data = try? Data(contentsOf: fileURL), let text = String(data: data, encoding: .utf8) else { continue }
                    let artifactID = "code_" + String(Self.sha256Hex("\(projectID):\(relativePath)").prefix(32))
                    guard storageByteCount + data.count <= storageBudgetBytes else {
                        rejectedFiles.append(
                            BurnBarProjectCodeRejectedFile(filePath: relativePath, labels: ["Storage budget cap reached"])
                        )
                        _ = try auditEvent(
                            action: "code.storage_rejected",
                            domain: "code",
                            projectID: projectID,
                            subjectID: artifactID,
                            labels: ["storage budget cap reached"]
                        )
                        continue
                    }
                    let blobSHA = Self.gitBlobSHA(data)
                    let labels = Self.secretLabels(in: text)
                    if labels.isEmpty == false {
                        rejectedFiles.append(BurnBarProjectCodeRejectedFile(filePath: relativePath, labels: labels))
                        _ = try auditEvent(action: "code.secret_rejected", domain: "code", projectID: projectID, subjectID: artifactID, labels: labels)
                        continue
                    }
                    let lang = Self.language(for: fileURL)
                    let mtime = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? Date().timeIntervalSince1970
                    try execute(
                        """
                        INSERT INTO code_artifacts
                            (id, project_id, file_path, blob_sha, commit_sha, lang, byte_count, mtime, indexed_at)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        [
                            .text(artifactID), .text(projectID), .text(relativePath), .text(blobSHA),
                            commitSHA.map(SQLiteBind.text) ?? .null, lang.map(SQLiteBind.text) ?? .null,
                            .int(data.count), .double(mtime), .text(now)
                        ]
                    )
                    artifactsForReferences.append(IndexedArtifact(id: artifactID, filePath: relativePath, blobSHA: blobSHA))
                    indexedFiles += 1
                    storageByteCount += data.count

                    let documentID = "doc_" + String(Self.sha256Hex("\(projectID):\(relativePath):\(blobSHA)").prefix(32))
                    try insertSearchDocument(
                        documentID: documentID,
                        artifactID: artifactID,
                        projectID: projectID,
                        filePath: relativePath,
                        title: relativePath,
                        preview: String(text.prefix(512)),
                        contentHash: blobSHA,
                        now: now
                    )
                    let chunks = Self.chunk(text: text, maxCharacters: 4_000)
                    for (ordinal, chunk) in chunks.enumerated() {
                        let chunkID = "chunk_" + String(Self.sha256Hex("\(documentID):\(ordinal):\(chunk.contentHash)").prefix(32))
                        try insertSearchChunk(
                            chunkID: chunkID,
                            documentID: documentID,
                            artifactID: artifactID,
                            projectID: projectID,
                            filePath: relativePath,
                            ordinal: ordinal,
                            startOffset: chunk.startOffset,
                            endOffset: chunk.endOffset,
                            text: chunk.text,
                            contentHash: chunk.contentHash,
                            now: now
                        )
                        chunkCount += 1
                    }
                    for symbol in Self.extractSymbols(text: text, lang: lang, relativePath: relativePath, rootPath: root.path, projectID: projectID, artifactID: artifactID, blobSHA: blobSHA) {
                        try insertSymbol(symbol, indexedAt: now)
                        symbolCount += 1
                    }
                }
                try buildReferences(projectID: projectID, root: root, artifacts: artifactsForReferences, indexedAt: now)
                try execute(
                    """
                    INSERT INTO code_index_checkpoints
                        (project_id, project_root, last_commit_sha, indexed_at, artifact_count, chunk_count, rejected_count, storage_byte_count, storage_budget_bytes, vacuumed_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(project_id) DO UPDATE SET
                        project_root = excluded.project_root,
                        last_commit_sha = excluded.last_commit_sha,
                        indexed_at = excluded.indexed_at,
                        artifact_count = excluded.artifact_count,
                        chunk_count = excluded.chunk_count,
                        rejected_count = excluded.rejected_count,
                        storage_byte_count = excluded.storage_byte_count,
                        storage_budget_bytes = excluded.storage_budget_bytes,
                        vacuumed_at = excluded.vacuumed_at
                    """,
                    [
                        .text(projectID), .text(root.path), commitSHA.map(SQLiteBind.text) ?? .null,
                        .text(now), .int(indexedFiles), .int(chunkCount), .int(rejectedFiles.count),
                        .int(storageByteCount), .int(storageBudgetBytes), .text(now)
                    ]
                )
                let auditHash = try auditEvent(
                    action: "code.index",
                    domain: "code",
                    projectID: projectID,
                    subjectID: root.path,
                    labels: ["indexed:\(indexedFiles)", "rejected:\(rejectedFiles.count)"]
                )
                try execute("COMMIT", [])
                try? runIncrementalVacuum()
                return BurnBarProjectCodeIndexProjectResponse(
                    traceID: traceID,
                    projectID: projectID,
                    projectRoot: root.path,
                    indexedFiles: indexedFiles,
                    chunkCount: chunkCount,
                    symbolCount: symbolCount,
                    rejectedFiles: rejectedFiles,
                    commitSHA: commitSHA,
                    auditHash: auditHash
                )
            } catch {
                try? execute("ROLLBACK", [])
                throw error
            }
        }
    }

    func watchProject(_ request: BurnBarProjectCodeWatchProjectRequest) throws -> BurnBarProjectCodeWatchProjectResponse {
        let traceID = TraceContextBridge.currentContext().traceID
        let root = try projectRoot(request.projectPath)
        let projectID = Self.projectID(for: root)
        let maxFiles = max(1, min(request.maxFiles, 25_000))
        let maxFileBytes = max(1_024, min(request.maxFileBytes, 10_000_000))
        let storageBudgetBytes = Self.normalizedStorageBudgetBytes(request.storageBudgetBytes)
        let interval = max(0.25, min(request.pollIntervalSeconds, 300.0))

        let indexed = try indexProject(
            BurnBarProjectCodeIndexProjectRequest(
                projectPath: root.path,
                maxFiles: maxFiles,
                maxFileBytes: maxFileBytes,
                storageBudgetBytes: storageBudgetBytes
            )
        )
        let signature = Self.projectIndexSignature(root: root, maxFiles: maxFiles)

        let queue = DispatchQueue(label: "com.openburnbar.daemon.project-code-memory.watch.\(projectID)")
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let watcher = ProjectWatcher(
            projectID: projectID,
            projectRoot: root,
            maxFiles: maxFiles,
            maxFileBytes: maxFileBytes,
            storageBudgetBytes: storageBudgetBytes,
            timer: timer,
            lastSignature: signature
        )
        timer.setEventHandler { [weak self, weak watcher] in
            guard let self, let watcher else { return }
            let currentSignature = Self.projectIndexSignature(root: watcher.projectRoot, maxFiles: watcher.maxFiles)
            guard currentSignature != watcher.lastSignature else { return }
            do {
                _ = try self.indexProject(
                    BurnBarProjectCodeIndexProjectRequest(
                        projectPath: watcher.projectRoot.path,
                        maxFiles: watcher.maxFiles,
                        maxFileBytes: watcher.maxFileBytes,
                        storageBudgetBytes: watcher.storageBudgetBytes
                    )
                )
                watcher.lastSignature = currentSignature
                self.logger.notice(
                    "project_code_memory_watch_reindexed",
                    metadata: ["project_id": watcher.projectID, "signature": currentSignature]
                )
            } catch {
                self.logger.warning(
                    "project_code_memory_watch_reindex_failed",
                    metadata: ["project_id": watcher.projectID, "error": error.localizedDescription]
                )
            }
        }
        timer.schedule(deadline: .now() + interval, repeating: interval)

        databaseSync {
            if let previous = projectWatchers[projectID] {
                previous.timer.cancel()
            }
            projectWatchers[projectID] = watcher
        }
        timer.resume()

        return BurnBarProjectCodeWatchProjectResponse(
            traceID: traceID,
            projectID: projectID,
            projectRoot: root.path,
            watching: true,
            pollIntervalSeconds: interval,
            signature: signature,
            indexedFiles: indexed.indexedFiles
        )
    }

    func searchCode(_ request: BurnBarProjectCodeSearchRequest) throws -> BurnBarProjectCodeSearchResponse {
        let traceID = TraceContextBridge.currentContext().traceID
        let root = try projectRoot(request.projectPath)
        let projectID = Self.projectID(for: root)
        let hits = try codeSearchHits(query: request.query, root: root, projectID: projectID, limit: request.limit)
        return BurnBarProjectCodeSearchResponse(traceID: traceID, projectID: projectID, hits: hits)
    }

    func contextPack(_ request: BurnBarProjectCodeContextPackRequest) throws -> BurnBarProjectCodeContextPackResponse {
        let traceID = TraceContextBridge.currentContext().traceID
        let root = try projectRoot(request.projectPath)
        let projectID = Self.projectID(for: root)
        let hits = try codeSearchHits(query: request.query, root: root, projectID: projectID, limit: request.limit)
        let maxBytes = max(1_000, min(request.maxBytes, 250_000))
        var output = ""
        var truncated = false
        try databaseSync {
            for hit in hits {
                let rows = try queryRows("SELECT text FROM search_chunks WHERE id = ? LIMIT 1", [.text(hit.chunkID)])
                guard let text = rows.first?.string(0) else { continue }
                let block = "## \(hit.filePath)\n\(text)\n\n"
                if output.utf8.count + block.utf8.count > maxBytes {
                    truncated = true
                    break
                }
                output += block
            }
        }
        return BurnBarProjectCodeContextPackResponse(
            traceID: traceID,
            projectID: projectID,
            context: output,
            hits: hits,
            truncated: truncated
        )
    }

    func getSymbol(_ request: BurnBarProjectCodeSymbolRequest) throws -> BurnBarProjectCodeSymbolResponse {
        let traceID = TraceContextBridge.currentContext().traceID
        let root = try projectRoot(request.projectPath)
        let projectID = Self.projectID(for: root)
        let symbols = try databaseSync {
            try querySymbols(
                """
                SELECT s.id, s.artifact_id, a.file_path, s.name, s.kind, s.range_json, s.confidence_tier,
                       s.blob_sha, s.tier_evidence_json
                FROM code_symbols s
                JOIN code_artifacts a ON a.id = s.artifact_id
                WHERE s.project_id = ? AND (s.name = ? OR s.name LIKE ?)
                ORDER BY CASE WHEN s.name = ? THEN 0 ELSE 1 END, a.file_path ASC
                LIMIT ?
                """,
                [.text(projectID), .text(request.name), .text("%\(request.name)%"), .text(request.name), .int(max(1, min(request.limit, 100)))]
            ).filter { Self.isCurrentBlob(root: root, filePath: $0.filePath, blobSHA: $0.blobSHA) }
             .map(Self.publicSymbol)
        }
        return BurnBarProjectCodeSymbolResponse(traceID: traceID, projectID: projectID, symbols: symbols)
    }

    func findReferences(_ request: BurnBarProjectCodeSymbolRequest) throws -> BurnBarProjectCodeReferencesResponse {
        let traceID = TraceContextBridge.currentContext().traceID
        let root = try projectRoot(request.projectPath)
        let projectID = Self.projectID(for: root)
        let exactReferences = try self.exactLSPReferences(
            symbolName: request.name,
            root: root,
            projectID: projectID,
            limit: request.limit
        )
        if exactReferences.isEmpty == false {
            return BurnBarProjectCodeReferencesResponse(traceID: traceID, projectID: projectID, references: exactReferences)
        }
        let references: [BurnBarProjectCodeReference] = try databaseSync {
            try queryRows(
                """
                SELECT r.id, a.file_path, target.id, target.artifact_id, target_art.file_path,
                       target.name, target.kind, target.range_json, target.confidence_tier,
                       r.range_json, r.confidence_tier, r.blob_sha, target.blob_sha,
                       target.tier_evidence_json
                FROM code_references r
                JOIN code_symbols target ON target.id = r.to_symbol_id
                JOIN code_artifacts target_art ON target_art.id = target.artifact_id
                JOIN code_artifacts a ON a.id = r.from_artifact_id
                WHERE r.project_id = ? AND target.name = ?
                ORDER BY a.file_path ASC
                LIMIT ?
                """,
                [.text(projectID), .text(request.name), .int(max(1, min(request.limit, 200)))]
            ).compactMap { row in
                guard Self.isCurrentBlob(root: root, filePath: row.string(1), blobSHA: row.string(11)),
                      Self.isCurrentBlob(root: root, filePath: row.string(4), blobSHA: row.string(12)) else {
                    return nil
                }
                return BurnBarProjectCodeReference(
                    referenceID: row.string(0),
                    fromFilePath: row.string(1),
                    targetSymbol: BurnBarProjectCodeSymbol(
                        symbolID: row.string(2),
                        name: row.string(5),
                        kind: row.string(6),
                        filePath: row.string(4),
                        range: Self.decodeRange(row.string(7)),
                        confidenceTier: row.string(8),
                        tierEvidence: Self.decodeTierEvidence(row.optionalString(13))
                    ),
                    range: Self.decodeRange(row.string(9)),
                    confidenceTier: row.string(10)
                )
            }
        }
        return BurnBarProjectCodeReferencesResponse(traceID: traceID, projectID: projectID, references: references)
    }

    func callGraph(_ request: BurnBarProjectCodeSymbolRequest) throws -> BurnBarProjectCodeCallGraphResponse {
        let traceID = TraceContextBridge.currentContext().traceID
        let root = try projectRoot(request.projectPath)
        let projectID = Self.projectID(for: root)
        let edges: [BurnBarProjectCodeCallEdge] = try databaseSync {
            try queryRows(
                """
                SELECT e.id,
                       caller.id, caller.name, caller.kind, caller_art.file_path, caller.range_json, caller.confidence_tier, caller.blob_sha, caller.tier_evidence_json,
                       callee.id, callee.name, callee.kind, callee_art.file_path, callee.range_json, callee.confidence_tier, callee.blob_sha, callee.tier_evidence_json,
                       e.confidence_tier
                FROM code_call_edges e
                JOIN code_symbols caller ON caller.id = e.caller_symbol_id
                JOIN code_symbols callee ON callee.id = e.callee_symbol_id
                JOIN code_artifacts caller_art ON caller_art.id = caller.artifact_id
                JOIN code_artifacts callee_art ON callee_art.id = callee.artifact_id
                WHERE e.project_id = ? AND (caller.name = ? OR callee.name = ?)
                ORDER BY caller_art.file_path ASC
                LIMIT ?
                """,
                [.text(projectID), .text(request.name), .text(request.name), .int(max(1, min(request.limit, 200)))]
            ).compactMap { row in
                guard Self.isCurrentBlob(root: root, filePath: row.string(4), blobSHA: row.string(7)),
                      Self.isCurrentBlob(root: root, filePath: row.string(12), blobSHA: row.string(15)) else {
                    return nil
                }
                return BurnBarProjectCodeCallEdge(
                    edgeID: row.string(0),
                    caller: BurnBarProjectCodeSymbol(
                        symbolID: row.string(1),
                        name: row.string(2),
                        kind: row.string(3),
                        filePath: row.string(4),
                        range: Self.decodeRange(row.string(5)),
                        confidenceTier: row.string(6),
                        tierEvidence: Self.decodeTierEvidence(row.optionalString(8))
                    ),
                    callee: BurnBarProjectCodeSymbol(
                        symbolID: row.string(9),
                        name: row.string(10),
                        kind: row.string(11),
                        filePath: row.string(12),
                        range: Self.decodeRange(row.string(13)),
                        confidenceTier: row.string(14),
                        tierEvidence: Self.decodeTierEvidence(row.optionalString(16))
                    ),
                    confidenceTier: row.string(17)
                )
            }
        }
        return BurnBarProjectCodeCallGraphResponse(traceID: traceID, projectID: projectID, edges: edges)
    }

    func diagnostics(_ request: BurnBarProjectCodeDiagnosticsRequest) throws -> BurnBarProjectCodeDiagnosticsResponse {
        let traceID = TraceContextBridge.currentContext().traceID
        let root = try projectRoot(request.projectPath)
        let projectID = Self.projectID(for: root)
        let diagnostics = try databaseSync {
            var sql = "SELECT file_path, tool, payload_json, cached_at FROM code_diagnostics_cache WHERE project_id = ?"
            var binds: [SQLiteBind] = [.text(projectID)]
            if let filePath = request.filePath?.trimmingCharacters(in: .whitespacesAndNewlines), filePath.isEmpty == false {
                sql += " AND file_path = ?"
                binds.append(.text(filePath))
            }
            sql += " ORDER BY cached_at DESC LIMIT 200"
            return try queryRows(sql, binds).map {
                BurnBarProjectCodeDiagnostic(
                    filePath: $0.string(0),
                    tool: $0.string(1),
                    payloadJSON: $0.string(2),
                    cachedAt: $0.string(3)
                )
            }
        }
        return BurnBarProjectCodeDiagnosticsResponse(traceID: traceID, projectID: projectID, diagnostics: diagnostics)
    }

    func indexStatus(_ request: BurnBarProjectCodeIndexStatusRequest) throws -> BurnBarProjectCodeIndexStatusResponse {
        let traceID = TraceContextBridge.currentContext().traceID
        let root = try projectRoot(request.projectPath)
        let projectID = Self.projectID(for: root)
        return try databaseSync {
            let checkpoint = try queryRows(
                """
                SELECT project_root, indexed_at, artifact_count, chunk_count, rejected_count,
                       last_commit_sha, storage_byte_count, storage_budget_bytes, vacuumed_at
                FROM code_index_checkpoints
                WHERE project_id = ?
                LIMIT 1
                """,
                [.text(projectID)]
            ).first
            let storageByteCount: Int
            if let checkpoint {
                storageByteCount = Int(checkpoint.int64(6))
            } else {
                storageByteCount = try projectStorageByteCount(projectID: projectID)
            }
            let storedBudgetBytes = checkpoint.map { Int($0.int64(7)) } ?? 0
            let storageBudgetBytes = storedBudgetBytes > 0 ? storedBudgetBytes : Self.defaultProjectStorageBudgetBytes
            return BurnBarProjectCodeIndexStatusResponse(
                traceID: traceID,
                projectID: projectID,
                projectRoot: checkpoint?.optionalString(0),
                indexedAt: checkpoint?.optionalString(1),
                artifactCount: try fetchInt("SELECT COUNT(*) FROM code_artifacts WHERE project_id = ?", [.text(projectID)]),
                chunkCount: checkpoint.map { Int($0.int64(3)) } ?? 0,
                symbolCount: try fetchInt("SELECT COUNT(*) FROM code_symbols WHERE project_id = ?", [.text(projectID)]),
                referenceCount: try fetchInt("SELECT COUNT(*) FROM code_references WHERE project_id = ?", [.text(projectID)]),
                callEdgeCount: try fetchInt("SELECT COUNT(*) FROM code_call_edges WHERE project_id = ?", [.text(projectID)]),
                rejectedCount: checkpoint.map { Int($0.int64(4)) } ?? 0,
                lastCommitSHA: checkpoint?.optionalString(5),
                pendingForgetCount: try fetchInt("SELECT COUNT(*) FROM memory_audit WHERE project_id = ? AND labels_json LIKE '%cloud hard delete pending%'", [.text(projectID)]),
                storageByteCount: storageByteCount,
                storageBudgetBytes: storageBudgetBytes,
                storageWithinBudget: storageByteCount <= storageBudgetBytes,
                lastVacuumedAt: checkpoint?.optionalString(8)
            )
        }
    }

    func explore(_ request: BurnBarProjectCodeExploreRequest) throws -> BurnBarProjectCodeExploreResponse {
        let traceID = TraceContextBridge.currentContext().traceID
        let root = try projectRoot(request.projectPath)
        let projectID = Self.projectID(for: root)
        let hasCheckpoint = try databaseSync {
            try fetchInt("SELECT COUNT(*) FROM code_index_checkpoints WHERE project_id = ?", [.text(projectID)]) > 0
        }
        if hasCheckpoint == false {
            _ = try indexProject(BurnBarProjectCodeIndexProjectRequest(projectPath: root.path))
        }
        let files = try databaseSync {
            try queryRows(
                """
                SELECT a.file_path, a.lang, COUNT(s.id) AS symbol_count
                FROM code_artifacts a
                LEFT JOIN code_symbols s ON s.artifact_id = a.id
                WHERE a.project_id = ?
                GROUP BY a.id
                ORDER BY symbol_count DESC, a.file_path ASC
                LIMIT ?
                """,
                [.text(projectID), .int(max(1, min(request.limit, 500)))]
            ).map {
                BurnBarProjectCodeExploreFile(filePath: $0.string(0), lang: $0.optionalString(1), symbolCount: Int($0.int64(2)))
            }
        }
        if let query = request.query?.trimmingCharacters(in: .whitespacesAndNewlines), query.isEmpty == false {
            let pack = try contextPack(
                BurnBarProjectCodeContextPackRequest(
                    query: query,
                    projectPath: root.path,
                    limit: request.limit,
                    maxBytes: request.maxBytes
                )
            )
            return BurnBarProjectCodeExploreResponse(
                traceID: traceID,
                projectID: projectID,
                files: files,
                context: pack.context,
                hits: pack.hits,
                truncated: pack.truncated
            )
        }
        return BurnBarProjectCodeExploreResponse(traceID: traceID, projectID: projectID, files: files)
    }

    private enum SQLiteBind {
        case text(String)
        case int(Int)
        case int64(Int64)
        case double(Double)
        case null
    }

    struct CodeChunk {
        let text: String
        let startOffset: Int
        let endOffset: Int
        let contentHash: String
    }

    struct ExtractedSymbol {
        let id: String
        let projectID: String
        let artifactID: String
        let blobSHA: String
        let name: String
        let kind: String
        let range: BurnBarProjectCodeRange
        let confidenceTier: String
        let tierEvidenceJSON: String?
    }

    struct StaticParserRequest: Encodable {
        let requestId: String
        let filePath: String
        let language: String?
        let blobSha: String
        let text: String
        let rootPath: String?
        let operation: String?
        let position: StaticParserPosition?

        init(
            requestId: String,
            filePath: String,
            language: String?,
            blobSha: String,
            text: String,
            rootPath: String? = nil,
            operation: String? = nil,
            position: StaticParserPosition? = nil
        ) {
            self.requestId = requestId
            self.filePath = filePath
            self.language = language
            self.blobSha = blobSha
            self.text = text
            self.rootPath = rootPath
            self.operation = operation
            self.position = position
        }
    }

    struct StaticParserPosition: Encodable {
        let line: Int
        let character: Int
    }

    struct StaticParserResponse: Decodable {
        let filePath: String
        let language: String
        let blobSha: String
        let ok: Bool
        let hasParseError: Bool
        let symbols: [StaticParserSymbol]
        let references: [StaticParserReference]?
        let errors: [String]
    }

    struct StaticParserSymbol: Decodable {
        let name: String
        let kind: String
        let startLine: Int
        let endLine: Int
        let confidenceTier: String
        let evidence: StaticParserTierEvidence
    }

    struct StaticParserReference: Decodable {
        let filePath: String
        let startLine: Int
        let endLine: Int
        let startCharacter: Int
        let endCharacter: Int
        let confidenceTier: String
    }

    struct StaticParserTierEvidence: Decodable {
        let parser: String?
        let language: String?
        let blobSha: String?
        let shaMatch: Bool?
        let lspResponded: Bool?
    }

    private func databaseSync<T>(_ work: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: projectCodeMemoryQueueKey) == dbQueueID {
            return try work()
        }
        return try dbQueue.sync(execute: work)
    }

    private func bootstrapSchema() throws {
        try execute("PRAGMA journal_mode = WAL", [])
        try execute("PRAGMA foreign_keys = ON", [])
        try execute("PRAGMA auto_vacuum = INCREMENTAL", [])
        try execute(
            """
            CREATE TABLE IF NOT EXISTS search_documents (
                id TEXT PRIMARY KEY,
                sourceKind TEXT NOT NULL,
                sourceID TEXT NOT NULL,
                sourceVersionID TEXT NOT NULL DEFAULT '',
                provider TEXT,
                projectName TEXT,
                title TEXT NOT NULL,
                subtitle TEXT,
                bodyPreview TEXT,
                sourceUpdatedAt TEXT,
                indexedAt TEXT NOT NULL,
                contentHash TEXT,
                createdAt TEXT NOT NULL,
                updatedAt TEXT NOT NULL
            )
            """,
            []
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS search_chunks (
                id TEXT PRIMARY KEY,
                documentID TEXT NOT NULL,
                sourceKind TEXT NOT NULL,
                sourceID TEXT NOT NULL,
                sourceVersionID TEXT NOT NULL DEFAULT '',
                ordinal INTEGER NOT NULL,
                startOffset INTEGER NOT NULL,
                endOffset INTEGER NOT NULL,
                messageStartOffset INTEGER,
                messageEndOffset INTEGER,
                sectionPath TEXT,
                text TEXT NOT NULL,
                contentHash TEXT,
                createdAt TEXT NOT NULL,
                updatedAt TEXT NOT NULL
            )
            """,
            []
        )
        try execute(
            """
            CREATE VIRTUAL TABLE IF NOT EXISTS search_chunks_fts USING fts5(
                chunkID UNINDEXED,
                documentID UNINDEXED,
                title,
                chunkText,
                projectName,
                provider,
                tokenize='porter unicode61'
            )
            """,
            []
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS agent_memories (
                id TEXT PRIMARY KEY,
                project_id TEXT NOT NULL,
                kind TEXT NOT NULL,
                scope TEXT NOT NULL,
                confidence REAL NOT NULL,
                body_ref TEXT NOT NULL,
                body_redacted TEXT NOT NULL,
                tags_json TEXT NOT NULL,
                source_path TEXT,
                valid_from TEXT NOT NULL,
                valid_to TEXT,
                superseded_by TEXT,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            )
            """,
            []
        )
        try execute("CREATE INDEX IF NOT EXISTS agent_memories_project_idx ON agent_memories(project_id, scope, updated_at)", [])
        try execute(
            """
            CREATE VIRTUAL TABLE IF NOT EXISTS agent_memories_fts USING fts5(
                memoryID UNINDEXED,
                projectID UNINDEXED,
                bodyText,
                tags,
                tokenize='porter unicode61'
            )
            """,
            []
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS memory_audit (
                seq INTEGER PRIMARY KEY AUTOINCREMENT,
                ts TEXT NOT NULL,
                actor TEXT NOT NULL,
                action TEXT NOT NULL,
                domain TEXT NOT NULL,
                project_id TEXT,
                subject_id TEXT,
                labels_json TEXT NOT NULL,
                prev_hash TEXT,
                hash TEXT NOT NULL
            )
            """,
            []
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS code_artifacts (
                id TEXT PRIMARY KEY,
                project_id TEXT NOT NULL,
                file_path TEXT NOT NULL,
                blob_sha TEXT NOT NULL,
                commit_sha TEXT,
                lang TEXT,
                byte_count INTEGER NOT NULL,
                mtime REAL NOT NULL,
                indexed_at TEXT NOT NULL
            )
            """,
            []
        )
        try execute("CREATE UNIQUE INDEX IF NOT EXISTS code_artifacts_project_path_idx ON code_artifacts(project_id, file_path)", [])
        try execute(
            """
            CREATE TABLE IF NOT EXISTS code_symbols (
                id TEXT PRIMARY KEY,
                project_id TEXT NOT NULL,
                artifact_id TEXT NOT NULL,
                blob_sha TEXT NOT NULL,
                name TEXT NOT NULL,
                kind TEXT NOT NULL,
                range_json TEXT NOT NULL,
                confidence_tier TEXT NOT NULL,
                tier_evidence_json TEXT,
                indexed_at TEXT NOT NULL
            )
            """,
            []
        )
        try ensureColumn(table: "code_symbols", column: "tier_evidence_json", definition: "TEXT")
        try execute("CREATE INDEX IF NOT EXISTS code_symbols_project_name_idx ON code_symbols(project_id, name)", [])
        try execute(
            """
            CREATE TABLE IF NOT EXISTS code_references (
                id TEXT PRIMARY KEY,
                project_id TEXT NOT NULL,
                from_artifact_id TEXT NOT NULL,
                to_symbol_id TEXT NOT NULL,
                range_json TEXT NOT NULL,
                blob_sha TEXT NOT NULL,
                confidence_tier TEXT NOT NULL,
                indexed_at TEXT NOT NULL
            )
            """,
            []
        )
        try execute("CREATE INDEX IF NOT EXISTS code_references_symbol_idx ON code_references(project_id, to_symbol_id)", [])
        try execute(
            """
            CREATE TABLE IF NOT EXISTS code_call_edges (
                id TEXT PRIMARY KEY,
                project_id TEXT NOT NULL,
                caller_symbol_id TEXT NOT NULL,
                callee_symbol_id TEXT NOT NULL,
                confidence_tier TEXT NOT NULL,
                indexed_at TEXT NOT NULL
            )
            """,
            []
        )
        try execute("CREATE INDEX IF NOT EXISTS code_call_edges_project_idx ON code_call_edges(project_id, caller_symbol_id)", [])
        try execute(
            """
            CREATE TABLE IF NOT EXISTS code_diagnostics_cache (
                id TEXT PRIMARY KEY,
                project_id TEXT NOT NULL,
                file_path TEXT NOT NULL,
                tool TEXT NOT NULL,
                payload_json TEXT NOT NULL,
                blob_sha TEXT,
                cached_at TEXT NOT NULL
            )
            """,
            []
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS code_index_checkpoints (
                project_id TEXT PRIMARY KEY,
                project_root TEXT NOT NULL,
                last_commit_sha TEXT,
                indexed_at TEXT NOT NULL,
                artifact_count INTEGER NOT NULL,
                chunk_count INTEGER NOT NULL,
                rejected_count INTEGER NOT NULL,
                storage_byte_count INTEGER NOT NULL DEFAULT 0,
                storage_budget_bytes INTEGER NOT NULL DEFAULT 0,
                vacuumed_at TEXT
            )
            """,
            []
        )
        try ensureColumn(table: "code_index_checkpoints", column: "storage_byte_count", definition: "INTEGER NOT NULL DEFAULT 0")
        try ensureColumn(table: "code_index_checkpoints", column: "storage_budget_bytes", definition: "INTEGER NOT NULL DEFAULT 0")
        try ensureColumn(table: "code_index_checkpoints", column: "vacuumed_at", definition: "TEXT")
        try execute(
            """
            CREATE TABLE IF NOT EXISTS project_memory_snapshots (
                projectSlug TEXT PRIMARY KEY,
                projectDisplayName TEXT NOT NULL,
                snapshotJSON TEXT NOT NULL,
                contentHash TEXT NOT NULL,
                sourceSessionCount INTEGER NOT NULL DEFAULT 0,
                sourceConversationCount INTEGER NOT NULL DEFAULT 0,
                generatedAt TEXT NOT NULL,
                schemaVersion INTEGER NOT NULL,
                updatedAt TEXT NOT NULL
            )
            """,
            []
        )
        try execute(
            "CREATE INDEX IF NOT EXISTS project_memory_snapshots_updated_idx ON project_memory_snapshots(updatedAt)",
            []
        )
        try migrateLegacyPlaintextAgentMemories()
    }

    private func migrateLegacyPlaintextAgentMemories() throws {
        let rows = try queryRows(
            """
            SELECT id, project_id, kind, scope, body_redacted, tags_json, source_path, updated_at
            FROM agent_memories
            WHERE body_redacted NOT LIKE 'Project Memory snapshot ref:%'
            """,
            []
        )
        for row in rows {
            let memoryID = row.string(0)
            let projectID = row.string(1)
            let body = row.string(4)
            let tags = decodeStringArray(row.string(5))
            let now = row.optionalString(7) ?? Self.isoNow()
            try upsertProjectMemorySection(
                projectID: projectID,
                projectDisplayName: projectID,
                memoryID: memoryID,
                body: body,
                kind: row.string(2),
                scope: row.string(3),
                tags: tags,
                sourcePath: row.optionalString(6),
                now: now
            )
            try execute(
                "UPDATE agent_memories SET body_redacted = ?, updated_at = ? WHERE id = ?",
                [.text(Self.memoryBodyReference(memoryID: memoryID, projectID: projectID)), .text(now), .text(memoryID)]
            )
        }
        try execute("DELETE FROM agent_memories_fts", [])
    }

    private func upsertProjectMemorySection(
        projectID: String,
        projectDisplayName: String,
        memoryID: String,
        body: String,
        kind: String,
        scope: String,
        tags: [String],
        sourcePath: String?,
        now: String
    ) throws {
        var snapshot = try loadProjectMemorySnapshot(projectID: projectID, projectDisplayName: projectDisplayName, now: now)
        var pages = snapshot["pages"] as? [[String: Any]] ?? []
        let section: [String: Any] = [
            "id": memoryID,
            "title": Self.memorySectionTitle(kind: kind, scope: scope, tags: tags),
            "body": body,
            "citations": Self.memoryCitations(memoryID: memoryID, sourcePath: sourcePath, now: now)
        ]

        if let index = pages.firstIndex(where: { ($0["id"] as? String) == Self.agentMemoryPageID }) {
            var page = pages[index]
            var sections = page["sections"] as? [[String: Any]] ?? []
            sections.removeAll { ($0["id"] as? String) == memoryID }
            sections.append(section)
            sections.sort { (($0["id"] as? String) ?? "") < (($1["id"] as? String) ?? "") }
            page["sections"] = sections
            page["summary"] = "\(sections.count) agent-maintained notes with provenance metadata."
            pages[index] = page
        } else {
            pages.append(Self.agentMemoryPage(sections: [section]))
        }

        snapshot["pages"] = pages
        if let sourcePath, sourcePath.isEmpty == false {
            var keyFiles = snapshot["keyFiles"] as? [String] ?? []
            if keyFiles.contains(sourcePath) == false {
                keyFiles.append(sourcePath)
            }
            snapshot["keyFiles"] = Array(keyFiles.prefix(24))
        }
        try writeProjectMemorySnapshot(snapshot, projectID: projectID, projectDisplayName: projectDisplayName, now: now)
    }

    private func removeProjectMemorySection(projectID: String, projectDisplayName: String, memoryID: String, now: String) throws {
        var snapshot = try loadProjectMemorySnapshot(projectID: projectID, projectDisplayName: projectDisplayName, now: now)
        var pages = snapshot["pages"] as? [[String: Any]] ?? []
        guard let index = pages.firstIndex(where: { ($0["id"] as? String) == Self.agentMemoryPageID }) else {
            return
        }
        var page = pages[index]
        var sections = page["sections"] as? [[String: Any]] ?? []
        sections.removeAll { ($0["id"] as? String) == memoryID }
        page["sections"] = sections
        page["summary"] = "\(sections.count) agent-maintained notes with provenance metadata."
        pages[index] = page
        snapshot["pages"] = pages
        try writeProjectMemorySnapshot(snapshot, projectID: projectID, projectDisplayName: projectDisplayName, now: now)
    }

    private func projectMemorySectionBody(projectID: String, memoryID: String) throws -> String? {
        guard let snapshot = try loadExistingProjectMemorySnapshot(projectID: projectID),
              let pages = snapshot["pages"] as? [[String: Any]] else {
            return nil
        }
        for page in pages {
            guard let sections = page["sections"] as? [[String: Any]] else { continue }
            if let section = sections.first(where: { ($0["id"] as? String) == memoryID }) {
                return section["body"] as? String
            }
        }
        return nil
    }

    private func loadProjectMemorySnapshot(projectID: String, projectDisplayName: String, now: String) throws -> [String: Any] {
        if let existing = try loadExistingProjectMemorySnapshot(projectID: projectID) {
            return existing
        }
        return Self.baseProjectMemorySnapshot(projectID: projectID, projectDisplayName: projectDisplayName, now: now)
    }

    private func loadExistingProjectMemorySnapshot(projectID: String) throws -> [String: Any]? {
        let slug = Self.projectMemorySlug(for: projectID)
        guard let json = try queryRows(
            "SELECT snapshotJSON FROM project_memory_snapshots WHERE projectSlug = ? LIMIT 1",
            [.text(slug)]
        ).first?.optionalString(0), let data = json.data(using: .utf8) else {
            return nil
        }
        return (try JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func writeProjectMemorySnapshot(
        _ snapshot: [String: Any],
        projectID: String,
        projectDisplayName: String,
        now: String
    ) throws {
        var updated = snapshot
        updated["projectSlug"] = Self.projectMemorySlug(for: projectID)
        updated["projectDisplayName"] = (snapshot["projectDisplayName"] as? String)?.nonEmpty ?? projectDisplayName
        updated["schemaVersion"] = 1
        updated["updatedAt"] = now
        if updated["generatedAt"] == nil {
            updated["generatedAt"] = now
        }
        var hashPayload = updated
        hashPayload["contentHash"] = ""
        let contentHash = Self.sha256Hex(try Self.jsonData(hashPayload))
        updated["contentHash"] = contentHash
        let snapshotJSON = String(data: try Self.jsonData(updated), encoding: .utf8) ?? "{}"
        let sourceSessionCount = (updated["sourceSessionIDs"] as? [Any])?.count ?? 0
        let sourceConversationCount = (updated["sourceConversationIDs"] as? [Any])?.count ?? 0
        try execute(
            """
            INSERT INTO project_memory_snapshots
                (projectSlug, projectDisplayName, snapshotJSON, contentHash, sourceSessionCount, sourceConversationCount, generatedAt, schemaVersion, updatedAt)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(projectSlug) DO UPDATE SET
                projectDisplayName = excluded.projectDisplayName,
                snapshotJSON = excluded.snapshotJSON,
                contentHash = excluded.contentHash,
                sourceSessionCount = excluded.sourceSessionCount,
                sourceConversationCount = excluded.sourceConversationCount,
                generatedAt = excluded.generatedAt,
                schemaVersion = excluded.schemaVersion,
                updatedAt = excluded.updatedAt
            """,
            [
                .text(Self.projectMemorySlug(for: projectID)),
                .text((updated["projectDisplayName"] as? String) ?? projectDisplayName),
                .text(snapshotJSON),
                .text(contentHash),
                .int(sourceSessionCount),
                .int(sourceConversationCount),
                .text((updated["generatedAt"] as? String) ?? now),
                .int(1),
                .text(now)
            ]
        )
    }

    private static func baseProjectMemorySnapshot(projectID: String, projectDisplayName: String, now: String) -> [String: Any] {
        [
            "projectSlug": projectMemorySlug(for: projectID),
            "projectDisplayName": projectDisplayName,
            "generatedAt": now,
            "sourceSessionIDs": [],
            "sourceConversationIDs": [],
            "sourceWindowStart": NSNull(),
            "sourceWindowEnd": NSNull(),
            "keyFiles": [],
            "keyCommands": [],
            "usageSummary": "Agent-maintained project memory notes.",
            "freshness": "fresh",
            "contentHash": "",
            "schemaVersion": 1,
            "pages": [agentMemoryPage(sections: [])],
            "visuals": []
        ]
    }

    private static func agentMemoryPage(sections: [[String: Any]]) -> [String: Any] {
        [
            "id": agentMemoryPageID,
            "title": "Agent Notes",
            "summary": "\(sections.count) agent-maintained notes with provenance metadata.",
            "sections": sections,
            "visualIDs": []
        ]
    }

    private static func memoryCitations(memoryID: String, sourcePath: String?, now: String) -> [[String: Any]] {
        guard let sourcePath, sourcePath.isEmpty == false else { return [] }
        return [[
            "id": "cite_" + String(sha256Hex("\(memoryID):\(sourcePath)").prefix(16)),
            "sourceID": sourcePath,
            "sourceKind": codeSourceKind,
            "title": sourcePath,
            "snippet": "Agent-supplied source path for this memory.",
            "createdAt": now
        ]]
    }

    private static func memorySectionTitle(kind: String, scope: String, tags: [String]) -> String {
        let base = "\(kind.capitalized) / \(scope)"
        guard let firstTag = tags.first(where: { $0.isEmpty == false }) else { return base }
        return "\(base) / \(firstTag)"
    }

    private static func projectMemorySlug(for projectID: String) -> String {
        "agent-\(projectID)"
    }

    private static func memoryBodyReference(memoryID: String, projectID: String) -> String {
        "Project Memory snapshot ref:\(projectMemorySlug(for: projectID))#\(memoryID)"
    }

    private static func jsonData(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func projectRoot(_ projectPath: String?) throws -> URL {
        let rawPath = projectPath?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? FileManager.default.currentDirectoryPath
        let url = URL(fileURLWithPath: rawPath, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw BurnBarProjectCodeMemoryStoreError.projectPathUnavailable(url.path)
        }
        return url
    }

    private func auditEvent(
        action: String,
        domain: String,
        projectID: String?,
        subjectID: String?,
        labels: [String]
    ) throws -> String {
        let previous = try queryRows("SELECT seq, hash FROM memory_audit ORDER BY seq DESC LIMIT 1", []).first
        let prevHash = previous?.optionalString(1)
        let ts = Self.isoNow()
        let labelsJSON = try encodeJSONString(labels)
        let payload = [
            previous.map { String($0.int64(0) + 1) } ?? "1",
            ts,
            "daemon",
            action,
            domain,
            projectID ?? "",
            subjectID ?? "",
            labelsJSON,
            prevHash ?? ""
        ].joined(separator: "|")
        let hash = Self.sha256Hex(payload)
        try execute(
            """
            INSERT INTO memory_audit
                (ts, actor, action, domain, project_id, subject_id, labels_json, prev_hash, hash)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(ts), .text("daemon"), .text(action), .text(domain),
                projectID.map(SQLiteBind.text) ?? .null, subjectID.map(SQLiteBind.text) ?? .null,
                .text(labelsJSON), prevHash.map(SQLiteBind.text) ?? .null, .text(hash)
            ]
        )
        return hash
    }

    private func insertSearchDocument(
        documentID: String,
        artifactID: String,
        projectID: String,
        filePath: String,
        title: String,
        preview: String,
        contentHash: String,
        now: String
    ) throws {
        try execute(
            """
            INSERT INTO search_documents
                (id, sourceKind, sourceID, sourceVersionID, provider, projectName, title, bodyPreview, indexedAt, contentHash, createdAt, updatedAt)
            VALUES (?, ?, ?, '', ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(documentID), .text(Self.codeSourceKind), .text(artifactID), .text(Self.codeProvider),
                .text(projectID), .text(title), .text(preview), .text(now), .text(contentHash), .text(now), .text(now)
            ]
        )
        _ = filePath
    }

    private func insertSearchChunk(
        chunkID: String,
        documentID: String,
        artifactID: String,
        projectID: String,
        filePath: String,
        ordinal: Int,
        startOffset: Int,
        endOffset: Int,
        text: String,
        contentHash: String,
        now: String
    ) throws {
        try execute(
            """
            INSERT INTO search_chunks
                (id, documentID, sourceKind, sourceID, sourceVersionID, ordinal, startOffset, endOffset, sectionPath, text, contentHash, createdAt, updatedAt)
            VALUES (?, ?, ?, ?, '', ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(chunkID), .text(documentID), .text(Self.codeSourceKind), .text(artifactID),
                .int(ordinal), .int(startOffset), .int(endOffset), .text(filePath),
                .text(text), .text(contentHash), .text(now), .text(now)
            ]
        )
        try execute(
            "INSERT INTO search_chunks_fts (chunkID, documentID, title, chunkText, projectName, provider) VALUES (?, ?, ?, ?, ?, ?)",
            [.text(chunkID), .text(documentID), .text(filePath), .text(text), .text(projectID), .text(Self.codeProvider)]
        )
    }

    private func insertSymbol(_ symbol: ExtractedSymbol, indexedAt: String) throws {
        let rangeJSON = try encodeJSONString(symbol.range)
        try execute(
            """
            INSERT OR IGNORE INTO code_symbols
                (id, project_id, artifact_id, blob_sha, name, kind, range_json, confidence_tier, tier_evidence_json, indexed_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(symbol.id), .text(symbol.projectID), .text(symbol.artifactID), .text(symbol.blobSHA),
                .text(symbol.name), .text(symbol.kind), .text(rangeJSON), .text(symbol.confidenceTier),
                symbol.tierEvidenceJSON.map(SQLiteBind.text) ?? .null, .text(indexedAt)
            ]
        )
    }

    private func buildReferences(projectID: String, root: URL, artifacts: [IndexedArtifact], indexedAt: String) throws {
        let symbols = try querySymbols(
            """
            SELECT s.id, s.artifact_id, a.file_path, s.name, s.kind, s.range_json,
                   s.confidence_tier, s.blob_sha, s.tier_evidence_json
            FROM code_symbols s
            JOIN code_artifacts a ON a.id = s.artifact_id
            WHERE s.project_id = ?
            """,
            [.text(projectID)]
        )
        guard symbols.isEmpty == false else { return }
        let symbolsByArtifact = Dictionary(grouping: symbols, by: \.artifactID)
        let symbolsByName = Dictionary(grouping: symbols, by: \.name)
        for artifact in artifacts {
            let fileURL = root.appendingPathComponent(artifact.filePath, isDirectory: false)
            guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            let fileSymbols = (symbolsByArtifact[artifact.id] ?? []).sorted { $0.range.startLine < $1.range.startLine }
            let lines = text.components(separatedBy: .newlines)
            for (lineIndex, line) in lines.enumerated() {
                let caller = fileSymbols.last(where: { $0.range.startLine <= lineIndex + 1 })
                for token in Self.identifierTokens(in: line) {
                    guard let targets = symbolsByName[token] else { continue }
                    for target in targets {
                        if target.artifactID == artifact.id, target.range.startLine == lineIndex + 1 { continue }
                        let refID = "ref_" + String(Self.sha256Hex("\(projectID):\(artifact.id):\(target.id):\(lineIndex + 1)").prefix(32))
                        let range = BurnBarProjectCodeRange(startLine: lineIndex + 1, endLine: lineIndex + 1)
                        try execute(
                            """
                            INSERT OR IGNORE INTO code_references
                                (id, project_id, from_artifact_id, to_symbol_id, range_json, blob_sha, confidence_tier, indexed_at)
                            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                            """,
                            [
                                .text(refID), .text(projectID), .text(artifact.id), .text(target.id),
                                .text(try encodeJSONString(range)), .text(artifact.blobSHA), .text("lexical_fallback"), .text(indexedAt)
                            ]
                        )
                        if let caller, line.contains("\(target.name)("), caller.id != target.id {
                            let edgeID = "edge_" + String(Self.sha256Hex("\(projectID):\(caller.id):\(target.id)").prefix(32))
                            try execute(
                                """
                                INSERT OR IGNORE INTO code_call_edges
                                    (id, project_id, caller_symbol_id, callee_symbol_id, confidence_tier, indexed_at)
                                VALUES (?, ?, ?, ?, ?, ?)
                                """,
                                [.text(edgeID), .text(projectID), .text(caller.id), .text(target.id), .text("lexical_fallback"), .text(indexedAt)]
                            )
                        }
                    }
                }
            }
        }
    }

    private func exactLSPReferences(
        symbolName: String,
        root: URL,
        projectID: String,
        limit: Int
    ) throws -> [BurnBarProjectCodeReference] {
        guard let helperPath = Self.staticParserExecutablePath() else { return [] }
        let target = try databaseSync {
            try querySymbols(
                """
                SELECT s.id, s.artifact_id, a.file_path, s.name, s.kind, s.range_json,
                       s.confidence_tier, s.blob_sha, s.tier_evidence_json
                FROM code_symbols s
                JOIN code_artifacts a ON a.id = s.artifact_id
                WHERE s.project_id = ? AND s.name = ?
                ORDER BY
                    CASE WHEN s.confidence_tier = 'exact_lsp' THEN 0
                         WHEN s.confidence_tier = 'static_tree_sitter' THEN 1
                         ELSE 2 END,
                    a.file_path ASC
                LIMIT 1
                """,
                [.text(projectID), .text(symbolName)]
            ).first
        }
        guard let target,
              Self.isCurrentBlob(root: root, filePath: target.filePath, blobSHA: target.blobSHA) else {
            return []
        }
        let fileURL = root.appendingPathComponent(target.filePath, isDirectory: false)
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        let request = StaticParserRequest(
            requestId: "refs:\(symbolName)",
            filePath: target.filePath,
            language: Self.language(for: fileURL),
            blobSha: target.blobSHA,
            text: text,
            rootPath: root.path,
            operation: "references",
            position: StaticParserPosition(
                line: max(0, target.range.startLine - 1),
                character: max(0, (target.range.startColumn ?? 1) - 1)
            )
        )
        guard let payload = try? JSONEncoder().encode(request) else { return [] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: helperPath)
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
            input.fileHandleForWriting.write(payload)
            input.fileHandleForWriting.write(Data("\n".utf8))
            try? input.fileHandleForWriting.close()
            process.waitUntilExit()
        } catch {
            return []
        }
        guard process.terminationStatus == 0 else { return [] }
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        guard let line = String(data: outputData, encoding: .utf8)?
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
            .first,
            let response = try? JSONDecoder().decode(StaticParserResponse.self, from: Data(line.utf8)),
            response.ok,
            response.blobSha == target.blobSHA,
            response.errors.isEmpty,
            let refs = response.references,
            refs.isEmpty == false
        else {
            return []
        }
        let capped = max(1, min(limit, 200))
        return refs.prefix(capped).enumerated().map { index, ref in
            let range = BurnBarProjectCodeRange(
                startLine: max(1, ref.startLine),
                endLine: max(max(1, ref.startLine), ref.endLine),
                startColumn: ref.startCharacter + 1,
                endColumn: ref.endCharacter + 1
            )
            let id = "lsp_ref_" + String(Self.sha256Hex("\(projectID):\(symbolName):\(ref.filePath):\(index)").prefix(32))
            return BurnBarProjectCodeReference(
                referenceID: id,
                fromFilePath: ref.filePath,
                targetSymbol: Self.publicSymbol(target),
                range: range,
                confidenceTier: ref.confidenceTier
            )
        }
    }

    private func codeSearchHits(query: String, root: URL, projectID: String, limit: Int) throws -> [BurnBarProjectCodeSearchHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { throw BurnBarProjectCodeMemoryStoreError.emptyQuery }
        let capped = max(1, min(limit, 100))
        let fts = Self.ftsQuery(for: trimmed)
        return try databaseSync {
            do {
                return try queryRows(
                    """
                    SELECT c.id, a.file_path, a.blob_sha,
                           snippet(search_chunks_fts, 3, '<b>', '</b>', '...', 18) AS snippet,
                           bm25(search_chunks_fts) AS rank
                    FROM search_chunks_fts
                    JOIN search_chunks c ON c.id = search_chunks_fts.chunkID
                    JOIN search_documents d ON d.id = c.documentID
                    JOIN code_artifacts a ON a.id = d.sourceID
                    WHERE search_chunks_fts MATCH ?
                      AND d.sourceKind = ?
                      AND a.project_id = ?
                    ORDER BY rank ASC
                    LIMIT ?
                    """,
                    [.text(fts), .text(Self.codeSourceKind), .text(projectID), .int(capped)]
                ).compactMap {
                    guard Self.isCurrentBlob(root: root, filePath: $0.string(1), blobSHA: $0.string(2)) else { return nil }
                    return BurnBarProjectCodeSearchHit(chunkID: $0.string(0), filePath: $0.string(1), snippet: $0.string(3), rank: $0.optionalDouble(4))
                }
            } catch {
                return try queryRows(
                    """
                    SELECT c.id, a.file_path, a.blob_sha, substr(c.text, 1, 500) AS snippet, NULL AS rank
                    FROM search_chunks c
                    JOIN search_documents d ON d.id = c.documentID
                    JOIN code_artifacts a ON a.id = d.sourceID
                    WHERE d.sourceKind = ?
                      AND a.project_id = ?
                      AND c.text LIKE ?
                    ORDER BY a.file_path ASC, c.ordinal ASC
                    LIMIT ?
                    """,
                    [.text(Self.codeSourceKind), .text(projectID), .text("%\(trimmed)%"), .int(capped)]
                ).compactMap {
                    guard Self.isCurrentBlob(root: root, filePath: $0.string(1), blobSHA: $0.string(2)) else { return nil }
                    return BurnBarProjectCodeSearchHit(chunkID: $0.string(0), filePath: $0.string(1), snippet: $0.string(3), rank: nil)
                }
            }
        }
    }

    private func recallLikeFallback(
        query: String,
        projectID: String,
        scope: String,
        includeCrossProject: Bool,
        limit: Int
    ) throws -> [BurnBarProjectMemoryHit] {
        var clauses = ["body_redacted LIKE ?"]
        var binds: [SQLiteBind] = [.text("%\(query)%")]
        if includeCrossProject == false {
            clauses.append("project_id = ?")
            binds.append(.text(projectID))
        }
        if scope != "all", scope.isEmpty == false {
            clauses.append("scope = ?")
            binds.append(.text(scope))
        }
        binds.append(.int(limit))
        return try queryRows(
            """
            SELECT id, project_id, kind, scope, confidence, body_redacted, tags_json, source_path
            FROM agent_memories
            WHERE \(clauses.joined(separator: " AND "))
            ORDER BY updated_at DESC
            LIMIT ?
            """,
            binds
        ).map { row in
            BurnBarProjectMemoryHit(
                memoryID: row.string(0),
                projectID: row.string(1),
                kind: row.string(2),
                scope: row.string(3),
                confidence: row.double(4),
                bodyRedacted: row.string(5),
                tags: decodeStringArray(row.string(6)),
                sourcePath: row.optionalString(7),
                snippet: row.string(5),
                rank: nil
            )
        }
    }

    private func groupedCounts(_ sql: String, _ binds: [SQLiteBind]) throws -> [String: Int] {
        var result: [String: Int] = [:]
        for row in try queryRows(sql, binds) {
            result[row.string(0)] = Int(row.int64(1))
        }
        return result
    }

    private func projectStorageByteCount(projectID: String) throws -> Int {
        try fetchInt("SELECT COALESCE(SUM(byte_count), 0) FROM code_artifacts WHERE project_id = ?", [.text(projectID)])
    }

    private func querySymbols(_ sql: String, _ binds: [SQLiteBind]) throws -> [SQLiteSymbolRow] {
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

    private func ensureColumn(table: String, column: String, definition: String) throws {
        let columns = try queryRows("PRAGMA table_info(\(table))", [])
            .compactMap { $0.optionalString(1) }
        guard columns.contains(column) == false else { return }
        try execute("ALTER TABLE \(table) ADD COLUMN \(column) \(definition)", [])
    }

    private func runIncrementalVacuum() throws {
        try execute("PRAGMA incremental_vacuum(256)", [])
    }

    private func execute(_ sql: String, _ binds: [SQLiteBind]) throws {
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

    private func queryRows(_ sql: String, _ binds: [SQLiteBind]) throws -> [SQLiteRow] {
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
            for index in 0..<count {
                if sqlite3_column_type(statement, index) == SQLITE_NULL {
                    values.append(nil)
                } else if let text = sqlite3_column_text(statement, index) {
                    values.append(String(cString: text))
                } else {
                    values.append(nil)
                }
            }
            rows.append(SQLiteRow(values: values))
        }
        return rows
    }

    private func fetchInt(_ sql: String, _ binds: [SQLiteBind]) throws -> Int {
        Int(try queryRows(sql, binds).first?.int64(0) ?? 0)
    }

    private func bind(_ binds: [SQLiteBind], to statement: OpaquePointer) throws {
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
            case .null:
                rc = sqlite3_bind_null(statement, position)
            }
            guard rc == SQLITE_OK else { throw sqliteError() }
        }
    }

    private func sqliteError() -> BurnBarProjectCodeMemoryStoreError {
        let message = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown sqlite error"
        return .sqlite(message)
    }

    private func encodeJSONString<T: Encodable>(_ value: T) throws -> String {
        String(data: try jsonEncoder.encode(value), encoding: .utf8) ?? "null"
    }

    private func decodeStringArray(_ json: String) -> [String] {
        (try? jsonDecoder.decode([String].self, from: Data(json.utf8))) ?? []
    }

    private static func publicSymbol(_ row: SQLiteSymbolRow) -> BurnBarProjectCodeSymbol {
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

    private static func decodeTierEvidence(_ json: String?) -> BurnBarProjectCodeTierEvidence? {
        guard let json, json.isEmpty == false else { return nil }
        return try? JSONDecoder().decode(BurnBarProjectCodeTierEvidence.self, from: Data(json.utf8))
    }

    private static func projectID(for root: URL) -> String {
        "proj_" + String(sha256Hex(root.path).prefix(16))
    }

    private static func normalizedStorageBudgetBytes(_ requested: Int?) -> Int {
        max(1, min(requested ?? defaultProjectStorageBudgetBytes, maximumProjectStorageBudgetBytes))
    }
}

private extension BurnBarProjectCodeMemoryStore.SQLiteRow {
    func optionalString(_ index: Int) -> String? {
        guard values.indices.contains(index) else { return nil }
        return values[index]
    }

    func string(_ index: Int) -> String {
        optionalString(index) ?? ""
    }

    func int64(_ index: Int) -> Int64 {
        Int64(string(index)) ?? 0
    }

    func double(_ index: Int) -> Double {
        Double(string(index)) ?? 0
    }

    func optionalDouble(_ index: Int) -> Double? {
        optionalString(index).flatMap(Double.init)
    }
}
