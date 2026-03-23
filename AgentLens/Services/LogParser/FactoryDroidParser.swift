import Foundation

// MARK: - Factory Droid Parser

/// FactoryDroidParser extracts token usage from Factory Droid sessions and categorizes
/// them by the underlying model provider (MiniMax, Z.ai, Claude, etc.)
final class FactoryDroidParser: LogParser {
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

        if let settingsFileURL = settingsFile {
            if let data = try? Data(contentsOf: settingsFileURL),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                tokenData.model = (json["model"] as? String) ?? "unknown"

                if let tokenUsage = json["tokenUsage"] as? [String: Any] {
                    tokenData.input = tokenUsage["inputTokens"] as? Int ?? 0
                    tokenData.output = tokenUsage["outputTokens"] as? Int ?? 0
                    tokenData.cacheCreation = tokenUsage["cacheCreationTokens"] as? Int ?? 0
                    tokenData.cacheRead = tokenUsage["cacheReadTokens"] as? Int ?? 0
                }
            }
        }

        let mtime = modificationDate(of: jsonlFile)
        let conv = ClaudeConversationAccumulator()

        if let handle = try? FileHandle(forReadingFrom: jsonlFile) {
            defer { try? handle.close() }
            while let line = handle.readLine(), !line.isEmpty {
                guard let data = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    continue
                }
                conv.ingest(jsonLine: json)
            }
        }

        conv.finalizeArrays()

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
}
