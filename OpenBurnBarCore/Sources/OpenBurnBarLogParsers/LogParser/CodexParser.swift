import Foundation
import OpenBurnBarKernel
import OpenBurnBarSQLiteReader

// MARK: - Codex Parser
//
// Windows-port Phase-2 (G2 parser lift, `docs/WINDOWS_PORT_MASTER_PLAN.md`). Lifted
// from the macOS app (`AgentLens/Services/UsageAggregatorParsers+Codex.swift`),
// with ONE structural difference: the GRDB `DatabaseQueue`/`Row.fetchAll` reads of
// the plain `state_5.sqlite` `threads` table are routed through the Foundation-only
// SQLite reader seam (`SQLiteConnection` + `SQLiteRow`, `Services/SQLite/`), whose
// typed getters reproduce GRDB's coercion exactly. The token/cost/model/session
// projection logic is byte-for-byte unchanged, and the rollout-file scanning is
// shared with the app copy via `CodexSessionLogScanner` — fix that scanner, fix both.

/// Reads token usage from Codex's SQLite store and JSONL session files.
/// Prefers exact token breakdowns from JSONL `token_count` events over the aggregate `tokens_used` in SQLite.
///
/// Resource behavior (2026-07-16 incident fix):
///  * rollout files are scanned **incrementally** — each cache entry carries a
///    `CodexTokenScanState` (byte offset + token accumulator), so a grown
///    append-only file costs only its new tail;
///  * scans are **governed** — `LogParseOptions.resourceGovernor` bounds the
///    bytes of new content per pass (files beyond the budget are deferred to
///    the next tick) and aborts on the process memory ceiling;
///  * `minimumFileModificationDate` defers files (by modification date) from
///    content reads entirely, per the `LogParseOptions` contract;
///  * the SQLite reader is closed **before** any file scanning starts, so
///    Codex's own database never has a read snapshot pinned across a scan;
///  * conversation bodies are never written to the on-disk parser cache.
public final class CodexParser: LogParser, Sendable {
    public let provider: AgentProvider = .codex
    private let fileManager: FileManager
    private let appPaths: OpenBurnBarAppPaths
    private let cacheURL: URL
    private let homeDirectoryURL: URL
    private let cacheStore: ParserDiskCacheStore<CodexCacheEntry>

    public init(
        fileManager: FileManager = .default,
        appPaths: OpenBurnBarAppPaths = .live(),
        homeDirectoryURL: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    ) {
        self.fileManager = fileManager
        self.appPaths = appPaths
        self.homeDirectoryURL = homeDirectoryURL
        self.cacheURL = appPaths.supportDirectory.appendingPathComponent("codex_parser_cache.json")
        self.cacheStore = ParserDiskCacheStore(
            cacheURL: cacheURL,
            fileManager: fileManager,
            schemaVersion: 6,
            logLabel: "CodexParser"
        )
        _ = try? OpenBurnBarMigration.prepareSupportDirectory(fileManager: fileManager, paths: appPaths) // try?-ok(best-effort dir prep)
    }

    public func parse() async throws -> ParseResult {
        try await parse(options: .default)
    }

    public func parse(options: LogParseOptions) async throws -> ParseResult {
        try parseSynchronously(options: options)
    }

    public func parseSynchronously(options: LogParseOptions) throws -> ParseResult {
        let dbURL = homeDirectoryURL
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("state_5.sqlite", isDirectory: false)

        guard fileManager.fileExists(atPath: dbURL.path) else {
            return ParseResult(usages: [], conversations: [])
        }

        // The state database is a metadata-only enumeration index, not rollout
        // content. Charging its on-disk size to the rollout byte budget
        // can starve every rollout forever when the index is larger than one
        // pass. Account for the metadata probe and enforce memory checkpoints,
        // but reserve the byte budget for the rollout bytes actually scanned.
        options.metrics?.recordCandidate()
        options.metrics?.recordMetadataStat()
        try options.resourceGovernor?.checkpoint()

        let parsed = try parseCodexDatabase(dbPath: dbURL.path, options: options)
        return ParseResult(
            usages: parsed.usages,
            conversations: parsed.conversations,
            usageSessionIDsToDelete: parsed.usageSessionIDsToDelete
        )
    }

