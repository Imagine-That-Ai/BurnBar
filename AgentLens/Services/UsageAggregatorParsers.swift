import Foundation
import CryptoKit
import GRDB
import OpenBurnBarCore

// MARK: - Copilot Parser

/// Parses Copilot CLI sessions from ~/.copilot/session-state/*/events.jsonl.
/// Post-Feb 2026 Copilot CLI persists assistant.usage and session.shutdown events with exact token counts.
/// Falls back to CompactionProcessor log deltas for older CLI versions.

/// Parses Copilot CLI sessions from ~/.copilot/session-state/*/events.jsonl.
/// Post-Feb 2026 Copilot CLI persists assistant.usage and session.shutdown events with exact token counts.
/// Falls back to CompactionProcessor log deltas for older CLI versions.
final class CopilotParser: OpenBurnBarCore.LogParser, Sendable {
    let provider: AgentProvider = .copilot

    func parse() async throws -> OpenBurnBarCore.ParseResult {
        let fm = FileManager.default
        let sessionStatePath = ("~/.copilot/session-state" as NSString).expandingTildeInPath
        let logsPath = ("~/.copilot/logs" as NSString).expandingTildeInPath

        guard fm.fileExists(atPath: sessionStatePath) else {
            return OpenBurnBarCore.ParseResult(usages: [], conversations: [])
        }

        // Parse CompactionProcessor token data from process logs (fallback for old CLI)
        let tokensBySession = parseProcessLogs(logsPath: logsPath)

        var usages: [TokenUsage] = []
        var conversations: [OpenBurnBarCore.ConversationRecord] = []

        let sessionDirs = (try? fm.contentsOfDirectory( // try?-ok(dir scan, empty fallback)
            at: URL(fileURLWithPath: sessionStatePath),
            includingPropertiesForKeys: [.isDirectoryKey]
        ))?.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true } ?? [] // try?-ok(isDir filter)

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

        return OpenBurnBarCore.ParseResult(usages: usages, conversations: conversations)
    }

    private func parseMetadata(_ file: URL) -> CopilotMetadataSummary? {
        guard let data = try? Data(contentsOf: file), // try?-ok(optional metadata read)
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { // try?-ok(metadata decode)
            return nil
        }

        let model = json["model"] as? String
        let usage = json["usage"] as? [String: Any] ?? json["tokenUsage"] as? [String: Any]
        var input = 0
        var output = 0
        var cached = 0

        if let usage {
            let extracted = OpenBurnBarCore.TokenExtractionUtility.extractUsageTokens(usage)
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
    ) -> (usage: TokenUsage?, conversation: OpenBurnBarCore.ConversationRecord?)? {
        guard let handle = try? FileHandle(forReadingFrom: eventsFile) else { return nil } // try?-ok(log open, skip if absent)
        defer { try? handle.close() } // try?-ok(handle teardown)

        let mtime = (try? FileManager.default.attributesOfItem(atPath: eventsFile.path)[.modificationDate]) as? Date // try?-ok(optional mtime)

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
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { // try?-ok(per-line decode, skip)
                continue
            }

            let eventType = json["type"] as? String ?? json["event"] as? String ?? ""
            let role = json["role"] as? String ?? ""

            // Timestamps
            if let ts = json["timestamp"] as? String {
                // Lock-guarded shared parser: accepts fractional-second timestamps
                // (which a default ISO8601DateFormatter() rejects) and avoids a
                // per-line formatter allocation.
                let date = ThreadSafeISO8601DateFormatter.parse(ts)
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
                // `usage` and `token_usage` are alternate spellings of the same
                // payload; an event carrying both would previously be counted
                // twice. Prefer `usage`, fall back to `token_usage` — never add
                // both for a single event.
                if let usage = (json["usage"] as? [String: Any]) ?? (json["token_usage"] as? [String: Any]) {
                    let extracted = OpenBurnBarCore.TokenExtractionUtility.extractUsageTokens(usage)
                    exactInputTokens += extracted.input
                    exactOutputTokens += extracted.output
                    exactCachedTokens += extracted.cacheRead
                    foundExactUsage = true
                }
            }

            // Also check for inline usage on any message
            if let usage = json["usage"] as? [String: Any], eventType != "assistant.usage" && eventType != "session.shutdown" {
                let extracted = OpenBurnBarCore.TokenExtractionUtility.extractUsageTokens(usage)
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
            inputTokens = OpenBurnBarCore.TokenExtractionUtility.estimatedTokenCount(for: userChars, charsPerToken: 3.5)
            outputTokens = OpenBurnBarCore.TokenExtractionUtility.estimatedTokenCount(for: assistantChars, charsPerToken: 3.5)
            cacheReadTokens = 0
            isExact = false
        }

        guard inputTokens > 0 || outputTokens > 0 else { return nil }

        let pricing = OpenBurnBarCore.ModelPricing.lookup(model: model)
        let cost = try pricing.cost(inputTokens: inputTokens, outputTokens: outputTokens, cacheReadTokens: cacheReadTokens)

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
            estimatorVersion: isExact ? "" : OpenBurnBarCore.TokenExtractionUtility.currentEstimatorVersion
        )

        let conversation = OpenBurnBarCore.ConversationRecord(
            id: OpenBurnBarCore.ConversationRecord.stableId(provider: .copilot, sessionId: sessionId),
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

        guard let logFiles = try? fm.contentsOfDirectory(atPath: logsPath) // try?-ok(log dir scan, empty fallback)
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
        full += OpenBurnBarCore.SessionLogMarkdownFormatter.transcriptTurnMarkdown(isAssistant: isAssistant, body: chunk)
    }

    private func wordCount(_ s: String) -> Int {
        s.split { $0.isWhitespace || $0.isNewline }.filter { !$0.isEmpty }.count
    }
}

