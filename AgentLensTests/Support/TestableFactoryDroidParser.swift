import Foundation
@testable import OpenBurnBar

/// Testable wrapper for FactoryDroidParser that allows injecting test paths.
final class TestableFactoryDroidParser: LogParser, @unchecked Sendable {
    let provider: AgentProvider = .factory
    private let fileManager: FileManager
    private let testSessionsPath: URL

    init(fileManager: FileManager = .default, testSessionsPath: URL) {
        self.fileManager = fileManager
        self.testSessionsPath = testSessionsPath
    }

    func parse() async throws -> ParseResult {
        guard fileManager.fileExists(atPath: testSessionsPath.path) else {
            return ParseResult(usages: [], conversations: [])
        }

        var usages: [TokenUsage] = []
        var conversations: [ConversationRecord] = []

        guard let projectDirs = try? fileManager.contentsOfDirectory(
            at: testSessionsPath,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            return ParseResult(usages: [], conversations: [])
        }

        for projectDir in projectDirs.filter(\.hasDirectoryPath) {
            let projectName = decodeProjectName(projectDir.lastPathComponent)

            guard let files = try? fileManager.contentsOfDirectory(at: projectDir, includingPropertiesForKeys: nil) else {
                continue
            }

            let jsonlFiles = files.filter { $0.pathExtension == "jsonl" }

            for jsonlFile in jsonlFiles {
                let baseName = jsonlFile.deletingPathExtension().lastPathComponent
                let settingsFile = projectDir.appendingPathComponent("\(baseName).settings.json")
                let metadataFile = projectDir.appendingPathComponent("\(baseName).metadata.json")

                if let parsed = try? parseSession(
                    jsonlFile: jsonlFile,
                    settingsFile: settingsFile,
                    metadataFile: metadataFile,
                    sessionId: baseName,
                    projectName: projectName
                ) {
                    if let usage = parsed.usage {
                        usages.append(usage)
                    }
                    if let conversation = parsed.conversation {
                        conversations.append(conversation)
                    }
                }
            }
        }

        return ParseResult(usages: usages, conversations: conversations)
    }

    private func decodeProjectName(_ encoded: String) -> String {
        encoded
            .replacingOccurrences(of: "-Users-", with: "~/")
            .replacingOccurrences(of: "-", with: "/")
    }

    private func parseSession(
        jsonlFile: URL,
        settingsFile: URL,
        metadataFile: URL,
        sessionId: String,
        projectName: String
    ) throws -> (usage: TokenUsage?, conversation: ConversationRecord?)? {
        var totalInput = 0
        var totalOutput = 0
        var cacheCreation = 0
        var cacheRead = 0
        var model = "unknown"
        var startTime: Date?
        var endTime: Date?

        // Check settings.json
        if let data = try? Data(contentsOf: settingsFile),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let m = json["model"] as? String {
                model = m
            }
            if let tokenUsage = json["tokenUsage"] as? [String: Any] {
                totalInput = tokenUsage["input_tokens"] as? Int ?? 0
                totalOutput = tokenUsage["output_tokens"] as? Int ?? 0
            }
        }

        // Check metadata.json if settings didn't have tokens
        if totalInput == 0 && totalOutput == 0 {
            if let data = try? Data(contentsOf: metadataFile),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if model == "unknown", let m = json["model"] as? String {
                    model = m
                }
                if let usage = json["usage"] as? [String: Any] ?? json["tokenUsage"] as? [String: Any] {
                    totalInput = usage["input_tokens"] as? Int ?? 0
                    totalOutput = usage["output_tokens"] as? Int ?? 0
                }
            }
        }

        // Parse JSONL for timestamps and additional tokens
        if let handle = try? FileHandle(forReadingFrom: jsonlFile) {
            defer { try? handle.close() }

            for line in handle.readAllUTF8Lines() {
                guard let data = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    continue
                }

                if let ts = parseTimestamp(json["timestamp"] as? String) {
                    if startTime == nil { startTime = ts }
                    endTime = ts
                }

                if let message = json["message"] as? [String: Any],
                   let usage = message["usage"] as? [String: Any] {
                    if totalInput == 0 {
                        totalInput = usage["input_tokens"] as? Int ?? 0
                    }
                    if totalOutput == 0 {
                        totalOutput = usage["output_tokens"] as? Int ?? 0
                    }
                }
            }
        }

        guard totalInput > 0 || totalOutput > 0 else {
            return nil
        }

        let mtime = (try? fileManager.attributesOfItem(atPath: jsonlFile.path)[.modificationDate]) as? Date
        let pricing = ModelPricing.lookup(model: model)
        let cost = pricing.cost(
            inputTokens: totalInput,
            outputTokens: totalOutput,
            cacheCreationTokens: cacheCreation,
            cacheReadTokens: cacheRead
        )

        let usageStart = startTime ?? mtime ?? Date()
        let usageEnd = endTime ?? mtime ?? usageStart

        let usage = TokenUsage(
            provider: .factory,
            sessionId: sessionId,
            projectName: projectName,
            model: model,
            inputTokens: totalInput,
            outputTokens: totalOutput,
            cacheCreationTokens: cacheCreation,
            cacheReadTokens: cacheRead,
            costUSD: cost,
            startTime: usageStart,
            endTime: usageEnd
        )

        let conversation = ConversationRecord(
            id: ConversationRecord.stableId(provider: .factory, sessionId: sessionId),
            provider: .factory,
            sessionId: sessionId,
            projectName: projectName,
            startTime: usageStart,
            endTime: usageEnd,
            messageCount: 0,
            userWordCount: 0,
            assistantWordCount: 0,
            keyFiles: [],
            keyCommands: [],
            keyTools: [],
            inferredTaskTitle: projectName,
            lastAssistantMessage: "",
            fullText: "",
            indexedAt: Date(),
            fileModifiedAt: mtime,
            summary: nil
        )

        return (usage, conversation)
    }

    private func parseTimestamp(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: raw)
    }
}