    private func fetchThreadRows(
        dbPath: String,
        governor: ParserResourceGovernor?
    ) throws -> (rows: [CodexThreadRow], usageSessionIDsToDelete: [String]) {
        // Read-only, plain SQLite (matches GRDB `Configuration.readonly = true`).
        try governor?.checkpoint()
        let reader = try SQLiteConnection.openReadOnly(path: dbPath)
        defer { reader.close() }

        // Check if rollout_path column exists.
        let columnNames = Set(try reader.columnNames(ofTable: "threads"))
        try governor?.checkpoint()
        let hasRolloutPath = columnNames.contains("rollout_path")
        let hasThreadSource = columnNames.contains("thread_source")

        let subagentSessionIDs: Set<String>
        if hasThreadSource {
            subagentSessionIDs = Set(try reader.query(
                "SELECT id FROM threads WHERE thread_source = 'subagent'"
            ).compactMap { $0.string("id") })
        } else if hasRolloutPath {
            // Legacy databases have no `thread_source`, and path markers alone
            // miss the common case: subagent rollouts sit at ordinary
            // date/UUID session paths and declare themselves only in
            // `session_meta.payload.source.subagent`. Admitting them would
            // double-count their tokens against the parent and leave already
            // imported subagent rows uninvalidated.
            //
            // Reading every rollout to sniff that metadata used to stall usage
            // refresh on large ~/.codex trees (hundreds of GB of
            // tmp/clones/sessions) and starve every later parser, so the
            // fallback is bounded on all three axes: a small head read per
            // file (`subagentMetadataHeadByteLimit`), only the first records of
            // that head (`subagentMetadataSniffLineLimit`), and a per-pass file
            // cap (`subagentMetadataSniffFileLimit`) spent on live, most
            // recently updated threads first. Like the metadata probe above,
            // these classification bytes stay off the rollout byte budget —
            // worst case is 32MB of file heads, and charging them could
            // starve the rollout scan they exist to protect.
            var subagentIDs: Set<String> = []
            var sniffedFiles = 0
            let candidates = try reader.query(
                "SELECT id, rollout_path FROM threads ORDER BY archived ASC, updated_at DESC"
            )
            for (index, row) in candidates.enumerated() {
                if index.isMultiple(of: 128) {
                    try governor?.checkpoint()
                }
                guard let threadID = row.string("id"),
                      let rolloutPath = row.string("rollout_path") else { continue }
                let expandedPath = (rolloutPath as NSString).expandingTildeInPath
                if Self.rolloutPathLooksLikeSubagent(expandedPath) {
                    subagentIDs.insert(threadID)
                    continue
                }
                guard sniffedFiles < Self.subagentMetadataSniffFileLimit else { continue }
                sniffedFiles += 1
                if Self.rolloutHeadDeclaresSubagent(atPath: expandedPath) {
                    subagentIDs.insert(threadID)
                }
            }
            subagentSessionIDs = subagentIDs
        } else {
            subagentSessionIDs = []
        }
        try governor?.checkpoint()

        let sql: String
        if hasRolloutPath {
            let sourceFilter = hasThreadSource
                ? "AND (thread_source IS NULL OR thread_source != 'subagent')"
                : ""
            sql = """
                SELECT
                    id, title, model, model_provider, tokens_used,
                    created_at, updated_at, cwd, rollout_path
                FROM threads
                WHERE archived = 0
                \(sourceFilter)
                -- The scanner is byte-budgeted. Prioritize threads that
                -- changed most recently so long-running parents active today
                -- are repaired before newer but idle sessions.
                ORDER BY updated_at DESC
            """
        } else {
            sql = """
                SELECT
                    id, title, model, model_provider, tokens_used,
                    created_at, updated_at, cwd
                FROM threads
                WHERE archived = 0
                ORDER BY updated_at DESC
            """
        }

        let rows = try reader.query(sql)
        try governor?.checkpoint()
        var threadRows: [CodexThreadRow] = []
        threadRows.reserveCapacity(rows.count)

        for (index, row) in rows.enumerated() {
            if index.isMultiple(of: 128) {
                try governor?.checkpoint()
            }
            guard let threadId: String = row.string("id"),
                  let createdAt: Int64 = row.int64("created_at"),
                  let updatedAt: Int64 = row.int64("updated_at") else {
                continue
            }
            let cwd: String = row.string("cwd") ?? "~"
            let rolloutPath: String? = hasRolloutPath ? row.string("rollout_path") : nil
            guard !subagentSessionIDs.contains(threadId) else { continue }
            threadRows.append(
                CodexThreadRow(
                    threadId: threadId,
                    model: row.string("model") ?? "unknown",
                    rawTitle: row.string("title") ?? "",
                    projectName: (cwd as NSString).lastPathComponent,
                    tokensUsed: row.int("tokens_used") ?? 0,
                    startTime: Date(timeIntervalSince1970: Double(createdAt)),
                    endTime: Date(timeIntervalSince1970: Double(updatedAt)),
                    expandedRolloutPath: rolloutPath.map { ($0 as NSString).expandingTildeInPath }
                )
            )
        }
        return (threadRows, subagentSessionIDs.sorted())
    }

