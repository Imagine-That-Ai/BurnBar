import Foundation
import CryptoKit
import GRDB
import OpenBurnBarCore

// MARK: - Copilot Parser

/// Parses Copilot CLI sessions from ~/.copilot/session-state/*/events.jsonl.
/// Post-Feb 2026 Copilot CLI persists assistant.usage and session.shutdown events with exact token counts.
/// Falls back to CompactionProcessor log deltas for older CLI versions.
final class CopilotParser: LogParser, Sendable {
    let provider: AgentProvider = .copilot

    func parse() async throws -> ParseResult {
        let fm = FileManager.default
        let sessionStatePath = ("~/.copilot/session-state" as NSString).expandingTildeInPath
        let logsPath = ("~/.copilot/logs" as NSString).expandingTildeInPath

        guard fm.fileExists(atPath: sessionStatePath) else {
            return ParseResult(usages: [], conversations: [])
        }

        // Parse CompactionProcessor token data from process logs (fallback for old CLI)
        let tokensBySession = parseProcessLogs(logsPath: logsPath)

        var usages: [TokenUsage] = []
        var conversations: [ConversationRecord] = []

        let sessionDirs = (try? fm.contentsOfDirectory(
            at: URL(fileURLWithPath: sessionStatePath),
            includingPropertiesForKeys: [.isDirectoryKey]
        ))?.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true } ?? []

        for sessionDir in sessionDirs {
            let sessionId = sessionDir.lastPathComponent
            let eventsFile = sessionDir.appendingPathComponent("events.jsonl")
            let metadataFile = sessionDir.appendingPathComponent("metadata.json")

            guard fm.fileExists(atPath: eventsFile.path) else { continue }

            // Try metadata.json for session-level summary first
            let metadataSummary = parseMetadata(metadataFile)

            if let pair = parseSession(
                eventsFile: eventsFile,
                sessionId: sessionId,
                metadataSummary: metadataSummary,
                processLogData: tokensBySession[sessionId]
            ) {
                if let usage = pair.usage { usages.append(usage) }
                if let conv = pair.conversation { conversations.append(conv) }
            }
        }

        return ParseResult(usages: usages, conversations: conversations)
    }

    private func parseMetadata(_ file: URL) -> CopilotMetadataSummary? {
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let model = json["model"] as? String
        let usage = json["usage"] as? [String: Any] ?? json["tokenUsage"] as? [String: Any]
        var input = 0
        var output = 0
        var cached = 0

        if let usage {
            let extracted = TokenExtractionUtility.extractUsageTokens(usage)
            input = extracted.input
            output = extracted.output
            cached = extracted.cacheRead
        }

        guard input > 0 || output > 0 else { return nil }
        return CopilotMetadataSummary(model: model, input: input, output: output, cached: cached)
    }

    private func parseSession(
        eventsFile: URL,
        sessionId: String,
        metadataSummary: CopilotMetadataSummary?,
        processLogData: (input: Int, output: Int)?
    ) -> (usage: TokenUsage?, conversation: ConversationRecord?)? {
        guard let handle = try? FileHandle(forReadingFrom: eventsFile) else { return nil }
        defer { try? handle.close() }

        let mtime = (try? FileManager.default.attributesOfItem(atPath: eventsFile.path)[.modificationDate]) as? Date

        var exactInputTokens = 0
        var exactOutputTokens = 0
        var exactCachedTokens = 0
        var foundExactUsage = false
        var userChars = 0
        var assistantChars = 0
        var startTime: Date?
        var endTime: Date?
        var model = metadataSummary?.model ?? "copilot"
        var fullText = ""
        var firstUser: String?
        var lastAssistant = ""
        var userWords = 0
        var assistantWords = 0
        var messageCount = 0

        for line in handle.readAllUTF8Lines() {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            let eventType = json["type"] as? String ?? json["event"] as? String ?? ""
            let role = json["role"] as? String ?? ""

            // Timestamps
            if let ts = json["timestamp"] as? String {
                let date = ISO8601DateFormatter().date(from: ts)
                if startTime == nil { startTime = date }
                endTime = date
            } else if let ts = json["timestamp"] as? Double {
                let date = Date(timeIntervalSince1970: ts)
                if startTime == nil { startTime = date }
                endTime = date
            }

            // Model
            if let m = json["model"] as? String, !m.isEmpty { model = m }

            // Exact usage data (post-Feb 2026 Copilot CLI)
            // assistant.usage events and session.shutdown events contain token counts
            if eventType == "assistant.usage" || eventType == "session.shutdown" {
                if let usage = json["usage"] as? [String: Any] {
                    let extracted = TokenExtractionUtility.extractUsageTokens(usage)
                    exactInputTokens += extracted.input
                    exactOutputTokens += extracted.output
                    exactCachedTokens += extracted.cacheRead
                    foundExactUsage = true
                }
                if let usage = json["token_usage"] as? [String: Any] {
                    let extracted = TokenExtractionUtility.extractUsageTokens(usage)
                    exactInputTokens += extracted.input
                    exactOutputTokens += extracted.output
                    exactCachedTokens += extracted.cacheRead
                    foundExactUsage = true
                }
            }

            // Also check for inline usage on any message
            if let usage = json["usage"] as? [String: Any], eventType != "assistant.usage" && eventType != "session.shutdown" {
                let extracted = TokenExtractionUtility.extractUsageTokens(usage)
                if extracted.input > 0 || extracted.output > 0 {
                    exactInputTokens += extracted.input
                    exactOutputTokens += extracted.output
                    exactCachedTokens += extracted.cacheRead
                    foundExactUsage = true
                }
            }

            // Content for conversation record
            let content = json["content"] as? String ?? json["text"] as? String ?? ""
            if role == "user" || eventType == "user_message" {
                userChars += content.count
                if !content.isEmpty {
                    userWords += wordCount(content)
                    if firstUser == nil {
                        firstUser = String(content.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
                    }
                    appendText(&fullText, content, isAssistant: false)
                    messageCount += 1
                }
            } else if role == "assistant" || eventType == "assistant_message" {
                assistantChars += content.count
                if !content.isEmpty {
                    assistantWords += wordCount(content)
                    lastAssistant = content
                    appendText(&fullText, content, isAssistant: true)
                    messageCount += 1
                }
            }
        }

        // Determine best token data source: exact events > metadata > process logs > char estimation
        let inputTokens: Int
        let outputTokens: Int
        let cacheReadTokens: Int
        let isExact: Bool

        if foundExactUsage {
            inputTokens = exactInputTokens
            outputTokens = exactOutputTokens
            cacheReadTokens = exactCachedTokens
            isExact = true
        } else if let meta = metadataSummary {
            inputTokens = meta.input
            outputTokens = meta.output
            cacheReadTokens = meta.cached
            isExact = true
        } else if let pd = processLogData {
            inputTokens = pd.input
            outputTokens = pd.output
            cacheReadTokens = 0
            isExact = true
        } else {
            inputTokens = TokenExtractionUtility.estimatedTokenCount(for: userChars, charsPerToken: 3.5)
            outputTokens = TokenExtractionUtility.estimatedTokenCount(for: assistantChars, charsPerToken: 3.5)
            cacheReadTokens = 0
            isExact = false
        }

        guard inputTokens > 0 || outputTokens > 0 else { return nil }

        let pricing = ModelPricing.lookup(model: model)
        let cost = pricing.cost(inputTokens: inputTokens, outputTokens: outputTokens, cacheReadTokens: cacheReadTokens)

        let usage = TokenUsage(
            provider: .copilot,
            sessionId: sessionId,
            projectName: "Copilot",
            model: model,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheCreationTokens: 0,
            cacheReadTokens: cacheReadTokens,
            costUSD: cost,
            startTime: startTime ?? Date(),
            endTime: endTime ?? Date(),
            provenanceMethod: isExact ? .providerLog : .heuristicEstimate,
            provenanceConfidence: isExact ? .exact : .lowConfidenceEstimate,
            estimatorVersion: isExact ? "" : TokenExtractionUtility.currentEstimatorVersion
        )

        let conversation = ConversationRecord(
            id: ConversationRecord.stableId(provider: .copilot, sessionId: sessionId),
            provider: .copilot,
            sessionId: sessionId,
            projectName: "Copilot",
            startTime: startTime ?? usage.startTime,
            endTime: endTime ?? usage.endTime,
            messageCount: messageCount,
            userWordCount: userWords,
            assistantWordCount: assistantWords,
            keyFiles: [],
            keyCommands: [],
            keyTools: [],
            inferredTaskTitle: firstUser ?? "Copilot Session",
            lastAssistantMessage: lastAssistant,
            fullText: fullText,
            indexedAt: Date(),
            fileModifiedAt: mtime,
            summary: nil
        )

        return (usage, conversation)
    }

    /// Parse process logs for CompactionProcessor entries (fallback for pre-Feb 2026 CLI).
    private func parseProcessLogs(logsPath: String) -> [String: (input: Int, output: Int)] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: logsPath) else { return [:] }

        var result: [String: (input: Int, output: Int)] = [:]

        guard let logFiles = try? fm.contentsOfDirectory(atPath: logsPath)
            .filter({ $0.hasPrefix("process-") && $0.hasSuffix(".log") }) else {
            return [:]
        }

        for logFile in logFiles {
            let fullPath = (logsPath as NSString).appendingPathComponent(logFile)
            guard let data = fm.contents(atPath: fullPath),
                  let content = String(data: data, encoding: .utf8) else { continue }

            var lastTokensBySession: [String: Int] = [:]
            var prevTokensBySession: [String: Int] = [:]

            for line in content.components(separatedBy: .newlines) {
                guard line.contains("CompactionProcessor") || line.contains("context_tokens") else { continue }

                var sessionId: String?
                var tokens: Int?

                let parts = line.components(separatedBy: .whitespaces)
                for part in parts {
                    if part.hasPrefix("session=") {
                        sessionId = String(part.dropFirst(8))
                    } else if part.hasPrefix("context_tokens=") {
                        tokens = Int(String(part.dropFirst(15)))
                    }
                }

                if let sid = sessionId, let t = tokens {
                    prevTokensBySession[sid] = lastTokensBySession[sid] ?? 0
                    lastTokensBySession[sid] = t
                }
            }

            for (sid, lastTokens) in lastTokensBySession {
                let prevTokens = prevTokensBySession[sid] ?? 0
                let outputEstimate = max(lastTokens - prevTokens, lastTokens / 20)
                let inputEstimate = max(lastTokens - outputEstimate, 0)
                result[sid] = (input: inputEstimate, output: outputEstimate)
            }
        }

        return result
    }

    private func appendText(_ full: inout String, _ chunk: String, isAssistant: Bool) {
        if !full.isEmpty { full += "\n\n" }
        full += SessionLogMarkdownFormatter.transcriptTurnMarkdown(isAssistant: isAssistant, body: chunk)
    }

    private func wordCount(_ s: String) -> Int {
        s.split { $0.isWhitespace || $0.isNewline }.filter { !$0.isEmpty }.count
    }
}

