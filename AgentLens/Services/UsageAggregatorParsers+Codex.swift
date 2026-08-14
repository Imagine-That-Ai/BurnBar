import Foundation
import GRDB
import OpenBurnBarCore

// Codex + OpenClaw log parsers.
// Extracted from UsageAggregatorParsers.swift (god-file decomposition).
//
// 2026-07-16 resource-exhaustion fix: all Codex rollout-file scanning —
// incremental token extraction, conversation parsing, budgets, memory
// checkpoints, and the on-disk cache shape — now lives in Core's
// `CodexSessionLogScanner` and is shared byte-for-byte with the Windows-port
// `OpenBurnBarCore.CodexParser`. This class only fetches `threads` rows via
// GRDB (materialized, connection closed) and delegates.

/// Reads token usage from Codex's SQLite store and JSONL session files.
/// Prefers exact token breakdowns from JSONL `token_count` events over the aggregate `tokens_used` in SQLite.
final class CodexParser: OpenBurnBarCore.LogParser, Sendable {
    let provider: AgentProvider = .codex
    private let fileManager: FileManager
    private let appPaths: OpenBurnBarCore.OpenBurnBarAppPaths
    private let cacheURL: URL
    private let homeDirectoryURL: URL
    private let cacheStore: OpenBurnBarCore.ParserDiskCacheStore<OpenBurnBarCore.CodexCacheEntry>

    init(
        fileManager: FileManager = .default,
        appPaths: OpenBurnBarCore.OpenBurnBarAppPaths = .live(),
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.fileManager = fileManager
        self.appPaths = appPaths
        self.homeDirectoryURL = homeDirectoryURL
        self.cacheURL = appPaths.supportDirectory.appendingPathComponent("codex_parser_cache.json")
        self.cacheStore = OpenBurnBarCore.ParserDiskCacheStore(
            cacheURL: cacheURL,
            fileManager: fileManager,
            schemaVersion: 6,
            logLabel: "CodexParser"
        )
        ParserSupportDirectoryWarmUp.prepare(fileManager: fileManager, appPaths: appPaths)
    }

    func parse() async throws -> OpenBurnBarCore.ParseResult {
        try await parse(options: .default)
    }

    func parse(options: OpenBurnBarCore.LogParseOptions) async throws -> OpenBurnBarCore.ParseResult {
        let dbPath = homeDirectoryURL
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("state_5.sqlite", isDirectory: false)
            .path

        guard fileManager.fileExists(atPath: dbPath) else {
            return OpenBurnBarCore.ParseResult(usages: [], conversations: [])
        }

        // Rows first, connection closed, then file scanning — never hold a
        // read snapshot on Codex's live database across multi-second file
        // work (a pinned snapshot starves Codex's own WAL checkpoints).
        let fetched = try fetchThreadRows(dbPath: dbPath)
        let parsed = try OpenBurnBarCore.CodexSessionLogScanner.processThreadRows(
            fetched.rows,
            options: options,
            fileManager: fileManager,
            cacheStore: cacheStore
        )
        let invalidations = Set(fetched.usageSessionIDsToDelete)
            .union(parsed.usageSessionIDsToDelete)
        return OpenBurnBarCore.ParseResult(
            usages: parsed.usages,
            conversations: parsed.conversations,
            usageSessionIDsToDelete: invalidations.sorted()
        )
    }

