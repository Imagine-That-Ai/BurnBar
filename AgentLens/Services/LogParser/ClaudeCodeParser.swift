import Foundation

// MARK: - Claude Code Parser

final class ClaudeCodeParser: LogParser, @unchecked Sendable {
    let provider: AgentProvider = .claudeCode
    private let fileManager: FileManager
    private let appPaths: OpenBurnBarAppPaths
    private let cacheURL: URL

    nonisolated(unsafe) private static let iso8601Basic: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    nonisolated(unsafe) private static let iso8601Fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    init(
        fileManager: FileManager = .default,
        appPaths: OpenBurnBarAppPaths = .live()
    ) {
        self.fileManager = fileManager
        self.appPaths = appPaths
        self.cacheURL = appPaths.claudeCodeParserCacheURL
        _ = try? OpenBurnBarMigration.prepareSupportDirectory(fileManager: fileManager, paths: appPaths)
    }

    func parse() async throws -> ParseResult {
        let projectsPath = (provider.logDirectory as NSString).expandingTildeInPath
        let projectsURL = URL(fileURLWithPath: projectsPath)

        guard fileManager.fileExists(atPath: projectsPath) else {
            return ParseResult(usages: [], conversations: [])
        }

        var usages: [TokenUsage] = []
        var conversations: [ConversationRecord] = []
        var parseCache = loadParseCache()
        var activePaths = Set<String>()
        var cacheMutated = false

        guard let projectDirs = try? fileManager.contentsOfDirectory(
            at: projectsURL,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            return ParseResult(usages: [], conversations: [])
        }

        let filteredDirs = projectDirs.filter { $0.hasDirectoryPath }

        for projectDir in filteredDirs {
            let projectName = decodeProjectName(projectDir.lastPathComponent)

            guard let files = try? fileManager.contentsOfDirectory(at: projectDir, includingPropertiesForKeys: nil) else {
                continue
            }

            let jsonlFiles = files.filter { $0.pathExtension == "jsonl" }

            for jsonlFile in jsonlFiles {
                let sessionId = jsonlFile.deletingPathExtension().lastPathComponent
                let cacheKey = cachePath(for: jsonlFile)
                activePaths.insert(cacheKey)

                if let signature = fileSignature(for: jsonlFile),
                   let cached = parseCache.fileEntries[cacheKey],
                   cached.signature == signature {
                    appendCached(cached, includeConversation: true, usages: &usages, conversations: &conversations)
                } else {
                    let parsed = try? parseClaudeSession(
                        file: jsonlFile,
                        sessionId: sessionId,
                        projectName: projectName
                    )
                    appendParsed(parsed, includeConversation: true, usages: &usages, conversations: &conversations)

                    if let signature = fileSignature(for: jsonlFile) {
                        parseCache.fileEntries[cacheKey] = ClaudeCodeCachedSession(
                            signature: signature,
                            usage: parsed?.usage,
                            conversation: parsed?.conversation
                        )
                        cacheMutated = true
                    }
                }

                // Parse subagent sessions in {sessionId}/subagents/agent-*.jsonl
                let subagentsDir = projectDir
                    .appendingPathComponent(sessionId)
                    .appendingPathComponent("subagents")
                if let subagentFiles = try? fileManager.contentsOfDirectory(
                    at: subagentsDir,
                    includingPropertiesForKeys: nil
                ) {
                    let agentJsonlFiles = subagentFiles.filter {
                        $0.pathExtension == "jsonl" && $0.lastPathComponent.hasPrefix("agent-")
                    }
                    for agentFile in agentJsonlFiles {
                        let agentId = agentFile.deletingPathExtension().lastPathComponent
                        let subSessionId = "\(sessionId)/\(agentId)"
                        let subagentCacheKey = cachePath(for: agentFile)
                        activePaths.insert(subagentCacheKey)

                        if let signature = fileSignature(for: agentFile),
                           let cached = parseCache.fileEntries[subagentCacheKey],
                           cached.signature == signature {
                            appendCached(cached, includeConversation: false, usages: &usages, conversations: &conversations)
                        } else {
                            let parsed = try? parseClaudeSession(
                                file: agentFile,
                                sessionId: subSessionId,
                                projectName: projectName
                            )
                            appendParsed(parsed, includeConversation: false, usages: &usages, conversations: &conversations)

                            if let signature = fileSignature(for: agentFile) {
                                parseCache.fileEntries[subagentCacheKey] = ClaudeCodeCachedSession(
                                    signature: signature,
                                    usage: parsed?.usage,
                                    conversation: parsed?.conversation
                                )
                                cacheMutated = true
                            }
                        }
                    }
                }
            }
        }

        let stalePaths = Set(parseCache.fileEntries.keys).subtracting(activePaths)
        if !stalePaths.isEmpty {
            for stalePath in stalePaths {
                parseCache.fileEntries.removeValue(forKey: stalePath)
            }
            cacheMutated = true
        }

        if cacheMutated {
            persistParseCache(parseCache)
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
        var seenUsageKeys = Set<String>()

        for line in handle.readAllUTF8Lines() {
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

            if let usageKey = claudeUsageIdentity(json: json, message: message) {
                guard seenUsageKeys.insert(usageKey).inserted else { continue }
            }

            if let date = Self.parseTimestamp(json["timestamp"]) {
                if acc.startTime == nil { acc.startTime = date }
                acc.endTime = date
            }

            let extracted = TokenExtractionUtility.extractUsageTokens(
                usage,
                inputHint: acc.inputTokens,
                outputHint: acc.outputTokens
            )
            acc.inputTokens += extracted.input
            acc.outputTokens += extracted.output
            acc.cacheCreationTokens += extracted.cacheCreation
            acc.cacheReadTokens += extracted.cacheRead

            if let model = message["model"] as? String {
                acc.models.insert(model)
            }
        }

        guard acc.inputTokens > 0 || acc.outputTokens > 0 else {
            return nil
        }

        conv.finalizeArrays()

        let model = acc.models.first ?? "claude"
        let pricing = ModelPricing.lookup(model: model)
        acc.totalCost = pricing.cost(
            inputTokens: acc.inputTokens,
            outputTokens: acc.outputTokens,
            cacheCreationTokens: acc.cacheCreationTokens,
            cacheReadTokens: acc.cacheReadTokens
        )

        let usageStartTime = acc.startTime ?? conv.startTime ?? mtime ?? Date()
        let usageEndTime = acc.endTime ?? conv.endTime ?? mtime ?? usageStartTime

        let usage = TokenUsage(
            provider: .claudeCode,
            sessionId: sessionId,
            projectName: acc.projectName,
            model: model,
            inputTokens: acc.inputTokens,
            outputTokens: acc.outputTokens,
            cacheCreationTokens: acc.cacheCreationTokens,
            cacheReadTokens: acc.cacheReadTokens,
            costUSD: acc.totalCost,
            startTime: usageStartTime,
            endTime: usageEndTime,
            provenanceMethod: .providerLog,
            provenanceConfidence: .exact
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

    private func claudeUsageIdentity(json: [String: Any], message: [String: Any]) -> String? {
        guard let messageID = message["id"] as? String,
              let requestID = json["requestId"] as? String,
              !messageID.isEmpty,
              !requestID.isEmpty else {
            return nil
        }
        return "\(messageID):\(requestID)"
    }

    private func modificationDate(of url: URL) -> Date? {
        (try? fileManager.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }

    private func cachePath(for file: URL) -> String {
        file.standardizedFileURL.path
    }

    private func appendCached(
        _ cached: ClaudeCodeCachedSession,
        includeConversation: Bool,
        usages: inout [TokenUsage],
        conversations: inout [ConversationRecord]
    ) {
        if let usage = cached.usage {
            usages.append(usage)
        }
        if includeConversation, let conversation = cached.conversation {
            conversations.append(conversation)
        }
    }

    private func appendParsed(
        _ parsed: (usage: TokenUsage?, conversation: ConversationRecord?)?,
        includeConversation: Bool,
        usages: inout [TokenUsage],
        conversations: inout [ConversationRecord]
    ) {
        guard let parsed else { return }
        if let usage = parsed.usage {
            usages.append(usage)
        }
        if includeConversation, let conversation = parsed.conversation {
            conversations.append(conversation)
        }
    }

    private func loadParseCache() -> ClaudeCodeParserCache {
        guard fileManager.fileExists(atPath: cacheURL.path) else { return .empty }
        do {
            let data = try Data(contentsOf: cacheURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let cache = try decoder.decode(ClaudeCodeParserCache.self, from: data)
            guard cache.schemaVersion == ClaudeCodeParserCache.empty.schemaVersion else {
                return .empty
            }
            return cache
        } catch {
            return .empty
        }
    }

    private func persistParseCache(_ cache: ClaudeCodeParserCache) {
        do {
            if !fileManager.fileExists(atPath: appPaths.supportDirectory.path) {
                try fileManager.createDirectory(at: appPaths.supportDirectory, withIntermediateDirectories: true)
            }
            var persisted = cache
            persisted.lastUpdatedAt = Date()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(persisted)
            try data.write(to: cacheURL, options: .atomic)
        } catch {
            AppLogger.parser.silentFailure("ClaudeCodeParser: Failed to persist parser cache", error: error)
        }
    }

    private func fileSignature(for file: URL) -> ClaudeCodeFileSignature? {
        let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey])
        guard values?.isRegularFile == true else { return nil }
        let modifiedAt = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let sizeBytes = Int64(values?.fileSize ?? 0)
        return ClaudeCodeFileSignature(modifiedAt: modifiedAt, sizeBytes: sizeBytes)
    }

    private static func parseTimestamp(_ raw: Any?) -> Date? {
        if let string = raw as? String {
            if let parsed = iso8601Fractional.date(from: string) { return parsed }
            if let parsed = iso8601Basic.date(from: string) { return parsed }
            return nil
        }

        let epoch: Double?
        if let number = raw as? NSNumber {
            epoch = number.doubleValue
        } else if let value = raw as? Double {
            epoch = value
        } else if let value = raw as? Int {
            epoch = Double(value)
        } else if let value = raw as? Int64 {
            epoch = Double(value)
        } else {
            epoch = nil
        }

        guard let epoch else { return nil }
        let seconds = epoch > 100_000_000_000 ? epoch / 1000.0 : epoch
        return Date(timeIntervalSince1970: seconds)
    }
}

private struct ClaudeCodeFileSignature: Codable, Equatable {
    let modifiedAt: TimeInterval
    let sizeBytes: Int64
}

private struct ClaudeCodeCachedSession: Codable, Equatable {
    let signature: ClaudeCodeFileSignature
    let usage: TokenUsage?
    let conversation: ConversationRecord?
}

private struct ClaudeCodeParserCache: Codable, Equatable {
    var schemaVersion: Int
    var fileEntries: [String: ClaudeCodeCachedSession]
    var lastUpdatedAt: Date?

    static let empty = ClaudeCodeParserCache(
        schemaVersion: 2,
        fileEntries: [:],
        lastUpdatedAt: nil
    )
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