private struct CopilotMetadataSummary {
    let model: String?
    let input: Int
    let output: Int
    let cached: Int
}

// MARK: - Aider Parser

/// Parses Aider analytics JSONL logs for exact per-message token usage.
/// Requires user to configure: `analytics-log: ~/.aider/analytics.jsonl` in .aider.conf.yml
final class AiderParser: LogParser, Sendable {
    let provider: AgentProvider = .aider

    func parse() async throws -> ParseResult {
        let fm = FileManager.default

        // Check common analytics log locations
        let candidatePaths = [
            ("~/.aider/analytics.jsonl" as NSString).expandingTildeInPath,
            ("~/.aider/analytics.json" as NSString).expandingTildeInPath
        ]

        // Also check for per-project .aider.analytics.jsonl in recent git repos
        var analyticsFiles: [URL] = []
        for path in candidatePaths where fm.fileExists(atPath: path) {
            analyticsFiles.append(URL(fileURLWithPath: path))
        }

        guard !analyticsFiles.isEmpty else {
            return ParseResult(usages: [], conversations: [])
        }

        var usages: [TokenUsage] = []
        var conversations: [ConversationRecord] = []

        for file in analyticsFiles {
            let (fileUsages, fileConvs) = parseAnalyticsLog(file: file)
            usages.append(contentsOf: fileUsages)
            conversations.append(contentsOf: fileConvs)
        }

        return ParseResult(usages: usages, conversations: conversations)
    }

    private func parseAnalyticsLog(file: URL) -> ([TokenUsage], [ConversationRecord]) {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return ([], []) }
        defer { try? handle.close() }

        // Group message_send events into sessions bounded by cli_session/exit events
        var sessions: [AiderSession] = []
        var current = AiderSession()

        for line in handle.readAllUTF8Lines() {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            let event = json["event"] as? String ?? ""
            let props = json["properties"] as? [String: Any] ?? [:]
            let time = json["time"] as? Double

            switch event {
            case "launched", "cli session":
                // Start a new session
                if current.hasData {
                    sessions.append(current)
                }
                current = AiderSession()
                if let t = time { current.startTime = Date(timeIntervalSince1970: t) }
                if let m = props["main_model"] as? String { current.model = m }

            case "message_send":
                let promptTokens = props["prompt_tokens"] as? Int ?? 0
                let completionTokens = props["completion_tokens"] as? Int ?? 0
                let cost = props["cost"] as? Double ?? 0
                current.inputTokens += promptTokens
                current.outputTokens += completionTokens
                current.totalCost += cost
                current.messageCount += 1
                if let t = time { current.endTime = Date(timeIntervalSince1970: t) }
                if current.startTime == nil, let t = time {
                    current.startTime = Date(timeIntervalSince1970: t)
                }
                if let m = props["main_model"] as? String, !m.isEmpty {
                    current.model = m
                }

            case "exit":
                if let t = time { current.endTime = Date(timeIntervalSince1970: t) }
                if current.hasData {
                    sessions.append(current)
                }
                current = AiderSession()

            default:
                break
            }
        }

        // Don't lose the last session if no exit event
        if current.hasData {
            sessions.append(current)
        }

        var usages: [TokenUsage] = []
        var conversations: [ConversationRecord] = []

        for (index, session) in sessions.enumerated() {
            let sessionId = "aider-\(index)-\(Int(session.startTime?.timeIntervalSince1970 ?? 0))"
            let model = session.model ?? "unknown"

            // Use cost from Aider if available, otherwise compute from pricing
            let cost: Double
            if session.totalCost > 0 {
                cost = session.totalCost
            } else {
                let pricing = ModelPricing.lookup(model: model)
                cost = pricing.cost(inputTokens: session.inputTokens, outputTokens: session.outputTokens)
            }

            let usage = TokenUsage(
                provider: .aider,
                sessionId: sessionId,
                projectName: "Aider",
                model: model,
                inputTokens: session.inputTokens,
                outputTokens: session.outputTokens,
                costUSD: cost,
                startTime: session.startTime ?? Date(),
                endTime: session.endTime ?? Date(),
                provenanceMethod: .providerLog,
                provenanceConfidence: .exact
            )
            usages.append(usage)

            let conversation = ConversationRecord(
                id: ConversationRecord.stableId(provider: .aider, sessionId: sessionId),
                provider: .aider,
                sessionId: sessionId,
                projectName: "Aider",
                startTime: session.startTime,
                endTime: session.endTime,
                messageCount: session.messageCount,
                userWordCount: 0,
                assistantWordCount: 0,
                keyFiles: [],
                keyCommands: [],
                keyTools: [],
                inferredTaskTitle: "Aider Session",
                lastAssistantMessage: "",
                fullText: "",
                indexedAt: Date(),
                fileModifiedAt: nil,
                summary: nil
            )
            conversations.append(conversation)
        }

