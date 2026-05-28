import Foundation
import OpenBurnBarCore

// MARK: - Grok Build Parser

/// Parses Grok Build CLI sessions from `~/.grok/sessions/<encoded-cwd>/<session-id>/`.
///
/// Token accounting prefers `signals.json` (`contextTokensUsed`) with a
/// user/assistant split derived from message counts. Conversation text is rebuilt
/// from `chat_history.jsonl` when present.
final class GrokParser: LogParser, Sendable {
    let provider: AgentProvider = .xAI
    let logDirectoryOverride: String?

    init(logDirectoryOverride: String? = nil) {
        self.logDirectoryOverride = logDirectoryOverride
    }

    func parse() async throws -> ParseResult {
        let fileManager = FileManager.default
        let sessionsRoot = logDirectoryOverride ?? NSString(string: provider.logDirectory).expandingTildeInPath
        guard fileManager.fileExists(atPath: sessionsRoot) else {
            return ParseResult(usages: [], conversations: [])
        }

        var usages: [TokenUsage] = []
        var conversations: [ConversationRecord] = []

        let workspaceDirs = try fileManager.contentsOfDirectory(
            at: URL(fileURLWithPath: sessionsRoot),
            includingPropertiesForKeys: [.isDirectoryKey]
        ).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }

        for workspaceDir in workspaceDirs {
            let projectName = decodedWorkspaceName(from: workspaceDir.lastPathComponent)
            let sessionDirs = try fileManager.contentsOfDirectory(
                at: workspaceDir,
                includingPropertiesForKeys: [.isDirectoryKey]
            ).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }

