import Foundation

// MARK: - Kimi Parser

/// KimiParser extracts token usage from Kimi (Moonshot) CLI sessions.
/// Since Kimi doesn't expose direct token counts in session files, this parser
/// estimates usage based on message content character counts.
final class KimiParser: LogParser {
    let provider: AgentProvider = .kimi

    /// Token estimation ratio: characters per token (approximate)
    private let charsPerToken = 4.0

    func parse() async throws -> ParseResult {
        let fileManager = FileManager.default
        let sessionsPath = NSString(string: provider.logDirectory).expandingTildeInPath
        let sessionsURL = URL(fileURLWithPath: sessionsPath)

        guard fileManager.fileExists(atPath: sessionsPath) else {
            return ParseResult(usages: [], conversations: [])
        }

        var usages: [TokenUsage] = []
        var conversations: [ConversationRecord] = []

        let workspaceDirs = try fileManager.contentsOfDirectory(at: sessionsURL, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }

        for workspaceDir in workspaceDirs {
            let workspaceId = workspaceDir.lastPathComponent

            let sessionDirs = try fileManager.contentsOfDirectory(at: workspaceDir, includingPropertiesForKeys: [.isDirectoryKey])
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }

            for sessionDir in sessionDirs {
                let sessionId = sessionDir.lastPathComponent
                let contextFile = sessionDir.appendingPathComponent("context.jsonl")

                if fileManager.fileExists(atPath: contextFile.path) {
                    if let pair = try parseSession(
                        sessionId: sessionId,
                        contextFile: contextFile,
                        projectName: workspaceId
                    ), let usage = pair.usage {
                        usages.append(usage)
                        if let conv = pair.conversation {
                            conversations.append(conv)
                        }
                    }
                }
            }
        }

        return ParseResult(usages: usages, conversations: conversations)
    }

    private func parseSession(
        sessionId: String,
        contextFile: URL,
        projectName: String
    ) throws -> (usage: TokenUsage?, conversation: ConversationRecord?)? {
        guard let handle = try? FileHandle(forReadingFrom: contextFile) else {
            return nil
        }
        defer { try? handle.close() }

        let mtime = (try? FileManager.default.attributesOfItem(atPath: contextFile.path)[.modificationDate]) as? Date

        var assistantChars = 0
        var userChars = 0
        var firstTimestamp: Date?
        var lastTimestamp: Date?
        let model = "kimi-for-coding"

        var fullText = ""
        var firstUser: String?
        var lastAssistant = ""
        var userWords = 0
        var assistantWords = 0
        var messageCount = 0

        while let line = handle.readLine(), !line.isEmpty {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            let role = json["role"] as? String ?? ""
            let content = json["content"] as? String ?? ""
            let charCount = content.count

            switch role {
            case "assistant":
                assistantChars += charCount
                if !content.isEmpty {
                    let w = wordCount(content)
                    assistantWords += w
                    lastAssistant = content
                    appendKimiText(&fullText, content)
                    messageCount += 1
                }
            case "user":
                userChars += charCount
                if !content.isEmpty {
                    userWords += wordCount(content)
                    if firstUser == nil {
                        firstUser = String(content.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
                    }
                    appendKimiText(&fullText, content)
                    messageCount += 1
                }
            default:
                break
            }

            if let ts = json["created_at"] as? String ?? json["timestamp"] as? String {
                let date = ISO8601DateFormatter().date(from: ts)
                if firstTimestamp == nil { firstTimestamp = date }
                lastTimestamp = date
            }
        }

        let estimatedInputTokens = Int(Double(userChars) / charsPerToken)
        let estimatedOutputTokens = Int(Double(assistantChars) / charsPerToken)

        guard estimatedInputTokens > 0 || estimatedOutputTokens > 0 else {
            return nil
        }

        let cost = calculateCost(inputTokens: estimatedInputTokens, outputTokens: estimatedOutputTokens, model: model)

        let usage = TokenUsage(
            provider: .kimi,
            sessionId: sessionId,
            projectName: projectName,
            model: model,
            inputTokens: estimatedInputTokens,
            outputTokens: estimatedOutputTokens,
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            costUSD: cost,
            startTime: firstTimestamp ?? Date(),
            endTime: lastTimestamp ?? Date()
        )

        let conversation = ConversationRecord(
            id: ConversationRecord.stableId(provider: .kimi, sessionId: sessionId),
            provider: .kimi,
            sessionId: sessionId,
            projectName: projectName,
            startTime: firstTimestamp ?? usage.startTime,
            endTime: lastTimestamp ?? usage.endTime,
            messageCount: messageCount,
            userWordCount: userWords,
            assistantWordCount: assistantWords,
            keyFiles: [],
            keyCommands: [],
            keyTools: [],
            inferredTaskTitle: firstUser ?? projectName,
            lastAssistantMessage: lastAssistant,
            fullText: fullText,
            indexedAt: Date(),
            fileModifiedAt: mtime,
            summary: nil
        )

        return (usage, conversation)
    }

    private func appendKimiText(_ full: inout String, _ chunk: String) {
        if !full.isEmpty { full += "\n\n" }
        full += chunk
    }

    private func wordCount(_ s: String) -> Int {
        s.split { $0.isWhitespace || $0.isNewline }.filter { !$0.isEmpty }.count
    }

    private func calculateCost(inputTokens: Int, outputTokens: Int, model: String) -> Double {
        let lowercasedModel = model.lowercased()

        if lowercasedModel.contains("k2") {
            return Double(inputTokens) * 0.0000006 + Double(outputTokens) * 0.000003
        }

        return Double(inputTokens) * 0.000003 + Double(outputTokens) * 0.000015
    }
}