    private func parseCodexDatabase(
        dbPath: String,
        options: LogParseOptions
    ) throws -> (
        usages: [TokenUsage],
        conversations: [ConversationRecord],
        usageSessionIDsToDelete: [String]
    ) {
        // Rows first, reader closed, then file scanning — never hold a read
        // connection on Codex's live database across multi-second file work.
        let fetched = try fetchThreadRows(
            dbPath: dbPath,
            governor: options.resourceGovernor
        )
        let parsed = try CodexSessionLogScanner.processThreadRows(
            fetched.rows,
            options: options,
            fileManager: fileManager,
            cacheStore: cacheStore
        )
        let invalidations = Set(fetched.usageSessionIDsToDelete)
            .union(parsed.usageSessionIDsToDelete)
        return (parsed.usages, parsed.conversations, invalidations.sorted())
    }

    public static func rolloutPathLooksLikeSubagent(_ path: String) -> Bool {
        let standardized = (path as NSString).standardizingPath.lowercased()
        let markers = ["/subagents/", "/subagent/", "-subagent-", "_subagent_"]
        return markers.contains { standardized.contains($0) }
    }

    /// Bytes read from the head of one rollout when classifying it. The
    /// subagent keys sit in the `session_meta` preamble — at most ~700B into
    /// every rollout of a real 974-file ~/.codex corpus — so this leaves 10x
    /// headroom while staying far cheaper than the record itself, whose
    /// embedded `base_instructions` push the median first line past 19KB.
    static let subagentMetadataHeadByteLimit = 8 * 1024
    /// Records parsed inside that head. `session_meta` is the first record
    /// Codex writes; the slack absorbs preamble lines without reading bodies.
    static let subagentMetadataSniffLineLimit = 8
    /// Rollouts head-read per pass on legacy (no `thread_source`) databases.
    /// Bounds the fallback at 32MB of I/O against a 16–256MB pass budget, and
    /// comfortably covers real thread tables (1751 rows on the corpus above,
    /// head-read in 0.16s). Threads past the cap keep path-marker
    /// classification for this pass.
    static let subagentMetadataSniffFileLimit = 4096

    /// Whether a rollout's `session_meta` record declares it a subagent
    /// thread. Bounded by design — see `subagentMetadataHeadByteLimit` — so
    /// legacy databases can be classified without opening rollout bodies.
    public static func rolloutHeadDeclaresSubagent(atPath path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() } // try?-ok(read-only teardown)

        guard let head = try? handle.read(upToCount: subagentMetadataHeadByteLimit),
              !head.isEmpty else { return false }

        let text = String(decoding: head, as: UTF8.self)
        if headDeclaresSubagentKey(text) { return true }

