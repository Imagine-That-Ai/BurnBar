import Foundation

// MARK: - Hermes Parser

/// Scaffold parser for Hermes CLI agent sessions.
/// Checks ~/.hermes/sessions/ for JSONL files and attempts best-effort parsing.
final class HermesParser: LogParser, @unchecked Sendable {
    let provider: AgentProvider = .hermes

    func parse() async throws -> ParseResult {
        let fm = FileManager.default
        let sessionsPath = (provider.logDirectory as NSString).expandingTildeInPath

        guard fm.fileExists(atPath: sessionsPath) else {
            return ParseResult(usages: [], conversations: [])
        }

        let sessionsURL = URL(fileURLWithPath: sessionsPath)
        var usages: [TokenUsage] = []
        var conversations: [ConversationRecord] = []

        let contents = (try? fm.contentsOfDirectory(at: sessionsURL, includingPropertiesForKeys: [.isDirectoryKey])) ?? []

        // Parse JSONL files at top level
        let jsonlFiles = contents.filter { $0.pathExtension == "jsonl" }
        for file in jsonlFiles {
            let sessionId = file.deletingPathExtension().lastPathComponent
            if let pair = parseSession(file: file, sessionId: sessionId, projectName: sessionId),
               let usage = pair.usage {
                usages.append(usage)
                if let conv = pair.conversation { conversations.append(conv) }
            }
        }

        // Parse subdirectories
        let dirs = contents.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        for dir in dirs {
            let projectName = dir.lastPathComponent
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension == "jsonl" {
                let sessionId = file.deletingPathExtension().lastPathComponent
                if let pair = parseSession(file: file, sessionId: sessionId, projectName: projectName),
                   let usage = pair.usage {
                    usages.append(usage)
                    if let conv = pair.conversation { conversations.append(conv) }
                }
            }
        }

        return ParseResult(usages: usages, conversations: conversations)
    }

    private func parseSession(
        file: URL,
        sessionId: String,
        projectName: String
    ) -> (usage: TokenUsage?, conversation: ConversationRecord?)? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }

        let mtime = (try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate]) as? Date

        var inputTokens = 0
        var outputTokens = 0
        var cacheCreationTokens = 0
        var cacheReadTokens = 0
        var model = "unknown"
        var startTime: Date?
        var endTime: Date?
        var userChars = 0
        var assistantChars = 0
        var messageCount = 0
        var fullText = ""
        var firstUser: String?
        var lastAssistant = ""
        var userWords = 0
        var assistantWords = 0

        for line in handle.readAllUTF8Lines() {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            // Try Claude-style nested format
            if let message = json["message"] as? [String: Any] {
                let role = (message["role"] as? String)?.lowercased() ?? ""

                if let ts = json["timestamp"] as? String,
                   let date = ISO8601DateFormatter().date(from: ts) {
                    if startTime == nil { startTime = date }
                    endTime = date
                }

                if let m = message["model"] as? String, !m.isEmpty {
                    model = TokenExtractionUtility.normalizeModelName(m)
                }

                if role == "assistant", let usage = message["usage"] as? [String: Any] {
                    let extracted = TokenExtractionUtility.extractUsageTokens(usage)
                    inputTokens += extracted.input
                    outputTokens += extracted.output
                    cacheCreationTokens += extracted.cacheCreation
                    cacheReadTokens += extracted.cacheRead
                }
                messageCount += 1
                continue
            }

            // Try flat format
            let role = (json["role"] as? String)?.lowercased() ?? ""
            let content = json["content"] as? String ?? ""

            if let ts = json["timestamp"] as? String,
               let date = ISO8601DateFormatter().date(from: ts) {
                if startTime == nil { startTime = date }
                endTime = date
            }

            if let m = json["model"] as? String, !m.isEmpty {
                model = TokenExtractionUtility.normalizeModelName(m)
            }

            if role == "user" && !content.isEmpty {
                userChars += content.count
                let w = content.split { $0.isWhitespace || $0.isNewline }.count
                userWords += w
                if firstUser == nil {
                    firstUser = String(content.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
                }
                if !fullText.isEmpty { fullText += "\n\n" }
                fullText += content
                messageCount += 1
            } else if role == "assistant" && !content.isEmpty {
                assistantChars += content.count
                let w = content.split { $0.isWhitespace || $0.isNewline }.count
                assistantWords += w
                lastAssistant = content
                if !fullText.isEmpty { fullText += "\n\n" }
                fullText += content
                messageCount += 1
            }

            if let usage = json["usage"] as? [String: Any] {
                let extracted = TokenExtractionUtility.extractUsageTokens(usage)
                inputTokens += extracted.input
                outputTokens += extracted.output
                cacheCreationTokens += extracted.cacheCreation
                cacheReadTokens += extracted.cacheRead
            }
        }

        // Fallback estimation
        if inputTokens == 0 && outputTokens == 0 {
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
        }

        guard inputTokens > 0 || outputTokens > 0 else { return nil }

        let pricing = ModelPricing.lookup(model: model)
        let cost = pricing.cost(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheCreationTokens: cacheCreationTokens,
            cacheReadTokens: cacheReadTokens
        )

        let usage = TokenUsage(
            provider: .hermes,
            sessionId: sessionId,
            projectName: projectName,
            model: model,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheCreationTokens: cacheCreationTokens,
            cacheReadTokens: cacheReadTokens,
            costUSD: cost,
            startTime: startTime ?? Date(),
            endTime: endTime ?? Date()
        )

        let conversation = ConversationRecord(
            id: ConversationRecord.stableId(provider: .hermes, sessionId: sessionId),
            provider: .hermes,
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
            inferredTaskTitle: firstUser ?? projectName,
            lastAssistantMessage: lastAssistant,
            fullText: fullText,
            indexedAt: Date(),
            fileModifiedAt: mtime,
            summary: nil
        )

        return (usage, conversation)
    }
}
