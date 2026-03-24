import Foundation

// MARK: - Factory Droid Parser

/// FactoryDroidParser extracts token usage from Factory Droid sessions and categorizes
/// them by the underlying model provider (MiniMax, Z.ai, Claude, etc.)
final class FactoryDroidParser: LogParser, @unchecked Sendable {
    let provider: AgentProvider = .factory

    func parse() async throws -> ParseResult {
        let fileManager = FileManager.default
        let sessionsPath = NSString(string: provider.logDirectory).expandingTildeInPath
        let sessionsURL = URL(fileURLWithPath: sessionsPath)

        guard fileManager.fileExists(atPath: sessionsPath) else {
            return ParseResult(usages: [], conversations: [])
        }

        var usages: [TokenUsage] = []
        var conversations: [ConversationRecord] = []

        let projectDirs = try fileManager.contentsOfDirectory(at: sessionsURL, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }

        for projectDir in projectDirs {
            let projectName = decodeProjectName(projectDir.lastPathComponent)

            let files = try fileManager.contentsOfDirectory(at: projectDir, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "jsonl" || $0.pathExtension == "json" }

            for jsonlFile in files where jsonlFile.pathExtension == "jsonl" {
                let baseName = jsonlFile.deletingPathExtension().lastPathComponent
                let settingsFile = projectDir.appendingPathComponent("\(baseName).settings.json")

                guard fileManager.fileExists(atPath: settingsFile.path) else {
                    continue
                }

                if let pair = try parseSession(
                    sessionId: baseName,
                    jsonlFile: jsonlFile,
                    settingsFile: settingsFile,
                    projectName: projectName
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

    private func decodeProjectName(_ encoded: String) -> String {
        var decoded = encoded
            .replacingOccurrences(of: "-Users-", with: "~/")
            .replacingOccurrences(of: "-", with: "/")

        while decoded.contains("//") {
            decoded = decoded.replacingOccurrences(of: "//", with: "/")
        }

        if decoded.hasSuffix("/") {
            decoded.removeLast()
        }

        return decoded
    }

    private func parseSession(
        sessionId: String,
        jsonlFile: URL,
        settingsFile: URL?,
        projectName: String
    ) throws -> (usage: TokenUsage?, conversation: ConversationRecord?)? {
        var tokenData: (
            input: Int,
            output: Int,
            cacheCreation: Int,
            cacheRead: Int,
            model: String,
            startTime: Date?,
            endTime: Date?
        ) = (0, 0, 0, 0, "unknown", nil, nil)

        var usedSettingsTotals = false
        var userCharCount = 0
        var assistantCharCount = 0
        var assistantReasoningCharCount = 0
        var userMessageCount = 0
        var assistantMessageCount = 0
        var inlineModel: String?

        // Check settings.json for model and token usage totals
        if let settingsFileURL = settingsFile {
            if let data = try? Data(contentsOf: settingsFileURL),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let model = json["model"] as? String {
                    tokenData.model = TokenExtractionUtility.normalizeModelName(model)
                }

                if let tokenUsage = json["tokenUsage"] as? [String: Any] {
                    let extracted = TokenExtractionUtility.extractUsageTokens(tokenUsage)
                    if extracted.input > 0 || extracted.output > 0 || extracted.cacheCreation > 0 || extracted.cacheRead > 0 {
                        tokenData.input = extracted.input
                        tokenData.output = extracted.output
                        tokenData.cacheCreation = extracted.cacheCreation
                        tokenData.cacheRead = extracted.cacheRead
                        usedSettingsTotals = true
                    }
                }
            }
        }

        // Also check metadata.json (newer Factory versions write this alongside settings.json)
        if !usedSettingsTotals {
            let metadataURL = jsonlFile.deletingLastPathComponent()
                .appendingPathComponent("\(sessionId).metadata.json")
            if let data = try? Data(contentsOf: metadataURL),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if tokenData.model == "unknown", let model = json["model"] as? String {
                    tokenData.model = TokenExtractionUtility.normalizeModelName(model)
                }
                if let tokenUsage = json["tokenUsage"] as? [String: Any] ?? json["usage"] as? [String: Any] {
                    let extracted = TokenExtractionUtility.extractUsageTokens(tokenUsage)
                    if extracted.input > 0 || extracted.output > 0 {
                        tokenData.input = extracted.input
                        tokenData.output = extracted.output
                        tokenData.cacheCreation = extracted.cacheCreation
                        tokenData.cacheRead = extracted.cacheRead
                        usedSettingsTotals = true
                    }
                }
            }
        }

        let mtime = modificationDate(of: jsonlFile)
        let conv = ClaudeConversationAccumulator()

        if let handle = try? FileHandle(forReadingFrom: jsonlFile) {
            defer { try? handle.close() }
            for line in handle.readAllUTF8Lines() {
                guard let data = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    continue
                }

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

                    // Check usage on ALL roles — Factory sometimes writes usage on non-assistant lines
                    if !usedSettingsTotals,
                       let usage = message["usage"] as? [String: Any] {
                        let extracted = TokenExtractionUtility.extractUsageTokens(
                            usage,
                            inputHint: userCharCount,
                            outputHint: assistantCharCount + assistantReasoningCharCount
                        )
                        tokenData.input += extracted.input
                        tokenData.output += extracted.output
                        tokenData.cacheCreation += extracted.cacheCreation
                        tokenData.cacheRead += extracted.cacheRead
                    }
                }

                conv.ingest(jsonLine: json)
            }
        }

        conv.finalizeArrays()

        if tokenData.input == 0 && tokenData.output == 0 && tokenData.cacheCreation == 0 && tokenData.cacheRead == 0 {
            let totalChars = userCharCount + assistantCharCount + assistantReasoningCharCount
            guard totalChars > 0 else { return nil }
            let estimated = TokenExtractionUtility.estimateFallbackTokens(
                userVisibleChars: userCharCount,
                assistantVisibleChars: assistantCharCount,
                assistantReasoningChars: assistantReasoningCharCount,
                userMessageCount: userMessageCount,
                assistantMessageCount: assistantMessageCount
            )
            tokenData.input = estimated.input
            tokenData.output = estimated.output
        }

        let resolvedModel = inlineModel ?? tokenData.model
        tokenData.model = TokenExtractionUtility.normalizeModelName(resolvedModel)

        // When JSONL has no parseable timestamps (common for token-only / metadata lines),
        // use the log file's modification time — not Date(), or every re-scan lands in "Today".
        let fallbackActivity = mtime ?? Date()
        let startTime = conv.startTime ?? tokenData.startTime ?? fallbackActivity
        let endTime = conv.endTime ?? tokenData.endTime ?? startTime

        let detectedProvider = detectProviderFromModel(tokenData.model)
        guard detectedProvider == .factory else { return nil }

        guard tokenData.input > 0 || tokenData.output > 0 else { return nil }

        let pricing = ModelPricing.lookup(model: tokenData.model)
        let cost = pricing.cost(
            inputTokens: tokenData.input,
            outputTokens: tokenData.output,
            cacheCreationTokens: tokenData.cacheCreation,
            cacheReadTokens: tokenData.cacheRead
        )

        let usage = TokenUsage(
            provider: .factory,
            sessionId: sessionId,
            projectName: projectName,
            model: tokenData.model,
            inputTokens: tokenData.input,
            outputTokens: tokenData.output,
            cacheCreationTokens: tokenData.cacheCreation,
            cacheReadTokens: tokenData.cacheRead,
            costUSD: cost,
            startTime: startTime,
            endTime: endTime
        )

        let conversation = ConversationRecord(
            id: ConversationRecord.stableId(provider: .factory, sessionId: sessionId),
            provider: .factory,
            sessionId: sessionId,
            projectName: projectName,
            startTime: startTime,
            endTime: endTime,
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

    private func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }

    private func detectProviderFromModel(_ model: String) -> AgentProvider {
        let lowercasedModel = model.lowercased()

        if lowercasedModel.contains("minimax") {
            return .minimax
        }

        if lowercasedModel.contains("glm") || lowercasedModel.contains("z.ai") || lowercasedModel.contains("zai") {
            return .zai
        }

        return .factory
    }
}