    private func fetchThreadRows(dbPath: String) throws -> (
        rows: [OpenBurnBarCore.CodexThreadRow],
        usageSessionIDsToDelete: [String]
    ) {
        var config = Configuration()
        config.readonly = true
        let db = try DatabaseQueue(path: dbPath, configuration: config)
        defer { try? db.close() } // try?-ok(read-only teardown)

        return try db.read { db in
            // Check if rollout_path column exists
            let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(threads)")
            let columnNames = Set(columns.compactMap { $0["name"] as? String })
            let hasRolloutPath = columnNames.contains("rollout_path")
            let hasThreadSource = columnNames.contains("thread_source")

            let subagentSessionIDs: Set<String>
            if hasThreadSource {
                subagentSessionIDs = Set(try String.fetchAll(
                    db,
                    sql: "SELECT id FROM threads WHERE thread_source = 'subagent'"
                ))
            } else if hasRolloutPath {
                let cleanupRows = try Row.fetchAll(db, sql: "SELECT id, rollout_path FROM threads")
                subagentSessionIDs = Set(cleanupRows.compactMap { row -> String? in
                    guard let threadID: String = row["id"],
                          let rolloutPath: String = row["rollout_path"] else { return nil }
                    let expandedPath = (rolloutPath as NSString).expandingTildeInPath
                    return isCodexSubagentRollout(expandedPath) ? threadID : nil
                })
            } else {
                subagentSessionIDs = []
            }

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
                    -- changed most recently so long-running parents active
                    -- today are repaired before newer but idle sessions.
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

            let rows = try Row.fetchAll(db, sql: sql)
            var threadRows: [OpenBurnBarCore.CodexThreadRow] = []
            threadRows.reserveCapacity(rows.count)

            for row in rows {
                guard let threadId: String = row["id"],
                      let createdAt: Int64 = row["created_at"],
                      let updatedAt: Int64 = row["updated_at"] else {
                    continue
                }
                let cwd: String = row["cwd"] ?? "~"
                let rolloutPath: String? = hasRolloutPath ? (row["rollout_path"] as? String) : nil
                guard !subagentSessionIDs.contains(threadId) else { continue }
                threadRows.append(
                    OpenBurnBarCore.CodexThreadRow(
                        threadId: threadId,
                        model: row["model"] ?? "unknown",
                        rawTitle: row["title"] ?? "",
                        projectName: (cwd as NSString).lastPathComponent,
                        tokensUsed: row["tokens_used"] ?? 0,
                        startTime: Date(timeIntervalSince1970: Double(createdAt)),
                        endTime: Date(timeIntervalSince1970: Double(updatedAt)),
                        expandedRolloutPath: rolloutPath.map { ($0 as NSString).expandingTildeInPath }
                    )
                )
            }
            return (threadRows, subagentSessionIDs.sorted())
        }
    }

    private func isCodexSubagentRollout(_ path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() } // try?-ok(read-only teardown)

        let prefix: Data
        do {
            guard let data = try handle.read(upToCount: 256 * 1024),
                  !data.isEmpty else { return false }
            prefix = data
        } catch {
            return false
        }

        let text = String(decoding: prefix, as: UTF8.self)
        for line in text.split(separator: "\n", maxSplits: 15, omittingEmptySubsequences: true) {
            guard let data = String(line).data(using: .utf8) else { continue }
            let json: [String: Any]
            do {
                guard let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    continue
                }
                json = decoded
            } catch {
                continue
            }
            guard json["type"] as? String == "session_meta",
                  let payload = json["payload"] as? [String: Any],
                  let source = payload["source"] as? [String: Any] else { continue }
            return source["subagent"] != nil
        }
        return false
    }
}

/// Parses OpenClaw JSON/JSONL session history from `~/.openclaw/sessions`.
///
/// OpenClaw is intentionally treated as a provider-log source, not a live
/// runtime bridge. The live OpenClaw chat path remains `ChatSessionController`;
/// this parser only gives mobile and cloud search a durable archive surface.
final class OpenClawParser: OpenBurnBarCore.LogParser, Sendable {
    let provider: AgentProvider = .openClaw

    private let fileManager: FileManager
    private let sessionsDirectory: URL
    private let cacheStore: OpenBurnBarCore.ParserDiskCacheStore<OpenBurnBarCore.CachedUsageBundleEntry<OpenBurnBarCore.FileSignature>>
    private let sessionScanCount = OpenBurnBarCore.Locked(0)
    private let sessionCacheHitCount = OpenBurnBarCore.Locked(0)

