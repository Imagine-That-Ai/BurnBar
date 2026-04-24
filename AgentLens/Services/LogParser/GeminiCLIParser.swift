import Foundation

// MARK: - Gemini CLI Parser

/// Parses Gemini CLI sessions from ~/.gemini/tmp/<project_hash>/chats/session-*.json (and .jsonl).
/// Gemini CLI stores sessions with message_update records containing input_tokens, output_tokens, cached_tokens.
final class GeminiCLIParser: LogParser, Sendable {
    let provider: AgentProvider = .geminiCLI

    func parse() async throws -> ParseResult {
        let fm = FileManager.default
        let basePath = ("~/.gemini/tmp" as NSString).expandingTildeInPath

        guard fm.fileExists(atPath: basePath) else {
            return ParseResult(usages: [], conversations: [])
        }

        var usages: [TokenUsage] = []
        var conversations: [ConversationRecord] = []

        let baseURL = URL(fileURLWithPath: basePath)
        let projectDirs = (try? fm.contentsOfDirectory(at: baseURL, includingPropertiesForKeys: [.isDirectoryKey]))?.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        } ?? []

        for projectDir in projectDirs {
            let projectName = projectDir.lastPathComponent
            let chatsDir = projectDir.appendingPathComponent("chats")

            guard fm.fileExists(atPath: chatsDir.path) else { continue }

            let chatFiles = (try? fm.contentsOfDirectory(at: chatsDir, includingPropertiesForKeys: nil))?.filter {
                let name = $0.lastPathComponent
                return name.hasPrefix("session-") && ($0.pathExtension == "json" || $0.pathExtension == "jsonl")
            } ?? []

            for chatFile in chatFiles {
                let sessionId = chatFile.deletingPathExtension().lastPathComponent

                let pair: (usage: TokenUsage?, conversation: ConversationRecord?)?
                if chatFile.pathExtension == "jsonl" {
                    pair = parseJsonlSession(file: chatFile, sessionId: sessionId, projectName: projectName)
                } else {
                    pair = parseJsonSession(file: chatFile, sessionId: sessionId, projectName: projectName)
                }

                if let pair, let usage = pair.usage {
                    usages.append(usage)
                    if let conv = pair.conversation { conversations.append(conv) }
                }
            }
        }

