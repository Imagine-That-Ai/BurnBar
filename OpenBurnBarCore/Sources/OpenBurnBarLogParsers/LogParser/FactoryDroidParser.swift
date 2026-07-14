import Foundation
import OpenBurnBarKernel

// MARK: - Factory Droid Parser

/// FactoryDroidParser extracts token usage from Factory Droid sessions and categorizes
/// them by the underlying model provider (MiniMax, Z.ai, Claude, etc.)
public final class FactoryDroidParser: LogParser, Sendable {
    public let provider: AgentProvider = .factory
    private let fileManager: FileManager
    private let appPaths: OpenBurnBarAppPaths
    private let cacheURL: URL
    private let cacheStore: ParserDiskCacheStore<FactoryDroidCacheEntry>
    private let sessionsDirectoryOverride: URL?

    public init(
        fileManager: FileManager = .default,
        appPaths: OpenBurnBarAppPaths = .live(),
        sessionsDirectoryOverride: URL? = nil
    ) {
        self.fileManager = fileManager
        self.appPaths = appPaths
        self.sessionsDirectoryOverride = sessionsDirectoryOverride
        self.cacheURL = appPaths.factoryDroidParserCacheURL
        self.cacheStore = ParserDiskCacheStore(
            cacheURL: cacheURL,
            fileManager: fileManager,
            schemaVersion: 3,
            logLabel: "FactoryDroidParser"
        )
        _ = try? OpenBurnBarMigration.prepareSupportDirectory(fileManager: fileManager, paths: appPaths) // try?-ok(best-effort dir prep)
    }

    public func parse() async throws -> ParseResult {
        try await parse(options: .default)
    }

    public func parse(options: LogParseOptions) async throws -> ParseResult {
        try parseSynchronously(options: options)
    }