    init(
        fileManager: FileManager = .default,
        sessionsDirectory: URL = URL(fileURLWithPath: (AgentProvider.openClaw.logDirectory as NSString).expandingTildeInPath),
        appPaths: OpenBurnBarCore.OpenBurnBarAppPaths = .live()
    ) {
        self.fileManager = fileManager
        self.sessionsDirectory = sessionsDirectory
        let usesOverride = sessionsDirectory.path != (AgentProvider.openClaw.logDirectory as NSString).expandingTildeInPath
        let cacheURL = usesOverride
            ? sessionsDirectory.appendingPathComponent(".obb-mac-openclaw-parser-cache.plist")
            : appPaths.macOpenClawParserCacheURL
        self.cacheStore = OpenBurnBarCore.ParserDiskCacheStore(
            cacheURL: cacheURL,
            fileManager: fileManager,
            schemaVersion: 1,
            logLabel: "MacOpenClawParser"
        )
        ParserSupportDirectoryWarmUp.prepare(fileManager: fileManager, appPaths: appPaths)
    }

    var lastSessionScanCount: Int { sessionScanCount.read() }
    var lastSessionCacheHitCount: Int { sessionCacheHitCount.read() }

    func parse(options: OpenBurnBarCore.LogParseOptions) async throws -> OpenBurnBarCore.ParseResult {
        sessionScanCount.write(0)
        sessionCacheHitCount.write(0)
        guard fileManager.fileExists(atPath: sessionsDirectory.path) else {
            return OpenBurnBarCore.ParseResult(usages: [], conversations: [])
        }

        let gate = OpenBurnBarCore.ParserFileReadGate(options: options, fileManager: fileManager)
        let files = sessionFiles(in: sessionsDirectory)
        var conversations: [OpenBurnBarCore.ConversationRecord] = []
        var usages: [TokenUsage] = []
        var parseCache = cacheStore.load()
        var activePaths = Set<String>()
        var cacheMutated = false
        defer {
            if cacheMutated {
                cacheStore.persist(parseCache)
            }
        }

        for file in files {
            let cacheKey = file.standardizedFileURL.path
            activePaths.insert(cacheKey)
            guard try gate.shouldRead(file) else { continue }
            let signature = OpenBurnBarCore.FileSignature(for: file, using: fileManager)
            if !options.includeConversationBodies,
               let signature,
               let cached = parseCache.fileEntries[cacheKey],
               cached.signature == signature {
                sessionCacheHitCount.withLock { $0 += 1 }
                usages.append(contentsOf: cached.sessions.map { $0.makeUsage(provider: .openClaw) })
                continue
            }
            sessionScanCount.withLock { $0 += 1 }
            guard let parsed = parseSession(file: file) else { continue }
            if options.includeConversationBodies {
                conversations.append(parsed.conversation)
            }
            if let usage = parsed.usage {
                usages.append(usage)
                if let signature {
                    parseCache.fileEntries[cacheKey] = OpenBurnBarCore.CachedUsageBundleEntry(
                        signature: signature,
                        usages: [usage]
                    )
                    cacheMutated = true
                }
            }
        }

        let stalePaths = Set(parseCache.fileEntries.keys).subtracting(activePaths)
        if !stalePaths.isEmpty {
            for stalePath in stalePaths {
                parseCache.fileEntries.removeValue(forKey: stalePath)
            }
            cacheMutated = true
        }

        return OpenBurnBarCore.ParseResult(usages: usages, conversations: conversations)
    }