        return ParseResult(usages: usages, conversations: conversations)
    }

    // MARK: - JSONL Session Parsing

    private func parseJsonlSession(
        file: URL,
        sessionId: String,
        projectName: String
    ) -> (usage: TokenUsage?, conversation: ConversationRecord?)? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }

        let mtime = modificationDate(of: file)
        var acc = GeminiSessionAccumulator()

        for line in handle.readAllUTF8Lines() {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            ingestLine(json, into: &acc)
        }

        return buildResult(acc: acc, sessionId: sessionId, projectName: projectName, mtime: mtime)
    }

    // MARK: - JSON Session Parsing

    private func parseJsonSession(
        file: URL,
        sessionId: String,
        projectName: String
    ) -> (usage: TokenUsage?, conversation: ConversationRecord?)? {
        guard let data = try? Data(contentsOf: file) else { return nil }

        let mtime = modificationDate(of: file)
        var acc = GeminiSessionAccumulator()

        // Try array of messages
        if let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for message in array {
                ingestLine(message, into: &acc)
            }
        }
        // Try single object with messages array
        else if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let messages = obj["messages"] as? [[String: Any]] {
            for message in messages {
                ingestLine(message, into: &acc)
            }
        }

        return buildResult(acc: acc, sessionId: sessionId, projectName: projectName, mtime: mtime)
    }

    // MARK: - Shared Ingestion

    private func ingestLine(_ json: [String: Any], into acc: inout GeminiSessionAccumulator) {
        let eventType = json["type"] as? String ?? ""

        // Timestamp
        if let ts = json["timestamp"] as? String {
            let date = ISO8601DateFormatter().date(from: ts)
            if acc.startTime == nil { acc.startTime = date }
            acc.endTime = date
        } else if let ts = json["timestamp"] as? Double {
            let date = Date(timeIntervalSince1970: ts)
            if acc.startTime == nil { acc.startTime = date }
            acc.endTime = date
        } else if let ts = json["createTime"] as? String {
            let date = ISO8601DateFormatter().date(from: ts)
            if acc.startTime == nil { acc.startTime = date }
            acc.endTime = date
        }

        // Model
        if let m = json["model"] as? String, !m.isEmpty {
            acc.model = TokenExtractionUtility.normalizeModelName(m)
        }

        // Token usage — check multiple locations
        if let usage = json["usage"] as? [String: Any] {
            accumulateUsage(usage, into: &acc)
        }
        if let usage = json["usageMetadata"] as? [String: Any] {
            accumulateUsage(usage, into: &acc)
        }
        if let message = json["message"] as? [String: Any],
           let usage = message["usage"] as? [String: Any] {
            accumulateUsage(usage, into: &acc)
        }
        // message_update events from Gemini CLI JSONL
        if eventType == "message_update" || eventType == "response" {
            if let usage = json["usage"] as? [String: Any] {
                accumulateUsage(usage, into: &acc)
            }
        }

        // Content for conversation record
        let role = (json["role"] as? String ?? (json["message"] as? [String: Any])?["role"] as? String ?? "").lowercased()
        let content = extractContent(from: json)

        if !content.isEmpty {
            if !acc.fullText.isEmpty { acc.fullText += "\n\n" }
            let isAssistant = role == "model" || role == "assistant"
            if role == "user" {
                acc.userChars += content.count
                acc.userWords += content.split { $0.isWhitespace || $0.isNewline }.count
                if acc.firstUserText == nil {
                    acc.firstUserText = String(content.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
                }
                acc.messageCount += 1
                acc.fullText += SessionLogMarkdownFormatter.transcriptTurnMarkdown(isAssistant: false, body: content)
            } else if isAssistant {
                acc.assistantChars += content.count
                acc.assistantWords += content.split { $0.isWhitespace || $0.isNewline }.count
                acc.lastAssistantText = content
                acc.messageCount += 1
                acc.fullText += SessionLogMarkdownFormatter.transcriptTurnMarkdown(isAssistant: true, body: content)
            } else {
                acc.fullText += content
            }
        }
    }

    private func accumulateUsage(_ usage: [String: Any], into acc: inout GeminiSessionAccumulator) {
        // Gemini uses promptTokenCount/candidatesTokenCount or standard names
        let input = TokenExtractionUtility.firstIntValue(in: usage, paths: [
            ["input_tokens"], ["prompt_tokens"], ["promptTokenCount"],
            ["inputTokens"], ["promptTokens"]
        ]) ?? 0
        let output = TokenExtractionUtility.firstIntValue(in: usage, paths: [
            ["output_tokens"], ["completion_tokens"], ["candidatesTokenCount"],
            ["outputTokens"], ["completionTokens"]
        ]) ?? 0
        let cached = TokenExtractionUtility.firstIntValue(in: usage, paths: [
            ["cached_tokens"], ["cachedContentTokenCount"], ["cache_read_input_tokens"]
        ]) ?? 0

        if input > 0 || output > 0 {
            acc.inputTokens += input
            acc.outputTokens += output
            acc.cacheReadTokens += cached
        }
    }

    private func extractContent(from json: [String: Any]) -> String {
        // Direct content field
        if let text = json["content"] as? String { return text }
        // Nested message.content
        if let message = json["message"] as? [String: Any] {
            if let text = message["content"] as? String { return text }
            if let parts = message["content"] as? [[String: Any]] {
                return parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
            }
        }
        // Gemini parts format
        if let parts = json["parts"] as? [[String: Any]] {
            return parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        return ""
    }

    // MARK: - Build Result

    private func buildResult(
        acc: GeminiSessionAccumulator,
        sessionId: String,
        projectName: String,
        mtime: Date?
    ) -> (usage: TokenUsage?, conversation: ConversationRecord?)? {
        var inputTokens = acc.inputTokens
        var outputTokens = acc.outputTokens

        // Fallback estimation
        if inputTokens == 0 && outputTokens == 0 {
            guard acc.userChars + acc.assistantChars > 0 else { return nil }
            let estimated = TokenExtractionUtility.estimateFallbackTokens(
                userVisibleChars: acc.userChars,
                assistantVisibleChars: acc.assistantChars,
                assistantReasoningChars: 0,
                userMessageCount: max(acc.messageCount / 2, 1),
                assistantMessageCount: max(acc.messageCount / 2, 1)
            )
            inputTokens = estimated.input
            outputTokens = estimated.output
        }

        guard inputTokens > 0 || outputTokens > 0 else { return nil }

        let model = acc.model ?? "gemini"
        let pricing = ModelPricing.lookup(model: model)
        let cost = pricing.cost(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: acc.cacheReadTokens
        )

        let startTime = acc.startTime ?? Date()
        let endTime = acc.endTime ?? startTime

        let usage = TokenUsage(
            provider: .geminiCLI,
            sessionId: sessionId,
            projectName: projectName,
            model: model,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheCreationTokens: 0,
            cacheReadTokens: acc.cacheReadTokens,
            costUSD: cost,
            startTime: startTime,
            endTime: endTime,
            provenanceMethod: .providerLog,
            provenanceConfidence: .exact
        )

        let conversation = ConversationRecord(
            id: ConversationRecord.stableId(provider: .geminiCLI, sessionId: sessionId),
            provider: .geminiCLI,
            sessionId: sessionId,
            projectName: projectName,
            startTime: startTime,
            endTime: endTime,
            messageCount: acc.messageCount,
            userWordCount: acc.userWords,
            assistantWordCount: acc.assistantWords,
            keyFiles: [],
            keyCommands: [],
            keyTools: [],
            inferredTaskTitle: acc.firstUserText ?? projectName,
            lastAssistantMessage: acc.lastAssistantText,
            fullText: acc.fullText,
            indexedAt: Date(),
            fileModifiedAt: mtime,
            summary: nil
        )

        return (usage, conversation)
    }

    private func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }
}

private struct GeminiSessionAccumulator {
    var inputTokens = 0
    var outputTokens = 0
    var cacheReadTokens = 0
    var model: String?
    var startTime: Date?
    var endTime: Date?
    var userChars = 0
    var assistantChars = 0
    var userWords = 0
    var assistantWords = 0
    var messageCount = 0
    var fullText = ""
    var firstUserText: String?
    var lastAssistantText = ""
}