            for sessionDir in sessionDirs {
                let summaryURL = sessionDir.appendingPathComponent("summary.json")
                guard fileManager.fileExists(atPath: summaryURL.path) else { continue }

                if let pair = try parseSession(
                    sessionDir: sessionDir,
                    summaryURL: summaryURL,
                    projectName: projectName
                ), let usage = pair.usage {
                    usages.append(usage)
                    if let conversation = pair.conversation {
                        conversations.append(conversation)
                    }
                }
            }
        }

        return ParseResult(usages: usages, conversations: conversations)
    }

    // MARK: - Session parsing

    private func parseSession(
        sessionDir: URL,
        summaryURL: URL,
        projectName: String
    ) throws -> (usage: TokenUsage?, conversation: ConversationRecord?)? {
        let mtime = (try? FileManager.default.attributesOfItem(atPath: summaryURL.path)[.modificationDate]) as? Date
        guard let summaryData = try? Data(contentsOf: summaryURL),
              let summary = try? JSONSerialization.jsonObject(with: summaryData) as? [String: Any] else {
            return nil
        }

        let info = summary["info"] as? [String: Any]
        let sessionId = (info?["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? sessionDir.lastPathComponent
        let cwd = (info?["cwd"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedProject = cwd.flatMap { URL(fileURLWithPath: $0).lastPathComponent } ?? projectName

        let model = (summary["current_model_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty ?? "grok-build"

        let startTime = parseISO8601(summary["created_at"] as? String) ?? mtime
        let endTime = parseISO8601(summary["updated_at"] as? String)
            ?? parseISO8601(summary["last_active_at"] as? String)
            ?? mtime

        let signalsURL = sessionDir.appendingPathComponent("signals.json")
        let signals = loadSignals(at: signalsURL)
        let chatHistoryURL = sessionDir.appendingPathComponent("chat_history.jsonl")
        let chatTurns = parseChatHistory(at: chatHistoryURL)

        let tokenBreakdown = tokenBreakdown(from: signals, chatTurns: chatTurns, updatesURL: sessionDir.appendingPathComponent("updates.jsonl"))
        guard tokenBreakdown.totalTokens > 0 else { return nil }

        let pricing = ModelPricing.lookup(model: model)
        let cost = pricing.cost(
            inputTokens: tokenBreakdown.inputTokens,
            outputTokens: tokenBreakdown.outputTokens,
            cacheCreationTokens: 0,
            cacheReadTokens: 0
        )

        let provenance: UsageProvenanceMethod = signals?.contextTokensUsed != nil ? .providerLog : .heuristicEstimate
        let confidence: UsageProvenanceConfidence = signals?.contextTokensUsed != nil ? .exact : .lowConfidenceEstimate

        let usage = TokenUsage(
            provider: .xAI,
            sessionId: sessionId,
            projectName: resolvedProject,
            model: model,
            inputTokens: tokenBreakdown.inputTokens,
            outputTokens: tokenBreakdown.outputTokens,
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            costUSD: cost,
            startTime: startTime ?? Date(),
            endTime: endTime ?? startTime ?? Date(),
            provenanceMethod: provenance,
            provenanceConfidence: confidence,
            estimatorVersion: confidence == .exact ? "" : TokenExtractionUtility.currentEstimatorVersion
        )

        let title = (summary["generated_title"] as? String)?.nilIfEmpty
            ?? (summary["session_summary"] as? String)?.nilIfEmpty
            ?? sessionId

        let conversation = buildConversation(
            sessionId: sessionId,
            projectName: resolvedProject,
            title: title,
            chatTurns: chatTurns,
            startTime: startTime,
            endTime: endTime,
            mtime: mtime
        )

        return (usage, conversation)
    }

    // MARK: - Token breakdown

    private struct GrokSignals: Sendable {
        let contextTokensUsed: Int?
        let userMessageCount: Int
        let assistantMessageCount: Int
    }

    private struct TokenBreakdown: Sendable {
        let inputTokens: Int
        let outputTokens: Int

        var totalTokens: Int { inputTokens + outputTokens }
    }

    private struct ChatTurn: Sendable {
        let role: String
        let content: String
    }

    private func loadSignals(at url: URL) -> GrokSignals? {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return GrokSignals(
            contextTokensUsed: json["contextTokensUsed"] as? Int,
            userMessageCount: json["userMessageCount"] as? Int ?? 0,
            assistantMessageCount: json["assistantMessageCount"] as? Int ?? 0
        )
    }

    private func tokenBreakdown(
        from signals: GrokSignals?,
        chatTurns: [ChatTurn],
        updatesURL: URL
    ) -> TokenBreakdown {
        let updatesMax = maxTotalTokens(in: updatesURL)
        let totalFromSignals = signals?.contextTokensUsed ?? 0
        let totalTokens = max(totalFromSignals, updatesMax)

        let userCount = max(
            signals?.userMessageCount ?? 0,
            chatTurns.filter { $0.role == "user" }.count
        )
        let assistantCount = max(
            signals?.assistantMessageCount ?? 0,
            chatTurns.filter { $0.role == "assistant" }.count
        )

        if totalTokens > 0 {
            let denominator = max(userCount + assistantCount, 1)
            let inputTokens = max(1, (totalTokens * userCount) / denominator)
            let outputTokens = max(0, totalTokens - inputTokens)
            return TokenBreakdown(inputTokens: inputTokens, outputTokens: outputTokens)
        }

        let userChars = chatTurns.filter { $0.role == "user" }.reduce(0) { $0 + $1.content.count }
        let assistantChars = chatTurns.filter { $0.role == "assistant" }.reduce(0) { $0 + $1.content.count }
        let allContent = chatTurns.map(\.content).joined()
        let ratio = TokenExtractionUtility.charsPerToken(for: allContent, defaultRatio: 3.5)
        return TokenBreakdown(
            inputTokens: TokenExtractionUtility.estimatedTokenCount(for: userChars, charsPerToken: ratio),
            outputTokens: TokenExtractionUtility.estimatedTokenCount(for: assistantChars, charsPerToken: ratio)
        )
    }

    private func maxTotalTokens(in url: URL) -> Int {
        guard FileManager.default.fileExists(atPath: url.path),
              let handle = try? FileHandle(forReadingFrom: url) else {
            return 0
        }
        defer { try? handle.close() }

        var maxTokens = 0
        for line in handle.readAllUTF8Lines() {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            if let meta = json["_meta"] as? [String: Any],
               let total = meta["totalTokens"] as? Int {
                maxTokens = max(maxTokens, total)
            }
            if let params = json["params"] as? [String: Any],
               let update = params["update"] as? [String: Any],
               let meta = update["_meta"] as? [String: Any],
               let total = meta["totalTokens"] as? Int {
                maxTokens = max(maxTokens, total)
            }
        }
        return maxTokens
    }

    // MARK: - Chat history

    private func parseChatHistory(at url: URL) -> [ChatTurn] {
        guard FileManager.default.fileExists(atPath: url.path),
              let handle = try? FileHandle(forReadingFrom: url) else {
            return []
        }
        defer { try? handle.close() }

        var turns: [ChatTurn] = []
        for line in handle.readAllUTF8Lines() {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            let role = (json["type"] as? String)?.lowercased() ?? ""
            guard role == "user" || role == "assistant" else { continue }
            let content = flattenedContent(json["content"])
            guard !content.isEmpty else { continue }
            turns.append(ChatTurn(role: role, content: content))
        }
        return turns
    }

    private func flattenedContent(_ value: Any?) -> String {
        if let text = value as? String {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let parts = value as? [[String: Any]] {
            return parts.compactMap { part in
                (part["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }.joined(separator: "\n")
        }
        return ""
    }

    private func buildConversation(
        sessionId: String,
        projectName: String,
        title: String,
        chatTurns: [ChatTurn],
        startTime: Date?,
        endTime: Date?,
        mtime: Date?
    ) -> ConversationRecord? {
        guard !chatTurns.isEmpty else { return nil }

        var fullText = ""
        var firstUser: String?
        var lastAssistant = ""
        var userWords = 0
        var assistantWords = 0

        for turn in chatTurns {
            switch turn.role {
            case "user":
                if firstUser == nil {
                    firstUser = String(turn.content.prefix(120))
                }
                userWords += wordCount(turn.content)
                appendText(&fullText, turn.content)
            case "assistant":
                lastAssistant = turn.content
                assistantWords += wordCount(turn.content)
                appendText(&fullText, turn.content)
            default:
                break
            }
        }

        return ConversationRecord(
            id: ConversationRecord.stableId(provider: .xAI, sessionId: sessionId),
            provider: .xAI,
            sessionId: sessionId,
            projectName: projectName,
            startTime: startTime ?? mtime ?? Date(),
            endTime: endTime ?? mtime ?? Date(),
            messageCount: chatTurns.count,
            userWordCount: userWords,
            assistantWordCount: assistantWords,
            keyFiles: [],
            keyCommands: [],
            keyTools: [],
            inferredTaskTitle: firstUser ?? title,
            lastAssistantMessage: lastAssistant,
            fullText: fullText,
            indexedAt: Date(),
            fileModifiedAt: mtime,
            summary: title
        )
    }

    // MARK: - Helpers

    private func decodedWorkspaceName(from encoded: String) -> String {
        encoded.removingPercentEncoding?
            .split(separator: "/")
            .last
            .map(String.init) ?? encoded
    }

    private func parseISO8601(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: trimmed) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: trimmed)
    }

    private func appendText(_ full: inout String, _ chunk: String) {
        if !full.isEmpty { full += "\n\n" }
        full += chunk
    }

    private func wordCount(_ value: String) -> Int {
        value.split { $0.isWhitespace || $0.isNewline }.filter { !$0.isEmpty }.count
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