    public func parseSynchronously(options: LogParseOptions) throws -> ParseResult {
        let sessionsURL = sessionsDirectoryOverride
            ?? URL(fileURLWithPath: NSString(string: provider.logDirectory).expandingTildeInPath)
        let sessionsPath = sessionsURL.path

        guard fileManager.fileExists(atPath: sessionsPath) else {
            return ParseResult(usages: [], conversations: [])
        }

        var usages: [TokenUsage] = []
        var conversations: [ConversationRecord] = []
        var parseCache = cacheStore.load()
        var activePaths = Set<String>()
        var cacheMutated = false

        let projectDirs = try fileManager.contentsOfDirectory(at: sessionsURL, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true } // try?-ok(non-dir filtered out)

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
                    let cached = updateCacheEntry(
                        cached,
                        signature: signature,
                        jsonlFile: jsonlFile,
                        settingsFile: settingsFile,
                        sessionId: baseName,
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
                    let parsed: (usage: TokenUsage?, conversation: ConversationRecord?)?
                    if fileManager.fileExists(atPath: settingsFile.path) {
                        // try?-ok(best-effort session parse)
                        parsed = try? parseSession(
                            sessionId: baseName,
                            jsonlFile: jsonlFile,
                            settingsFile: settingsFile,
                            projectName: projectName
                        )
                    } else {
                        parsed = nil
                    }
                    appendParsed(
                        parsed,
                        includeConversation: options.includeConversationBodies,
                        usages: &usages,
                        conversations: &conversations
                    )

                    if let signature = compositeSignature(
                        jsonlFile: jsonlFile,
                        settingsFile: settingsFile,
                        metadataFile: metadataFile
                    ) {
                        parseCache.fileEntries[cacheKey] = FactoryDroidCacheEntry(
                            signature: signature,
                            usage: parsed?.usage,
                            conversation: nil
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
            cacheStore.persist(parseCache)
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

    /// Token totals and session metadata accumulated while parsing one session.
    private struct SessionTokenData {
        var input: Int = 0
        var output: Int = 0
        var cacheCreation: Int = 0
        var cacheRead: Int = 0
        var model: String = "unknown"
        var startTime: Date?
        var endTime: Date?
    }

    private func parseSession(
        sessionId: String,
        jsonlFile: URL,
        settingsFile: URL?,
        projectName: String
    ) throws -> (usage: TokenUsage?, conversation: ConversationRecord?)? {
        var tokenData = SessionTokenData()

        var usedSettingsTotals = false
        var userCharCount = 0
        var assistantCharCount = 0
        var assistantReasoningCharCount = 0
        var userMessageCount = 0
        var assistantMessageCount = 0
        var inlineModel: String?
        var workingDirectory: String?

        // Check settings.json for model and token usage totals
        // VAL-TOKEN-003: Settings/metadata exact totals suppress per-message fallback accumulation
        // VAL-TOKEN-011: Cache-only exact totals also suppress fallback (any non-zero bucket counts)
        if let settingsFileURL = settingsFile {
            if let data = try? Data(contentsOf: settingsFileURL), // try?-ok(missing settings skipped)
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { // try?-ok(malformed json skipped)
                if let model = json["model"] as? String {
                    tokenData.model = TokenExtractionUtility.normalizeModelName(model)
                }
                workingDirectory = (json["cwd"] as? String)
                    ?? (json["workingDirectory"] as? String)
                    ?? (json["working_dir"] as? String)

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
            if let data = try? Data(contentsOf: metadataURL), // try?-ok(missing metadata skipped)
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { // try?-ok(malformed json skipped)
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

        if let handle = try? FileHandle(forReadingFrom: jsonlFile) { // try?-ok(unreadable log skipped)
            defer { try? handle.close() } // try?-ok(handle teardown)
            for line in handle.readAllUTF8Lines() {
                guard let data = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { // try?-ok(bad log line skipped)
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

        tokenData.model = resolveModel(structuredModel: tokenData.model, inlineModel: inlineModel)

        // When JSONL has no parseable timestamps (common for token-only / metadata lines),
        // use the log file's modification time — not Date(), or every re-scan lands in "Today".
        let fallbackActivity = mtime ?? Date()
        let startTime = conv.startTime ?? tokenData.startTime ?? fallbackActivity
        let endTime = conv.endTime ?? tokenData.endTime ?? startTime

        guard tokenData.input > 0
            || tokenData.output > 0
            || tokenData.cacheCreation > 0
            || tokenData.cacheRead > 0 else { return nil }

        let pricing = ModelPricing.lookup(model: tokenData.model, providerID: "factory")
        let cost = try pricing.cost(
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
            workingDirectory: workingDirectory,
            fileModifiedAt: mtime,
            summary: nil
        )

        return (usage, conversation)
    }

    private func modificationDate(of url: URL) -> Date? {
        (try? fileManager.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date // try?-ok(mtime fallback to now)
    }

    private func cachePath(for file: URL) -> String {
        file.standardizedFileURL.path
    }

    private func appendCached(
        _ cached: FactoryDroidCacheEntry,
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
        _ cached: FactoryDroidCacheEntry,
        signature: CompositeFileSignature<FileSignature>,
        jsonlFile: URL,
        settingsFile: URL,
        sessionId: String,
        projectName: String,
        includeConversationBodies: Bool,
        parseCache: inout ParserDiskCache<FactoryDroidCacheEntry>,
        cacheKey: String,
        cacheMutated: inout Bool
    ) -> FactoryDroidCacheEntry {
        if !includeConversationBodies {
            guard cached.conversation != nil else { return cached }
            let stripped = FactoryDroidCacheEntry(
                signature: cached.signature,
                usage: cached.usage,
                conversation: nil
            )
            parseCache.fileEntries[cacheKey] = stripped
            cacheMutated = true
            return stripped
        }

        let parsed = try? parseSession( // try?-ok(best-effort conversation cache reparse)
            sessionId: sessionId,
            jsonlFile: jsonlFile,
            settingsFile: settingsFile,
            projectName: projectName
        )
        let transient = FactoryDroidCacheEntry(
            signature: signature,
            usage: cached.usage ?? parsed?.usage,
            conversation: parsed?.conversation
        )
        if cached.conversation != nil || (cached.usage == nil && parsed?.usage != nil) {
            parseCache.fileEntries[cacheKey] = FactoryDroidCacheEntry(
                signature: signature,
                usage: transient.usage,
                conversation: nil
            )
            cacheMutated = true
        }
        return transient
    }

    private func resolveModel(structuredModel: String, inlineModel: String?) -> String {
        let structured = TokenExtractionUtility.normalizeModelName(structuredModel)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedInline = inlineModel.map {
            TokenExtractionUtility.normalizeModelName($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let inline = normalizedInline, !inline.isEmpty else {
            return structured.isEmpty ? "unknown" : structured
        }

        if structured.isEmpty || structured == "unknown" {
            return inline
        }

        if ModelPricing.hasCatalogPricing(model: structured, providerID: "factory") {
            return structured
        }

        if ModelPricing.hasCatalogPricing(model: inline, providerID: "factory") {
            return inline
        }

        return structured
    }

    private func compositeSignature(
        jsonlFile: URL,
        settingsFile: URL,
        metadataFile: URL
    ) -> CompositeFileSignature<FileSignature>? {
        guard let jsonl = FileSignature(for: jsonlFile) else { return nil }
        let settings = FileSignature(for: settingsFile)
        let metadata = FileSignature(for: metadataFile)
        return CompositeFileSignature(primary: jsonl, settings: settings, metadata: metadata)
    }
}

private struct FactoryDroidCacheEntry: Codable, Equatable {
    let signature: CompositeFileSignature<FileSignature>
    let usage: TokenUsage?
    let conversation: ConversationRecord?
}