        return (usages, conversations)
    }
}

private struct AiderSession {
    var startTime: Date?
    var endTime: Date?
    var model: String?
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var totalCost: Double = 0
    var messageCount: Int = 0

    var hasData: Bool { inputTokens > 0 || outputTokens > 0 }
}

// MARK: - Cursor Parser

/// Parses Cursor's ai-code-tracking.db for code provenance data and model usage distribution.
/// Token-level tracking requires the CursorConnector BYOK proxy.
final class CursorParser: LogParser, Sendable {
    let provider: AgentProvider = .cursor

    func parse() async throws -> ParseResult {
        let dbPath = ("~/.cursor/ai-tracking/ai-code-tracking.db" as NSString).expandingTildeInPath

        guard FileManager.default.fileExists(atPath: dbPath) else {
            return ParseResult(usages: [], conversations: [])
        }

        let usages = try parseCursorDatabase(dbPath: dbPath)
        return ParseResult(usages: usages, conversations: [])
    }

    private func parseCursorDatabase(dbPath: String) throws -> [TokenUsage] {
        var usages: [TokenUsage] = []

        var config = Configuration()
        config.readonly = true
        let db = try DatabaseQueue(path: dbPath, configuration: config)

        try db.read { db in
            // Check if ai_code_hashes table exists
            let tables = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table'")
            guard tables.contains("ai_code_hashes") else { return }

            // Aggregate by conversationId + model to create usage records
            let rows = try Row.fetchAll(db, sql: """
                SELECT
                    conversationId,
                    model,
                    COUNT(*) as hash_count,
                    MIN(createdAt) as first_seen,
                    MAX(createdAt) as last_seen
                FROM ai_code_hashes
                WHERE conversationId IS NOT NULL AND conversationId != ''
                GROUP BY conversationId, model
                ORDER BY last_seen DESC
                LIMIT 500
            """)

            for row in rows {
                guard let conversationId: String = row["conversationId"],
                      let hashCount: Int = row["hash_count"] else {
                    continue
                }

                let model: String = row["model"] ?? "cursor"
                let firstSeenRaw: Double = row["first_seen"] ?? Date().timeIntervalSince1970
                let lastSeenRaw: Double = row["last_seen"] ?? firstSeenRaw
                let startTime = TimestampNormalizationUtility.date(fromEpoch: firstSeenRaw)
                let normalizedLastSeen = TimestampNormalizationUtility.date(fromEpoch: lastSeenRaw, fallback: startTime)
                let endTime = max(startTime, normalizedLastSeen)

                // Estimate tokens from code hash count — each hash represents a generated code block.
                // Average code block ~150 tokens output, ~500 tokens input context.
                let estimatedOutput = hashCount * 150
                let estimatedInput = hashCount * 500

                let pricing = ModelPricing.lookup(model: model)
                let cost = pricing.cost(inputTokens: estimatedInput, outputTokens: estimatedOutput)

                let usage = TokenUsage(
                    provider: .cursor,
                    sessionId: conversationId,
                    projectName: "Cursor",
                    model: model,
                    inputTokens: estimatedInput,
                    outputTokens: estimatedOutput,
                    costUSD: cost,
                    startTime: startTime,
                    endTime: endTime,
                    provenanceMethod: .heuristicEstimate,
                    provenanceConfidence: .lowConfidenceEstimate,
                    estimatorVersion: "hash-count-ratio-v1"
                )
                usages.append(usage)
            }
        }

        return usages
    }
}

// MARK: - Codex Parser

/// Reads token usage from Codex's SQLite store and JSONL session files.
/// Prefers exact token breakdowns from JSONL `token_count` events over the aggregate `tokens_used` in SQLite.
final class CodexParser: LogParser, Sendable {
    let provider: AgentProvider = .codex
    private let fileManager: FileManager
    private let appPaths: OpenBurnBarAppPaths
    private let cacheURL: URL
    private let homeDirectoryURL: URL
    private let cacheStore: ParserDiskCacheStore<CodexCacheEntry>

    init(
        fileManager: FileManager = .default,
        appPaths: OpenBurnBarAppPaths = .live(),
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
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
        _ = try? OpenBurnBarMigration.prepareSupportDirectory(fileManager: fileManager, paths: appPaths)
    }

    func parse() async throws -> ParseResult {
        let dbPath = homeDirectoryURL
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("state_5.sqlite", isDirectory: false)
            .path

        guard fileManager.fileExists(atPath: dbPath) else {
            return ParseResult(usages: [], conversations: [])
        }

        let parsed = try parseCodexDatabase(dbPath: dbPath)
        return ParseResult(usages: parsed.usages, conversations: parsed.conversations)
    }

