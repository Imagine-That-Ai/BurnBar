import Foundation
import OpenBurnBarCore

// MARK: - Claude Code Parser

public final class ClaudeCodeParser: LogParser, Sendable {
    public let provider: AgentProvider = .claudeCode
    private let fileManager: FileManager
    private let appPaths: OpenBurnBarAppPaths
    private let cacheURL: URL
    private let cacheStore: ParserDiskCacheStore<ClaudeCodeCacheEntry>
    private let projectsDirectoryOverride: URL?

    public init(
        fileManager: FileManager = .default,
        appPaths: OpenBurnBarAppPaths = .live(),
        projectsDirectoryOverride: URL? = nil
    ) {
        self.fileManager = fileManager
        self.appPaths = appPaths
        self.projectsDirectoryOverride = projectsDirectoryOverride
        self.cacheURL = appPaths.claudeCodeParserCacheURL
        self.cacheStore = ParserDiskCacheStore(
            cacheURL: cacheURL,
            fileManager: fileManager,
            schemaVersion: 2,
            logLabel: "ClaudeCodeParser"
        )
        _ = try? OpenBurnBarMigration.prepareSupportDirectory(fileManager: fileManager, paths: appPaths) // try?-ok(best-effort dir prep)
    }

    public func parse() async throws -> ParseResult {
        try await parse(options: .default)
    }

    public func parse(options: LogParseOptions) async throws -> ParseResult {
        try parseSynchronously(options: options)
    }

