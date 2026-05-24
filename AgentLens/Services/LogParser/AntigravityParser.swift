import Foundation

// MARK: - Antigravity Parser

/// Parses Antigravity CLI sessions from ~/.gemini/antigravity-cli/brain/<conversationId>/.system_generated/logs/transcript.jsonl
final class AntigravityParser: LogParser, Sendable {
    let provider: AgentProvider = .antigravity

    struct SettingsFile: Decodable {
        let model: String?
    }

    func parse() async throws -> ParseResult {
        let fm = FileManager.default
        let basePath = ("~/.gemini/antigravity-cli" as NSString).expandingTildeInPath
        let brainPath = (basePath as NSString).appendingPathComponent("brain")

        guard fm.fileExists(atPath: brainPath) else {
            return ParseResult(usages: [], conversations: [])
        }

        // Fetch settings for active model
        let settingsURL = URL(fileURLWithPath: basePath).appendingPathComponent("settings.json")
        let activeModelName: String = {
            guard let data = try? Data(contentsOf: settingsURL),
                  let settings = try? JSONDecoder().decode(SettingsFile.self, from: data),
                  let model = settings.model, !model.isEmpty else {
                return "Claude Opus 4.6 (Thinking)"
            }
            return model
        }()

        var usages: [TokenUsage] = []
        var conversations: [ConversationRecord] = []

        let brainURL = URL(fileURLWithPath: brainPath)
        let conversationDirs = (try? fm.contentsOfDirectory(at: brainURL, includingPropertiesForKeys: [.isDirectoryKey]))?.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        } ?? []

        for conversationDir in conversationDirs {
            let sessionId = conversationDir.lastPathComponent
            let transcriptFile = conversationDir
                .appendingPathComponent(".system_generated")
                .appendingPathComponent("logs")
                .appendingPathComponent("transcript.jsonl")

            guard fm.fileExists(atPath: transcriptFile.path) else { continue }

            if let pair = parseSession(transcriptFile: transcriptFile, sessionId: sessionId, model: activeModelName) {
                if let usage = pair.usage { usages.append(usage) }
                if let conv = pair.conversation { conversations.append(conv) }
            }
        }

        return ParseResult(usages: usages, conversations: conversations)
    }

    private func parseSession(
        transcriptFile: URL,
        sessionId: String,
        model: String
    ) -> (usage: TokenUsage?, conversation: ConversationRecord?)? {
        guard let handle = try? FileHandle(forReadingFrom: transcriptFile) else { return nil }
        defer { try? handle.close() }

        let mtime = (try? FileManager.default.attributesOfItem(atPath: transcriptFile.path)[.modificationDate]) as? Date

        var userChars = 0
        var assistantChars = 0
        var startTime: Date?
        var endTime: Date?
        var fullText = ""
        var firstUser: String?
        var lastAssistant = ""
        var userWords = 0
        var assistantWords = 0
        var messageCount = 0

        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let fallbackDateFormatter = ISO8601DateFormatter()
        fallbackDateFormatter.formatOptions = [.withInternetDateTime]

        for line in handle.readAllUTF8Lines() {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            let source = json["source"] as? String ?? ""
            let type = json["type"] as? String ?? ""
            let content = json["content"] as? String ?? ""
            let createdAtStr = json["created_at"] as? String

            if let createdAtStr, let date = dateFormatter.date(from: createdAtStr) ?? fallbackDateFormatter.date(from: createdAtStr) {
                if startTime == nil { startTime = date }
                endTime = date
            }

            if source == "USER_EXPLICIT" || type == "USER_INPUT" {
                userChars += content.count
                if !content.isEmpty {
                    userWords += wordCount(content)
                    if firstUser == nil {
                        firstUser = String(content.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
                    }
                    appendText(&fullText, content, isAssistant: false)
                    messageCount += 1
                }
            } else if (source == "MODEL" || type == "PLANNER_RESPONSE") && !content.isEmpty {
                assistantChars += content.count
                assistantWords += wordCount(content)
                lastAssistant = content
                appendText(&fullText, content, isAssistant: true)
                messageCount += 1
            }
        }

        guard userChars > 0 || assistantChars > 0 else { return nil }

        let inputTokens = TokenExtractionUtility.estimatedTokenCount(for: userChars, charsPerToken: 3.5)
        let outputTokens = TokenExtractionUtility.estimatedTokenCount(for: assistantChars, charsPerToken: 3.5)

        let pricing = ModelPricing.lookup(model: model)
        let cost = pricing.cost(inputTokens: inputTokens, outputTokens: outputTokens)

        let finalStartTime = startTime ?? mtime ?? Date()
        let finalEndTime = endTime ?? mtime ?? Date()

        let usage = TokenUsage(
            provider: .antigravity,
            sessionId: sessionId,
            projectName: "Antigravity",
            model: model,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            costUSD: cost,
            startTime: finalStartTime,
            endTime: finalEndTime,
            provenanceMethod: .heuristicEstimate,
            provenanceConfidence: .lowConfidenceEstimate,
            estimatorVersion: TokenExtractionUtility.currentEstimatorVersion
        )

        let conversation = ConversationRecord(
            id: ConversationRecord.stableId(provider: .antigravity, sessionId: sessionId),
            provider: .antigravity,
            sessionId: sessionId,
            projectName: "Antigravity",
            startTime: finalStartTime,
            endTime: finalEndTime,
            messageCount: messageCount,
            userWordCount: userWords,
            assistantWordCount: assistantWords,
            keyFiles: [],
            keyCommands: [],
            keyTools: [],
            inferredTaskTitle: firstUser ?? "Antigravity Session",
            lastAssistantMessage: lastAssistant,
            fullText: fullText,
            indexedAt: Date(),
            fileModifiedAt: mtime,
            summary: nil
        )

        return (usage, conversation)
    }

    private func appendText(_ full: inout String, _ chunk: String, isAssistant: Bool) {
        if !full.isEmpty { full += "\n\n" }
        full += SessionLogMarkdownFormatter.transcriptTurnMarkdown(isAssistant: isAssistant, body: chunk)
    }

    private func wordCount(_ s: String) -> Int {
        s.split { $0.isWhitespace || $0.isNewline }.filter { !$0.isEmpty }.count
    }
}
