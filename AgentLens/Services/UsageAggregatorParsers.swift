import Foundation
import CryptoKit
import GRDB

// MARK: - Copilot Parser

/// Parses Copilot CLI sessions from ~/.copilot/session-state/*/events.jsonl.
/// Post-Feb 2026 Copilot CLI persists assistant.usage and session.shutdown events with exact token counts.
/// Falls back to CompactionProcessor log deltas for older CLI versions.
final class CopilotParser: LogParser, @unchecked Sendable {
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
final class AiderParser: LogParser, @unchecked Sendable {
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
        for path in candidatePaths {
            if fm.fileExists(atPath: path) {
                analyticsFiles.append(URL(fileURLWithPath: path))
            }
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
final class CursorParser: LogParser, @unchecked Sendable {
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
final class CodexParser: LogParser, @unchecked Sendable {
    let provider: AgentProvider = .codex
    private let fileManager: FileManager
    private let appPaths: OpenBurnBarAppPaths
    private let cacheURL: URL
    private let homeDirectoryURL: URL

    init(
        fileManager: FileManager = .default,
        appPaths: OpenBurnBarAppPaths = .live(),
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.fileManager = fileManager
        self.appPaths = appPaths
        self.homeDirectoryURL = homeDirectoryURL
        self.cacheURL = appPaths.supportDirectory.appendingPathComponent("codex_parser_cache.json")
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

        let usages = try parseCodexDatabase(dbPath: dbPath)
        return ParseResult(usages: usages, conversations: [])
    }

    private func parseCodexDatabase(dbPath: String) throws -> [TokenUsage] {
        var usages: [TokenUsage] = []
        var sessionCache = loadSessionCache()
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
                let cwd: String = row["cwd"] ?? "~"
                let projectName = (cwd as NSString).lastPathComponent
                let startTime = Date(timeIntervalSince1970: Double(createdAt))
                let endTime = Date(timeIntervalSince1970: Double(updatedAt))

                // Try to get exact token breakdown from JSONL session file
                var inputTokens: Int = 0
                var outputTokens: Int = 0
                var cacheReadTokens: Int = 0
                var foundExact = false

                if hasRolloutPath, let rolloutPath: String = row["rollout_path"] {
                    let expandedPath = (rolloutPath as NSString).expandingTildeInPath
                    let cacheKey = URL(fileURLWithPath: expandedPath).standardizedFileURL.path
                    activePaths.insert(cacheKey)

                    if let signature = fileSignature(forPath: expandedPath),
                       let cached = sessionCache.fileEntries[cacheKey],
                       cached.signature == signature {
                        if let tokenUsage = cached.tokenUsage {
                            inputTokens = tokenUsage.input
                            outputTokens = tokenUsage.output
                            cacheReadTokens = tokenUsage.cacheRead
                            foundExact = true
                        }
                    } else {
                        let parsed = parseCodexSessionJSONL(path: expandedPath)
                        if let parsed {
                            inputTokens = parsed.input
                            outputTokens = parsed.output
                            cacheReadTokens = parsed.cacheRead
                            foundExact = true
                        }

                        if let signature = fileSignature(forPath: expandedPath) {
                            sessionCache.fileEntries[cacheKey] = CodexSessionCacheEntry(
                                signature: signature,
                                tokenUsage: parsed.map {
                                    CodexSessionTokenUsage(
                                        input: $0.input,
                                        output: $0.output,
                                        cacheRead: $0.cacheRead
                                    )
                                }
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

                guard inputTokens > 0 || outputTokens > 0 else { continue }

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
        }

        let stalePaths = Set(sessionCache.fileEntries.keys).subtracting(activePaths)
        if !stalePaths.isEmpty {
            for stalePath in stalePaths {
                sessionCache.fileEntries.removeValue(forKey: stalePath)
            }
            cacheMutated = true
        }

        if cacheMutated {
            persistSessionCache(sessionCache)
        }

        return usages
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
                // If we had previously accumulated delta values, replace with cumulative.
                // This ensures cumulative > delta precedence for mixed logs.
                if foundDelta {
                    inputTokens = extracted.input
                    outputTokens = extracted.output
                    cacheReadTokens = extracted.cacheRead
                    foundDelta = false
                } else {
                    inputTokens = extracted.input
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

    private func loadSessionCache() -> CodexSessionParserCache {
        guard fileManager.fileExists(atPath: cacheURL.path) else { return .empty }
        do {
            let data = try Data(contentsOf: cacheURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let cache = try decoder.decode(CodexSessionParserCache.self, from: data)
            guard cache.schemaVersion == CodexSessionParserCache.empty.schemaVersion else {
                return .empty
            }
            return cache
        } catch {
            return .empty
        }
    }

    private func persistSessionCache(_ cache: CodexSessionParserCache) {
        do {
            if !fileManager.fileExists(atPath: appPaths.supportDirectory.path) {
                try fileManager.createDirectory(at: appPaths.supportDirectory, withIntermediateDirectories: true)
            }
            var persisted = cache
            persisted.lastUpdatedAt = Date()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(persisted)
            try data.write(to: cacheURL, options: .atomic)
        } catch {
            AppLogger.parser.silentFailure("CodexParser: Failed to persist session cache", error: error)
        }
    }

    private func fileSignature(forPath path: String) -> CodexSessionFileSignature? {
        let fileURL = URL(fileURLWithPath: path)
        let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey])
        guard values?.isRegularFile == true else { return nil }
        let modifiedAt = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let sizeBytes = Int64(values?.fileSize ?? 0)
        return CodexSessionFileSignature(modifiedAt: modifiedAt, sizeBytes: sizeBytes)
    }
}

private struct CodexSessionFileSignature: Codable, Equatable {
    let modifiedAt: TimeInterval
    let sizeBytes: Int64
}

private struct CodexSessionTokenUsage: Codable, Equatable {
    let input: Int
    let output: Int
    let cacheRead: Int
}

private struct CodexSessionCacheEntry: Codable, Equatable {
    let signature: CodexSessionFileSignature
    let tokenUsage: CodexSessionTokenUsage?
}

private struct CodexSessionParserCache: Codable, Equatable {
    var schemaVersion: Int
    var fileEntries: [String: CodexSessionCacheEntry]
    var lastUpdatedAt: Date?

    static let empty = CodexSessionParserCache(
        schemaVersion: 1,
        fileEntries: [:],
        lastUpdatedAt: nil
    )
}

// MARK: - Model Filter Parser (for Zai/MiniMax which use Factory sessions)

final class ModelFilterParser: LogParser, @unchecked Sendable {
    let provider: AgentProvider
    private let modelPattern: String
    private let fileManager: FileManager
    private let appPaths: OpenBurnBarAppPaths
    private let cacheURL: URL

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
        var parseCache = loadParseCache()
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
                        parseCache.fileEntries[cacheKey] = ModelFilterCachedSession(
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
            persistParseCache(parseCache)
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
        _ cached: ModelFilterCachedSession,
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

    private func loadParseCache() -> ModelFilterParserCache {
        guard fileManager.fileExists(atPath: cacheURL.path) else { return .empty }
        do {
            let data = try Data(contentsOf: cacheURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let cache = try decoder.decode(ModelFilterParserCache.self, from: data)
            guard cache.schemaVersion == ModelFilterParserCache.empty.schemaVersion else {
                return .empty
            }
            return cache
        } catch {
            return .empty
        }
    }

    private func persistParseCache(_ cache: ModelFilterParserCache) {
        do {
            if !fileManager.fileExists(atPath: appPaths.supportDirectory.path) {
                try fileManager.createDirectory(at: appPaths.supportDirectory, withIntermediateDirectories: true)
            }
            var persisted = cache
            persisted.lastUpdatedAt = Date()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(persisted)
            try data.write(to: cacheURL, options: .atomic)
        } catch {
            AppLogger.parser.silentFailure("ModelFilterParser (\(provider.rawValue)): Failed to persist parser cache", error: error)
        }
    }

    private func compositeSignature(
        jsonlFile: URL,
        settingsFile: URL,
        metadataFile: URL
    ) -> ModelFilterCompositeSignature? {
        guard let jsonl = fileSignature(for: jsonlFile) else { return nil }
        let settings = fileSignature(for: settingsFile)
        let metadata = fileSignature(for: metadataFile)
        return ModelFilterCompositeSignature(jsonl: jsonl, settings: settings, metadata: metadata)
    }

    private func fileSignature(for file: URL) -> ModelFilterFileSignature? {
        let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey])
        guard values?.isRegularFile == true else { return nil }
        let modifiedAt = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let sizeBytes = Int64(values?.fileSize ?? 0)
        return ModelFilterFileSignature(modifiedAt: modifiedAt, sizeBytes: sizeBytes)
    }
}

private struct ModelFilterFileSignature: Codable, Equatable {
    let modifiedAt: TimeInterval
    let sizeBytes: Int64
}

private struct ModelFilterCompositeSignature: Codable, Equatable {
    let jsonl: ModelFilterFileSignature
    let settings: ModelFilterFileSignature?
    let metadata: ModelFilterFileSignature?
}

private struct ModelFilterCachedSession: Codable, Equatable {
    let signature: ModelFilterCompositeSignature
    let usage: TokenUsage?
    let conversation: ConversationRecord?
}

private struct ModelFilterParserCache: Codable, Equatable {
    var schemaVersion: Int
    var fileEntries: [String: ModelFilterCachedSession]
    var lastUpdatedAt: Date?

    static let empty = ModelFilterParserCache(
        schemaVersion: 2,
        fileEntries: [:],
        lastUpdatedAt: nil
    )
}
