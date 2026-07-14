import Foundation
import CryptoKit
import GRDB
import OpenBurnBarCore

// Codex + OpenClaw log parsers and their cache entry types.
// Extracted from UsageAggregatorParsers.swift (god-file decomposition) — same module, verbatim.

/// Reads token usage from Codex's SQLite store and JSONL session files.
/// Prefers exact token breakdowns from JSONL `token_count` events over the aggregate `tokens_used` in SQLite.
final class CodexParser: OpenBurnBarCore.LogParser, Sendable {
    let provider: AgentProvider = .codex
    private let fileManager: FileManager
    private let appPaths: OpenBurnBarCore.OpenBurnBarAppPaths
    private let cacheURL: URL
    private let homeDirectoryURL: URL
    private let cacheStore: OpenBurnBarCore.ParserDiskCacheStore<CodexCacheEntry>

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
            schemaVersion: 3,
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

        let parsed = try parseCodexDatabase(
            dbPath: dbPath,
            includeConversationBodies: options.includeConversationBodies
        )
        return OpenBurnBarCore.ParseResult(
            usages: parsed.usages,
            conversations: parsed.conversations,
            usageSessionIDsToDelete: parsed.usageSessionIDsToDelete
        )
    }

    private func parseCodexDatabase(
        dbPath: String,
        includeConversationBodies: Bool
    ) throws -> (
        usages: [TokenUsage],
        conversations: [OpenBurnBarCore.ConversationRecord],
        usageSessionIDsToDelete: [String]
    ) {
        var usages: [TokenUsage] = []
        var conversations: [OpenBurnBarCore.ConversationRecord] = []
        var usageSessionIDsToDelete: [String] = []
        var sessionCache = cacheStore.load()
        var activePaths = Set<String>()
        var cacheMutated = false

        var config = Configuration()
        config.readonly = true
        let db = try DatabaseQueue(path: dbPath, configuration: config)

        try db.read { db in
            // Check if rollout_path column exists
            let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(threads)")
            let columnNames = Set(columns.compactMap { $0["name"] as? String })
            let hasRolloutPath = columnNames.contains("rollout_path")
            let hasThreadSource = columnNames.contains("thread_source")

            if hasRolloutPath {
                let sourceProjection = hasThreadSource ? ", thread_source" : ""
                let cleanupRows = try Row.fetchAll(
                    db,
                    sql: "SELECT id, rollout_path\(sourceProjection) FROM threads"
                )
                for cleanupRow in cleanupRows {
                    guard let threadId: String = cleanupRow["id"] else { continue }
                    let threadSource: String? = hasThreadSource ? cleanupRow["thread_source"] : nil
                    let rolloutPath: String? = cleanupRow["rollout_path"]
                    let expandedPath = rolloutPath.map { ($0 as NSString).expandingTildeInPath }
                    if threadSource == "subagent"
                        || (threadSource == nil && expandedPath.map(isCodexSubagentRollout) == true) {
                        usageSessionIDsToDelete.append(threadId)
                    }
                }
            }

        let sql: String
        if hasRolloutPath {
            let threadSourceProjection = hasThreadSource ? ", thread_source" : ""
            sql = """
                    SELECT
                        id, title, model, model_provider, tokens_used,
                        created_at, updated_at, cwd, rollout_path\(threadSourceProjection)
                    FROM threads
                    WHERE archived = 0
                    ORDER BY created_at DESC
                    LIMIT 500
                """
            } else {
                sql = """
                    SELECT
                        id, title, model, model_provider, tokens_used,
                        created_at, updated_at, cwd
                    FROM threads
                    WHERE archived = 0
                    ORDER BY created_at DESC
                    LIMIT 500
                """
            }

            let rows = try Row.fetchAll(db, sql: sql)

            for row in rows {
                guard let threadId: String = row["id"],
                      let createdAt: Int64 = row["created_at"],
                      let updatedAt: Int64 = row["updated_at"] else {
                    continue
                }

                let model: String = row["model"] ?? "unknown"
                let rawTitle: String = row["title"] ?? ""
                let cwd: String = row["cwd"] ?? "~"
                let projectName = (cwd as NSString).lastPathComponent
                let startTime = Date(timeIntervalSince1970: Double(createdAt))
                let endTime = Date(timeIntervalSince1970: Double(updatedAt))
                let rolloutPath: String? = hasRolloutPath ? (row["rollout_path"] as? String) : nil
                let expandedRolloutPath = rolloutPath.map { ($0 as NSString).expandingTildeInPath }
                // Current Codex builds broadcast the top-level task's cumulative token
                // counter into every spawned subagent rollout. Emitting each mirrored
                // counter as an independent session multiplies one task's usage by its
                // agent count. Keep subagent conversations, but let the active parent
                // row (selected by updated_at above) own the process-wide usage total.
                let storedThreadSource: String? = hasThreadSource ? row["thread_source"] : nil
                let isSubagentRollout = storedThreadSource == "subagent"
                    || expandedRolloutPath.map(isCodexSubagentRollout) == true
                if isSubagentRollout {
                    usageSessionIDsToDelete.append(threadId)
                }

                // Try to get exact token breakdown from JSONL session file
                var inputTokens: Int = 0
                var outputTokens: Int = 0
                var cacheReadTokens: Int = 0
                var dailyTokenUsage: [CodexDailyTokenUsage] = []
                var foundExact = false

                var parsedConversation: CodexConversationCacheEntry?
                var shouldEmitConversation = includeConversationBodies && expandedRolloutPath == nil

                if let expandedPath = expandedRolloutPath {
                    let cacheKey = URL(fileURLWithPath: expandedPath).standardizedFileURL.path
                    activePaths.insert(cacheKey)

                    if let signature = OpenBurnBarCore.FileSignature(for: URL(fileURLWithPath: expandedPath)),
                       let cached = sessionCache.fileEntries[cacheKey],
                       cached.signature == signature {
                        let cachedTokenUsage = cached.tokenUsage
                        if let tokenUsage = cached.tokenUsage {
                            inputTokens = tokenUsage.input
                            outputTokens = tokenUsage.output
                            cacheReadTokens = tokenUsage.cacheRead
                            dailyTokenUsage = tokenUsage.daily
                            foundExact = true
                        }
                        if includeConversationBodies {
                            parsedConversation = cached.conversation
                                ?? parseCodexConversationJSONL(path: expandedPath, fallbackTitle: rawTitle)
                            shouldEmitConversation = parsedConversation != nil
                            if parsedConversation != cached.conversation {
                                sessionCache.fileEntries[cacheKey] = CodexCacheEntry(
                                    signature: signature,
                                    tokenUsage: cachedTokenUsage,
                                    conversation: parsedConversation
                                )
                                cacheMutated = true
                            }
                        } else {
                            parsedConversation = nil
                            shouldEmitConversation = false
                            if cached.conversation != nil {
                                sessionCache.fileEntries[cacheKey] = CodexCacheEntry(
                                    signature: signature,
                                    tokenUsage: cachedTokenUsage,
                                    conversation: nil
                                )
                                cacheMutated = true
                            }
                        }
                    } else {
                        let cached = sessionCache.fileEntries[cacheKey]
                        let parsed = parseCodexSessionJSONL(path: expandedPath)
                        if let parsed {
                            inputTokens = parsed.input
                            outputTokens = parsed.output
                            cacheReadTokens = parsed.cacheRead
                            dailyTokenUsage = parsed.daily
                            foundExact = true
                        }
                        parsedConversation = includeConversationBodies
                            ? parseCodexConversationJSONL(path: expandedPath, fallbackTitle: rawTitle)
                            : nil
                        shouldEmitConversation = includeConversationBodies && parsedConversation != nil

                        if let signature = OpenBurnBarCore.FileSignature(for: URL(fileURLWithPath: expandedPath)) {
                            sessionCache.fileEntries[cacheKey] = CodexCacheEntry(
                                signature: signature,
                                tokenUsage: parsed.map {
                                    CodexTokenUsage(
                                        input: $0.input,
                                        output: $0.output,
                                        cacheRead: $0.cacheRead,
                                        daily: $0.daily
                                    )
                                },
                                conversation: parsedConversation
                            )
                            cacheMutated = true
                        } else if cached != nil {
                            sessionCache.fileEntries.removeValue(forKey: cacheKey)
                            cacheMutated = true
                        }
                    }
                }

                if !foundExact {
                    let tokensUsed: Int = row["tokens_used"] ?? 0
                    // Better than 50/50: Codex sessions are heavily input-weighted (~95/5)
                    inputTokens = Int(Double(tokensUsed) * 0.95)
                    outputTokens = max(tokensUsed - inputTokens, 0)
                }

                if !isSubagentRollout {
                    if !dailyTokenUsage.isEmpty {
                        // Remove the legacy lifetime row once exact day slices are
                        // available; otherwise it would overlap every selected day.
                        usageSessionIDsToDelete.append(threadId)
                        for bucket in dailyTokenUsage {
                            let pricing = OpenBurnBarCore.ModelPricing.lookup(model: model)
                            let cost = pricing.cost(
                                inputTokens: bucket.input,
                                outputTokens: bucket.output,
                                cacheReadTokens: bucket.cacheRead
                            )
                            usages.append(TokenUsage(
                                provider: .codex,
                                sessionId: "\(threadId)#day-\(Int(bucket.dayStart.timeIntervalSince1970))",
                                projectName: projectName,
                                model: model,
                                inputTokens: bucket.input,
                                outputTokens: bucket.output,
                                cacheCreationTokens: 0,
                                cacheReadTokens: bucket.cacheRead,
                                costUSD: cost,
                                startTime: bucket.dayStart,
                                endTime: bucket.endTime,
                                provenanceMethod: .providerLog,
                                provenanceConfidence: .exact,
                                estimatorVersion: "codex-daily-cumulative-v1"
                            ))
                        }
                    } else if inputTokens > 0 || outputTokens > 0 {
                        let pricing = OpenBurnBarCore.ModelPricing.lookup(model: model)
                        let cost = pricing.cost(
                            inputTokens: inputTokens,
                            outputTokens: outputTokens,
                            cacheReadTokens: cacheReadTokens
                        )
                        usages.append(TokenUsage(
                            provider: .codex,
                            sessionId: threadId,
                            projectName: projectName,
                            model: model,
                            inputTokens: inputTokens,
                            outputTokens: outputTokens,
                            cacheCreationTokens: 0,
                            cacheReadTokens: cacheReadTokens,
                            costUSD: cost,
                            startTime: startTime,
                            endTime: endTime,
                            provenanceMethod: foundExact ? .providerLog : .heuristicEstimate,
                            provenanceConfidence: foundExact ? .exact : .lowConfidenceEstimate,
                            estimatorVersion: foundExact ? "" : "tokens-used-split-v1"
                        ))
                    }
                }

                if shouldEmitConversation {
                    let inferredTitle = parsedConversation?.title
                        ?? rawTitle.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                        ?? threadId
                    let fullText = parsedConversation?.markdown
                        ?? rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    let conversation = OpenBurnBarCore.ConversationRecord(
                        id: OpenBurnBarCore.ConversationRecord.stableId(provider: .codex, sessionId: threadId),
                        provider: .codex,
                        sessionId: threadId,
                        projectName: projectName,
                        startTime: startTime,
                        endTime: endTime,
                        messageCount: parsedConversation?.messageCount ?? (fullText.isEmpty ? 0 : 1),
                        userWordCount: parsedConversation?.userWordCount ?? rawTitle.split(separator: " ").count,
                        assistantWordCount: parsedConversation?.assistantWordCount ?? 0,
                        keyFiles: parsedConversation?.keyFiles ?? [],
                        keyCommands: parsedConversation?.keyCommands ?? [],
                        keyTools: parsedConversation?.keyTools ?? [],
                        inferredTaskTitle: inferredTitle,
                        lastAssistantMessage: parsedConversation?.lastAssistantMessage ?? "",
                        fullText: fullText,
                        indexedAt: Date(),
                        fileModifiedAt: expandedRolloutPath.flatMap { modificationDate(of: URL(fileURLWithPath: $0)) },
                        summary: nil
                    )
                    conversations.append(conversation)
                }
            }
        }

        let stalePaths = Set(sessionCache.fileEntries.keys).subtracting(activePaths)
        if !stalePaths.isEmpty {
            for stalePath in stalePaths {
                sessionCache.fileEntries.removeValue(forKey: stalePath)
            }
            cacheMutated = true
        }

        if cacheMutated {
            cacheStore.persist(sessionCache)
        }

        return (usages, conversations, Array(Set(usageSessionIDsToDelete)).sorted())
    }

    /// Parse a Codex session JSONL file to extract exact token breakdowns.
    /// Codex rollout logs usually wrap `token_count` in an `event_msg` envelope and
    /// report cumulative totals where cached input is a subset of input.
    ///
    /// VAL-TOKEN-002: Uses exact token breakdown from JSONL when present, skips delta
    /// accumulation to avoid double-counting.
    /// VAL-TOKEN-010: When both cumulative totals and delta events are present, cumulative
    /// totals take precedence and delta events are ignored to prevent additive double-counting.
    private func parseCodexSessionJSONL(
        path: String
    ) -> (input: Int, output: Int, cacheRead: Int, daily: [CodexDailyTokenUsage])? {
        guard fileManager.fileExists(atPath: path),
              let handle = FileHandle(forReadingAtPath: path) else {
            return nil
        }
        defer { try? handle.close() } // try?-ok(handle teardown)

        var inputTokens = 0
        var outputTokens = 0
        var cacheReadTokens = 0
        var foundCumulative = false
        var foundDelta = false
        var cumulativeHighWater = (input: 0, output: 0, cacheRead: 0)
        var dailyUsage: [Date: CodexDailyTokenUsage] = [:]
        let calendar = Calendar.current

        for line in handle.readAllUTF8Lines() {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { // try?-ok(per-line decode, skip)
                continue
            }

            guard let info = OpenBurnBarCore.TokenExtractionUtility.codexTokenCountInfo(from: json) else {
                continue
            }

            // VAL-TOKEN-010: Cumulative totals take precedence over delta events.
            // If we've already found cumulative totals, skip processing delta events.
            if let extracted = OpenBurnBarCore.TokenExtractionUtility.codexCumulativeTotalsFromTokenCountInfo(info) {
                if !foundCumulative, foundDelta {
                    dailyUsage.removeAll()
                    foundDelta = false
                }
                let nextHighWater = (
                    input: max(cumulativeHighWater.input, extracted.input),
                    output: max(cumulativeHighWater.output, extracted.output),
                    cacheRead: max(cumulativeHighWater.cacheRead, extracted.cacheRead)
                )
                // Codex reports `input_tokens` inclusive of `cached_input_tokens`.
                // Subtract the cached portion so the non-cached input and cached
                // buckets stay disjoint (VAL-TOKEN-002 / matches delta path below).
                inputTokens = max(nextHighWater.input - nextHighWater.cacheRead, 0)
                outputTokens = nextHighWater.output
                cacheReadTokens = nextHighWater.cacheRead
                foundCumulative = true
                if let eventDate = codexEventDate(from: json["timestamp"] as? String) {
                    let rawInputDelta = nextHighWater.input - cumulativeHighWater.input
                    let outputDelta = nextHighWater.output - cumulativeHighWater.output
                    let cacheReadDelta = nextHighWater.cacheRead - cumulativeHighWater.cacheRead
                    recordCodexDailyUsage(
                        eventDate: eventDate,
                        input: max(rawInputDelta - cacheReadDelta, 0),
                        output: outputDelta,
                        cacheRead: cacheReadDelta,
                        calendar: calendar,
                        buckets: &dailyUsage
                    )
                }
                cumulativeHighWater = nextHighWater
                continue
            }

            // VAL-TOKEN-002: Only process delta events if no cumulative totals found yet.
            // This prevents double-counting when both cumulative and delta events exist.
            if !foundCumulative,
               let lastUsage = info["last_token_usage"] as? [String: Any] {
                let deltaInput = lastUsage["input_tokens"] as? Int ?? 0
                let deltaCacheRead = lastUsage["cached_input_tokens"] as? Int
                    ?? lastUsage["cache_read_input_tokens"] as? Int
                    ?? 0
                inputTokens += max(deltaInput - deltaCacheRead, 0)
                outputTokens += lastUsage["output_tokens"] as? Int ?? 0
                cacheReadTokens += deltaCacheRead
                if let eventDate = codexEventDate(from: json["timestamp"] as? String) {
                    recordCodexDailyUsage(
                        eventDate: eventDate,
                        input: max(deltaInput - deltaCacheRead, 0),
                        output: lastUsage["output_tokens"] as? Int ?? 0,
                        cacheRead: deltaCacheRead,
                        calendar: calendar,
                        buckets: &dailyUsage
                    )
                }
                foundDelta = true
            }
        }

        // Return cumulative if found, otherwise return delta-accumulated if found
        if foundCumulative {
            return (
                input: inputTokens,
                output: outputTokens,
                cacheRead: cacheReadTokens,
                daily: dailyUsage.values.sorted { $0.dayStart < $1.dayStart }
            )
        }
        return foundDelta
            ? (
                input: inputTokens,
                output: outputTokens,
                cacheRead: cacheReadTokens,
                daily: dailyUsage.values.sorted { $0.dayStart < $1.dayStart }
            )
            : nil
    }

    private func codexEventDate(from timestamp: String?) -> Date? {
        guard let timestamp else { return nil }
        return OpenBurnBarCore.ThreadSafeISO8601DateFormatter.parse(timestamp)
    }

    private func recordCodexDailyUsage(
        eventDate: Date,
        input: Int,
        output: Int,
        cacheRead: Int,
        calendar: Calendar,
        buckets: inout [Date: CodexDailyTokenUsage]
    ) {
        guard input > 0 || output > 0 || cacheRead > 0 else { return }
        let dayStart = calendar.startOfDay(for: eventDate)
        let existing = buckets[dayStart]
        buckets[dayStart] = CodexDailyTokenUsage(
            dayStart: dayStart,
            endTime: max(existing?.endTime ?? eventDate, eventDate),
            input: (existing?.input ?? 0) + input,
            output: (existing?.output ?? 0) + output,
            cacheRead: (existing?.cacheRead ?? 0) + cacheRead
        )
    }

    /// Codex subagent rollout files carry the parent's process-wide cumulative
    /// token counter, so they are conversation sources rather than independent
    /// usage ledgers. `session_meta` is the first record in current rollouts;
    /// inspect only a bounded prefix to avoid an extra scan of large files.
    private func isCodexSubagentRollout(_ path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() } // try?-ok(handle teardown)

        guard let prefix = try? handle.read(upToCount: 256 * 1024), // try?-ok(optional bounded rollout probe)
              !prefix.isEmpty else {
            return false
        }

        let text = String(decoding: prefix, as: UTF8.self)
        for line in text.split(separator: "\n", maxSplits: 15, omittingEmptySubsequences: true) {
            guard let data = String(line).data(using: .utf8),
                  let record = try? JSONDecoder().decode(CodexSessionMetaProbe.self, from: data), // try?-ok(per-line bounded probe)
                  record.type == "session_meta" else {
                continue
            }
            return record.payload?.source?.subagent != nil
        }
        return false
    }

    private func parseCodexConversationJSONL(path: String, fallbackTitle: String) -> CodexConversationCacheEntry? {
        guard fileManager.fileExists(atPath: path),
              let handle = FileHandle(forReadingAtPath: path) else {
            return nil
        }
        defer { try? handle.close() } // try?-ok(handle teardown)

        var turns: [(role: String, text: String)] = []
        var keyFiles = Set<String>()
        var keyCommands = Set<String>()
        var keyTools = Set<String>()

        for line in handle.readAllUTF8Lines() {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { // try?-ok(per-line decode, skip)
                continue
            }
            if let extracted = Self.extractCodexMessage(from: json) {
                turns.append(extracted)
            }
            if let tool = Self.extractCodexTool(from: json) {
                keyTools.insert(tool.name)
                if let detail = tool.detail {
                    if tool.name.lowercased().contains("bash") || tool.name.lowercased().contains("exec") {
                        keyCommands.insert(detail)
                    } else if detail.contains("/") || detail.contains(".swift") || detail.contains(".ts") || detail.contains(".kt") {
                        keyFiles.insert(detail)
                    }
                }
            }
        }

        guard !turns.isEmpty else { return nil }

        let markdown = turns.map { turn -> String in
            let header = turn.role == "assistant" ? "## Assistant" : "## You"
            return "\(header)\n\n\(turn.text)"
        }.joined(separator: "\n\n")
        let title = turns.first(where: { $0.role == "user" })?.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
            ?? fallbackTitle.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? "Codex session"
        let lastAssistant = turns.last(where: { $0.role == "assistant" })?.text ?? ""
        let userWords = turns
            .filter { $0.role == "user" }
            .reduce(0) { $0 + $1.text.split(separator: " ").count }
        let assistantWords = turns
            .filter { $0.role == "assistant" }
            .reduce(0) { $0 + $1.text.split(separator: " ").count }

        return CodexConversationCacheEntry(
            title: String(title.prefix(160)),
            markdown: markdown,
            messageCount: turns.count,
            userWordCount: userWords,
            assistantWordCount: assistantWords,
            keyFiles: Array(Array(keyFiles).sorted().prefix(12)),
            keyCommands: Array(Array(keyCommands).sorted().prefix(12)),
            keyTools: Array(Array(keyTools).sorted().prefix(12)),
            lastAssistantMessage: String(lastAssistant.prefix(500))
        )
    }

    private static func extractCodexMessage(from json: [String: Any]) -> (role: String, text: String)? {
        let item = (json["item"] as? [String: Any])
            ?? (json["payload"] as? [String: Any])?["item"] as? [String: Any]
            ?? (json["msg"] as? [String: Any])?["item"] as? [String: Any]
        guard let item,
              let role = item["role"] as? String,
              role == "user" || role == "assistant" else {
            return nil
        }
        let text = extractText(from: item["content"])
            ?? extractText(from: item["message"])
            ?? (item["text"] as? String)
        guard let cleaned = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !cleaned.isEmpty else {
            return nil
        }
        return (role, cleaned)
    }

    private static func extractText(from raw: Any?) -> String? {
        if let string = raw as? String { return string }
        if let pieces = raw as? [[String: Any]] {
            let text = pieces.compactMap { piece -> String? in
                if let text = piece["text"] as? String { return text }
                if let text = piece["content"] as? String { return text }
                return nil
            }.joined(separator: "\n")
            return text.isEmpty ? nil : text
        }
        return nil
    }

    private static func extractCodexTool(from json: [String: Any]) -> (name: String, detail: String?)? {
        let item = (json["item"] as? [String: Any])
            ?? (json["payload"] as? [String: Any])?["item"] as? [String: Any]
            ?? (json["msg"] as? [String: Any])?["item"] as? [String: Any]
        guard let item else { return nil }
        let name = (item["name"] as? String)
            ?? (item["tool_name"] as? String)
            ?? (item["type"] as? String)
        guard let name, !name.isEmpty else { return nil }
        let detail = (item["command"] as? String)
            ?? (item["path"] as? String)
            ?? (item["file_path"] as? String)
            ?? (item["query"] as? String)
            ?? (item["pattern"] as? String)
        return (name, detail)
    }

    private func modificationDate(of url: URL) -> Date? {
        (try? fileManager.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date // try?-ok(optional mtime)
    }

}

