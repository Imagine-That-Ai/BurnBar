import Foundation

// MARK: - Cline Format Parser

/// Shared parser for Cline-family VS Code extensions (Cline, Kilo Code, Roo Code).
/// All three use the same `tasks/*/api_conversation_history.json` format.
final class ClineFormatParser: LogParser, @unchecked Sendable {
    let provider: AgentProvider
    private let storagePaths: [String]

    init(provider: AgentProvider, storagePaths: [String]) {
        self.provider = provider
        self.storagePaths = storagePaths
    }

    func parse() async throws -> ParseResult {
        let fm = FileManager.default
        var usages: [TokenUsage] = []
        var conversations: [ConversationRecord] = []
        var seenTaskIds = Set<String>()

        for storagePath in storagePaths {
            let expanded = (storagePath as NSString).expandingTildeInPath
            guard fm.fileExists(atPath: expanded) else { continue }

            let tasksURL = URL(fileURLWithPath: expanded)
            guard let taskDirs = try? fm.contentsOfDirectory(
                at: tasksURL,
                includingPropertiesForKeys: [.isDirectoryKey]
            ) else { continue }

            let dirs = taskDirs.filter {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }

            for taskDir in dirs {
                let taskId = taskDir.lastPathComponent
                guard !seenTaskIds.contains(taskId) else { continue }
                seenTaskIds.insert(taskId)

                let historyFile = taskDir.appendingPathComponent("api_conversation_history.json")
                guard fm.fileExists(atPath: historyFile.path) else { continue }

                if let pair = parseTask(
                    taskId: taskId,
                    historyFile: historyFile
                ), let usage = pair.usage {
                    usages.append(usage)
                    if let conv = pair.conversation {
                        conversations.append(conv)
                    }
                }
            }
        }

        return ParseResult(usages: usages, conversations: conversations)
    }

    // MARK: - Task Parsing

    private func parseTask(
        taskId: String,
        historyFile: URL
    ) -> (usage: TokenUsage?, conversation: ConversationRecord?)? {
        guard let data = try? Data(contentsOf: historyFile),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }

        let mtime = modificationDate(of: historyFile)

        var inputTokens = 0
        var outputTokens = 0
        var cacheCreationTokens = 0
        var cacheReadTokens = 0
        var models = Set<String>()
        var firstTimestamp: Date?
        var lastTimestamp: Date?

        var fullText = ""
        var firstUserText: String?
        var lastAssistantText = ""
        var userWords = 0
        var assistantWords = 0
        var messageCount = 0

        for message in array {
            let role = (message["role"] as? String ?? "").lowercased()

            // Timestamp: ts is milliseconds since epoch
            if let ts = message["ts"] as? Double {
                let date = Date(timeIntervalSince1970: ts / 1000.0)
                if firstTimestamp == nil { firstTimestamp = date }
                lastTimestamp = date
            } else if let ts = message["ts"] as? Int {
                let date = Date(timeIntervalSince1970: Double(ts) / 1000.0)
                if firstTimestamp == nil { firstTimestamp = date }
                lastTimestamp = date
            }

            // Model detection
            if let model = message["model"] as? String, !model.isEmpty {
                models.insert(TokenExtractionUtility.normalizeModelName(model))
            }

            // Token usage on assistant messages
            if role == "assistant", let usage = message["usage"] as? [String: Any] {
                let extracted = TokenExtractionUtility.extractUsageTokens(
                    usage,
                    inputHint: inputTokens,
                    outputHint: outputTokens
                )
                inputTokens += extracted.input
                outputTokens += extracted.output
                cacheCreationTokens += extracted.cacheCreation
                cacheReadTokens += extracted.cacheRead
            }

            // Content extraction for conversation record
            let contentText = extractText(from: message["content"])
            guard !contentText.isEmpty else { continue }

            let words = contentText.split { $0.isWhitespace || $0.isNewline }.count

            if role == "user" {
                userWords += words
                if firstUserText == nil {
                    firstUserText = String(contentText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
                }
                appendText(&fullText, contentText)
                messageCount += 1
            } else if role == "assistant" {
                assistantWords += words
                lastAssistantText = contentText
                appendText(&fullText, contentText)
                messageCount += 1
            }
        }

        // Fallback estimation if no usage data
        if inputTokens == 0 && outputTokens == 0 {
            let userChars = fullText.isEmpty ? 0 : userWords * 5
            let assistantChars = fullText.isEmpty ? 0 : assistantWords * 5
            guard userChars + assistantChars > 0 else { return nil }
            let estimated = TokenExtractionUtility.estimateFallbackTokens(
                userVisibleChars: userChars,
                assistantVisibleChars: assistantChars,
                assistantReasoningChars: 0,
                userMessageCount: messageCount / 2,
                assistantMessageCount: messageCount / 2
            )
            inputTokens = estimated.input
            outputTokens = estimated.output
        }

        guard inputTokens > 0 || outputTokens > 0 else { return nil }

        let model = models.first ?? "unknown"
        let pricing = ModelPricing.lookup(model: model)
        let cost = pricing.cost(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheCreationTokens: cacheCreationTokens,
            cacheReadTokens: cacheReadTokens
        )

        let startTime = firstTimestamp ?? Date()
        let endTime = lastTimestamp ?? startTime

        let usage = TokenUsage(
            provider: provider,
            sessionId: taskId,
            projectName: taskId,
            model: model,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheCreationTokens: cacheCreationTokens,
            cacheReadTokens: cacheReadTokens,
            costUSD: cost,
            startTime: startTime,
            endTime: endTime
        )

        let conversation = ConversationRecord(
            id: ConversationRecord.stableId(provider: provider, sessionId: taskId),
            provider: provider,
            sessionId: taskId,
            projectName: taskId,
            startTime: startTime,
            endTime: endTime,
            messageCount: messageCount,
            userWordCount: userWords,
            assistantWordCount: assistantWords,
            keyFiles: [],
            keyCommands: [],
            keyTools: [],
            inferredTaskTitle: firstUserText ?? taskId,
            lastAssistantMessage: lastAssistantText,
            fullText: fullText,
            indexedAt: Date(),
            fileModifiedAt: mtime,
            summary: nil
        )

        return (usage, conversation)
    }

    // MARK: - Helpers

    /// Extract plain text from a content field that may be a String or array of content blocks.
    private func extractText(from content: Any?) -> String {
        if let text = content as? String {
            return text
        }
        if let blocks = content as? [[String: Any]] {
            return blocks.compactMap { block -> String? in
                guard (block["type"] as? String) == "text" else { return nil }
                return block["text"] as? String
            }.joined(separator: "\n")
        }
        return ""
    }

    private func appendText(_ full: inout String, _ chunk: String) {
        if !full.isEmpty { full += "\n\n" }
        full += chunk
    }

    private func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }
}