struct CopilotMetadataSummary {
    let model: String?
    let input: Int
    let output: Int
    let cached: Int
}

/// Parses Aider analytics JSONL logs for exact per-message token usage.
/// Requires user to configure: `analytics-log: ~/.aider/analytics.jsonl` in .aider.conf.yml
final class AiderParser: OpenBurnBarCore.LogParser, Sendable {
    let provider: AgentProvider = .aider

    func parse() async throws -> OpenBurnBarCore.ParseResult {
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
            return OpenBurnBarCore.ParseResult(usages: [], conversations: [])
        }

        var usages: [TokenUsage] = []
        var conversations: [OpenBurnBarCore.ConversationRecord] = []

        for file in analyticsFiles {
            let (fileUsages, fileConvs) = parseAnalyticsLog(file: file)
            usages.append(contentsOf: fileUsages)
            conversations.append(contentsOf: fileConvs)
        }

        return OpenBurnBarCore.ParseResult(usages: usages, conversations: conversations)
    }

    private func parseAnalyticsLog(file: URL) -> ([TokenUsage], [OpenBurnBarCore.ConversationRecord]) {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return ([], []) } // try?-ok(log open, skip if absent)
        defer { try? handle.close() } // try?-ok(handle teardown)

        // Group message_send events into sessions bounded by cli_session/exit events
        var sessions: [AiderSession] = []
        var current = AiderSession()

        for line in handle.readAllUTF8Lines() {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { // try?-ok(per-line decode, skip)
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
        var conversations: [OpenBurnBarCore.ConversationRecord] = []

        for (index, session) in sessions.enumerated() {
            let sessionId = "aider-\(index)-\(Int(session.startTime?.timeIntervalSince1970 ?? 0))"
            let model = session.model ?? "unknown"

            // Use cost from Aider if available, otherwise compute from pricing
            let cost: Double
            if session.totalCost > 0 {
                cost = session.totalCost
            } else {
                let pricing = OpenBurnBarCore.ModelPricing.lookup(model: model)
                cost = try pricing.cost(inputTokens: session.inputTokens, outputTokens: session.outputTokens)
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

            let conversation = OpenBurnBarCore.ConversationRecord(
                id: OpenBurnBarCore.ConversationRecord.stableId(provider: .aider, sessionId: sessionId),
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

struct AiderSession {
    var startTime: Date?
    var endTime: Date?
    var model: String?
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var totalCost: Double = 0
    var messageCount: Int = 0

    var hasData: Bool { inputTokens > 0 || outputTokens > 0 }
}

/// Parses Cursor's ai-code-tracking.db for code provenance data and model usage distribution.
/// Token-level tracking requires the CursorConnector BYOK proxy.
final class CursorParser: OpenBurnBarCore.LogParser, Sendable {
    let provider: AgentProvider = .cursor

    func parse() async throws -> OpenBurnBarCore.ParseResult {
        let dbPath = ("~/.cursor/ai-tracking/ai-code-tracking.db" as NSString).expandingTildeInPath

        guard FileManager.default.fileExists(atPath: dbPath) else {
            return OpenBurnBarCore.ParseResult(usages: [], conversations: [])
        }

        let usages = try parseCursorDatabase(dbPath: dbPath)
        return OpenBurnBarCore.ParseResult(usages: usages, conversations: [])
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
                let startTime = OpenBurnBarCore.TimestampNormalizationUtility.date(fromEpoch: firstSeenRaw)
                let normalizedLastSeen = OpenBurnBarCore.TimestampNormalizationUtility.date(fromEpoch: lastSeenRaw, fallback: startTime)
                let endTime = max(startTime, normalizedLastSeen)

                // Estimate tokens from code hash count — each hash represents a generated code block.
                // Average code block ~150 tokens output, ~500 tokens input context.
                let estimatedOutput = hashCount * 150
                let estimatedInput = hashCount * 500

                let pricing = OpenBurnBarCore.ModelPricing.lookup(model: model)
                let cost = try pricing.cost(inputTokens: estimatedInput, outputTokens: estimatedOutput)

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

/// Shared warm-up for disk-cache-backed parsers.
///
/// The `OpenBurnBarCore.ParserDiskCacheStore` that each of these parsers owns is self-healing on
/// write (it re-creates the support directory with intermediates and logs via
/// `AppLogger.parser.silentFailure` if persistence fails). Eagerly preparing the
/// directory in the initializer is therefore a best-effort optimization that lets
/// the *first* cache write succeed without a directory-creation round trip.
///
/// The previous optional-try form of `prepareSupportDirectory(...)` swallowed
/// every failure totally silently. A failure here is recoverable (the
/// store self-heals later) but it should be **observable**: a persistent prep
/// failure usually signals a deeper filesystem fault (revoked sandbox access,
/// migration collision, a regular file occupying the support path) that we want
/// surfaced in logs the moment it happens, not only when the first write trips it.
///
/// This does NOT fail closed — a parser must remain constructible even when its
/// scratch directory is unavailable, and it degrades gracefully by re-parsing.
enum ParserSupportDirectoryWarmUp {
    /// Prepare the OpenBurnBar support directory, logging (never throwing /
    /// crashing) on failure.
    ///
    /// - Returns: `true` when the directory is ready, `false` when preparation
    ///   failed (already logged). The boolean exists purely so the behavior is
    ///   testable; callers in initializers discard it.
    @discardableResult
    nonisolated static func prepare(
        fileManager: FileManager,
        appPaths: OpenBurnBarCore.OpenBurnBarAppPaths
    ) -> Bool {
        do {
            _ = try OpenBurnBarCore.OpenBurnBarMigration.prepareSupportDirectory(
                fileManager: fileManager,
                paths: appPaths
            )
            return true
        } catch {
            AppLogger.parser.error(
                "parser.supportDirectoryPrepFailed",
                metadata: ["errorClass": "\(String(describing: type(of: error)))"]
            )
            return false
        }
    }
}