    private func parseCodexDatabase(dbPath: String) throws -> (usages: [TokenUsage], conversations: [ConversationRecord]) {
        var usages: [TokenUsage] = []
        var conversations: [ConversationRecord] = []
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

            let sql: String
            if hasRolloutPath {
                sql = """
                    SELECT
                        id, title, model, model_provider, tokens_used,
                        created_at, updated_at, cwd, rollout_path
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

                // Try to get exact token breakdown from JSONL session file
                var inputTokens: Int = 0
                var outputTokens: Int = 0
                var cacheReadTokens: Int = 0
                var foundExact = false

                var parsedConversation: CodexConversationCacheEntry?
                var shouldEmitConversation = expandedRolloutPath == nil

                if let expandedPath = expandedRolloutPath {
                    let cacheKey = URL(fileURLWithPath: expandedPath).standardizedFileURL.path
                    activePaths.insert(cacheKey)

                    if let signature = FileSignature(for: URL(fileURLWithPath: expandedPath)),
                       let cached = sessionCache.fileEntries[cacheKey],
                       cached.signature == signature {
                        if let tokenUsage = cached.tokenUsage {
                            inputTokens = tokenUsage.input
                            outputTokens = tokenUsage.output
                            cacheReadTokens = tokenUsage.cacheRead
                            foundExact = true
                        }
                        parsedConversation = cached.conversation
                        shouldEmitConversation = cached.conversation != nil
                    } else {
                        let parsed = parseCodexSessionJSONL(path: expandedPath)
                        if let parsed {
                            inputTokens = parsed.input
                            outputTokens = parsed.output
                            cacheReadTokens = parsed.cacheRead
                            foundExact = true
                        }
                        parsedConversation = parseCodexConversationJSONL(path: expandedPath, fallbackTitle: rawTitle)
                        shouldEmitConversation = true

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
                                conversation: parsedConversation
                            )
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
        defer { try? handle.close() }

        var inputTokens = 0
        var outputTokens = 0
        var cacheReadTokens = 0
        var foundCumulative = false
        var foundDelta = false

        for line in handle.readAllUTF8Lines() {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
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
        defer { try? handle.close() }

        var turns: [(role: String, text: String)] = []
        var keyFiles = Set<String>()
        var keyCommands = Set<String>()
        var keyTools = Set<String>()

        for line in handle.readAllUTF8Lines() {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
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
        (try? fileManager.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }

}

// MARK: - OpenClaw Parser

/// Parses OpenClaw JSON/JSONL session history from `~/.openclaw/sessions`.
///
/// OpenClaw is intentionally treated as a provider-log source, not a live
/// runtime bridge. The live OpenClaw chat path remains `ChatSessionController`;
/// this parser only gives mobile and cloud search a durable archive surface.
final class OpenClawParser: LogParser, Sendable {
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

    func parse() async throws -> ParseResult {
        guard fileManager.fileExists(atPath: sessionsDirectory.path) else {
            return ParseResult(usages: [], conversations: [])
        }

        let files = sessionFiles(in: sessionsDirectory)
        var conversations: [ConversationRecord] = []
        var usages: [TokenUsage] = []

        for file in files {
            guard let parsed = parseSession(file: file) else { continue }
            conversations.append(parsed.conversation)
            if let usage = parsed.usage {
                usages.append(usage)
            }
        }

        return ParseResult(usages: usages, conversations: conversations)
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
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            files.append(url)
        }
        return files.sorted { lhs, rhs in
            let lm = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rm = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lm > rm
        }
    }

    private func parseSession(file: URL) -> (usage: TokenUsage?, conversation: ConversationRecord)? {
        let data: Data
        if file.pathExtension.lowercased() == "jsonl" || file.pathExtension.lowercased() == "log" {
            guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
            defer { try? handle.close() }
            data = handle.readDataToEndOfFile()
        } else {
            guard let fileData = try? Data(contentsOf: file) else { return nil }
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
            let usage = TokenExtractionUtility.extractUsageTokens(object["usage"] as? [String: Any] ?? object["tokenUsage"] as? [String: Any] ?? [:])
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
        let modifiedAt = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
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
            inputTokens = TokenExtractionUtility.estimatedTokenCount(for: userText.joined(separator: "\n").count, charsPerToken: 3.5)
            outputTokens = TokenExtractionUtility.estimatedTokenCount(for: assistantText.joined(separator: "\n").count, charsPerToken: 3.5)
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
            costUSD: ModelPricing.lookup(model: model).cost(inputTokens: inputTokens, outputTokens: outputTokens, cacheReadTokens: cacheReadTokens),
            startTime: effectiveStart,
            endTime: effectiveEnd,
            provenanceMethod: cacheReadTokens > 0 ? .providerLog : .heuristicEstimate,
            provenanceConfidence: cacheReadTokens > 0 ? .exact : .lowConfidenceEstimate,
            estimatorVersion: cacheReadTokens > 0 ? "" : TokenExtractionUtility.currentEstimatorVersion
        ) : nil

        let conversation = ConversationRecord(
            id: ConversationRecord.stableId(provider: .openClaw, sessionId: sessionId),
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
                return try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            } ?? []
        if !jsonLineObjects.isEmpty {
            return jsonLineObjects
        }

        guard let root = try? JSONSerialization.jsonObject(with: data) else {
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
                if let date = ISO8601DateFormatter().date(from: string) { return date }
                if let seconds = Double(string) { return Date(timeIntervalSince1970: seconds) }
            }
            if let seconds = object[key] as? Double { return Date(timeIntervalSince1970: seconds) }
            if let seconds = object[key] as? Int { return Date(timeIntervalSince1970: TimeInterval(seconds)) }
        }
        return nil
    }
}

private struct CodexTokenUsage: Codable, Equatable {
    let input: Int
    let output: Int
    let cacheRead: Int
}

private struct CodexConversationCacheEntry: Codable, Equatable {
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

private struct CodexCacheEntry: Codable, Equatable {
    let signature: FileSignature
    let tokenUsage: CodexTokenUsage?
    let conversation: CodexConversationCacheEntry?
}

// MARK: - Model Filter Parser (for Zai/MiniMax which use Factory sessions)

final class ModelFilterParser: LogParser, Sendable {
    let provider: AgentProvider
    private let modelPattern: String
    private let fileManager: FileManager
    private let appPaths: OpenBurnBarAppPaths
    private let cacheURL: URL
    private let cacheStore: ParserDiskCacheStore<ModelFilterCacheEntry>

    init(
        modelPattern: String,
        provider: AgentProvider,
        fileManager: FileManager = .default,
        appPaths: OpenBurnBarAppPaths = .live()
    ) {
        self.modelPattern = modelPattern.lowercased()
        self.provider = provider
        self.fileManager = fileManager
        self.appPaths = appPaths

        let providerKey = provider.rawValue
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
        self.cacheURL = appPaths.supportDirectory
            .appendingPathComponent("model_filter_parser_\(providerKey).json")
        self.cacheStore = ParserDiskCacheStore(
            cacheURL: cacheURL,
            fileManager: fileManager,
            schemaVersion: 2,
            logLabel: "ModelFilterParser (\(provider.rawValue))"
        )
        _ = try? OpenBurnBarMigration.prepareSupportDirectory(fileManager: fileManager, paths: appPaths)
    }

    func parse() async throws -> ParseResult {
        let sessionsPath = "~/.factory/sessions"
        let sessionsURL = URL(fileURLWithPath: (sessionsPath as NSString).expandingTildeInPath)

        guard fileManager.fileExists(atPath: sessionsURL.path) else {
            return ParseResult(usages: [], conversations: [])
        }

        var usages: [TokenUsage] = []
        var conversations: [ConversationRecord] = []
        var parseCache = cacheStore.load()
        var activePaths = Set<String>()
        var cacheMutated = false

        let projectDirs = try fileManager.contentsOfDirectory(at: sessionsURL, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }

        for projectDir in projectDirs {
            let projectName = decodeProjectName(projectDir.lastPathComponent)

            let files = try fileManager.contentsOfDirectory(at: projectDir, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "jsonl" }

            for jsonlFile in files {
                let baseName = jsonlFile.deletingPathExtension().lastPathComponent
                let settingsFile = projectDir.appendingPathComponent("\(baseName).settings.json")
                let metadataFile = projectDir.appendingPathComponent("\(baseName).metadata.json")
                let cacheKey = cachePath(for: jsonlFile)
                activePaths.insert(cacheKey)

                if let signature = compositeSignature(
                    jsonlFile: jsonlFile,
                    settingsFile: settingsFile,
                    metadataFile: metadataFile
                ),
                   let cached = parseCache.fileEntries[cacheKey],
                   cached.signature == signature {
                    appendCached(cached, usages: &usages, conversations: &conversations)
                } else {
                    let parsed = try? parseSession(file: jsonlFile, projectName: projectName)
                    appendParsed(parsed, usages: &usages, conversations: &conversations)

                    if let signature = compositeSignature(
                        jsonlFile: jsonlFile,
                        settingsFile: settingsFile,
                        metadataFile: metadataFile
                    ) {
                        parseCache.fileEntries[cacheKey] = ModelFilterCacheEntry(
                            signature: signature,
                            usage: parsed?.usage,
                            conversation: parsed?.conversation
                        )
                        cacheMutated = true
                    }
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

        if cacheMutated {
            cacheStore.persist(parseCache)
        }

        return ParseResult(usages: usages, conversations: conversations)
    }

    private func decodeProjectName(_ encoded: String) -> String {
        var decoded = encoded
            .replacingOccurrences(of: "-Users-", with: "~/")
            .replacingOccurrences(of: "-", with: "/")
        while decoded.contains("//") {
            decoded = decoded.replacingOccurrences(of: "//", with: "/")
        }
        return decoded
    }

    private func parseSession(file: URL, projectName: String) throws -> (usage: TokenUsage?, conversation: ConversationRecord?)? {
        guard let handle = try? FileHandle(forReadingFrom: file) else {
            return nil
        }
        defer { try? handle.close() }

        let mtime = (try? fileManager.attributesOfItem(atPath: file.path)[.modificationDate]) as? Date
        let conv = ClaudeConversationAccumulator()

        let baseName = file.deletingPathExtension().lastPathComponent
        let settingsURL = file.deletingLastPathComponent().appendingPathComponent("\(baseName).settings.json")
        let metadataURL = file.deletingLastPathComponent().appendingPathComponent("\(baseName).metadata.json")

        var inlineModel: String?
        var inputTokens = 0
        var outputTokens = 0
        var cacheCreationTokens = 0
        var cacheReadTokens = 0
        var usedSettingsTotals = false
        var usedFallbackEstimate = false
        var settingsModel: String?

        if let data = try? Data(contentsOf: settingsURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let m = json["model"] as? String {
                settingsModel = TokenExtractionUtility.normalizeModelName(m)
            }
            if let tokenUsage = json["tokenUsage"] as? [String: Any] {
                let extracted = TokenExtractionUtility.extractUsageTokens(tokenUsage)
                if extracted.input > 0 || extracted.output > 0 || extracted.cacheCreation > 0 || extracted.cacheRead > 0 {
                    inputTokens = extracted.input
                    outputTokens = extracted.output
                    cacheCreationTokens = extracted.cacheCreation
                    cacheReadTokens = extracted.cacheRead
                    usedSettingsTotals = true
                }
            }
        }

        if !usedSettingsTotals,
           let data = try? Data(contentsOf: metadataURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if settingsModel == nil, let m = json["model"] as? String {
                settingsModel = TokenExtractionUtility.normalizeModelName(m)
            }
            if let tokenUsage = json["tokenUsage"] as? [String: Any] ?? json["usage"] as? [String: Any] {
                let extracted = TokenExtractionUtility.extractUsageTokens(tokenUsage)
                if extracted.input > 0 || extracted.output > 0 || extracted.cacheCreation > 0 || extracted.cacheRead > 0 {
                    inputTokens = extracted.input
                    outputTokens = extracted.output
                    cacheCreationTokens = extracted.cacheCreation
                    cacheReadTokens = extracted.cacheRead
                    usedSettingsTotals = true
                }
            }
        }

        var startTime: Date?
        var endTime: Date?
        var userCharCount = 0
        var assistantCharCount = 0
        var assistantReasoningCharCount = 0
        var userMessageCount = 0
        var assistantMessageCount = 0

        for line in handle.readAllUTF8Lines() {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            conv.ingest(jsonLine: json)

            if let message = json["message"] as? [String: Any] {
                let role = (message["role"] as? String)?.lowercased()
                if let content = message["content"] {
                    let metrics = TokenExtractionUtility.contentMetrics(from: content)
                    if role == "user" {
                        let chars = metrics.visibleChars + metrics.reasoningChars
                        if chars > 0 {
                            userCharCount += chars
                            userMessageCount += 1
                        }
                    } else if role == "assistant" {
                        let chars = metrics.visibleChars + metrics.reasoningChars
                        if chars > 0 {
                            assistantMessageCount += 1
                        }
                        assistantCharCount += metrics.visibleChars
                        assistantReasoningCharCount += metrics.reasoningChars
                    }

                    if inlineModel == nil, let detectedModel = TokenExtractionUtility.detectModelHint(from: content) {
                        inlineModel = TokenExtractionUtility.normalizeModelName(detectedModel)
                    }
                }
            }

            if usedSettingsTotals {
                if let message = json["message"] as? [String: Any],
                   message["role"] as? String == "assistant",
                   let ts = json["timestamp"] as? String {
                    let date = ISO8601DateFormatter().date(from: ts)
                    if startTime == nil { startTime = date }
                    endTime = date
                }
                continue
            }

            if let message = json["message"] as? [String: Any],
               let usage = message["usage"] as? [String: Any] {
                let extracted = TokenExtractionUtility.extractUsageTokens(
                    usage,
                    inputHint: userCharCount,
                    outputHint: assistantCharCount + assistantReasoningCharCount
                )
                inputTokens += extracted.input
                outputTokens += extracted.output
                cacheCreationTokens += extracted.cacheCreation
                cacheReadTokens += extracted.cacheRead

                if let ts = json["timestamp"] as? String {
                    let date = ISO8601DateFormatter().date(from: ts)
                    if startTime == nil { startTime = date }
                    endTime = date
                }
            }
        }

        conv.finalizeArrays()

        if inputTokens == 0 && outputTokens == 0 && cacheCreationTokens == 0 && cacheReadTokens == 0 {
            guard userCharCount + assistantCharCount + assistantReasoningCharCount > 0 else { return nil }
            let estimated = TokenExtractionUtility.estimateFallbackTokens(
                userVisibleChars: userCharCount,
                assistantVisibleChars: assistantCharCount,
                assistantReasoningChars: assistantReasoningCharCount,
                userMessageCount: userMessageCount,
                assistantMessageCount: assistantMessageCount
            )
            inputTokens = estimated.input
            outputTokens = estimated.output
            usedFallbackEstimate = true
        }

        let modelFromSettings = settingsModel.flatMap { m in
            m.lowercased().contains(modelPattern) ? m : nil
        }
        let resolvedModel = modelFromSettings ?? inlineModel
        guard let model = resolvedModel, model.lowercased().contains(modelPattern) else {
            return nil
        }

        guard inputTokens > 0 || outputTokens > 0 || cacheCreationTokens > 0 || cacheReadTokens > 0 else {
            return nil
        }

        let resolvedStart = startTime ?? conv.startTime ?? Date()
        let resolvedEnd = endTime ?? conv.endTime ?? resolvedStart

        let cost = ModelPricing.lookup(model: model).cost(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheCreationTokens: cacheCreationTokens,
            cacheReadTokens: cacheReadTokens
        )
        let sessionId = baseName

        let usage = TokenUsage(
            provider: provider,
            sessionId: sessionId,
            projectName: projectName,
            model: model,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheCreationTokens: cacheCreationTokens,
            cacheReadTokens: cacheReadTokens,
            costUSD: cost,
            startTime: resolvedStart,
            endTime: resolvedEnd,
            provenanceMethod: usedFallbackEstimate ? .heuristicEstimate : .providerLog,
            provenanceConfidence: usedFallbackEstimate ? .lowConfidenceEstimate : .exact,
            estimatorVersion: usedFallbackEstimate ? TokenExtractionUtility.currentEstimatorVersion : ""
        )

        let conversation = ConversationRecord(
            id: ConversationRecord.stableId(provider: provider, sessionId: sessionId),
            provider: provider,
            sessionId: sessionId,
            projectName: projectName,
            startTime: conv.startTime ?? usage.startTime,
            endTime: conv.endTime ?? usage.endTime,
            messageCount: conv.messageCount,
            userWordCount: conv.userWordCount,
            assistantWordCount: conv.assistantWordCount,
            keyFiles: conv.keyFiles,
            keyCommands: conv.keyCommands,
            keyTools: conv.keyTools,
            inferredTaskTitle: conv.firstUserText ?? projectName,
            lastAssistantMessage: conv.lastAssistantText,
            fullText: conv.fullText,
            indexedAt: Date(),
            fileModifiedAt: mtime,
            summary: nil
        )

        return (usage, conversation)
    }

    private func cachePath(for file: URL) -> String {
        file.standardizedFileURL.path
    }

    private func appendCached(
        _ cached: ModelFilterCacheEntry,
        usages: inout [TokenUsage],
        conversations: inout [ConversationRecord]
    ) {
        if let usage = cached.usage {
            usages.append(usage)
        }
        if let conversation = cached.conversation {
            conversations.append(conversation)
        }
    }

    private func appendParsed(
        _ parsed: (usage: TokenUsage?, conversation: ConversationRecord?)?,
        usages: inout [TokenUsage],
        conversations: inout [ConversationRecord]
    ) {
        guard let parsed else { return }
        if let usage = parsed.usage {
            usages.append(usage)
        }
        if let conversation = parsed.conversation {
            conversations.append(conversation)
        }
    }

    private func compositeSignature(
        jsonlFile: URL,
        settingsFile: URL,
        metadataFile: URL
    ) -> CompositeFileSignature<FileSignature>? {
        guard let jsonl = FileSignature(for: jsonlFile) else { return nil }
        let settings = FileSignature(for: settingsFile)
        let metadata = FileSignature(for: metadataFile)
        return CompositeFileSignature(primary: jsonl, settings: settings, metadata: metadata)
    }
}

private struct ModelFilterCacheEntry: Codable, Equatable {
    let signature: CompositeFileSignature<FileSignature>
    let usage: TokenUsage?
    let conversation: ConversationRecord?
}

// MARK: - OpenCode Parser

/// Parses OpenCode sessions from the local SQLite store (`~/.local/share/opencode/opencode.db`).
///
/// OpenCode persists three tables — `session`, `message`, and `part` — where each row stores a
/// JSON `data` blob. Messages carry role / token / cost / model metadata; parts carry the text
/// content. This parser stitches them into per-session `TokenUsage` rows plus full
/// `ConversationRecord` transcripts so OpenCode conversations back up and search like every
/// other CLI agent. Schema discovery is defensive (column and JSON-key fallbacks) so future
/// OpenCode storage tweaks degrade gracefully instead of dropping data.
final class OpenCodeParser: LogParser, Sendable {
    let provider: AgentProvider = .openCode

    /// When set, the parser reads this exact `opencode.db` path instead of
    /// discovering it from the environment / default install locations. Keeps
    /// tests hermetic and supports non-default OpenCode data homes.
    private let databasePathOverride: String?

    init(databasePathOverride: String? = nil) {
        self.databasePathOverride = databasePathOverride
    }

    func parse() async throws -> ParseResult {
        let fm = FileManager.default
        let resolved = databasePathOverride.map { ($0 as NSString).expandingTildeInPath }
            ?? Self.resolvedDatabasePath()
        guard let dbPath = resolved, fm.fileExists(atPath: dbPath) else {
            return ParseResult(usages: [], conversations: [])
        }
        return try parseDatabase(dbPath: dbPath)
    }

    static func resolvedDatabasePath() -> String? {
        let env = ProcessInfo.processInfo.environment
        if let explicit = env["OPENCODE_DB_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty {
            return (explicit as NSString).expandingTildeInPath
        }
        if let dataHome = env["OPENCODE_DATA_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines), !dataHome.isEmpty {
            return ((dataHome as NSString).appendingPathComponent("opencode.db") as NSString).expandingTildeInPath
        }
        if let xdg = env["XDG_DATA_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines), !xdg.isEmpty {
            return ((xdg as NSString).appendingPathComponent("opencode/opencode.db") as NSString).expandingTildeInPath
        }
        return ("~/.local/share/opencode/opencode.db" as NSString).expandingTildeInPath
    }

    private struct SessionMeta {
        var title: String?
        var directory: String?
        var created: Date?
        var updated: Date?
    }

    private struct MessageRow {
        let messageID: String
        let role: String
        let time: Double
        var model: String?
        var input = 0
        var output = 0
        var cacheCreation = 0
        var cacheRead = 0
        var cost: Double?
    }

    private func parseDatabase(dbPath: String) throws -> ParseResult {
        var config = Configuration()
        config.readonly = true
        let db = try DatabaseQueue(path: dbPath, configuration: config)

        var sessionMeta: [String: SessionMeta] = [:]
        var messagesBySession: [String: [MessageRow]] = [:]
        var textByMessage: [String: String] = [:]

        try db.read { db in
            let tables = Set(try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table'"))

            if tables.contains("session") {
                for row in try Row.fetchAll(db, sql: "SELECT * FROM session") {
                    guard let json = Self.dataJSON(row) else { continue }
                    let id = Self.identifier(row, json, keys: ["id", "sessionID", "session_id", "sessionId"])
                    guard let sessionID = id else { continue }
                    var meta = SessionMeta()
                    meta.title = (json["title"] as? String)?.nonEmpty
                    meta.directory = (json["directory"] as? String
                        ?? json["cwd"] as? String
                        ?? json["worktree"] as? String)?.nonEmpty
                    let time = json["time"] as? [String: Any]
                    meta.created = Self.date(time?["created"] ?? json["created"] ?? Self.columnValue(row, "time_created"))
                    meta.updated = Self.date(time?["updated"] ?? json["updated"] ?? Self.columnValue(row, "time_updated"))
                    sessionMeta[sessionID] = meta
                }
            }

            if tables.contains("message") {
                for row in try Row.fetchAll(db, sql: "SELECT * FROM message") {
                    guard let json = Self.dataJSON(row),
                          let sessionID = Self.identifier(row, json, keys: ["sessionID", "session_id", "sessionId"]) else { continue }
                    let messageID = Self.identifier(row, json, keys: ["id", "messageID", "message_id", "messageId"]) ?? UUID().uuidString
                    let role = (json["role"] as? String ?? "").lowercased()
                    let time = json["time"] as? [String: Any]
                    let created = Self.epoch(time?["created"] ?? json["created"] ?? Self.columnValue(row, "time_created")) ?? 0
                    var message = MessageRow(messageID: messageID, role: role, time: created)
                    if let tokens = Self.openCodeTokens(json) {
                        message.input = tokens.input
                        message.output = tokens.output
                        message.cacheCreation = tokens.cacheCreation
                        message.cacheRead = tokens.cacheRead
                    }
                    message.cost = Self.doubleValue(json["cost"])
                    message.model = Self.resolvedModel(json)
                    messagesBySession[sessionID, default: []].append(message)
                }
            }

            if tables.contains("part") {
                for row in try Row.fetchAll(db, sql: "SELECT * FROM part") {
                    guard let json = Self.dataJSON(row) else { continue }
                    let type = (json["type"] as? String ?? "text").lowercased()
                    guard type == "text" || type == "reasoning" else { continue }
                    guard let messageID = Self.identifier(row, json, keys: ["messageID", "message_id", "messageId"]) else { continue }
                    let text = (json["text"] as? String ?? json["content"] as? String ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    if var existing = textByMessage[messageID] {
                        existing += "\n\n" + text
                        textByMessage[messageID] = existing
                    } else {
                        textByMessage[messageID] = text
                    }
                }
            }
        }

        var usages: [TokenUsage] = []
        var conversations: [ConversationRecord] = []

        for (sessionID, rawMessages) in messagesBySession {
            let messages = rawMessages.sorted { $0.time < $1.time }
            let meta = sessionMeta[sessionID] ?? SessionMeta()

            var input = 0, output = 0, cacheCreation = 0, cacheRead = 0
            var cost = 0.0
            var model = "opencode"
            for message in messages {
                input += message.input
                output += message.output
                cacheCreation += message.cacheCreation
                cacheRead += message.cacheRead
                if let messageCost = message.cost { cost += messageCost }
                if let messageModel = message.model?.nonEmpty { model = messageModel }
            }

            let directory = meta.directory ?? "~"
            let projectName = (directory as NSString).lastPathComponent.nonEmpty
                ?? meta.title?.nonEmpty
                ?? sessionID
            let firstTime = messages.first?.time ?? 0
            let lastTime = messages.last?.time ?? firstTime
            let startTime = meta.created ?? Self.date(fromEpoch: firstTime) ?? Date()
            let endTime = meta.updated ?? Self.date(fromEpoch: lastTime) ?? startTime

            var usedFallback = false
            if input == 0 && output == 0 && cacheCreation == 0 && cacheRead == 0 {
                let userChars = messages
                    .filter { $0.role == "user" }
                    .reduce(0) { $0 + (textByMessage[$1.messageID]?.count ?? 0) }
                let assistantChars = messages
                    .filter { $0.role == "assistant" }
                    .reduce(0) { $0 + (textByMessage[$1.messageID]?.count ?? 0) }
                guard userChars + assistantChars > 0 else { continue }
                let estimated = TokenExtractionUtility.estimateFallbackTokens(
                    userVisibleChars: userChars,
                    assistantVisibleChars: assistantChars,
                    assistantReasoningChars: 0,
                    userMessageCount: max(messages.filter { $0.role == "user" }.count, 1),
                    assistantMessageCount: max(messages.filter { $0.role == "assistant" }.count, 1)
                )
                input = estimated.input
                output = estimated.output
                usedFallback = true
            }

            if cost <= 0 {
                cost = ModelPricing.lookup(model: model).cost(
                    inputTokens: input,
                    outputTokens: output,
                    cacheCreationTokens: cacheCreation,
                    cacheReadTokens: cacheRead
                )
            }

            usages.append(
                TokenUsage(
                    provider: .openCode,
                    sessionId: sessionID,
                    projectName: projectName,
                    model: model,
                    inputTokens: input,
                    outputTokens: output,
                    cacheCreationTokens: cacheCreation,
                    cacheReadTokens: cacheRead,
                    costUSD: cost,
                    startTime: startTime,
                    endTime: endTime,
                    provenanceMethod: usedFallback ? .heuristicEstimate : .providerLog,
                    provenanceConfidence: usedFallback ? .lowConfidenceEstimate : .exact,
                    estimatorVersion: usedFallback ? TokenExtractionUtility.currentEstimatorVersion : ""
                )
            )

            var fullText = ""
            var firstUser: String?
            var lastAssistant = ""
            var userWords = 0
            var assistantWords = 0
            var renderedMessages = 0
            for message in messages {
                guard let text = textByMessage[message.messageID]?.nonEmpty else { continue }
                let isAssistant = message.role == "assistant"
                if isAssistant {
                    assistantWords += text.split { $0.isWhitespace || $0.isNewline }.count
                    lastAssistant = text
                } else {
                    userWords += text.split { $0.isWhitespace || $0.isNewline }.count
                    if firstUser == nil { firstUser = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120)) }
                }
                if !fullText.isEmpty { fullText += "\n\n" }
                fullText += SessionLogMarkdownFormatter.transcriptTurnMarkdown(isAssistant: isAssistant, body: text)
                renderedMessages += 1
            }

            conversations.append(
                ConversationRecord(
                    id: ConversationRecord.stableId(provider: .openCode, sessionId: sessionID),
                    provider: .openCode,
                    sessionId: sessionID,
                    projectName: projectName,
                    startTime: startTime,
                    endTime: endTime,
                    messageCount: renderedMessages,
                    userWordCount: userWords,
                    assistantWordCount: assistantWords,
                    keyFiles: [],
                    keyCommands: [],
                    keyTools: [],
                    inferredTaskTitle: meta.title?.nonEmpty ?? firstUser ?? sessionID,
                    lastAssistantMessage: String(lastAssistant.prefix(500)),
                    fullText: fullText,
                    indexedAt: Date(),
                    workingDirectory: meta.directory,
                    fileModifiedAt: endTime,
                    summary: nil
                )
            )
        }

        return ParseResult(usages: usages, conversations: conversations)
    }

    // MARK: - JSON / column helpers

    private static func dataJSON(_ row: Row) -> [String: Any]? {
        for column in ["data", "json", "value", "content", "payload"] {
            if let text: String = row[column],
               let data = text.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return json
            }
        }
        return nil
    }

    private static func columnValue(_ row: Row, _ column: String) -> Any? {
        // Read through `DatabaseValue` so a type mismatch (e.g. a TEXT epoch
        // column) never trips GRDB's force-decode `fatalError`.
        guard let dbValue: DatabaseValue = row[column] else { return nil }
        switch dbValue.storage {
        case .int64(let value): return value
        case .double(let value): return value
        case .string(let value): return value
        case .null, .blob: return nil
        }
    }

    private static func identifier(_ row: Row, _ json: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value: String = row[key], !value.isEmpty { return value }
        }
        for key in keys {
            if let value = json[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    private static func resolvedModel(_ json: [String: Any]) -> String? {
        let modelID = (json["modelID"] as? String ?? json["model"] as? String ?? json["model_id"] as? String)?.nonEmpty
        if let modelID { return TokenExtractionUtility.normalizeModelName(modelID) }
        if let provider = (json["providerID"] as? String ?? json["provider"] as? String)?.nonEmpty {
            return TokenExtractionUtility.normalizeModelName(provider)
        }
        return nil
    }

    private static func openCodeTokens(_ json: [String: Any]) -> (input: Int, output: Int, cacheCreation: Int, cacheRead: Int)? {
        guard let tokens = json["tokens"] as? [String: Any] else {
            if let usage = json["usage"] as? [String: Any] {
                let extracted = TokenExtractionUtility.extractUsageTokens(usage)
                return (extracted.input, extracted.output, extracted.cacheCreation, extracted.cacheRead)
            }
            return nil
        }
        let input = intValue(tokens["input"])
        let output = intValue(tokens["output"])
        var cacheRead = intValue(tokens["cache_read"])
        var cacheWrite = intValue(tokens["cache_write"])
        if let cache = tokens["cache"] as? [String: Any] {
            cacheRead = intValue(cache["read"])
            cacheWrite = intValue(cache["write"])
        }
        return (input, output, cacheWrite, cacheRead)
    }

    private static func intValue(_ value: Any?) -> Int {
        switch value {
        case let int as Int: return int
        case let int as Int64: return Int(int)
        case let double as Double: return Int(double.rounded())
        case let number as NSNumber: return number.intValue
        case let string as String: return Int(string) ?? Int(Double(string) ?? 0)
        default: return 0
        }
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        switch value {
        case let double as Double: return double
        case let int as Int: return Double(int)
        case let number as NSNumber: return number.doubleValue
        case let string as String: return Double(string)
        default: return nil
        }
    }

    private static func epoch(_ value: Any?) -> Double? {
        switch value {
        case let double as Double: return double
        case let int as Int: return Double(int)
        case let int as Int64: return Double(int)
        case let number as NSNumber: return number.doubleValue
        case let string as String:
            if let double = Double(string) { return double }
            return ThreadSafeISO8601DateFormatter.parse(string)?.timeIntervalSince1970
        default: return nil
        }
    }

    private static func date(_ value: Any?) -> Date? {
        if let string = value as? String, let parsed = ThreadSafeISO8601DateFormatter.parse(string) {
            return parsed
        }
        guard let epoch = epoch(value) else { return nil }
        return date(fromEpoch: epoch)
    }

    private static func date(fromEpoch epoch: Double) -> Date? {
        guard epoch > 0 else { return nil }
        return TimestampNormalizationUtility.date(fromEpoch: epoch)
    }
}

// MARK: - Pi Agent Parser

/// Parses Pi Agent workspace logs from `~/.pi/sessions/*.jsonl`.
///
/// Pi writes one JSONL file per session with user/assistant turns and optional inline `usage`
/// blocks. This parser extracts exact tokens when present, estimates from transcript volume
/// otherwise, and always emits a full `ConversationRecord` so Pi conversations back up and
/// search alongside every other agent.
final class PiAgentParser: LogParser, Sendable {
    let provider: AgentProvider = .piAgent

    func parse() async throws -> ParseResult {
        let fm = FileManager.default
        let sessionsPath = (provider.logDirectory as NSString).expandingTildeInPath
        guard fm.fileExists(atPath: sessionsPath) else {
            return ParseResult(usages: [], conversations: [])
        }

        let sessionsURL = URL(fileURLWithPath: sessionsPath)
        let jsonlFiles = (try? fm.contentsOfDirectory(at: sessionsURL, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "jsonl" } ?? []

        var usages: [TokenUsage] = []
        var conversations: [ConversationRecord] = []

        for file in jsonlFiles {
            let sessionId = file.deletingPathExtension().lastPathComponent
            if let pair = parseSession(file: file, sessionId: sessionId) {
                if let usage = pair.usage { usages.append(usage) }
                if let conversation = pair.conversation { conversations.append(conversation) }
            }
        }

        return ParseResult(usages: usages, conversations: conversations)
    }

    private func parseSession(file: URL, sessionId: String) -> (usage: TokenUsage?, conversation: ConversationRecord?)? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }

        let mtime = (try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate]) as? Date

        var inputTokens = 0
        var outputTokens = 0
        var cacheCreationTokens = 0
        var cacheReadTokens = 0
        var model = "pi"
        var startTime: Date?
        var endTime: Date?
        var workingDirectory: String?
        var userChars = 0
        var assistantChars = 0
        var userWords = 0
        var assistantWords = 0
        var messageCount = 0
        var fullText = ""
        var firstUser: String?
        var lastAssistant = ""

        for line in handle.readAllUTF8Lines() {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            if let ts = json["timestamp"] as? String ?? json["time"] as? String,
               let date = ThreadSafeISO8601DateFormatter.parse(ts) {
                if startTime == nil { startTime = date }
                endTime = date
            }
            if let m = (json["model"] as? String ?? (json["message"] as? [String: Any])?["model"] as? String)?.nonEmpty {
                model = TokenExtractionUtility.normalizeModelName(m)
            }
            if let cwd = (json["cwd"] as? String ?? json["workingDirectory"] as? String ?? json["directory"] as? String)?.nonEmpty {
                workingDirectory = cwd
            }

            if let usage = json["usage"] as? [String: Any]
                ?? (json["message"] as? [String: Any])?["usage"] as? [String: Any] {
                let extracted = TokenExtractionUtility.extractUsageTokens(usage)
                inputTokens += extracted.input
                outputTokens += extracted.output
                cacheCreationTokens += extracted.cacheCreation
                cacheReadTokens += extracted.cacheRead
            }

            let message = json["message"] as? [String: Any]
            let role = (json["role"] as? String ?? message?["role"] as? String ?? json["type"] as? String ?? "").lowercased()
            let content = Self.contentText(json["content"] ?? message?["content"] ?? json["text"])

            guard !content.isEmpty else { continue }

            if role == "user" || role == "human" || role == "user_message" {
                userChars += content.count
                userWords += content.split { $0.isWhitespace || $0.isNewline }.count
                if firstUser == nil { firstUser = String(content.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120)) }
                if !fullText.isEmpty { fullText += "\n\n" }
                fullText += SessionLogMarkdownFormatter.transcriptTurnMarkdown(isAssistant: false, body: content)
                messageCount += 1
            } else if role == "assistant" || role == "ai" || role == "assistant_message" {
                assistantChars += content.count
                assistantWords += content.split { $0.isWhitespace || $0.isNewline }.count
                lastAssistant = content
                if !fullText.isEmpty { fullText += "\n\n" }
                fullText += SessionLogMarkdownFormatter.transcriptTurnMarkdown(isAssistant: true, body: content)
                messageCount += 1
            }
        }

        let hasUsage = inputTokens > 0 || outputTokens > 0 || cacheCreationTokens > 0 || cacheReadTokens > 0
        var usedFallback = false
        if !hasUsage {
            guard userChars + assistantChars > 0 else { return nil }
            let estimated = TokenExtractionUtility.estimateFallbackTokens(
                userVisibleChars: userChars,
                assistantVisibleChars: assistantChars,
                assistantReasoningChars: 0,
                userMessageCount: max(messageCount / 2, 1),
                assistantMessageCount: max(messageCount / 2, 1)
            )
            inputTokens = estimated.input
            outputTokens = estimated.output
            usedFallback = true
        }

        guard inputTokens > 0 || outputTokens > 0 || cacheCreationTokens > 0 || cacheReadTokens > 0 else { return nil }

        let cost = ModelPricing.lookup(model: model).cost(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheCreationTokens: cacheCreationTokens,
            cacheReadTokens: cacheReadTokens
        )
        let projectName = workingDirectory.map { ($0 as NSString).lastPathComponent.nonEmpty ?? $0 } ?? sessionId

        let usage = TokenUsage(
            provider: .piAgent,
            sessionId: sessionId,
            projectName: projectName,
            model: model,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheCreationTokens: cacheCreationTokens,
            cacheReadTokens: cacheReadTokens,
            costUSD: cost,
            startTime: startTime ?? mtime ?? Date(),
            endTime: endTime ?? mtime ?? Date(),
            provenanceMethod: usedFallback ? .heuristicEstimate : .providerLog,
            provenanceConfidence: usedFallback ? .lowConfidenceEstimate : .exact,
            estimatorVersion: usedFallback ? TokenExtractionUtility.currentEstimatorVersion : ""
        )

        let conversation = ConversationRecord(
            id: ConversationRecord.stableId(provider: .piAgent, sessionId: sessionId),
            provider: .piAgent,
            sessionId: sessionId,
            projectName: projectName,
            startTime: startTime ?? usage.startTime,
            endTime: endTime ?? usage.endTime,
            messageCount: messageCount,
            userWordCount: userWords,
            assistantWordCount: assistantWords,
            keyFiles: [],
            keyCommands: [],
            keyTools: [],
            inferredTaskTitle: firstUser ?? sessionId,
            lastAssistantMessage: String(lastAssistant.prefix(500)),
            fullText: fullText,
            indexedAt: Date(),
            workingDirectory: workingDirectory,
            fileModifiedAt: mtime,
            summary: nil
        )

        return (usage, conversation)
    }

    /// Flattens Pi content that may be a plain string or an array of `{type, text}` blocks.
    private static func contentText(_ raw: Any?) -> String {
        if let string = raw as? String { return string }
        if let blocks = raw as? [[String: Any]] {
            let parts = blocks.compactMap { block -> String? in
                let type = (block["type"] as? String ?? "text").lowercased()
                guard type == "text" || type == "reasoning" || type.isEmpty else { return nil }
                return (block["text"] as? String ?? block["content"] as? String)?.nonEmpty
            }
            return parts.joined(separator: "\n\n")
        }
        return ""
    }
}
