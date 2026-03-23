import Foundation

// MARK: - Claude Code Parser

final class ClaudeCodeParser: LogParser {
    let provider: AgentProvider = .claudeCode

    func parse() async throws -> ParseResult {
        let projectsPath = (provider.logDirectory as NSString).expandingTildeInPath
        let projectsURL = URL(fileURLWithPath: projectsPath)

        guard FileManager.default.fileExists(atPath: projectsPath) else {
            return ParseResult(usages: [], conversations: [])
        }

        var usages: [TokenUsage] = []
        var conversations: [ConversationRecord] = []

        guard let projectDirs = try? FileManager.default.contentsOfDirectory(at: projectsURL, includingPropertiesForKeys: nil) else {
            return ParseResult(usages: [], conversations: [])
        }

        let filteredDirs = projectDirs.filter { $0.hasDirectoryPath }

        for projectDir in filteredDirs {
            let projectName = decodeProjectName(projectDir.lastPathComponent)

            guard let files = try? FileManager.default.contentsOfDirectory(at: projectDir, includingPropertiesForKeys: nil) else {
                continue
            }

            let jsonlFiles = files.filter { $0.pathExtension == "jsonl" }

            for jsonlFile in jsonlFiles {
                let sessionId = jsonlFile.deletingPathExtension().lastPathComponent

                if let pair = try? parseClaudeSession(
                    file: jsonlFile,
                    sessionId: sessionId,
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
        guard encoded.hasPrefix("-Users-") else {
            return encoded
        }

        let pathAfterPrefix = String(encoded.dropFirst(7))

        var segments: [String] = []
        var currentSegment = ""

        for (index, char) in pathAfterPrefix.enumerated() {
            if char == "-" && index + 1 < pathAfterPrefix.count {
                let nextIndex = pathAfterPrefix.index(pathAfterPrefix.startIndex, offsetBy: index + 1)
                let nextChar = pathAfterPrefix[nextIndex]

                if nextChar.isUppercase {
                    if !currentSegment.isEmpty {
                        segments.append(currentSegment)
                    }
                    currentSegment = ""
                } else {
                    currentSegment.append(char)
                }
            } else {
                currentSegment.append(char)
            }
        }

        if !currentSegment.isEmpty {
            segments.append(currentSegment)
        }

        if segments.count == 1 {
            return "~/" + segments[0]
        } else {
            let pathComponents = segments.dropFirst()
            return "~/" + pathComponents.joined(separator: "/")
        }
    }

    private func parseClaudeSession(
        file: URL,
        sessionId: String,
        projectName: String
    ) throws -> (usage: TokenUsage?, conversation: ConversationRecord?)? {
        guard let handle = try? FileHandle(forReadingFrom: file) else {
            return nil
        }
        defer { try? handle.close() }

        let mtime = modificationDate(of: file)

        let acc = ClaudeSessionAccumulator(projectName: projectName)
        let conv = ClaudeConversationAccumulator()

        while let line = handle.readLine(), !line.isEmpty {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            conv.ingest(jsonLine: json)

            guard json["type"] as? String == "assistant",
                  let message = json["message"] as? [String: Any],
                  message["role"] as? String == "assistant",
                  let usage = message["usage"] as? [String: Any] else {
                continue
            }

            if let timestamp = json["timestamp"] as? String {
                let date = ISO8601DateFormatter().date(from: timestamp)
                if acc.startTime == nil { acc.startTime = date }
                acc.endTime = date
            }

            acc.inputTokens += usage["input_tokens"] as? Int ?? 0
            acc.outputTokens += usage["output_tokens"] as? Int ?? 0
            acc.cacheCreationTokens += usage["cache_creation_input_tokens"] as? Int ?? 0
            acc.cacheReadTokens += usage["cache_read_input_tokens"] as? Int ?? 0

            if let model = message["model"] as? String {
                acc.models.insert(model)
            }
        }

        guard acc.inputTokens > 0 || acc.outputTokens > 0 else {
            return nil
        }

        conv.finalizeArrays()

        acc.totalCost = calculateClaudeCost(
            inputTokens: acc.inputTokens,
            outputTokens: acc.outputTokens,
            cacheCreationTokens: acc.cacheCreationTokens,
            cacheReadTokens: acc.cacheReadTokens,
            models: Array(acc.models)
        )

        let usage = TokenUsage(
            provider: .claudeCode,
            sessionId: sessionId,
            projectName: acc.projectName,
            model: acc.models.first ?? "claude",
            inputTokens: acc.inputTokens,
            outputTokens: acc.outputTokens,
            cacheCreationTokens: acc.cacheCreationTokens,
            cacheReadTokens: acc.cacheReadTokens,
            costUSD: acc.totalCost,
            startTime: acc.startTime ?? Date(),
            endTime: acc.endTime ?? Date()
        )

        let conversation = ConversationRecord(
            id: ConversationRecord.stableId(provider: .claudeCode, sessionId: sessionId),
            provider: .claudeCode,
            sessionId: sessionId,
            projectName: projectName,
            startTime: conv.startTime ?? usage.startTime,
            endTime: conv.endTime ?? usage.endTime,
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

    private func calculateClaudeCost(
        inputTokens: Int,
        outputTokens: Int,
        cacheCreationTokens: Int,
        cacheReadTokens: Int,
        models: [String]
    ) -> Double {
        let model = models.first?.lowercased() ?? ""

        let inputCost: Double
        let outputCost: Double
        let cacheCreationCost: Double
        let cacheReadCost: Double

        if model.contains("opus") {
            inputCost = 0.000015
            outputCost = 0.000075
            cacheCreationCost = 0.00001875
            cacheReadCost = 0.0000015
        } else if model.contains("sonnet") {
            inputCost = 0.000003
            outputCost = 0.000015
            cacheCreationCost = 0.00000375
            cacheReadCost = 0.0000003
        } else if model.contains("haiku") {
            inputCost = 0.00000025
            outputCost = 0.00000125
            cacheCreationCost = 0.0000003125
            cacheReadCost = 0.00000003
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

// MARK: - Session Accumulator (class so modifications persist)

private class ClaudeSessionAccumulator {
    let projectName: String
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheCreationTokens: Int = 0
    var cacheReadTokens: Int = 0
    var totalCost: Double = 0
    var models: Set<String> = []
    var startTime: Date?
    var endTime: Date?

    init(projectName: String) {
        self.projectName = projectName
    }
}