        // Whitespace-formatted or string-tagged variants the raw key scan
        // cannot match. Only complete lines decode; a first record longer than
        // the head is exactly the case the scan above already covers.
        let lines = text
            .split(
                separator: "\n",
                maxSplits: subagentMetadataSniffLineLimit,
                omittingEmptySubsequences: true
            )
            .prefix(subagentMetadataSniffLineLimit)
        for line in lines {
            guard let data = String(line).data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["type"] as? String == "session_meta",
                  let payload = json["payload"] as? [String: Any] else { continue }
            return payloadDeclaresSubagent(payload)
        }
        return false
    }

    /// Raw-key scan over the head. Codex writes compact JSON and `session_meta`
    /// is the first record, but that record is routinely larger than the head,
    /// so decoding it whole is not an option — these keys are read where they
    /// lie. A raw `"` never occurs inside JSON string content (it is escaped),
    /// so a hit can only come from record structure, never from a rollout body
    /// that merely discusses subagents.
    private static func headDeclaresSubagentKey(_ text: String) -> Bool {
        text.contains("\"thread_source\":\"subagent\"")
            || text.contains("\"source\":{\"subagent\"")
    }

    private static func payloadDeclaresSubagent(_ payload: [String: Any]) -> Bool {
        if (payload["thread_source"] as? String)?.lowercased() == "subagent" { return true }
        // Newer rollouts carry a structured `source` object; older ones a bare
        // string tag alongside `originator`.
        if let source = payload["source"] as? [String: Any] {
            if let subagent = source["subagent"], !(subagent is NSNull) { return true }
            return (source["type"] as? String)?.lowercased() == "subagent"
        }
        return (payload["source"] as? String)?.lowercased() == "subagent"
    }

}

public struct CodexTokenUsage: Codable, Equatable, Sendable {
    public let input: Int
    public let output: Int
    public let cacheRead: Int
    public let daily: [CodexDailyTokenUsage]

    public init(input: Int, output: Int, cacheRead: Int, daily: [CodexDailyTokenUsage] = []) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.daily = daily
    }
}

public struct CodexDailyTokenUsage: Codable, Equatable, Sendable {
    public let dayStart: Date
    public let endTime: Date
    public let input: Int
    public let output: Int
    public let cacheRead: Int

    public init(dayStart: Date, endTime: Date, input: Int, output: Int, cacheRead: Int) {
        self.dayStart = dayStart
        self.endTime = endTime
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
    }
}

public struct CodexConversationCacheEntry: Codable, Equatable, Sendable {
    public let title: String
    public let markdown: String
    public let messageCount: Int
    public let userWordCount: Int
    public let assistantWordCount: Int
    public let keyFiles: [String]
    public let keyCommands: [String]
    public let keyTools: [String]
    public let lastAssistantMessage: String

    public init(
        title: String,
        markdown: String,
        messageCount: Int,
        userWordCount: Int,
        assistantWordCount: Int,
        keyFiles: [String],
        keyCommands: [String],
        keyTools: [String],
        lastAssistantMessage: String
    ) {
        self.title = title
        self.markdown = markdown
        self.messageCount = messageCount
        self.userWordCount = userWordCount
        self.assistantWordCount = assistantWordCount
        self.keyFiles = keyFiles
        self.keyCommands = keyCommands
        self.keyTools = keyTools
        self.lastAssistantMessage = lastAssistantMessage
    }
}

/// v2 (schemaVersion 2): carries the incremental `scanState` and, by
/// construction, can no longer hold conversation bodies — parser caches are
/// privacy-transient for conversation text (PR #1808).
public struct CodexCacheEntry: Codable, Equatable, Sendable {
    public let signature: FileSignature
    public let tokenUsage: CodexTokenUsage?
    public let scanState: CodexTokenScanState?
    public let executionSource: UsageExecutionSource

    public init(
        signature: FileSignature,
        tokenUsage: CodexTokenUsage?,
        scanState: CodexTokenScanState?,
        executionSource: UsageExecutionSource = .unknown
    ) {
        self.signature = signature
        self.tokenUsage = tokenUsage
        self.scanState = scanState
        self.executionSource = executionSource
    }
}
