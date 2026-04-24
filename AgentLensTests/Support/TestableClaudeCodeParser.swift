import Foundation
@testable import OpenBurnBar

// AUDIT(@unchecked Sendable): FileManager is thread-safe but not formally Sendable.
final class TestableClaudeCodeParser: LogParser, @unchecked Sendable {
    let provider: AgentProvider = .claudeCode
    private let fileManager: FileManager
    private let testProjectsPath: URL
    private let cacheURL: URL

    init(fileManager: FileManager = .default, testProjectsPath: URL) {
        self.fileManager = fileManager
        self.testProjectsPath = testProjectsPath
        self.cacheURL = fileManager.temporaryDirectory
            .appendingPathComponent("claude-parser-test-cache-\(UUID().uuidString).json")
    }

    private func parseTimestamp(_ raw: Any?) -> Date? {
        if let string = raw as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: string) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: string) { return date }
            return nil
        }

        let epoch: Double?
        if let number = raw as? NSNumber {
            epoch = number.doubleValue
        } else if let value = raw as? Double {
            epoch = value
        } else if let value = raw as? Int {
            epoch = Double(value)
        } else {
            epoch = nil
        }

        guard let epoch else { return nil }
        let seconds = epoch > 100_000_000_000 ? epoch / 1000.0 : epoch
        return Date(timeIntervalSince1970: seconds)
    }

    func parse() async throws -> ParseResult {
        guard fileManager.fileExists(atPath: testProjectsPath.path) else {
            return ParseResult(usages: [], conversations: [])
        }

        var usages: [TokenUsage] = []
        var conversations: [ConversationRecord] = []

        guard let projectDirs = try? fileManager.contentsOfDirectory(
            at: testProjectsPath,
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
                let sessionId = jsonlFile.deletingPathExtension().lastPathComponent
                if let parsed = try? parseSession(file: jsonlFile, sessionId: sessionId, projectName: projectName) {
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
                    if currentSegment.isEmpty == false {
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
        if currentSegment.isEmpty == false {
            segments.append(currentSegment)
        }

        if segments.count == 1 {
            return "~/" + segments[0]
        }
        return "~/" + segments.dropFirst().joined(separator: "/")
    }

    private func parseSession(
        file: URL,
        sessionId: String,
        projectName: String
    ) throws -> (usage: TokenUsage?, conversation: ConversationRecord?)? {
        guard let handle = try? FileHandle(forReadingFrom: file) else {
            return nil
        }
        defer { try? handle.close() }

        let mtime = modificationDate(of: file)
        var totalInput = 0
        var totalOutput = 0
        var cacheCreation = 0
        var cacheRead = 0
        var models: Set<String> = []
        var startTime: Date?
        var endTime: Date?
        var seenUsageKeys = Set<String>()

        for line in handle.readAllUTF8Lines() {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            guard json["type"] as? String == "assistant",
                  let message = json["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else {
                continue
            }

            if let usageKey = self.claudeUsageIdentity(json: json, message: message) {
                guard seenUsageKeys.insert(usageKey).inserted else { continue }
            }

            if let ts = parseTimestamp(json["timestamp"]) {
                if startTime == nil { startTime = ts }
                endTime = ts
            }

            totalInput += (usage["input_tokens"] as? Int) ?? 0
            totalOutput += (usage["output_tokens"] as? Int) ?? 0
            cacheCreation += (usage["cache_creation_input_tokens"] as? Int) ?? 0
            cacheRead += (usage["cache_read_input_tokens"] as? Int) ?? 0

            if let model = message["model"] as? String {
                models.insert(model)
            }
        }

        guard totalInput > 0 || totalOutput > 0 else {
            return nil
        }

        let model = models.first ?? "claude"
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
            provider: .claudeCode,
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
            id: ConversationRecord.stableId(provider: .claudeCode, sessionId: sessionId),
            provider: .claudeCode,
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

    private func claudeUsageIdentity(json: [String: Any], message: [String: Any]) -> String? {
        guard let messageID = message["id"] as? String,
              let requestID = json["requestId"] as? String,
              messageID.isEmpty == false,
              requestID.isEmpty == false else {
            return nil
        }
        return "\(messageID):\(requestID)"
    }

    private func modificationDate(of url: URL) -> Date? {
        (try? fileManager.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }

    private static func parseTimestamp(_ raw: Any?) -> Date? {
        if let string = raw as? String {
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let parsed = fractional.date(from: string) { return parsed }

            let basic = ISO8601DateFormatter()
            basic.formatOptions = [.withInternetDateTime]
            if let parsed = basic.date(from: string) { return parsed }
            return nil
        }

        let epoch: Double?
        if let number = raw as? NSNumber {
            epoch = number.doubleValue
        } else if let value = raw as? Double {
            epoch = value
        } else if let value = raw as? Int {
            epoch = Double(value)
        } else {
            epoch = nil
        }

        guard let epoch else { return nil }
        let seconds = epoch > 100_000_000_000 ? epoch / 1000.0 : epoch
        return Date(timeIntervalSince1970: seconds)
    }
}
