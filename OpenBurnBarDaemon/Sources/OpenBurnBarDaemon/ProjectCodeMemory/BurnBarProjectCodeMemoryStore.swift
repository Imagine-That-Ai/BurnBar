#if canImport(CoreServices)
import CoreServices
#endif
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import OpenBurnBarCore
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

let projectCodeMemorySQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
let projectCodeMemoryQueueKey = DispatchSpecificKey<UUID>()

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
    struct SQLiteRow {
        let values: [String?]
    }

    struct SQLiteSymbolRow {
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

    struct IndexedArtifact {
        let id: String
        let filePath: String
        let blobSHA: String
    }

    struct ProjectIdentity {
        let projectID: String
        let canonicalPath: String
        let pathHash: String
        let fingerprint: String
    }

    struct CodeSearchEvaluation {
        let hits: [BurnBarProjectCodeSearchHit]
        let staleCandidateCount: Int
        let totalCandidateCount: Int
        let degradation: BurnBarProjectCodeDegradation?
    }

    struct CodeContextSelection {
        let text: String
        let contentKind: String
        let confidenceTier: String
        let symbolName: String?
        let contentHash: String?
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
        let pollIntervalSeconds: TimeInterval
#if canImport(CoreServices)
        var fseventStream: FSEventStreamRef?
#endif
#if os(Linux)
        var linuxEventStream: LinuxFileSystemEventStream?
#endif
        var lastSignature: String
        /// Event-driven change source (sub-second responsiveness). The timer above is
        /// the reliability backstop for volumes/conditions where native events can miss.
#if canImport(CoreServices)
        var eventStream: FSEventStreamRef?
#endif
        var onFileSystemEvent: (() -> Void)?

        init(
            projectID: String,
            projectRoot: URL,
            maxFiles: Int,
            maxFileBytes: Int,
            storageBudgetBytes: Int,
            timer: DispatchSourceTimer,
            pollIntervalSeconds: TimeInterval,
            lastSignature: String
        ) {
            self.projectID = projectID
            self.projectRoot = projectRoot
            self.maxFiles = maxFiles
            self.maxFileBytes = maxFileBytes
            self.storageBudgetBytes = storageBudgetBytes
            self.timer = timer
            self.pollIntervalSeconds = pollIntervalSeconds
            self.lastSignature = lastSignature
        }

        func nudge() {
            timer.schedule(deadline: .now() + 0.05, repeating: pollIntervalSeconds)
        }

        deinit {
#if canImport(CoreServices)
            if let fseventStream {
                FSEventStreamStop(fseventStream)
                FSEventStreamInvalidate(fseventStream)
                FSEventStreamRelease(fseventStream)
            }
#endif
            timer.cancel()
            teardownEventStream()
        }

        /// Stop native filesystem event delivery. Idempotent. On macOS the FSEvents
        /// stream was created with a retained `info` (+1 on this watcher), so releasing
        /// it balances that reference; invalidation guarantees no further callbacks fire
        /// afterward, so there is no use-after-free on teardown. On Linux, canceling the
        /// dispatch read source closes the inotify fd in its cancel handler.
        func teardownEventStream() {
#if canImport(CoreServices)
            guard let stream = eventStream else { return }
            eventStream = nil
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
#endif
#if os(Linux)
            linuxEventStream?.cancel()
            linuxEventStream = nil
#endif
        }
    }

    struct MemoryIndexRow {
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

    static let agentMemoryPageID = "agent-notes"
    static let codeSourceKind = "code"
    static let codeProvider = "local-code"
    static let ignoredDirectories: Set<String> = [
        ".git", ".build", ".swiftpm", ".deriveddata", "DerivedData", "node_modules",
        "build", "dist", ".next", ".gradle", ".idea", ".vscode", ".serena",
        ".codex", ".claude", ".venv", "target", "Vendor"
    ]
    static let indexedExtensions: Set<String> = [
        "swift", "kt", "kts", "java",
        "ts", "tsx", "js", "jsx",
        "py", "rs", "go",
        "m", "mm", "h", "hpp", "c", "cc", "cpp",
        "json", "md", "yml", "yaml"
    ]
    static let defaultProjectStorageBudgetBytes = 512 * 1_024 * 1_024
    static let maximumProjectStorageBudgetBytes = 10 * 1_024 * 1_024 * 1_024
    static let minimumSemanticCodeCosineScore = 0.20
    /// Bump when the code-store schema changes; surfaced by operator diagnostics so an
    /// operator can confirm which schema generation a daemon's index DB is running.
    static let schemaVersion = 2

    let db: OpaquePointer?
    let dbQueue = DispatchQueue(label: "com.openburnbar.daemon.project-code-memory.sqlite")
    let dbQueueID = UUID()
    let logger: BurnBarDaemonLogger
    let databasePath: String
    let jsonEncoder = JSONEncoder()
    let jsonDecoder = JSONDecoder()
    private var projectWatchers: [String: ProjectWatcher] = [:]
    /// Daemon-owned code embedder (default: the OS NaturalLanguage sentence model).
    /// Injectable so tests can use a deterministic provider for version-floor / RRF checks.
    let embeddingProvider: BurnBarCodeEmbeddingProvider

    init(
        databasePath: String,
        logger: BurnBarDaemonLogger,
        embeddingProvider: BurnBarCodeEmbeddingProvider = NLSentenceEmbeddingProvider()
    ) throws {
        self.databasePath = databasePath
        self.logger = logger
        self.embeddingProvider = embeddingProvider
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
        let projectID = try resolveProjectIdentity(root: root).projectID
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
        let projectID = try resolveProjectIdentity(root: root).projectID
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
        let projectID = try resolveProjectIdentity(root: root).projectID
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
                try execute("DELETE FROM agent_memories WHERE id = ? AND project_id = ?", [.text(memoryID), .text(projectID)])
                // Cross-tier forget for the paths PCM actually uses. The local row is hard-
                // deleted above, and the memory's ONLY cloud presence — its section in
                // project_memory_snapshots, which syncs to the cloud as a sealed blob — was
                // removed by removeProjectMemorySection, so the next snapshot sync propagates
                // the deletion (the snapshot-purge regression test proves the body is gone).
                // PCM writes no server-readable Pensieve knowledge rows (remember stores to
                // agent_memories + the sealed snapshot, not the knowledge store), so there is
                // no separate sealed row to hard-delete — and therefore no honest "pending"
                // tombstone to leave behind. `requireCloudDelete` is reserved for the future
                // hosted-code-sync opt-in, which would additionally drive an app-authenticated
                // deleteKnowledgeSource by projectHmac; until that ships, forget is complete.
                let auditHash = try auditEvent(
                    action: "memory.forget",
                    domain: "memory",
                    projectID: projectID,
                    subjectID: memoryID,
                    labels: ["local hard delete", "snapshot section removed"]
                )
                try execute("COMMIT", [])
                return BurnBarProjectMemoryForgetResponse(
                    traceID: traceID,
                    projectID: projectID,
                    memoryID: memoryID,
                    localDeleted: existed,
                    cloudDeletePending: false,
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
        let projectID = try resolveProjectIdentity(root: root).projectID
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
        let projectID = try resolveProjectIdentity(root: root).projectID
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
        let projectID = try resolveProjectIdentity(root: root).projectID
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
                let existingRows = try queryRows(
                    """
                    SELECT id, file_path
                    FROM code_artifacts
                    WHERE project_id = ?
                    """,
                    [.text(projectID)]
                )
                var existingArtifactByPath: [String: String] = [:]
                for row in existingRows {
                    existingArtifactByPath[row.string(1)] = row.string(0)
                }

                try execute("DELETE FROM code_call_edges WHERE project_id = ?", [.text(projectID)])
                try execute("DELETE FROM code_references WHERE project_id = ?", [.text(projectID)])

                var seenArtifactIDs = Set<String>()
                // Age-aware budget eviction: index newest-first so a project larger than
                // its storage budget keeps the most-recently-modified (most relevant)
                // files and the over-budget rejections are the oldest — deterministic,
                // not whatever order the filesystem walk happened to yield.
                let rankedFiles = Self.enumerateIndexableFiles(root: root, maxFiles: maxFiles)
                    .map { url -> (url: URL, mtime: TimeInterval) in
                        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
                        return (url, (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
                    }
                    .sorted { $0.mtime > $1.mtime }
                for ranked in rankedFiles {
                    let fileURL = ranked.url
                    guard let relativePath = Self.relativePath(fileURL, root: root) else { continue }
                    let artifactID = "code_" + String(Self.sha256Hex("\(projectID):\(relativePath)").prefix(32))
                    let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
                    let fileSize = (attributes?[.size] as? NSNumber)?.intValue ?? 0
                    let mtime = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? Date().timeIntervalSince1970
                    guard fileSize <= maxFileBytes else {
                        try upsertFileManifest(
                            projectID: projectID,
                            filePath: relativePath,
                            artifactID: nil,
                            blobSHA: nil,
                            contentHash: nil,
                            byteCount: fileSize,
                            mtime: mtime,
                            lang: Self.language(for: fileURL),
                            ignoredReason: "max_file_bytes",
                            secretLabels: [],
                            parserTier: nil,
                            now: now
                        )
                        continue
                    }
                    guard let data = try? Data(contentsOf: fileURL), let text = String(data: data, encoding: .utf8) else {
                        try upsertFileManifest(
                            projectID: projectID,
                            filePath: relativePath,
                            artifactID: nil,
                            blobSHA: nil,
                            contentHash: nil,
                            byteCount: fileSize,
                            mtime: mtime,
                            lang: Self.language(for: fileURL),
                            ignoredReason: "unreadable_or_non_utf8",
                            secretLabels: [],
                            parserTier: nil,
                            now: now
                        )
                        continue
                    }
                    let blobSHA = Self.gitBlobSHA(data)
                    let contentHash = Self.sha256Hex(data)
                    let lang = Self.language(for: fileURL)
                    let labels = Self.secretLabels(in: text)
                    if labels.isEmpty == false {
                        rejectedFiles.append(BurnBarProjectCodeRejectedFile(filePath: relativePath, labels: labels))
                        try upsertFileManifest(
                            projectID: projectID,
                            filePath: relativePath,
                            artifactID: nil,
                            blobSHA: blobSHA,
                            contentHash: contentHash,
                            byteCount: data.count,
                            mtime: mtime,
                            lang: lang,
                            ignoredReason: "secret_rejected",
                            secretLabels: labels,
                            parserTier: nil,
                            now: now
                        )
                        _ = try auditEvent(action: "code.secret_rejected", domain: "code", projectID: projectID, subjectID: artifactID, labels: labels)
                        continue
                    }
                    let symbols = Self.extractSymbols(
                        text: text,
                        lang: lang,
                        relativePath: relativePath,
                        rootPath: root.path,
                        projectID: projectID,
                        artifactID: artifactID,
                        blobSHA: blobSHA
                    )
                    let chunks: [CodeChunk]
                    if let lang, ["swift", "typescript", "tsx", "python"].contains(lang) {
                        chunks = Self.astAwareChunks(text: text, symbols: symbols)
                    } else {
                        chunks = Self.chunk(text: text)
                    }
                    let preparedChunks = chunks.map {
                        PreparedCodeChunk(chunk: $0, embeddingVector: codeEmbeddingVector(for: $0.text))
                    }
                    let vectorBytes = preparedChunks.reduce(0) { partial, prepared in
                        partial + Self.codeEmbeddingVectorStorageByteCount(prepared.embeddingVector)
                    }
                    let candidateStorageByteCount = Self.estimatedCodeStorageByteCount(
                        sourceBytes: data.count,
                        chunks: chunks,
                        filePath: relativePath,
                        projectID: projectID,
                        provider: Self.codeProvider,
                        vectorBytes: vectorBytes
                    )
                    guard storageByteCount + candidateStorageByteCount <= storageBudgetBytes else {
                        rejectedFiles.append(
                            BurnBarProjectCodeRejectedFile(filePath: relativePath, labels: ["Storage budget cap reached"])
                        )
                        try upsertFileManifest(
                            projectID: projectID,
                            filePath: relativePath,
                            artifactID: nil,
                            blobSHA: nil,
                            contentHash: nil,
                            byteCount: data.count,
                            mtime: mtime,
                            lang: lang,
                            ignoredReason: "storage_budget",
                            secretLabels: ["Storage budget cap reached"],
                            parserTier: nil,
                            now: now
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
                    let existingArtifact = try queryRows(
                        """
                        SELECT blob_sha, content_hash, byte_count
                        FROM code_artifacts
                        WHERE id = ?
                        LIMIT 1
                        """,
                        [.text(artifactID)]
                    ).first
                    if existingArtifact?.string(0) == blobSHA,
                       (existingArtifact?.optionalString(1) ?? contentHash) == contentHash {
                        artifactsForReferences.append(IndexedArtifact(id: artifactID, filePath: relativePath, blobSHA: blobSHA))
                        seenArtifactIDs.insert(artifactID)
                        indexedFiles += 1
                        storageByteCount += candidateStorageByteCount
                        chunkCount += try fetchInt("SELECT COUNT(*) FROM search_chunks WHERE sourceID = ?", [.text(artifactID)])
                        symbolCount += try fetchInt("SELECT COUNT(*) FROM code_symbols WHERE artifact_id = ?", [.text(artifactID)])
                        try upsertFileManifest(
                            projectID: projectID,
                            filePath: relativePath,
                            artifactID: artifactID,
                            blobSHA: blobSHA,
                            contentHash: contentHash,
                            byteCount: data.count,
                            mtime: mtime,
                            lang: lang,
                            ignoredReason: nil,
                            secretLabels: [],
                            parserTier: nil,
                            now: now
                        )
                        continue
                    }

                    try deleteCodeArtifact(artifactID: artifactID)
                    try execute(
                        """
                        INSERT INTO code_artifacts
                            (id, project_id, file_path, blob_sha, content_hash, commit_sha, lang, byte_count, mtime, indexed_at)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        [
                            .text(artifactID), .text(projectID), .text(relativePath), .text(blobSHA), .text(contentHash),
                            commitSHA.map(SQLiteBind.text) ?? .null, lang.map(SQLiteBind.text) ?? .null,
                            .int(data.count), .double(mtime), .text(now)
                        ]
                    )
                    try upsertFileManifest(
                        projectID: projectID,
                        filePath: relativePath,
                        artifactID: artifactID,
                        blobSHA: blobSHA,
                        contentHash: contentHash,
                        byteCount: data.count,
                        mtime: mtime,
                        lang: lang,
                        ignoredReason: nil,
                        secretLabels: [],
                        parserTier: nil,
                        now: now
                    )
                    artifactsForReferences.append(IndexedArtifact(id: artifactID, filePath: relativePath, blobSHA: blobSHA))
                    seenArtifactIDs.insert(artifactID)
                    indexedFiles += 1
                    storageByteCount += candidateStorageByteCount

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
                    for (ordinal, prepared) in preparedChunks.enumerated() {
                        let chunk = prepared.chunk
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
                            embeddingVector: prepared.embeddingVector,
                            now: now
                        )
                        chunkCount += 1
                    }
                    for symbol in symbols {
                        try insertSymbol(symbol, indexedAt: now)
                        symbolCount += 1
                    }
                    try produceCodeDiagnostics(
                        projectID: projectID,
                        filePath: relativePath,
                        lang: lang,
                        text: text,
                        blobSHA: blobSHA,
                        now: now
                    )
                }
                for artifactID in existingArtifactByPath.values where seenArtifactIDs.contains(artifactID) == false {
                    try deleteCodeArtifact(artifactID: artifactID)
                }
                try execute(
                    """
                    DELETE FROM pcm_file_manifest
                    WHERE project_id = ?
                      AND artifact_id IS NOT NULL
                      AND artifact_id NOT IN (SELECT id FROM code_artifacts WHERE project_id = ?)
                    """,
                    [.text(projectID), .text(projectID)]
                )
                try buildReferences(projectID: projectID, root: root, artifacts: artifactsForReferences, indexedAt: now)
                let previousVacuumedAt = try queryRows(
                    "SELECT vacuumed_at FROM code_index_checkpoints WHERE project_id = ? LIMIT 1",
                    [.text(projectID)]
                ).first?.optionalString(0)
                let compactionDecision = try sqliteCompactionDecision()
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
                        .int(storageByteCount), .int(storageBudgetBytes), previousVacuumedAt.map(SQLiteBind.text) ?? .null
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
                if compactionDecision.shouldCompact {
                    do {
                        try runIncrementalVacuum(maxPages: compactionDecision.freelistCount)
                        try execute(
                            "UPDATE code_index_checkpoints SET vacuumed_at = ? WHERE project_id = ?",
                            [.text(now), .text(projectID)]
                        )
                    } catch {
                        logger.warning(
                            "project_code_memory_compaction_failed",
                            metadata: [
                                "project_id": projectID,
                                "freelist_pages": String(compactionDecision.freelistCount),
                                "page_count": String(compactionDecision.pageCount),
                                "reclaimable_bytes": String(compactionDecision.reclaimableBytes),
                                "error": error.localizedDescription
                            ]
                        )
                    }
                }
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
        let projectID = try resolveProjectIdentity(root: root).projectID
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
            pollIntervalSeconds: interval,
            lastSignature: signature
        )
        // Backstop poll: reliably catches anything FSEvents coalesces or misses.
        timer.setEventHandler { [weak self, weak watcher] in
            guard let self, let watcher else { return }
            self.reindexWatcherIfChanged(watcher)
        }
        timer.schedule(deadline: .now() + interval, repeating: interval)

        // Event-driven fast path: native filesystem events fire on real changes
        // under the project root — including .git/HEAD and refs on branch switches — so a
        // change is reindexed in sub-second time instead of waiting a full poll interval.
        watcher.onFileSystemEvent = { [weak self, weak watcher] in
            guard let self, let watcher else { return }
            self.reindexWatcherIfChanged(watcher)
        }
#if canImport(CoreServices)
        watcher.eventStream = Self.makeFileSystemEventStream(root: root, queue: queue, watcher: watcher)
#endif
#if os(Linux)
        watcher.linuxEventStream = LinuxFileSystemEventStream.make(
            roots: Self.projectWatchEventPaths(root: root),
            queue: queue,
            onEvent: { [weak watcher] in
                watcher?.onFileSystemEvent?()
            }
        )
#endif

        databaseSync {
            if let previous = projectWatchers[projectID] {
                previous.timer.cancel()
                previous.teardownEventStream()
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

    /// Re-walk the project signature and full-reindex only when it changed. Invoked by
    /// both the FSEvents fast path and the poll backstop; both run on the same serial
    /// watch queue so reindexes never overlap.
    private func reindexWatcherIfChanged(_ watcher: ProjectWatcher) {
        let currentSignature = Self.projectIndexSignature(root: watcher.projectRoot, maxFiles: watcher.maxFiles)
        guard currentSignature != watcher.lastSignature else { return }
        do {
            _ = try indexProject(
                BurnBarProjectCodeIndexProjectRequest(
                    projectPath: watcher.projectRoot.path,
                    maxFiles: watcher.maxFiles,
                    maxFileBytes: watcher.maxFileBytes,
                    storageBudgetBytes: watcher.storageBudgetBytes
                )
            )
            watcher.lastSignature = currentSignature
            logger.notice(
                "project_code_memory_watch_reindexed",
                metadata: ["project_id": watcher.projectID, "signature": currentSignature]
            )
        } catch {
            logger.warning(
                "project_code_memory_watch_reindex_failed",
                metadata: ["project_id": watcher.projectID, "error": error.localizedDescription]
            )
        }
    }

#if canImport(CoreServices)
    /// FSEvents C callback bridges back to the watcher through the retained `info`.
    private static let fileSystemEventCallback: FSEventStreamCallback = { _, info, _, _, _, _ in
        guard let info else { return }
        Unmanaged<ProjectWatcher>.fromOpaque(info).takeUnretainedValue().onFileSystemEvent?()
    }

    /// Create + start a recursive FSEvents stream over `root`, delivering on `queue`.
    /// The watcher is retained for the stream's lifetime (balanced by the context
    /// release callback, which teardownEventStream triggers via FSEventStreamRelease),
    /// so the callback can never dereference a freed pointer. Returns nil if the stream
    /// cannot be created — the poll backstop still guarantees eventual reindex.
    private static func makeFileSystemEventStream(root: URL, queue: DispatchQueue, watcher: ProjectWatcher) -> FSEventStreamRef? {
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passRetained(watcher).toOpaque(),
            retain: nil,
            release: { pointer in
                if let pointer { Unmanaged<ProjectWatcher>.fromOpaque(pointer).release() }
            },
            copyDescription: nil
        )
        let flags = UInt32(kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagFileEvents)
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            fileSystemEventCallback,
            &context,
            [root.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.2,
            flags
        ) else {
            if let info = context.info {
                Unmanaged<ProjectWatcher>.fromOpaque(info).release()
            }
            return nil
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        return stream
    }
#endif

    private func auditEvent(
        action: String,
        domain: String,
        projectID: String?,
        subjectID: String?,
        labels: [String]
    ) throws -> String {
        let previous = try queryRows("SELECT seq, hash FROM memory_audit ORDER BY seq DESC LIMIT 1", []).first
        let prevHash = previous?.optionalString(1)
        let nextSequence = previous.map { Int($0.int64(0)) + 1 } ?? 1
        let ts = Self.isoNow()
        let normalizedLabels = Array(Set(labels)).sorted()
        let labelsJSON = try encodeJSONString(normalizedLabels)
        let payload = try Self.jsonData([
            "schema": "openburnbar.memory_audit.v2",
            "seq": nextSequence,
            "ts": ts,
            "actor": "daemon",
            "action": action,
            "domain": domain,
            "projectID": projectID.map { $0 as Any } ?? NSNull(),
            "subjectID": subjectID.map { $0 as Any } ?? NSNull(),
            "labels": normalizedLabels,
            "prevHash": prevHash ?? ""
        ])
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
        embeddingVector: [Float]?,
        now: String
    ) throws {
        // FTS row first so its rowid can be recorded on the chunk row: the FTS5
        // key columns (`chunkID`/`documentID`) are UNINDEXED, so any later
        // `DELETE ... WHERE documentID = ?` would full-scan the entire FTS
        // content table (GBs of chunk text on a mature index). Recording the
        // rowid keeps deletes O(log n). Mirrors the app-side
        // `v55_search_chunks_fts_rowid` contract on the shared schema.
        try execute(
            "INSERT INTO search_chunks_fts (chunkID, documentID, title, chunkText, projectName, provider) VALUES (?, ?, ?, ?, ?, ?)",
            [.text(chunkID), .text(documentID), .text(filePath), .text(text), .text(projectID), .text(Self.codeProvider)]
        )
        if try searchChunksHasFtsRowidColumn() {
            let ftsRowid = try queryRows("SELECT last_insert_rowid()", []).first?.int64(0)
            try execute(
                """
                INSERT INTO search_chunks
                    (id, documentID, sourceKind, sourceID, sourceVersionID, ordinal, startOffset, endOffset, sectionPath, text, contentHash, ftsRowid, createdAt, updatedAt)
                VALUES (?, ?, ?, ?, '', ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    .text(chunkID), .text(documentID), .text(Self.codeSourceKind), .text(artifactID),
                    .int(ordinal), .int(startOffset), .int(endOffset), .text(filePath),
                    .text(text), .text(contentHash), ftsRowid.map { SQLiteBind.int64($0) } ?? .null,
                    .text(now), .text(now)
                ]
            )
        } else {
            // Pre-v55 database (the app's migrator hasn't added `ftsRowid`
            // yet). Insert without the mapping; deletes fall back to the
            // legacy scan path for these rows.
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
        }
        // Daemon-owned semantic vector for this chunk, tagged with the embedding version
        // so search never mixes generations. Stored base64 (TEXT) to ride the existing
        // string-based row machinery. Missing/declined embeddings degrade to lexical-only.
        if let vector = embeddingVector {
            try execute(
                """
                INSERT OR REPLACE INTO code_chunk_embeddings
                    (chunk_id, project_id, embedding_version, dimension, vector)
                VALUES (?, ?, ?, ?, ?)
                """,
                [
                    .text(chunkID), .text(projectID), .text(embeddingProvider.versionID),
                    .int(vector.count), .text(BurnBarCodeVectorCodec.encode(vector).base64EncodedString())
                ]
            )
        }
    }

    /// Whether `search_chunks` carries the `ftsRowid` mapping column added by
    /// the app-side `v55_search_chunks_fts_rowid` migration on the shared
    /// schema. Probed once per process (the column never disappears; a
    /// mid-run app migration is picked up on the next daemon start, and rows
    /// written meanwhile stay correct via the NULL-rowid legacy delete path).
    private var cachedSearchChunksHasFtsRowid: Bool?

    private func searchChunksHasFtsRowidColumn() throws -> Bool {
        if let cached = cachedSearchChunksHasFtsRowid { return cached }
        let has = try queryRows("PRAGMA table_info(search_chunks)", [])
            .contains { $0.string(1) == "ftsRowid" }
        cachedSearchChunksHasFtsRowid = has
        return has
    }

    private struct PreparedCodeChunk {
        let chunk: CodeChunk
        let embeddingVector: [Float]?
    }

    private func codeEmbeddingVector(for text: String) -> [Float]? {
        guard embeddingProvider.isAvailable else { return nil }
        return embeddingProvider.embed(text)
    }

    private static func codeEmbeddingVectorStorageByteCount(_ vector: [Float]?) -> Int {
        guard let vector else { return 0 }
        return BurnBarCodeVectorCodec.base64EncodedByteCount(vectorDimension: vector.count)
    }

    private func deleteCodeArtifact(artifactID: String) throws {
        var docIDs = Set(try queryRows(
            "SELECT id FROM search_documents WHERE sourceKind = ? AND sourceID = ?",
            [.text(Self.codeSourceKind), .text(artifactID)]
        ).map { $0.string(0) })
        for row in try queryRows(
            "SELECT DISTINCT documentID FROM search_chunks WHERE sourceKind = ? AND sourceID = ?",
            [.text(Self.codeSourceKind), .text(artifactID)]
        ) {
            docIDs.insert(row.string(0))
        }
        for docID in docIDs {
            let chunkIDs = try queryRows("SELECT id FROM search_chunks WHERE documentID = ?", [.text(docID)])
                .map { $0.string(0) }
            for chunkID in chunkIDs {
                try execute("DELETE FROM chunk_embeddings WHERE chunkID = ?", [.text(chunkID)])
                try execute("DELETE FROM code_chunk_embeddings WHERE chunk_id = ?", [.text(chunkID)])
            }
            // Rowid-targeted FTS delete via the `ftsRowid` mapping — matching
            // on the UNINDEXED `documentID` column scans the entire FTS
            // content table per document. Rows written before the mapping
            // existed carry NULL and take the scan path once, individually.
            if try searchChunksHasFtsRowidColumn() {
                try execute(
                    """
                    DELETE FROM search_chunks_fts WHERE rowid IN (
                        SELECT ftsRowid FROM search_chunks
                        WHERE documentID = ? AND ftsRowid IS NOT NULL
                    )
                    """,
                    [.text(docID)]
                )
                let legacyChunkIDs = try queryRows(
                    "SELECT id FROM search_chunks WHERE documentID = ? AND ftsRowid IS NULL",
                    [.text(docID)]
                ).map { $0.string(0) }
                for chunkID in legacyChunkIDs {
                    try execute("DELETE FROM search_chunks_fts WHERE chunkID = ?", [.text(chunkID)])
                }
            } else {
                try execute("DELETE FROM search_chunks_fts WHERE documentID = ?", [.text(docID)])
            }
            try execute("DELETE FROM search_chunks WHERE documentID = ?", [.text(docID)])
            try execute("DELETE FROM search_documents WHERE id = ?", [.text(docID)])
        }
        try execute(
            """
            DELETE FROM code_call_edges
            WHERE caller_symbol_id IN (SELECT id FROM code_symbols WHERE artifact_id = ?)
               OR callee_symbol_id IN (SELECT id FROM code_symbols WHERE artifact_id = ?)
            """,
            [.text(artifactID), .text(artifactID)]
        )
        try execute(
            """
            DELETE FROM code_references
            WHERE from_artifact_id = ?
               OR to_symbol_id IN (SELECT id FROM code_symbols WHERE artifact_id = ?)
            """,
            [.text(artifactID), .text(artifactID)]
        )
        try execute("DELETE FROM code_symbols WHERE artifact_id = ?", [.text(artifactID)])
        try execute(
            "DELETE FROM code_diagnostics_cache WHERE blob_sha IN (SELECT blob_sha FROM code_artifacts WHERE id = ?)",
            [.text(artifactID)]
        )
        try execute("DELETE FROM code_artifacts WHERE id = ?", [.text(artifactID)])
    }

    private func produceCodeDiagnostics(
        projectID: String,
        filePath: String,
        lang: String?,
        text: String,
        blobSHA: String,
        now: String
    ) throws {
        guard lang == "python" else { return }
        let script = """
        import json
        import sys
        source = sys.stdin.read()
        diagnostics = []
        try:
            compile(source, sys.argv[1], "exec")
        except SyntaxError as error:
            diagnostics.append({
                "severity": "error",
                "message": error.msg,
                "line": error.lineno,
                "column": error.offset,
                "endLine": error.end_lineno,
                "endColumn": error.end_offset,
            })
        print(json.dumps({
            "schema": "openburnbar.project_code_diagnostics.v1",
            "producer": "python.compile",
            "diagnostics": diagnostics,
        }, sort_keys=True, separators=(",", ":")))
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-c", script, filePath]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()
        let payload = Data(text.utf8)
        guard Self.runHelperProcess(process, input: input, payload: payload),
              process.terminationStatus == 0,
              let outputData = Optional(output.fileHandleForReading.readDataToEndOfFile()),
              outputData.count <= Self.codeHelperMaxOutputBytes(),
              let firstLine = String(data: outputData, encoding: .utf8)?
                .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
                .first
        else {
            return
        }
        let diagnosticID = "diag_" + String(Self.sha256Hex("\(projectID):\(filePath):python.compile").prefix(32))
        try execute(
            """
            INSERT INTO code_diagnostics_cache
                (id, project_id, file_path, tool, payload_json, blob_sha, cached_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                payload_json = excluded.payload_json,
                blob_sha = excluded.blob_sha,
                cached_at = excluded.cached_at
            """,
            [
                .text(diagnosticID),
                .text(projectID),
                .text(filePath),
                .text("python.compile"),
                .text(String(firstLine)),
                .text(blobSHA),
                .text(now)
            ]
        )
    }

    private func upsertFileManifest(
        projectID: String,
        filePath: String,
        artifactID: String?,
        blobSHA: String?,
        contentHash: String?,
        byteCount: Int,
        mtime: Double,
        lang: String?,
        ignoredReason: String?,
        secretLabels: [String],
        parserTier: String?,
        now: String
    ) throws {
        let id = "manifest_" + String(Self.sha256Hex("\(projectID):\(filePath)").prefix(32))
        let labelsJSON = try encodeJSONString(secretLabels.sorted())
        try execute(
            """
            INSERT INTO pcm_file_manifest
                (id, project_id, file_path, artifact_id, blob_sha, content_hash, byte_count, mtime,
                 lang, ignored_reason, secret_labels_json, parser_tier, indexed_at, last_seen_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(project_id, file_path) DO UPDATE SET
                artifact_id = excluded.artifact_id,
                blob_sha = excluded.blob_sha,
                content_hash = excluded.content_hash,
                byte_count = excluded.byte_count,
                mtime = excluded.mtime,
                lang = excluded.lang,
                ignored_reason = excluded.ignored_reason,
                secret_labels_json = excluded.secret_labels_json,
                parser_tier = excluded.parser_tier,
                indexed_at = excluded.indexed_at,
                last_seen_at = excluded.last_seen_at
            """,
            [
                .text(id), .text(projectID), .text(filePath),
                artifactID.map(SQLiteBind.text) ?? .null,
                blobSHA.map(SQLiteBind.text) ?? .null,
                contentHash.map(SQLiteBind.text) ?? .null,
                .int(byteCount), .double(mtime),
                lang.map(SQLiteBind.text) ?? .null,
                ignoredReason.map(SQLiteBind.text) ?? .null,
                .text(labelsJSON),
                parserTier.map(SQLiteBind.text) ?? .null,
                .text(now), .text(now)
            ]
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
                let scanLine = Self.referenceScanLine(line)
                let caller = fileSymbols.last(where: { $0.range.startLine <= lineIndex + 1 })
                for token in Self.identifierTokens(in: scanLine) {
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
                        if let caller, Self.lineContainsCall(to: target.name, in: scanLine), caller.id != target.id {
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

    func exactLSPReferences(
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
        guard Self.runHelperProcess(process, input: input, payload: payload) else {
            return []
        }
        guard process.terminationStatus == 0 else { return [] }
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        guard outputData.count <= Self.codeHelperMaxOutputBytes() else { return [] }
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

    func codeSearchHits(query: String, root: URL, projectID: String, limit: Int) throws -> CodeSearchEvaluation {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { throw BurnBarProjectCodeMemoryStoreError.emptyQuery }
        let capped = max(1, min(limit, 100))
        return try databaseSync {
            // Pull a wider candidate pool from each retriever than the final limit so RRF
            // has room to reorder lexical (BM25) and semantic (cosine) hits.
            let pool = min(200, max(capped * 5, capped))
            let lexicalIDs = try self.lexicalCodeChunkIDs(query: trimmed, projectID: projectID, limit: pool)
            let semanticIDs = Self.isExactIdentifierSearchIntent(trimmed)
                ? []
                : try self.semanticCodeChunkIDs(query: trimmed, projectID: projectID, limit: pool)
            // Hybrid when both retrievers return; lexical-only when embeddings are
            // unavailable so search never regresses below the keyword baseline.
            let fusedIDs = semanticIDs.isEmpty
                ? lexicalIDs
                : BurnBarReciprocalRankFusion.fuse([lexicalIDs, semanticIDs])
            return try self.resolveCodeHits(chunkIDs: fusedIDs, root: root, projectID: projectID, query: trimmed, limit: capped)
        }
    }

    /// Lexical (FTS5 BM25) chunk ids, with a LIKE fallback if the MATCH query is rejected.
    private func lexicalCodeChunkIDs(query: String, projectID: String, limit: Int) throws -> [String] {
        let fts = Self.ftsQuery(for: query)
        do {
            return try queryRows(
                """
                SELECT c.id
                FROM search_chunks_fts
                JOIN search_chunks c ON c.id = search_chunks_fts.chunkID
                JOIN search_documents d ON d.id = c.documentID
                JOIN code_artifacts a ON a.id = d.sourceID
                WHERE search_chunks_fts MATCH ?
                  AND d.sourceKind = ?
                  AND a.project_id = ?
                ORDER BY bm25(search_chunks_fts) ASC
                LIMIT ?
                """,
                [.text(fts), .text(Self.codeSourceKind), .text(projectID), .int(limit)]
            ).map { $0.string(0) }
        } catch {
            return try queryRows(
                """
                SELECT c.id
                FROM search_chunks c
                JOIN search_documents d ON d.id = c.documentID
                JOIN code_artifacts a ON a.id = d.sourceID
                WHERE d.sourceKind = ?
                  AND a.project_id = ?
                  AND c.text LIKE ?
                ORDER BY a.file_path ASC, c.ordinal ASC
                LIMIT ?
                """,
                [.text(Self.codeSourceKind), .text(projectID), .text("%\(query)%"), .int(limit)]
            ).map { $0.string(0) }
        }
    }

    /// Semantic (cosine) chunk ids over the daemon-owned embeddings, restricted to the
    /// ACTIVE embedding version (the §5.9 floor — vectors from a different generation are
    /// ignored, never silently compared). Empty when embeddings are unavailable.
    private func semanticCodeChunkIDs(query: String, projectID: String, limit: Int) throws -> [String] {
        guard embeddingProvider.isAvailable, let queryVector = embeddingProvider.embed(query) else { return [] }
        let dimension = queryVector.count
        let rows = try queryRows(
            """
            SELECT chunk_id, vector
            FROM code_chunk_embeddings
            WHERE project_id = ? AND embedding_version = ? AND dimension = ?
            """,
            [.text(projectID), .text(embeddingProvider.versionID), .int(dimension)]
        )
        let scored: [(id: String, score: Double)] = rows.compactMap { row in
            guard let data = Data(base64Encoded: row.string(1)),
                  let vector = BurnBarCodeVectorCodec.decode(data, dimension: dimension) else { return nil }
            return (row.string(0), BurnBarCodeVectorCodec.cosine(queryVector, vector))
        }
        return scored
            .filter { $0.score >= Self.minimumSemanticCodeCosineScore }
            .sorted { $0.score == $1.score ? $0.id < $1.id : $0.score > $1.score }
            .prefix(limit)
            .map { $0.id }
    }

    /// Resolve fused chunk ids to hits, preserving fused order, dropping rows whose file no
    /// longer matches the indexed blob (stale), up to `limit`.
    private func resolveCodeHits(chunkIDs: [String], root: URL, projectID: String, query: String, limit: Int) throws -> CodeSearchEvaluation {
        guard chunkIDs.isEmpty == false else {
            return CodeSearchEvaluation(
                hits: [],
                staleCandidateCount: 0,
                totalCandidateCount: 0,
                degradation: nil
            )
        }
        let placeholders = chunkIDs.map { _ in "?" }.joined(separator: ",")
        var binds: [SQLiteBind] = chunkIDs.map { .text($0) }
        binds.append(.text(Self.codeSourceKind))
        binds.append(.text(projectID))
        let rows = try queryRows(
            """
            SELECT c.id, a.file_path, a.blob_sha, c.contentHash, c.text
            FROM search_chunks c
            JOIN search_documents d ON d.id = c.documentID
            JOIN code_artifacts a ON a.id = d.sourceID
            WHERE c.id IN (\(placeholders))
              AND d.sourceKind = ?
              AND a.project_id = ?
            """,
            binds
        )
        var byID: [String: (filePath: String, blobSHA: String, contentHash: String?, text: String)] = [:]
        for row in rows {
            byID[row.string(0)] = (row.string(1), row.string(2), row.optionalString(3), row.string(4))
        }
        var hits: [BurnBarProjectCodeSearchHit] = []
        var staleCount = 0
        for (fusedRank, chunkID) in chunkIDs.enumerated() {
            guard let meta = byID[chunkID] else { continue }
            guard Self.isCurrentBlob(root: root, filePath: meta.filePath, blobSHA: meta.blobSHA) else {
                staleCount += 1
                continue
            }
            if hits.count < limit {
                let wrapped = Self.wrapUntrustedCode(
                    Self.codeSnippet(text: meta.text, query: query),
                    sourceTool: "daemon.code.search",
                    projectID: projectID,
                    filePath: meta.filePath,
                    chunkID: chunkID,
                    blobSHA: meta.blobSHA,
                    contentHash: meta.contentHash
                )
                hits.append(
                    BurnBarProjectCodeSearchHit(
                        chunkID: chunkID,
                        filePath: meta.filePath,
                        snippet: wrapped,
                        rank: Double(fusedRank),
                        rankFeatures: [
                            "fusedRank": Double(fusedRank),
                            "candidatePool": Double(chunkIDs.count)
                        ],
                        blobSHA: meta.blobSHA,
                        contentHash: meta.contentHash
                    )
                )
            }
        }
        return CodeSearchEvaluation(
            hits: hits,
            staleCandidateCount: staleCount,
            totalCandidateCount: rows.count,
            degradation: try staleDegradation(
                projectID: projectID,
                staleCandidateCount: staleCount,
                totalCandidateCount: rows.count
            )
        )
    }

    /// A short snippet windowed around the first query-token match, else the text head.
    private static func codeSnippet(text: String, query: String) -> String {
        let tokens = query.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        for token in tokens where token.isEmpty == false {
            if let range = text.range(of: token, options: .caseInsensitive) {
                let start = text.index(range.lowerBound, offsetBy: -80, limitedBy: text.startIndex) ?? text.startIndex
                let end = text.index(range.upperBound, offsetBy: 160, limitedBy: text.endIndex) ?? text.endIndex
                let prefix = start > text.startIndex ? "..." : ""
                let suffix = end < text.endIndex ? "..." : ""
                return prefix + String(text[start..<end]) + suffix
            }
        }
        return String(text.prefix(240))
    }

    func contextSelection(
        for hit: BurnBarProjectCodeSearchHit,
        root: URL,
        projectID: String
    ) throws -> CodeContextSelection {
        let rows = try queryRows(
            """
            SELECT c.text, c.startOffset, c.endOffset, c.sourceID, a.file_path, a.blob_sha, c.contentHash
            FROM search_chunks c
            JOIN search_documents d ON d.id = c.documentID
            JOIN code_artifacts a ON a.id = d.sourceID
            WHERE c.id = ?
            LIMIT 1
            """,
            [.text(hit.chunkID)]
        )
        guard let row = rows.first else {
            return CodeContextSelection(
                text: "",
                contentKind: "chunk",
                confidenceTier: "lexical_fallback",
                symbolName: nil,
                contentHash: hit.contentHash
            )
        }
        let chunkText = row.string(0)
        let chunkStart = Int(row.int64(1))
        let chunkEnd = Int(row.int64(2))
        let artifactID = row.string(3)
        let filePath = row.string(4)
        let blobSHA = row.string(5)
        let fallbackHash = row.optionalString(6) ?? Self.sha256Hex(chunkText)
        let fileURL = root.appendingPathComponent(filePath, isDirectory: false)
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return CodeContextSelection(
                text: chunkText,
                contentKind: "chunk",
                confidenceTier: "lexical_fallback",
                symbolName: nil,
                contentHash: fallbackHash
            )
        }
        let symbolRows = try queryRows(
            """
            SELECT name, kind, range_json, confidence_tier
            FROM code_symbols
            WHERE project_id = ? AND artifact_id = ? AND blob_sha = ?
            """,
            [.text(projectID), .text(artifactID), .text(blobSHA)]
        )
        var best: (start: Int, end: Int, name: String, confidenceTier: String)?
        for symbol in symbolRows {
            let range = Self.decodeRange(symbol.string(2))
            guard let offsets = Self.rangeOffsets(for: range, in: text),
                  offsets.start < chunkEnd,
                  offsets.end > chunkStart else { continue }
            let length = offsets.end - offsets.start
            guard length > 0, length <= 16_000 else { continue }
            if best == nil || length < ((best?.end ?? 0) - (best?.start ?? 0)) {
                best = (offsets.start, offsets.end, symbol.string(0), symbol.string(3))
            }
        }
        guard let best else {
            return CodeContextSelection(
                text: chunkText,
                contentKind: "chunk",
                confidenceTier: "lexical_fallback",
                symbolName: nil,
                contentHash: fallbackHash
            )
        }
        let startIndex = text.index(text.startIndex, offsetBy: best.start)
        let endIndex = text.index(text.startIndex, offsetBy: best.end)
        let symbolText = String(text[startIndex..<endIndex])
        return CodeContextSelection(
            text: symbolText,
            contentKind: "complete_symbol",
            confidenceTier: best.confidenceTier,
            symbolName: best.name,
            contentHash: Self.sha256Hex(symbolText)
        )
    }

    func staleDegradation(
        projectID: String,
        staleCandidateCount: Int,
        totalCandidateCount: Int
    ) throws -> BurnBarProjectCodeDegradation? {
        guard totalCandidateCount > 0, staleCandidateCount * 2 >= totalCandidateCount else { return nil }
        return BurnBarProjectCodeDegradation(
            code: "STALE_INDEX",
            message: "At least half of the candidate rows point at files whose current blob no longer matches the indexed blob.",
            staleCandidateCount: staleCandidateCount,
            totalCandidateCount: totalCandidateCount,
            indexAgeSeconds: try indexAgeSeconds(projectID: projectID),
            reindexHint: "Run burnbar_index_project for this project before relying on code-memory results."
        )
    }

    private func indexAgeSeconds(projectID: String) throws -> Double? {
        guard let indexedAt = try queryRows(
            "SELECT indexed_at FROM code_index_checkpoints WHERE project_id = ? LIMIT 1",
            [.text(projectID)]
        ).first?.optionalString(0) else {
            return nil
        }
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: indexedAt) else { return nil }
        return max(0, Date().timeIntervalSince(date))
    }

    func projectCodeMemoryProductionReadinessReasons() -> [String] {
        var reasons = [
            "PROJECT_CODE_MEMORY_PRODUCTION_READY=false",
            "real local embeddings are not configured; semanticAvailable=false",
            "hosted code sync remains disabled unless an explicit code asset-class flag is enabled"
        ]
        if Self.staticParserExecutablePath() == nil {
            reasons.append("static parser helper is unavailable")
        }
        if BurnBarDaemonDatabaseCipher.isCipherAvailable() == false {
            reasons.append("SQLCipher codec not linked; Project Code Memory release readiness is blocked")
        }
        if BurnBarDaemonDatabaseCipher.isEncryptedDatabaseFile(at: databasePath) == false {
            reasons.append("database file is not encrypted for this daemon handle")
        }
        return reasons
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
}