    private func sessionFiles(in directory: URL) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [URL] = []
        while let url = enumerator.nextObject() as? URL {
            let ext = url.pathExtension.lowercased()
            guard ext == "jsonl" || ext == "json" || ext == "log" else { continue }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey]) // try?-ok(isRegularFile probe)
            guard values?.isRegularFile == true else { continue }
            files.append(url)
        }
        return files.sorted { lhs, rhs in
            let lm = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast // try?-ok(sort mtime fallback)
            let rm = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast // try?-ok(sort mtime fallback)
            return lm > rm
        }
    }

    private func parseSession(file: URL) -> (usage: TokenUsage?, conversation: OpenBurnBarCore.ConversationRecord)? {
        var turns: [(role: String, text: String, timestamp: Date?)] = []
        var inputTokens = 0
        var outputTokens = 0
        var cacheReadTokens = 0
        var model = "openclaw"
        var startTime: Date?
        var endTime: Date?

        Self.enumerateSessionObjects(from: file, fileManager: fileManager) { object in
            let timestamp = Self.timestamp(in: object)
            if startTime == nil { startTime = timestamp }
            endTime = timestamp ?? endTime
            if let discoveredModel = Self.nonBlank(Self.firstString(in: object, keys: ["model", "modelName", "model_name"])) {
                model = discoveredModel
            }
            let usage = OpenBurnBarCore.TokenExtractionUtility.extractUsageTokens(object["usage"] as? [String: Any] ?? object["tokenUsage"] as? [String: Any] ?? [:])
            inputTokens += usage.input
            outputTokens += usage.output
            cacheReadTokens += usage.cacheRead

            if let role = Self.role(in: object), let text = Self.nonBlank(Self.content(in: object)) {
                turns.append((role: role, text: text, timestamp: timestamp))
            } else if let message = object["message"] as? [String: Any],
                      let role = Self.role(in: message),
                      let text = Self.nonBlank(Self.content(in: message)) {
                turns.append((role: role, text: text, timestamp: timestamp ?? Self.timestamp(in: message)))
            }
        }

        guard !turns.isEmpty else { return nil }

        let sessionId = file.deletingPathExtension().lastPathComponent
        let modifiedAt = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date() // try?-ok(mtime, now fallback)
        let effectiveStart = startTime ?? turns.compactMap(\.timestamp).min() ?? modifiedAt
        let effectiveEnd = endTime ?? turns.compactMap(\.timestamp).max() ?? modifiedAt
        let userText = turns.filter { $0.role == "user" }.map(\.text)
        let assistantText = turns.filter { $0.role == "assistant" }.map(\.text)
        let fullText: String = turns.map { turn in
            let heading: String = turn.role == "user" ? "## User" : turn.role == "assistant" ? "## Assistant" : "## \(turn.role.capitalized)"
            return "\(heading)\n\n\(turn.text)"
        }.joined(separator: "\n\n")
        let firstUser = userText.first?.trimmingCharacters(in: .whitespacesAndNewlines)
        let lastAssistant = assistantText.last ?? ""
        let title = firstUser.map { String($0.prefix(120)) } ?? "OpenClaw Session"

        if inputTokens == 0 && outputTokens == 0 {
            inputTokens = OpenBurnBarCore.TokenExtractionUtility.estimatedTokenCount(for: userText.joined(separator: "\n").count, charsPerToken: 3.5)
            outputTokens = OpenBurnBarCore.TokenExtractionUtility.estimatedTokenCount(for: assistantText.joined(separator: "\n").count, charsPerToken: 3.5)
        }

        let cost = AppLogger.shared.silentlyOptional("domain_core_pricing_cost", try OpenBurnBarCore.ModelPricing.lookup(model: model).cost(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: cacheReadTokens
        ))
        let usage: TokenUsage? = (inputTokens > 0 || outputTokens > 0) ? cost.map { computedCost in TokenUsage(
            provider: .openClaw,
            sessionId: sessionId,
            projectName: "OpenClaw",
            model: model,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheCreationTokens: 0,
            cacheReadTokens: cacheReadTokens,
            costUSD: computedCost,
            startTime: effectiveStart,
            endTime: effectiveEnd,
            provenanceMethod: cacheReadTokens > 0 ? .providerLog : .heuristicEstimate,
            provenanceConfidence: cacheReadTokens > 0 ? .exact : .lowConfidenceEstimate,
            estimatorVersion: cacheReadTokens > 0 ? "" : OpenBurnBarCore.TokenExtractionUtility.currentEstimatorVersion
        ) } : nil

        let conversation = OpenBurnBarCore.ConversationRecord(
            id: OpenBurnBarCore.ConversationRecord.stableId(provider: .openClaw, sessionId: sessionId),
            provider: .openClaw,
            sessionId: sessionId,
            projectName: "OpenClaw",
            startTime: effectiveStart,
            endTime: effectiveEnd,
            messageCount: turns.count,
            userWordCount: userText.joined(separator: " ").split(separator: " ").count,
            assistantWordCount: assistantText.joined(separator: " ").split(separator: " ").count,
            keyFiles: [],
            keyCommands: [],
            keyTools: [],
            inferredTaskTitle: title,
            lastAssistantMessage: lastAssistant,
            fullText: fullText,
            indexedAt: Date(),
            fileModifiedAt: modifiedAt,
            summary: nil
        )
        return (usage, conversation)
    }

    /// Streams session objects to `handler` without materializing whole files.
    ///
    /// JSONL-style content is decoded line by line (buffered reads, one
    /// `parserAutoReleasePool` per line — the JSON object graphs are
    /// autoreleased on Darwin and parse loops run in contexts that never
    /// drain). Only when a file yields no line objects does the legacy
    /// whole-file JSON fallback run.
    private static func enumerateSessionObjects(
        from file: URL,
        fileManager: FileManager,
        handler: ([String: Any]) -> Void
    ) {
        var yieldedLineObject = false
        if let handle = try? FileHandle(forReadingFrom: file) { // try?-ok(unreadable file falls back below)
            defer { try? handle.close() } // try?-ok(handle teardown)
            for line in handle.readAllUTF8Lines() {
                parserAutoReleasePool {
                    guard let lineData = line.data(using: .utf8),
                          let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { // try?-ok(per-line decode, skip)
                        return
                    }
                    yieldedLineObject = true
                    handler(object)
                }
            }
        }
        guard !yieldedLineObject else { return }

        // Whole-file fallback: single-document JSON sessions (arrays or
        // nested `messages`/`turns`/… containers).
        guard let data = try? Data(contentsOf: file) else { return } // try?-ok(session read, skip if absent)
        parserAutoReleasePool {
            guard let root = try? JSONSerialization.jsonObject(with: data) else { return } // try?-ok(whole-file decode, empty fallback)
            for object in flattenSessionObjects(root) {
                handler(object)
            }
        }
    }

    private static func flattenSessionObjects(_ value: Any) -> [[String: Any]] {
        if let array = value as? [Any] {
            return array.flatMap(flattenSessionObjects)
        }
        guard let object = value as? [String: Any] else { return [] }

        let nestedKeys = ["messages", "turns", "events", "conversation", "history", "items"]
        let nested = nestedKeys.flatMap { key -> [[String: Any]] in
            guard let value = object[key] else { return [] }
            return flattenSessionObjects(value)
        }
        return nested.isEmpty ? [object] : nested
    }

    private static func role(in object: [String: Any]) -> String? {
        firstString(in: object, keys: ["role", "author", "speaker"])?.lowercased()
    }

    private static func content(in object: [String: Any]) -> String? {
        if let text = firstString(in: object, keys: ["content", "text", "message", "delta"]) {
            return text
        }
        if let content = object["content"] as? [[String: Any]] {
            return content.compactMap { firstString(in: $0, keys: ["text", "content"]) }.joined(separator: "\n")
        }
        return nil
    }

    private static func firstString(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = object[key] as? String { return value }
        }
        return nil
    }

    private static func nonBlank(_ string: String?) -> String? {
        guard let trimmed = string?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func timestamp(in object: [String: Any]) -> Date? {
        for key in ["timestamp", "createdAt", "created_at", "time"] {
            if let string = object[key] as? String {
                // Shared lenient parser: accepts fractional seconds (default
                // ISO8601DateFormatter() rejects them) without per-call allocation.
                // Numeric-epoch fallback below is unaffected: numeric strings never
                // parse as ISO8601.
                if let date = ThreadSafeISO8601DateFormatter.parse(string) { return date }
                if let seconds = Double(string) { return Date(timeIntervalSince1970: seconds) }
            }
            if let seconds = object[key] as? Double { return Date(timeIntervalSince1970: seconds) }
            if let seconds = object[key] as? Int { return Date(timeIntervalSince1970: TimeInterval(seconds)) }
        }
        return nil
    }
}