    func parseSynchronously(options: LogParseOptions) throws -> ParseResult {
        let projectsURL = projectsDirectoryOverride
            ?? URL(fileURLWithPath: (provider.logDirectory as NSString).expandingTildeInPath)
        let projectsPath = projectsURL.path

        guard fileManager.fileExists(atPath: projectsPath) else {
            return ParseResult(usages: [], conversations: [])
        }

        var usages: [TokenUsage] = []
        var conversations: [ConversationRecord] = []
        var parseCache = cacheStore.load()
        var activePaths = Set<String>()
        var cacheMutated = false

        // try?-ok(dir read returns empty)
        guard let projectDirs = try? fileManager.contentsOfDirectory(
            at: projectsURL,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            return ParseResult(usages: [], conversations: [])
        }

        let filteredDirs = projectDirs.filter { $0.hasDirectoryPath }

        for projectDir in filteredDirs {
            let projectName = decodeProjectName(projectDir.lastPathComponent)

            guard let files = try? fileManager.contentsOfDirectory(at: projectDir, includingPropertiesForKeys: nil) else { // try?-ok(dir read skip)
                continue
            }

            let jsonlFiles = files.filter { $0.pathExtension == "jsonl" }

            for jsonlFile in jsonlFiles {
                let sessionId = jsonlFile.deletingPathExtension().lastPathComponent
                let cacheKey = cachePath(for: jsonlFile)
                activePaths.insert(cacheKey)

                if let signature = FileSignature(for: jsonlFile),
                   let cached = parseCache.fileEntries[cacheKey],
                   cached.signature == signature {
                    let cached = updateCacheEntry(
                        cached,
                        signature: signature,
                        file: jsonlFile,
                        sessionId: sessionId,
                        projectName: projectName,
                        includeConversationBodies: options.includeConversationBodies,
                        parseCache: &parseCache,
                        cacheKey: cacheKey,
                        cacheMutated: &cacheMutated
                    )
                    appendCached(
                        cached,
                        includeConversation: options.includeConversationBodies,
                        usages: &usages,
                        conversations: &conversations
                    )
                } else {
                    let parsed = try? parseClaudeSession( // try?-ok(best-effort log parse)
                        file: jsonlFile,
                        sessionId: sessionId,
                        projectName: projectName
                    )
                    appendParsed(
                        parsed,
                        includeConversation: options.includeConversationBodies,
                        usages: &usages,
                        conversations: &conversations
                    )

                    if let signature = FileSignature(for: jsonlFile) {
                        parseCache.fileEntries[cacheKey] = ClaudeCodeCacheEntry(
                            signature: signature,
                            usage: parsed?.usage,
                            conversation: nil
                        )
                        cacheMutated = true
                    }
                }

                // Parse subagent sessions in {sessionId}/subagents/agent-*.jsonl
                let subagentsDir = projectDir
                    .appendingPathComponent(sessionId)
                    .appendingPathComponent("subagents")
                if let subagentFiles = try? fileManager.contentsOfDirectory( // try?-ok(optional dir skip)
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

                        if let signature = FileSignature(for: agentFile),
                           let cached = parseCache.fileEntries[subagentCacheKey],
                           cached.signature == signature {
                            let cached = stripCachedConversationIfNeeded(
                                cached,
                                parseCache: &parseCache,
                                cacheKey: subagentCacheKey,
                                cacheMutated: &cacheMutated
                            )
                            appendCached(cached, includeConversation: false, usages: &usages, conversations: &conversations)
                        } else {
                            let parsed = try? parseClaudeSession( // try?-ok(best-effort log parse)
                                file: agentFile,
                                sessionId: subSessionId,
                                projectName: projectName
                            )
                            appendParsed(parsed, includeConversation: false, usages: &usages, conversations: &conversations)

                            if let signature = FileSignature(for: agentFile) {
                                parseCache.fileEntries[subagentCacheKey] = ClaudeCodeCacheEntry(
                                    signature: signature,
                                    usage: parsed?.usage,
                                    conversation: nil
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
            cacheStore.persist(parseCache)
        }

        return ParseResult(usages: usages, conversations: conversations)
    }

    public func decodeProjectName(_ encoded: String) -> String {
        var decoded = ClaudeCodeProjectPathCodec.decode(encoded)
        if decoded.isAmbiguous {
            decoded = ClaudeCodeProjectPathCodec.decode(encoded, style: .windows)
        }
        let path = decoded.displayPath

        if decoded.style == .posix, path.hasPrefix("/Users/") {
            let components = path.split(separator: "/")
            if components.count >= 2 {
                let rest = components.dropFirst(2).joined(separator: "/")
                return rest.isEmpty ? "~" : "~/" + rest
            }
        }

        if decoded.style == .windows {
            let components = path.split(separator: "\\")
            if components.count >= 3,
               components[0].hasSuffix(":"),
               components[1].lowercased() == "users" {
                let rest = components.dropFirst(3).joined(separator: "\\")
                return rest.isEmpty ? "~" : "~\\" + rest
            }
        }

        return path
    }

    private func parseClaudeSession(
        file: URL,
        sessionId: String,
        projectName: String
    ) throws -> (usage: TokenUsage?, conversation: ConversationRecord?)? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { // try?-ok(unreadable file skip)
            return nil
        }
        defer { try? handle.close() } // try?-ok(handle teardown)

        let mtime = modificationDate(of: file)

        let acc = ClaudeSessionAccumulator(projectName: projectName)
        let conv = ClaudeConversationAccumulator()
        var seenUsageKeys = Set<String>()

        for line in handle.readAllUTF8Lines() {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { // try?-ok(malformed line skip)
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

        guard acc.inputTokens > 0
            || acc.outputTokens > 0
            || acc.cacheCreationTokens > 0
            || acc.cacheReadTokens > 0 else {
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
            workingDirectory: projectName.hasPrefix("~/") || projectName.hasPrefix("/") ? projectName : nil,
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
        (try? fileManager.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date // try?-ok(optional mtime fallback)
    }

    private func cachePath(for file: URL) -> String {
        file.standardizedFileURL.path
    }

    private func appendCached(
        _ cached: ClaudeCodeCacheEntry,
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

    private func updateCacheEntry(
        _ cached: ClaudeCodeCacheEntry,
        signature: FileSignature,
        file: URL,
        sessionId: String,
        projectName: String,
        includeConversationBodies: Bool,
        parseCache: inout ParserDiskCache<ClaudeCodeCacheEntry>,
        cacheKey: String,
        cacheMutated: inout Bool
    ) -> ClaudeCodeCacheEntry {
        if !includeConversationBodies {
            return stripCachedConversationIfNeeded(
                cached,
                parseCache: &parseCache,
                cacheKey: cacheKey,
                cacheMutated: &cacheMutated
            )
        }

        let parsed = try? parseClaudeSession( // try?-ok(best-effort conversation cache reparse)
            file: file,
            sessionId: sessionId,
            projectName: projectName
        )
        let transient = ClaudeCodeCacheEntry(
            signature: signature,
            usage: cached.usage ?? parsed?.usage,
            conversation: parsed?.conversation
        )
        if cached.conversation != nil || (cached.usage == nil && parsed?.usage != nil) {
            parseCache.fileEntries[cacheKey] = ClaudeCodeCacheEntry(
                signature: signature,
                usage: transient.usage,
                conversation: nil
            )
            cacheMutated = true
        }
        return transient
    }

    private func stripCachedConversationIfNeeded(
        _ cached: ClaudeCodeCacheEntry,
        parseCache: inout ParserDiskCache<ClaudeCodeCacheEntry>,
        cacheKey: String,
        cacheMutated: inout Bool
    ) -> ClaudeCodeCacheEntry {
        guard cached.conversation != nil else { return cached }
        let stripped = ClaudeCodeCacheEntry(
            signature: cached.signature,
            usage: cached.usage,
            conversation: nil
        )
        parseCache.fileEntries[cacheKey] = stripped
        cacheMutated = true
        return stripped
    }

    private static func parseTimestamp(_ raw: Any?) -> Date? {
        if let string = raw as? String {
            return ThreadSafeISO8601DateFormatter.parse(string)
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

private struct ClaudeCodeCacheEntry: Codable, Equatable {
    let signature: FileSignature
    let usage: TokenUsage?
    let conversation: ConversationRecord?
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
