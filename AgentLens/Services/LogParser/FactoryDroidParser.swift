import Foundation

// MARK: - Factory Droid Parser

/// FactoryDroidParser extracts token usage from Factory Droid sessions and categorizes
/// them by the underlying model provider (MiniMax, Z.ai, Claude, etc.)
final class FactoryDroidParser: LogParser, Sendable {
    let provider: AgentProvider = .factory
    private let fileManager: FileManager
    private let appPaths: OpenBurnBarAppPaths
    private let cacheURL: URL

    init(
        fileManager: FileManager = .default,
        appPaths: OpenBurnBarAppPaths = .live()
    ) {
        self.fileManager = fileManager
        self.appPaths = appPaths
        self.cacheURL = appPaths.factoryDroidParserCacheURL
        _ = try? OpenBurnBarMigration.prepareSupportDirectory(fileManager: fileManager, paths: appPaths)
    }

    func parse() async throws -> ParseResult {
        let sessionsPath = NSString(string: provider.logDirectory).expandingTildeInPath
        let sessionsURL = URL(fileURLWithPath: sessionsPath)

        guard fileManager.fileExists(atPath: sessionsPath) else {
            return ParseResult(usages: [], conversations: [])
        }

        var usages: [TokenUsage] = []
        var conversations: [ConversationRecord] = []
        var parseCache = loadParseCache()
        var activePaths = Set<String>()
        var cacheMutated = false

        let projectDirs = try fileManager.contentsOfDirectory(at: sessionsURL, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }

        for projectDir in projectDirs {
            let projectName = decodeProjectName(projectDir.lastPathComponent)

            let files = try fileManager.contentsOfDirectory(at: projectDir, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "jsonl" || $0.pathExtension == "json" }

            for jsonlFile in files where jsonlFile.pathExtension == "jsonl" {
                let baseName = jsonlFile.deletingPathExtension().lastPathComponent
                let settingsFile = projectDir.appendingPathComponent("\(baseName).settings.json")
                let metadataFile = projectDir.appendingPathComponent("\(baseName).metadata.json")
                let cacheKey = cachePath(for: jsonlFile)
                activePaths.insert(cacheKey)

                if let signature = compositeSignature(
                    jsonlFile: jsonlFile,
                    settingsFile: settingsFile,
                    metadataFile: metadataFile
                ), let cached = parseCache.fileEntries[cacheKey], cached.signature == signature {
                    appendCached(cached, usages: &usages, conversations: &conversations)
                } else {
                    let parsed: (usage: TokenUsage?, conversation: ConversationRecord?)?
                    if fileManager.fileExists(atPath: settingsFile.path) {
                        parsed = try? parseSession(
                            sessionId: baseName,
                            jsonlFile: jsonlFile,
                            settingsFile: settingsFile,
                            projectName: projectName
                        )
                    } else {
                        parsed = nil
                    }
                    appendParsed(parsed, usages: &usages, conversations: &conversations)

                    if let signature = compositeSignature(
                        jsonlFile: jsonlFile,
                        settingsFile: settingsFile,
                        metadataFile: metadataFile
                    ) {
                        parseCache.fileEntries[cacheKey] = FactoryDroidCachedSession(
                            signature: signature,
                            usage: parsed?.usage,
                            conversation: parsed?.conversation
                        )
                        cacheMutated = true
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
        // VAL-TOKEN-003: Settings/metadata exact totals suppress per-message fallback accumulation
        // VAL-TOKEN-011: Cache-only exact totals also suppress fallback (any non-zero bucket counts)
        if let settingsFileURL = settingsFile {
            if let data = try? Data(contentsOf: settingsFileURL),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let model = json["model"] as? String {
                    tokenData.model = TokenExtractionUtility.normalizeModelName(model)
                }

                if let tokenUsage = json["tokenUsage"] as? [String: Any] {
                    let extracted = TokenExtractionUtility.extractUsageTokens(tokenUsage)
                    // VAL-TOKEN-011: Any non-zero bucket (including cache-only) means exact total
                    if extracted.hasNoExplicitBuckets == false {
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
        // VAL-TOKEN-011: Cache-only exact totals also suppress fallback (any non-zero bucket counts)
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
                    // VAL-TOKEN-011: Any non-zero bucket (including cache-only) means exact total
                    if extracted.hasNoExplicitBuckets == false {
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
            endTime: endTime,
            provenanceMethod: .providerLog,
            provenanceConfidence: .exact
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
        (try? fileManager.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }

    private func cachePath(for file: URL) -> String {
        file.standardizedFileURL.path
    }

    private func appendCached(
        _ cached: FactoryDroidCachedSession,
        usages: inout [TokenUsage],
        conversations: inout [ConversationRecord]
    ) {
        if let usage = cached.usage {
            usages.append(usage)
        }
        if let conversation = cached.conversation {
            conversations.append(conversation)
        }
    }

    private func appendParsed(
        _ parsed: (usage: TokenUsage?, conversation: ConversationRecord?)?,
        usages: inout [TokenUsage],
        conversations: inout [ConversationRecord]
    ) {
        guard let parsed else { return }
        if let usage = parsed.usage {
            usages.append(usage)
        }
        if let conversation = parsed.conversation {
            conversations.append(conversation)
        }
    }

    private func loadParseCache() -> FactoryDroidParserCache {
        guard fileManager.fileExists(atPath: cacheURL.path) else { return .empty }
        do {
            let data = try Data(contentsOf: cacheURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let cache = try decoder.decode(FactoryDroidParserCache.self, from: data)
            guard cache.schemaVersion == FactoryDroidParserCache.empty.schemaVersion else {
                return .empty
            }
            return cache
        } catch {
            return .empty
        }
    }

    private func persistParseCache(_ cache: FactoryDroidParserCache) {
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
            AppLogger.parser.silentFailure("FactoryDroidParser: Failed to persist parser cache", error: error)
        }
    }

    private func compositeSignature(
        jsonlFile: URL,
        settingsFile: URL,
        metadataFile: URL
    ) -> FactoryDroidCompositeSignature? {
        guard let jsonl = fileSignature(for: jsonlFile) else {
            return nil
        }
        let settings = fileSignature(for: settingsFile)
        let metadata = fileSignature(for: metadataFile)
        return FactoryDroidCompositeSignature(
            jsonl: jsonl,
            settings: settings,
            metadata: metadata
        )
    }

    private func fileSignature(for file: URL) -> FactoryDroidFileSignature? {
        let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey])
        guard values?.isRegularFile == true else { return nil }
        let modifiedAt = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let sizeBytes = Int64(values?.fileSize ?? 0)
        return FactoryDroidFileSignature(modifiedAt: modifiedAt, sizeBytes: sizeBytes)
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

private struct FactoryDroidFileSignature: Codable, Equatable {
    let modifiedAt: TimeInterval
    let sizeBytes: Int64
}

private struct FactoryDroidCompositeSignature: Codable, Equatable {
    let jsonl: FactoryDroidFileSignature
    let settings: FactoryDroidFileSignature?
    let metadata: FactoryDroidFileSignature?
}

private struct FactoryDroidCachedSession: Codable, Equatable {
    let signature: FactoryDroidCompositeSignature
    let usage: TokenUsage?
    let conversation: ConversationRecord?
}

private struct FactoryDroidParserCache: Codable, Equatable {
    var schemaVersion: Int
    var fileEntries: [String: FactoryDroidCachedSession]
    var lastUpdatedAt: Date?

    static let empty = FactoryDroidParserCache(
        schemaVersion: 2,
        fileEntries: [:],
        lastUpdatedAt: nil
    )
}