private struct CodexSessionMetaProbe: Decodable {
    struct Payload: Decodable {
        struct Source: Decodable {
            struct Subagent: Decodable {}

            let subagent: Subagent?
        }

        let source: Source?
    }

    let type: String
    let payload: Payload?
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

    init(
        fileManager: FileManager = .default,
        sessionsDirectory: URL = URL(fileURLWithPath: (AgentProvider.openClaw.logDirectory as NSString).expandingTildeInPath)
    ) {
        self.fileManager = fileManager
        self.sessionsDirectory = sessionsDirectory
    }

    func parse() async throws -> OpenBurnBarCore.ParseResult {
        guard fileManager.fileExists(atPath: sessionsDirectory.path) else {
            return OpenBurnBarCore.ParseResult(usages: [], conversations: [])
        }

        let files = sessionFiles(in: sessionsDirectory)
        var conversations: [OpenBurnBarCore.ConversationRecord] = []
        var usages: [TokenUsage] = []

        for file in files {
            guard let parsed = parseSession(file: file) else { continue }
            conversations.append(parsed.conversation)
            if let usage = parsed.usage {
                usages.append(usage)
            }
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
        let data: Data
        if file.pathExtension.lowercased() == "jsonl" || file.pathExtension.lowercased() == "log" {
            guard let handle = try? FileHandle(forReadingFrom: file) else { return nil } // try?-ok(log open, skip if absent)
            defer { try? handle.close() } // try?-ok(handle teardown)
            data = handle.readDataToEndOfFile()
        } else {
            guard let fileData = try? Data(contentsOf: file) else { return nil } // try?-ok(session read, skip if absent)
            data = fileData
        }

        var turns: [(role: String, text: String, timestamp: Date?)] = []
        var inputTokens = 0
        var outputTokens = 0
        var cacheReadTokens = 0
        var model = "openclaw"
        var startTime: Date?
        var endTime: Date?

        for object in Self.sessionObjects(from: data) {
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

        let usage: TokenUsage? = (inputTokens > 0 || outputTokens > 0) ? TokenUsage(
            provider: .openClaw,
            sessionId: sessionId,
            projectName: "OpenClaw",
            model: model,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheCreationTokens: 0,
            cacheReadTokens: cacheReadTokens,
            costUSD: OpenBurnBarCore.ModelPricing.lookup(model: model).cost(inputTokens: inputTokens, outputTokens: outputTokens, cacheReadTokens: cacheReadTokens),
            startTime: effectiveStart,
            endTime: effectiveEnd,
            provenanceMethod: cacheReadTokens > 0 ? .providerLog : .heuristicEstimate,
            provenanceConfidence: cacheReadTokens > 0 ? .exact : .lowConfidenceEstimate,
            estimatorVersion: cacheReadTokens > 0 ? "" : OpenBurnBarCore.TokenExtractionUtility.currentEstimatorVersion
        ) : nil

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

    private static func sessionObjects(from data: Data) -> [[String: Any]] {
        let jsonLineObjects = String(data: data, encoding: .utf8)?
            .components(separatedBy: .newlines)
            .compactMap { line -> [String: Any]? in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, let lineData = trimmed.data(using: .utf8) else { return nil }
                return try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] // try?-ok(per-line decode, skip)
            } ?? []
        if !jsonLineObjects.isEmpty {
            return jsonLineObjects
        }

        guard let root = try? JSONSerialization.jsonObject(with: data) else { // try?-ok(whole-file decode, empty fallback)
            return []
        }
        return flattenSessionObjects(root)
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

struct CodexTokenUsage: Codable, Equatable {
    let input: Int
    let output: Int
    let cacheRead: Int
    let daily: [CodexDailyTokenUsage]
}

struct CodexDailyTokenUsage: Codable, Equatable {
    let dayStart: Date
    let endTime: Date
    let input: Int
    let output: Int
    let cacheRead: Int
}

struct CodexConversationCacheEntry: Codable, Equatable {
    let title: String
    let markdown: String
    let messageCount: Int
    let userWordCount: Int
    let assistantWordCount: Int
    let keyFiles: [String]
    let keyCommands: [String]
    let keyTools: [String]
    let lastAssistantMessage: String
}

struct CodexCacheEntry: Codable, Equatable {
    let signature: OpenBurnBarCore.FileSignature
    let tokenUsage: CodexTokenUsage?
    let conversation: CodexConversationCacheEntry?
}
