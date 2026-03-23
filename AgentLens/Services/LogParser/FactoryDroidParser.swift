import Foundation

// MARK: - Factory Droid Parser

/// FactoryDroidParser extracts token usage from Factory Droid sessions and categorizes
/// them by the underlying model provider (MiniMax, Z.ai, Claude, etc.)
final class FactoryDroidParser: LogParser {
    let provider: AgentProvider = .factory
    private let ignoredContentKeys: Set<String> = ["type", "role", "id", "tool_use_id", "name"]

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

        if let settingsFileURL = settingsFile {
            if let data = try? Data(contentsOf: settingsFileURL),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let model = json["model"] as? String {
                    tokenData.model = normalizeModelName(model)
                }

                if let tokenUsage = json["tokenUsage"] as? [String: Any] {
                    let extracted = extractUsageTokens(
                        tokenUsage,
                        userCharHint: 0,
                        assistantCharHint: 0
                    )
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
                        let metrics = contentMetrics(from: content)
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

                        if inlineModel == nil, let detectedModel = detectModelHint(from: content) {
                            inlineModel = normalizeModelName(detectedModel)
                        }
                    }

                    if !usedSettingsTotals,
                       role == "assistant",
                       let usage = message["usage"] as? [String: Any] {
                        let extracted = extractUsageTokens(
                            usage,
                            userCharHint: userCharCount,
                            assistantCharHint: assistantCharCount + assistantReasoningCharCount
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
            let estimated = estimateFallbackTokens(
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
        tokenData.model = normalizeModelName(resolvedModel)

        let startTime = conv.startTime ?? tokenData.startTime ?? Date()
        let endTime = conv.endTime ?? tokenData.endTime ?? startTime

        let cost = calculateCost(
            inputTokens: tokenData.input,
            outputTokens: tokenData.output,
            cacheCreationTokens: tokenData.cacheCreation,
            cacheReadTokens: tokenData.cacheRead,
            model: tokenData.model
        )

        guard tokenData.input > 0 || tokenData.output > 0 else { return nil }

        let detectedProvider = detectProviderFromModel(tokenData.model)
        guard detectedProvider == .factory else { return nil }

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

    /// Detects the appropriate provider based on model name
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

    private func calculateCost(
        inputTokens: Int,
        outputTokens: Int,
        cacheCreationTokens: Int,
        cacheReadTokens: Int,
        model: String
    ) -> Double {
        let lowercasedModel = model.lowercased()

        let inputCost: Double
        let outputCost: Double
        let cacheCreationCost: Double
        let cacheReadCost: Double

        if lowercasedModel.contains("opus") {
            inputCost = 0.000015
            outputCost = 0.000075
            cacheCreationCost = 0.00001875
            cacheReadCost = 0.0000015
        } else if lowercasedModel.contains("sonnet") {
            inputCost = 0.000003
            outputCost = 0.000015
            cacheCreationCost = 0.00000375
            cacheReadCost = 0.0000003
        } else if lowercasedModel.contains("haiku") {
            inputCost = 0.00000025
            outputCost = 0.00000125
            cacheCreationCost = 0.0000003125
            cacheReadCost = 0.00000003
        } else if lowercasedModel.contains("glm") || lowercasedModel.contains("z.ai") || lowercasedModel.contains("zai") {
            inputCost = 0.000001
            outputCost = 0.000002
            cacheCreationCost = 0.0000005
            cacheReadCost = 0.0000001
        } else if lowercasedModel.contains("minimax") {
            inputCost = 0.000001
            outputCost = 0.000002
            cacheCreationCost = 0
            cacheReadCost = 0
        } else if lowercasedModel.contains("kimi-k2") || lowercasedModel.contains("kimi k2") {
            inputCost = 0.0000006
            outputCost = 0.000003
            cacheCreationCost = 0
            cacheReadCost = 0
        } else if lowercasedModel.contains("kimi") || lowercasedModel.contains("moonshot") {
            inputCost = 0.000003
            outputCost = 0.000015
            cacheCreationCost = 0
            cacheReadCost = 0
        } else {
            inputCost = 0.000003
            outputCost = 0.000015
            cacheCreationCost = 0.00000375
            cacheReadCost = 0.0000003
        }

        return Double(inputTokens) * inputCost
            + Double(outputTokens) * outputCost
            + Double(cacheCreationTokens) * cacheCreationCost
            + Double(cacheReadTokens) * cacheReadCost
    }

    private func normalizeModelName(_ model: String) -> String {
        model.hasPrefix("custom:") ? String(model.dropFirst(7)) : model
    }

    private func extractUsageTokens(
        _ usage: [String: Any],
        userCharHint: Int,
        assistantCharHint: Int
    ) -> (input: Int, output: Int, cacheCreation: Int, cacheRead: Int) {
        var input = firstIntValue(
            in: usage,
            paths: [
                ["input_tokens"],
                ["prompt_tokens"],
                ["inputTokens"],
                ["promptTokens"]
            ]
        ) ?? 0

        var output = firstIntValue(
            in: usage,
            paths: [
                ["output_tokens"],
                ["completion_tokens"],
                ["outputTokens"],
                ["completionTokens"]
            ]
        ) ?? 0

        let cacheCreation = firstIntValue(
            in: usage,
            paths: [
                ["cache_creation_input_tokens"],
                ["cache_creation_tokens"],
                ["cacheCreationTokens"]
            ]
        ) ?? 0

        let cacheRead = firstIntValue(
            in: usage,
            paths: [
                ["cache_read_input_tokens"],
                ["cache_read_tokens"],
                ["cacheReadTokens"],
                ["prompt_tokens_details", "cached_tokens"],
                ["promptTokensDetails", "cachedTokens"],
                ["cached_tokens"],
                ["cachedTokens"]
            ]
        ) ?? 0

        let thinking = firstIntValue(
            in: usage,
            paths: [
                ["thinking_tokens"],
                ["reasoning_tokens"],
                ["thinkingTokens"],
                ["reasoningTokens"],
                ["completion_tokens_details", "reasoning_tokens"],
                ["output_tokens_details", "reasoning_tokens"]
            ]
        ) ?? 0

        let total = firstIntValue(
            in: usage,
            paths: [
                ["total_tokens"],
                ["totalTokens"]
            ]
        ) ?? 0

        let explicitPayloadTotal = max(input, 0) + max(output, 0) + max(cacheCreation, 0) + max(cacheRead, 0)
        let normalizedTotal = max(total, explicitPayloadTotal)
        if normalizedTotal > 0 {
            let availableForInOut = max(normalizedTotal - cacheCreation - cacheRead, 0)
            if input == 0 && output == 0 && availableForInOut > 0 {
                let combinedHints = userCharHint + assistantCharHint
                let inputRatio = combinedHints > 0
                    ? Double(userCharHint) / Double(combinedHints)
                    : 0.62
                input = Int((Double(availableForInOut) * inputRatio).rounded())
                output = max(availableForInOut - input, 0)
            } else if input == 0 && output > 0 && availableForInOut > output {
                input = availableForInOut - output
            } else if output == 0 && input > 0 && availableForInOut > input {
                output = availableForInOut - input
            } else if input + output < availableForInOut {
                output += availableForInOut - (input + output)
            }
        }

        if thinking > 0 && total == 0 {
            output += thinking
        }

        return (
            input: max(input, 0),
            output: max(output, 0),
            cacheCreation: max(cacheCreation, 0),
            cacheRead: max(cacheRead, 0)
        )
    }

    private func firstIntValue(in dictionary: [String: Any], paths: [[String]]) -> Int? {
        for path in paths {
            if let value = nestedValue(in: dictionary, path: path),
               let intValue = parseInt(value) {
                return intValue
            }
        }
        return nil
    }

    private func nestedValue(in dictionary: [String: Any], path: [String]) -> Any? {
        var cursor: Any = dictionary
        for key in path {
            guard let dict = cursor as? [String: Any], let next = dict[key] else {
                return nil
            }
            cursor = next
        }
        return cursor
    }

    private func parseInt(_ value: Any?) -> Int? {
        guard let value else { return nil }
        if let intValue = value as? Int {
            return max(intValue, 0)
        }
        if let int64Value = value as? Int64 {
            return max(Int(int64Value), 0)
        }
        if let doubleValue = value as? Double {
            return max(Int(doubleValue.rounded()), 0)
        }
        if let numberValue = value as? NSNumber {
            return max(numberValue.intValue, 0)
        }
        if let stringValue = value as? String {
            let trimmed = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if let intValue = Int(trimmed) {
                return max(intValue, 0)
            }
            if let doubleValue = Double(trimmed) {
                return max(Int(doubleValue.rounded()), 0)
            }
        }
        return nil
    }

    private func detectModelHint(from value: Any) -> String? {
        switch value {
        case let text as String:
            guard text.lowercased().contains("model:") else { return nil }
            guard let range = text.range(of: "model:", options: .caseInsensitive) else { return nil }
            let afterModel = text[range.upperBound...]
            let endIndex = afterModel.firstIndex(of: "\n") ?? afterModel.endIndex
            let model = String(afterModel[..<endIndex]).trimmingCharacters(in: .whitespaces)
            return model.isEmpty ? nil : model
        case let array as [Any]:
            for item in array {
                if let found = detectModelHint(from: item) {
                    return found
                }
            }
            return nil
        case let dictionary as [String: Any]:
            for (_, nestedValue) in dictionary {
                if let found = detectModelHint(from: nestedValue) {
                    return found
                }
            }
            return nil
        default:
            return nil
        }
    }

    private func contentMetrics(from value: Any, key: String? = nil) -> (visibleChars: Int, reasoningChars: Int) {
        switch value {
        case let text as String:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return (0, 0) }
            if key == "signature" {
                return (0, trimmed.count)
            }
            if let key, ignoredContentKeys.contains(key) {
                return (0, 0)
            }
            return (trimmed.count, 0)
        case let array as [Any]:
            var visible = 0
            var reasoning = 0
            for item in array {
                let nested = contentMetrics(from: item)
                visible += nested.visibleChars
                reasoning += nested.reasoningChars
            }
            return (visible, reasoning)
        case let dictionary as [String: Any]:
            var visible = 0
            var reasoning = 0
            for (nestedKey, nestedValue) in dictionary {
                let nested = contentMetrics(from: nestedValue, key: nestedKey)
                visible += nested.visibleChars
                reasoning += nested.reasoningChars
            }
            return (visible, reasoning)
        default:
            return (0, 0)
        }
    }

    private func estimateFallbackTokens(
        userVisibleChars: Int,
        assistantVisibleChars: Int,
        assistantReasoningChars: Int,
        userMessageCount: Int,
        assistantMessageCount: Int
    ) -> (input: Int, output: Int) {
        let userTokens = estimatedTokenCount(for: userVisibleChars, charsPerToken: 3.35) + (userMessageCount * 9)
        let assistantVisibleTokens = estimatedTokenCount(for: assistantVisibleChars, charsPerToken: 3.35)
        let assistantReasoningTokens = estimatedTokenCount(for: assistantReasoningChars, charsPerToken: 2.45)
        let assistantTokens = assistantVisibleTokens + assistantReasoningTokens + (assistantMessageCount * 7)

        return (
            input: max(userTokens, 0),
            output: max(assistantTokens, 0)
        )
    }

    private func estimatedTokenCount(for characters: Int, charsPerToken: Double) -> Int {
        guard characters > 0 else { return 0 }
        return Int((Double(characters) / charsPerToken).rounded(.up))
    }
}
