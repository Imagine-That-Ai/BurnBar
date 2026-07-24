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
            subagentSessionIDs = Set(try reader.query(
                "SELECT id, rollout_path FROM threads"
            ).compactMap { row -> String? in
                guard let threadID = row.string("id"),
                      let rolloutPath = row.string("rollout_path") else { return nil }
                let expandedPath = (rolloutPath as NSString).expandingTildeInPath
                return isCodexSubagentRollout(expandedPath) ? threadID : nil
            })
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

    private func isCodexSubagentRollout(_ path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() } // try?-ok(read-only teardown)

        guard let prefix = try? handle.read(upToCount: 256 * 1024),
              !prefix.isEmpty else { return false }

        let text = String(decoding: prefix, as: UTF8.self)
        for line in text.split(separator: "\n", maxSplits: 15, omittingEmptySubsequences: true) {
            guard let data = String(line).data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["type"] as? String == "session_meta",
                  let payload = json["payload"] as? [String: Any],
                  let source = payload["source"] as? [String: Any] else { continue }
            return source["subagent"] != nil
        }
        return false
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
