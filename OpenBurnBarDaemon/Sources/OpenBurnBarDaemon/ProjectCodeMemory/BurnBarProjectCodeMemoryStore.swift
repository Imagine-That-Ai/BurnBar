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
import OpenBurnBarEngine
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

let projectCodeMemorySQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
// DispatchSpecificKey is not Sendable; access is confined to the project-code serial queue.
nonisolated(unsafe) let projectCodeMemoryQueueKey = DispatchSpecificKey<UUID>()

enum BurnBarProjectCodeMemoryStoreError: Error, LocalizedError {
    case emptyText
    case emptyQuery
    case memoryNotFound(String)
    case invalidMemoryReviewStatus(String)
    case projectPathUnavailable(String)
    case secretRejected(labels: [String])
    case databaseSnapshotUnavailable(String)
    case databaseSnapshotInvalidPath(String)
    case databaseSnapshotTooLarge(Int)
    case databaseSnapshotPermissions(String)
    case databaseSnapshotFailed(String)
    case snapshotInvalidRequest(String)
    case memoryAuthorityInvalidRequest(String)
    case memoryAuthorityConflict(String)
    case sqlite(String)

    var errorDescription: String? {
        switch self {
        case .emptyText:
            return "Memory text is empty."
        case .emptyQuery:
            return "Query is empty."
        case .memoryNotFound(let memoryID):
            return "Memory was not found in the selected project: \(memoryID)"
        case .invalidMemoryReviewStatus(let status):
            return "Unsupported memory review status: \(status)"
        case .projectPathUnavailable(let path):
            return "Project path is not readable: \(path)"
        case .secretRejected(let labels):
            return "Rejected before persistence by the project memory secret scanner: \(labels.joined(separator: ", "))."
        case .databaseSnapshotUnavailable(let reason):
            return "Encrypted database snapshots are unavailable: \(reason)"
        case .databaseSnapshotInvalidPath(let path):
            return "Database snapshot path is not allowed: \(path)"
        case .databaseSnapshotTooLarge(let bytes):
            return "Database snapshot exceeds the configured byte limit (\(bytes) bytes)."
        case .databaseSnapshotPermissions(let path):
            return "Database snapshot permissions are unsafe: \(path)"
        case .databaseSnapshotFailed(let reason):
            return "Database snapshot operation failed: \(reason)"
        case .snapshotInvalidRequest(let detail):
            return "Invalid project memory snapshot request: \(detail)"
        case .memoryAuthorityInvalidRequest(let detail):
            return "Invalid memory authority request: \(detail)"
        case .memoryAuthorityConflict(let detail):
            return "Memory authority precondition failed: \(detail)"
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
        let blobs: [Data?]
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
        let reviewStatus: MemoryReviewStatus
    }

    struct MemoryRecallCandidate {
        let row: MemoryIndexRow
        let body: String
        let searchableTokens: [String]
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
    static let schemaVersion = 3

    var db: OpaquePointer?
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
    /// Last semantic retriever used by `searchCode` (`hnsw`, `cosine-scan`, or `none`).
    /// Tests assert PCM search actually walks the HNSW backend, not a silent scan.
    var lastSemanticCodeSearchBackend: String = "none"
    var codeHNSWSnapshot: CodeHNSWSnapshot?

    struct CodeHNSWSnapshot {
        let projectID: String
        let embeddingVersion: String
        let directoryURL: URL
        let reader: any BurnBarPersistentVectorIndexReadableIndex
        let keyToChunk: [UInt64: String]
    }

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
            try backfillMemoryEmbeddings()
        }
        // The code-memory store contains indexed source text and memory
        // references. Tighten the primary file on every open so snapshot export
        // never has to copy a group/world-readable database.
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: databasePath
        )
    }

    deinit {
        projectWatchers.values.forEach { $0.timer.cancel() }
        guard let db else { return }
        _ = databaseSync {
            sqlite3_close(db)
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
        let queryVector = embeddingProvider.isAvailable ? embeddingProvider.embed(query) : nil

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
                       m.tags_json, m.source_path, m.updated_at, m.review_status
                FROM agent_memories AS m
                \(whereClause.isEmpty ? "WHERE 1 = 1" : whereClause)
                AND (
                    m.review_status = 'approved'
                    OR (? = 1 AND m.review_status IN ('quarantined', 'rejected'))
                    OR (? = 1 AND m.review_status = 'forgotten')
                )
                ORDER BY m.updated_at DESC
                LIMIT 1000
            """
            let queryBinds = binds + [.int(request.includeQuarantined ? 1 : 0), .int(request.includeForgotten ? 1 : 0)]
            let candidates = try queryRows(sql, queryBinds)
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
                        updatedAt: row.string(8),
                        reviewStatus: MemoryReviewStatus(rawValue: row.string(9)) ?? .approved
                    )
                }
                .compactMap { row -> MemoryRecallCandidate? in
                    let body: String?
                    if row.reviewStatus == .approved {
                        body = try projectMemorySectionBody(projectID: row.projectID, memoryID: row.id)
                    } else {
                        body = try quarantineMemoryBody(projectID: row.projectID, memoryID: row.id)
                    }
                    if body == nil, row.reviewStatus != .forgotten || request.includeForgotten == false {
                        return nil
                    }
                    let searchable = ([body ?? ""] + row.tags + [row.sourcePath ?? ""]).joined(separator: " ")
                    return MemoryRecallCandidate(row: row, body: body ?? "", searchableTokens: BurnBarMemoryRanking.tokenize(searchable))
                }
            if request.includeQuarantined || request.includeForgotten {
                return Array(candidates.prefix(limit).map { candidate in
                    BurnBarProjectMemoryHit(
                        memoryID: candidate.row.id,
                        projectID: candidate.row.projectID,
                        kind: candidate.row.kind,
                        scope: candidate.row.scope,
                        confidence: candidate.row.confidence,
                        bodyRedacted: candidate.body,
                        tags: candidate.row.tags,
                        sourcePath: candidate.row.sourcePath,
                        snippet: candidate.body.isEmpty ? "" : Self.memorySnippet(body: candidate.body, tokens: tokens, fallbackQuery: query),
                        rank: nil,
                        reviewStatus: candidate.row.reviewStatus
                    )
                })
            }
            let candidatesByID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.row.id, $0) })
            let salienceRows = try salienceRows(candidateIDs: candidatesByID.keys.sorted())
            let salienceByID = Dictionary(uniqueKeysWithValues: salienceRows.map { row in
                (row.string(0), (hitCount: Int(row.int64(1)), lastReinforcedAt: row.optionalString(2)))
            })
            let lexical = BurnBarMemoryRanking.bm25Rank(
                documents: candidates.reduce(into: [:]) { $0[$1.row.id] = $1.searchableTokens },
                queryTokens: BurnBarMemoryRanking.tokenize(query),
                limit: max(limit * 4, 50)
            )
            var semantic: [(id: String, score: Double)] = []
            if let queryVector, queryVector.count == embeddingProvider.dimension {
                let ranked = try semanticCandidateScores(candidateIDs: candidatesByID.keys.sorted(), queryVector: queryVector)
                semantic = Array(ranked.prefix(max(limit * 4, 50)))
            }
            let fusedScores = BurnBarMemoryRanking.reciprocalRankScores(
                lexical: lexical.map(\.id),
                semantic: semantic.map(\.id)
            )
            let now = Date()
            // B9: the ranking report, built from the values the scorer already
            // has. Reported alongside each hit; never read back into `scores`.
            var whyByID: [String: (matchedBy: String, why: BurnBarMemoryWhyBreakdown)] = [:]
            let lanes = BurnBarMemoryRanking.LanePositions(lexical: lexical, semantic: semantic)
            let finalScores = fusedScores.reduce(into: [String: Double]()) { scores, entry in
                guard let candidate = candidatesByID[entry.key] else { return }
                let state = salienceByID[entry.key] ?? (hitCount: 0, lastReinforcedAt: nil)
                let salience = BurnBarMemoryRanking.salience(
                    kind: candidate.row.kind,
                    confidence: candidate.row.confidence,
                    accessCount: state.hitCount
                )
                let recency = BurnBarMemoryRanking.recencyFactor(
                    kind: candidate.row.kind,
                    updatedAt: candidate.row.updatedAt,
                    lastAccessedAt: state.lastReinforcedAt,
                    now: now
                )
                scores[entry.key] = entry.value * (0.6 + 0.4 * min(1.0, max(0.0, salience))) * recency
                whyByID[entry.key] = BurnBarMemoryRanking.why(
                    id: entry.key,
                    lanes: lanes,
                    salience: salience,
                    recency: recency
                )
            }
            let rankedIDs = finalScores.keys.sorted { lhs, rhs in
                let lhsScore = finalScores[lhs] ?? 0
                let rhsScore = finalScores[rhs] ?? 0
                if lhsScore != rhsScore { return lhsScore > rhsScore }
                let lhsUpdatedAt = candidatesByID[lhs]?.row.updatedAt ?? ""
                let rhsUpdatedAt = candidatesByID[rhs]?.row.updatedAt ?? ""
                return lhsUpdatedAt == rhsUpdatedAt ? lhs < rhs : lhsUpdatedAt < rhsUpdatedAt
            }
            let selectedIDs = Array(rankedIDs.prefix(limit))
            let reinforcedAt = Self.isoNow()
            for id in selectedIDs {
                guard let candidate = candidatesByID[id] else { continue }
                let nextHitCount = (salienceByID[id]?.hitCount ?? 0) + 1
                let nextSalience = BurnBarMemoryRanking.salience(
                    kind: candidate.row.kind,
                    confidence: candidate.row.confidence,
                    accessCount: nextHitCount
                )
                try execute(
                    """
                    INSERT INTO memory_salience
                        (memory_id, salience, hit_count, last_reinforced_at, corroboration, source_trust, computed_at, updated_at)
                    VALUES (?, ?, ?, ?, 1, ?, ?, ?)
                    ON CONFLICT(memory_id) DO UPDATE SET
                        salience = excluded.salience,
                        hit_count = excluded.hit_count,
                        last_reinforced_at = excluded.last_reinforced_at,
                        computed_at = excluded.computed_at,
                        updated_at = excluded.updated_at
                    """,
                    [
                        .text(id), .double(nextSalience), .int(nextHitCount), .text(reinforcedAt),
                        .double(1.0), .text(reinforcedAt), .text(reinforcedAt)
                    ]
                )
            }
            return selectedIDs.enumerated().compactMap { index, id in
                guard let candidate = candidatesByID[id] else { return nil }
                return BurnBarProjectMemoryHit(
                    memoryID: candidate.row.id,
                    projectID: candidate.row.projectID,
                    kind: candidate.row.kind,
                    scope: candidate.row.scope,
                    confidence: candidate.row.confidence,
                    bodyRedacted: candidate.body,
                    tags: candidate.row.tags,
                    sourcePath: candidate.row.sourcePath,
                    snippet: Self.memorySnippet(body: candidate.body, tokens: tokens, fallbackQuery: query),
                    rank: Double(index),
                    reviewStatus: candidate.row.reviewStatus,
                    matchedBy: whyByID[id]?.matchedBy,
                    why: whyByID[id]?.why
                )
            }
        }
        return BurnBarProjectMemoryRecallResponse(traceID: traceID, projectID: projectID, hits: hits)
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
                total: try fetchInt("SELECT COUNT(*) FROM agent_memories WHERE project_id = ? AND review_status != 'forgotten'", [.text(projectID)]),
                byKind: try groupedCounts("SELECT kind, COUNT(*) FROM agent_memories WHERE project_id = ? AND review_status != 'forgotten' GROUP BY kind", [.text(projectID)]),
                byScope: try groupedCounts("SELECT scope, COUNT(*) FROM agent_memories WHERE project_id = ? AND review_status != 'forgotten' GROUP BY scope", [.text(projectID)]),
                lastAuditHash: try queryRows("SELECT hash FROM memory_audit ORDER BY seq DESC LIMIT 1", []).first?.optionalString(0)
            )
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

    func auditEvent(
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
        // Shared builder with the 2.1c-iii app lane: identical keys and
        // encoding, so both lanes commit to identical bytes.
        let payload = try Self.memoryAuditPayloadData(
            seq: nextSequence,
            ts: ts,
            actor: "daemon",
            action: action,
            domain: domain,
            projectID: projectID,
            subjectID: subjectID,
            labels: normalizedLabels,
            prevHash: prevHash
        )
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

    func insertSearchDocument(
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

    func insertSearchChunk(
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

    struct PreparedCodeChunk {
        let chunk: CodeChunk
        let embeddingVector: [Float]?
    }

    func codeEmbeddingVector(for text: String) -> [Float]? {
        guard embeddingProvider.isAvailable else { return nil }
        return embeddingProvider.embed(text)
    }

    func deleteCodeArtifact(artifactID: String) throws {
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

    func produceCodeDiagnostics(
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

    func upsertFileManifest(
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
            "hosted code sync remains disabled unless an explicit code asset-class flag is enabled"
        ]
        if embeddingProvider.isAvailable == false {
            reasons.append("real local embeddings are not configured; semanticAvailable=false")
        }
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

    func suspendProjectWatchersForSnapshot() -> [BurnBarProjectCodeWatchProjectRequest] {
        let requests = projectWatchers.values.map { watcher in
            BurnBarProjectCodeWatchProjectRequest(
                projectPath: watcher.projectRoot.path,
                maxFiles: watcher.maxFiles,
                maxFileBytes: watcher.maxFileBytes,
                storageBudgetBytes: watcher.storageBudgetBytes,
                pollIntervalSeconds: watcher.pollIntervalSeconds
            )
        }
        for watcher in projectWatchers.values {
            watcher.timer.cancel()
            watcher.teardownEventStream()
        }
        projectWatchers.removeAll()
        return requests
    }

    func resumeProjectWatchersAfterSnapshot(_ requests: [BurnBarProjectCodeWatchProjectRequest]) throws {
        for request in requests {
            _ = try watchProject(request)
        }
    }
}
