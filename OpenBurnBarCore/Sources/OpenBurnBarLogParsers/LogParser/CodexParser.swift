import Foundation
import OpenBurnBarKernel
import OpenBurnBarSQLiteReader

// MARK: - Codex Parser
//
// Windows-port Phase-2 (G2 parser lift, `docs/WINDOWS_PORT_MASTER_PLAN.md`). Lifted
// verbatim from the macOS app (`AgentLens/Services/UsageAggregatorParsers+Codex.swift`),
// with ONE change: the GRDB `DatabaseQueue`/`Row.fetchAll` reads of the plain
// `state_5.sqlite` `threads` table are routed through the Foundation-only SQLite
// reader seam (`SQLiteConnection` + `SQLiteRow`, `Services/SQLite/`), whose typed
// getters reproduce GRDB's coercion exactly. The token/cost/model/session projection
// logic is byte-for-byte unchanged.

/// Reads token usage from Codex's SQLite store and JSONL session files.
/// Prefers exact token breakdowns from JSONL `token_count` events over the aggregate `tokens_used` in SQLite.
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
            schemaVersion: 1,
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
        let dbPath = homeDirectoryURL
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("state_5.sqlite", isDirectory: false)
            .path

        guard fileManager.fileExists(atPath: dbPath) else {
            return ParseResult(usages: [], conversations: [])
        }

        let parsed = try parseCodexDatabase(
            dbPath: dbPath,
            includeConversationBodies: options.includeConversationBodies,
            minimumFileModificationDate: options.minimumFileModificationDate
        )
        return ParseResult(usages: parsed.usages, conversations: parsed.conversations)
    }

    private func parseCodexDatabase(
        dbPath: String,
        includeConversationBodies: Bool,
        minimumFileModificationDate: Date?
    ) throws -> (usages: [TokenUsage], conversations: [ConversationRecord]) {
        var usages: [TokenUsage] = []
        var conversations: [ConversationRecord] = []
        var sessionCache = cacheStore.load()
        var activePaths = Set<String>()
        var cacheMutated = false

        // Read-only, plain SQLite (matches GRDB `Configuration.readonly = true`).
        let reader = try SQLiteConnection.openReadOnly(path: dbPath)
        defer { reader.close() }

        // Check if rollout_path column exists
        let columnNames = Set(try reader.columnNames(ofTable: "threads"))
        let hasRolloutPath = columnNames.contains("rollout_path")

        let createdAtFilter: String
        if let minimumFileModificationDate {
            createdAtFilter = " AND created_at >= \(Int64(minimumFileModificationDate.timeIntervalSince1970))"
        } else {
            createdAtFilter = ""
        }

        let sql: String
        if hasRolloutPath {
            sql = """
                SELECT
                    id, title, model, model_provider, tokens_used,
                    created_at, updated_at, cwd, rollout_path
                FROM threads
                WHERE archived = 0\(createdAtFilter)
                ORDER BY created_at DESC
                LIMIT 500
            """
        } else {
            sql = """
                SELECT
                    id, title, model, model_provider, tokens_used,
                    created_at, updated_at, cwd
                FROM threads
                WHERE archived = 0\(createdAtFilter)
                ORDER BY created_at DESC
                LIMIT 500
            """
        }

        let rows = try reader.query(sql)

        for row in rows {
            guard let threadId: String = row.string("id"),
                  let createdAt: Int64 = row.int64("created_at"),
                  let updatedAt: Int64 = row.int64("updated_at") else {
                continue
            }

            let model: String = row.string("model") ?? "unknown"
            let rawTitle: String = row.string("title") ?? ""
            let cwd: String = row.string("cwd") ?? "~"
            let projectName = (cwd as NSString).lastPathComponent
            let startTime = Date(timeIntervalSince1970: Double(createdAt))
            let endTime = Date(timeIntervalSince1970: Double(updatedAt))
            let rolloutPath: String? = hasRolloutPath ? row.string("rollout_path") : nil
            let expandedRolloutPath = rolloutPath.map { ($0 as NSString).expandingTildeInPath }

            // Try to get exact token breakdown from JSONL session file
            var inputTokens: Int = 0
            var outputTokens: Int = 0
            var cacheReadTokens: Int = 0
            var foundExact = false

            var parsedConversation: CodexConversationCacheEntry?
            var shouldEmitConversation = includeConversationBodies && expandedRolloutPath == nil

            if let expandedPath = expandedRolloutPath {
                let cacheKey = URL(fileURLWithPath: expandedPath).standardizedFileURL.path
                activePaths.insert(cacheKey)

                if let signature = FileSignature(for: URL(fileURLWithPath: expandedPath)),
                   let cached = sessionCache.fileEntries[cacheKey],
                   cached.signature == signature {
                    let cachedTokenUsage = cached.tokenUsage
                    if let tokenUsage = cached.tokenUsage {
                        inputTokens = tokenUsage.input
                        outputTokens = tokenUsage.output
                        cacheReadTokens = tokenUsage.cacheRead
                        foundExact = true
                    }
                    if includeConversationBodies {
                        parsedConversation = parseCodexConversationJSONL(path: expandedPath, fallbackTitle: rawTitle)
                        shouldEmitConversation = parsedConversation != nil
                        if cached.conversation != nil {
                            sessionCache.fileEntries[cacheKey] = CodexCacheEntry(
                                signature: signature,
                                tokenUsage: cachedTokenUsage,
                                conversation: nil
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
                        foundExact = true
                    }
                    parsedConversation = includeConversationBodies
                        ? parseCodexConversationJSONL(path: expandedPath, fallbackTitle: rawTitle)
                        : nil
                    shouldEmitConversation = includeConversationBodies && parsedConversation != nil

                    if let signature = FileSignature(for: URL(fileURLWithPath: expandedPath)) {
                        sessionCache.fileEntries[cacheKey] = CodexCacheEntry(
                            signature: signature,
                            tokenUsage: parsed.map {
                                CodexTokenUsage(
                                    input: $0.input,
                                    output: $0.output,
                                    cacheRead: $0.cacheRead
                                )
                            },
                            conversation: nil
                        )
                        cacheMutated = true
                    } else if cached != nil {
                        sessionCache.fileEntries.removeValue(forKey: cacheKey)
                        cacheMutated = true
                    }
                }
            }

            if !foundExact {
                let tokensUsed: Int = row.int("tokens_used") ?? 0
                // Better than 50/50: Codex sessions are heavily input-weighted (~95/5)
                inputTokens = Int(Double(tokensUsed) * 0.95)
                outputTokens = max(tokensUsed - inputTokens, 0)
            }

            if inputTokens > 0 || outputTokens > 0 {
                let pricing = ModelPricing.lookup(model: model)
                let cost = pricing.cost(
                    inputTokens: inputTokens,
                    outputTokens: outputTokens,
                    cacheReadTokens: cacheReadTokens
                )

                let usage = TokenUsage(
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
                )
                usages.append(usage)
            }

            if shouldEmitConversation {
                let inferredTitle = parsedConversation?.title
                    ?? rawTitle.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                    ?? threadId
                let fullText = parsedConversation?.markdown
                    ?? rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                let conversation = ConversationRecord(
                    id: ConversationRecord.stableId(provider: .codex, sessionId: threadId),
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

        return (usages, conversations)
    }

    /// Parse a Codex session JSONL file to extract exact token breakdowns.
    /// Codex rollout logs usually wrap `token_count` in an `event_msg` envelope and
    /// report cumulative totals where cached input is a subset of input.
    ///
    /// VAL-TOKEN-002: Uses exact token breakdown from JSONL when present, skips delta
    /// accumulation to avoid double-counting.
    /// VAL-TOKEN-010: When both cumulative totals and delta events are present, cumulative
    /// totals take precedence and delta events are ignored to prevent additive double-counting.
    private func parseCodexSessionJSONL(path: String) -> (input: Int, output: Int, cacheRead: Int)? {
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

        for line in handle.readAllUTF8Lines() {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { // try?-ok(per-line decode, skip)
                continue
            }

            guard let info = TokenExtractionUtility.codexTokenCountInfo(from: json) else {
                continue
            }

            // VAL-TOKEN-010: Cumulative totals take precedence over delta events.
            // If we've already found cumulative totals, skip processing delta events.
            if let extracted = TokenExtractionUtility.codexCumulativeTotalsFromTokenCountInfo(info) {
                // Codex reports `input_tokens` inclusive of `cached_input_tokens`.
                // Subtract the cached portion so the non-cached input and cached
                // buckets stay disjoint (VAL-TOKEN-002 / matches delta path below).
                let nonCachedInput = max(extracted.input - extracted.cacheRead, 0)
                if foundDelta {
                    inputTokens = nonCachedInput
                    outputTokens = extracted.output
                    cacheReadTokens = extracted.cacheRead
                    foundDelta = false
                } else {
                    inputTokens = nonCachedInput
                    outputTokens = extracted.output
                    cacheReadTokens = extracted.cacheRead
                }
                foundCumulative = true
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
                foundDelta = true
            }
        }

        // Return cumulative if found, otherwise return delta-accumulated if found
        if foundCumulative {
            return (input: inputTokens, output: outputTokens, cacheRead: cacheReadTokens)
        }
        return foundDelta ? (input: inputTokens, output: outputTokens, cacheRead: cacheReadTokens) : nil
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

public struct CodexTokenUsage: Codable, Equatable, Sendable {
    public let input: Int
    public let output: Int
    public let cacheRead: Int
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
}

public struct CodexCacheEntry: Codable, Equatable, Sendable {
    public let signature: FileSignature
    public let tokenUsage: CodexTokenUsage?
    public let conversation: CodexConversationCacheEntry?
}
