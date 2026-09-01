import Foundation
import OpenBurnBarKernel

// MARK: - Antigravity Parser

/// Parses Antigravity CLI sessions from ~/.gemini/antigravity-cli/brain/<conversationId>/.system_generated/logs/transcript.jsonl
///
/// Token estimation counts ALL content categories for accurate results:
///   - **Input tokens**: user content + system messages + tool output (results fed back as context)
///   - **Output tokens**: assistant visible text + thinking/reasoning + tool call arguments
///
/// Prefers `transcript_full.jsonl` (untruncated) over `transcript.jsonl` when available.
/// Extracts per-session model name from `USER_SETTINGS_CHANGE` metadata and workspace
/// project name from `user_information` blocks embedded in the transcript.
///
/// Idle usage ticks resume unchanged transcripts from a mtime+size disk cache
/// (token totals only — never conversation bodies). The configured fallback
/// model from `settings.json` participates in the signature so a selector
/// change cannot reuse a cached row that still carried the previous model.
public final class AntigravityParser: LogParser, Sendable {
    public let logDirectoryOverride: String?
    private let fileManager: FileManager
    private let cacheStore: ParserDiskCacheStore<CachedUsageEntry<AntigravityCacheSignature>>
    private let sessionScanCount = Locked(0)
    private let sessionCacheHitCount = Locked(0)

    /// Transcript identity plus the settings.json fallback model. Session-level
    /// model extracted from the transcript is already in the cached totals;
    /// including the fallback string still busts hits when a session has no
    /// embedded model and the user changes the selector.
    private struct AntigravityCacheSignature: Codable, Equatable, Sendable {
        var transcript: FileSignature
        var fallbackModel: String
    }

    public init(
        logDirectoryOverride: String? = nil,
        fileManager: FileManager = .default,
        appPaths: OpenBurnBarAppPaths = .live()
    ) {
        self.logDirectoryOverride = logDirectoryOverride
        self.fileManager = fileManager
        let cacheURL: URL
        if let override = logDirectoryOverride {
            cacheURL = URL(fileURLWithPath: override).appendingPathComponent(".obb-antigravity-parser-cache.plist")
        } else {
            cacheURL = appPaths.antigravityParserCacheURL
        }
        self.cacheStore = ParserDiskCacheStore(
            cacheURL: cacheURL,
            fileManager: fileManager,
            schemaVersion: 1,
            logLabel: "AntigravityParser"
        )
    }

    var lastSessionScanCount: Int { sessionScanCount.read() }
    var lastSessionCacheHitCount: Int { sessionCacheHitCount.read() }

    public let provider: AgentProvider = .antigravity

    struct SettingsFile: Decodable {
        let model: String?
    }

    private struct SessionContentReadError: Error {
        let underlying: Error
    }

    private struct SettingsCacheEntry: Sendable {
        let identity: ParserDiscoveredFile
        let model: String
    }

    /// `settings.json` contains one model selector. A fixed metadata ceiling
    /// prevents a corrupt file from exploiting the governor's soft first-file
    /// admission rule to allocate an unbounded `Data` payload.
    static let maximumSettingsFileBytes = 64 * 1024

    private let settingsCache = Locked<SettingsCacheEntry?>(nil)

    private func candidateBasePaths() -> [String] {
        if let override = logDirectoryOverride {
            return [(override as NSString).expandingTildeInPath]
        }
        return [
            ("~/.gemini/antigravity" as NSString).expandingTildeInPath,
            ("~/.gemini/antigravity-cli" as NSString).expandingTildeInPath,
            ("~/.antigravity" as NSString).expandingTildeInPath
        ]
    }

    private func resolveSettingsURL(candidateRoots: [String]) -> URL? {
        for root in candidateRoots {
            let url = URL(fileURLWithPath: root).appendingPathComponent("settings.json")
            if fileManager.fileExists(atPath: url.path) {
                return url
            }
        }
        if logDirectoryOverride == nil {
            let geminiSettings = URL(fileURLWithPath: ("~/.gemini/settings.json" as NSString).expandingTildeInPath)
            if fileManager.fileExists(atPath: geminiSettings.path) {
                return geminiSettings
            }
        }
        return nil
    }

    public func parse() async throws -> ParseResult {
        try await parse(options: .default)
    }

    public func parse(options: LogParseOptions) async throws -> ParseResult {
        sessionScanCount.write(0)
        sessionCacheHitCount.write(0)
        let gate = ParserFileReadGate(options: options, fileManager: fileManager)
        let basePaths = candidateBasePaths()
        let settingsURL = resolveSettingsURL(candidateRoots: basePaths)
        let fallbackModelName = try configuredFallbackModel(
            at: settingsURL,
            options: options,
            fileManager: fileManager,
            readGate: gate
        )

        var usages: [TokenUsage] = []
        var conversations: [ConversationRecord] = []
        var parseCache = cacheStore.load()
        var activePaths = Set<String>()
        var seenSessionIds = Set<String>()
        var cacheMutated = false
        defer {
            if cacheMutated {
                cacheStore.persist(parseCache)
            }
        }

        for basePath in basePaths {
            let brainPath = (basePath as NSString).appendingPathComponent("brain")
            guard fileManager.fileExists(atPath: brainPath) else { continue }
            let brainURL = URL(fileURLWithPath: brainPath)
            let conversationDirs = (try? fileManager.contentsOfDirectory(at: brainURL, includingPropertiesForKeys: [.isDirectoryKey]))?.filter {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            } ?? []

            for conversationDir in conversationDirs {
                let sessionId = conversationDir.lastPathComponent
                guard seenSessionIds.insert(sessionId).inserted else { continue }

                let logsDir = conversationDir
                    .appendingPathComponent(".system_generated")
                    .appendingPathComponent("logs")

                let fullTranscript = logsDir.appendingPathComponent("transcript_full.jsonl")
                let truncatedTranscript = logsDir.appendingPathComponent("transcript.jsonl")
                let transcriptFile = fileManager.fileExists(atPath: fullTranscript.path) ? fullTranscript : truncatedTranscript

                guard fileManager.fileExists(atPath: transcriptFile.path) else { continue }
                let cacheKey = transcriptFile.standardizedFileURL.path
                activePaths.insert(cacheKey)
                guard try gate.shouldRead(transcriptFile) else { continue }

                let signature = FileSignature(for: transcriptFile, using: fileManager).map {
                    AntigravityCacheSignature(transcript: $0, fallbackModel: fallbackModelName)
                }
                if !options.includeConversationBodies,
                   let signature,
                   let cached = parseCache.fileEntries[cacheKey],
                   cached.signature == signature {
                    sessionCacheHitCount.withLock { $0 += 1 }
                    usages.append(cached.totals.makeUsage(provider: .antigravity, sessionId: sessionId))
                    continue
                }

                sessionScanCount.withLock { $0 += 1 }
                do {
                    if let pair = try parseSession(
                        transcriptFile: transcriptFile,
                        sessionId: sessionId,
                        fallbackModel: fallbackModelName,
                        includeConversationBodies: options.includeConversationBodies
                    ) {
                        if let usage = pair.usage {
                            usages.append(usage)
                            if let signature {
                                parseCache.fileEntries[cacheKey] = CachedUsageEntry(signature: signature, usage: usage)
                                cacheMutated = true
                            }
                        }
                        if options.includeConversationBodies, let conv = pair.conversation {
                            conversations.append(conv)
                        }
                    }
                } catch let error as SessionContentReadError {
                    gate.recordContentReadFailure(for: transcriptFile)
                    ParserDiagnostics.silentFailure(
                        "antigravity_transcript_unreadable path=\(transcriptFile.path)",
                        error: error.underlying
                    )
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

        return ParseResult(usages: usages, conversations: conversations)
    }

    private func configuredFallbackModel(
        at settingsURL: URL?,
        options: LogParseOptions,
        fileManager: FileManager,
        readGate: ParserFileReadGate
    ) throws -> String {
        let defaultModel = "Claude Opus 4.6 (Thinking)"
        guard let settingsURL, fileManager.fileExists(atPath: settingsURL.path) else {
            settingsCache.withLock { $0 = nil }
            return defaultModel
        }

        try options.resourceGovernor?.checkpoint()
        options.metrics?.recordCandidate()
        options.metrics?.recordMetadataStat()

        let attributes = try? fileManager.attributesOfItem(atPath: settingsURL.path)
        let identity = ParserDiscoveredFile.capture(for: settingsURL, attributes: attributes)
        _ = options.fileDiscoveryTracker?.record(identity)

        if let cachedModel = settingsCache.withLock({ entry in
            entry.flatMap { $0.identity == identity ? $0.model : nil }
        }) {
            options.fileDiscoveryTracker?.recordAdmitted(identity)
            return cachedModel
        }

        func deferOversizedSettings() {
            options.resourceGovernor?.recordDeferredFile()
            options.metrics?.recordDeferred(.byteBudget)
            options.fileDiscoveryTracker?.recordDeferred(identity)
        }

        if let fileSize = identity.fileSizeBytes,
           fileSize > Int64(Self.maximumSettingsFileBytes) {
            deferOversizedSettings()
            return defaultModel
        }

        if let governor = options.resourceGovernor {
            guard let fileSize = identity.fileSizeBytes else {
                governor.recordDeferredFile()
                options.metrics?.recordDeferred(.metadataUnavailable)
                options.fileDiscoveryTracker?.recordDeferred(identity)
                return defaultModel
            }
            guard governor.admitFile(estimatedBytes: max(0, fileSize)) else {
                options.metrics?.recordDeferred(.byteBudget)
                options.fileDiscoveryTracker?.recordDeferred(identity)
                return defaultModel
            }
        }

        let data: Data
        do {
            let handle = try FileHandle(forReadingFrom: settingsURL)
            defer { try? handle.close() } // try?-ok(handle teardown)
            data = try handle.read(upToCount: Self.maximumSettingsFileBytes + 1) ?? Data()
        } catch {
            readGate.recordContentReadFailure(for: settingsURL)
            return defaultModel
        }
        options.metrics?.recordContentRead(bytes: Int64(data.count))

        guard data.count <= Self.maximumSettingsFileBytes else {
            deferOversizedSettings()
            return defaultModel
        }

        try options.resourceGovernor?.checkpoint()
        let settings = try? JSONDecoder().decode(SettingsFile.self, from: data)
        let model = settings?.model.flatMap { $0.isEmpty ? nil : $0 } ?? defaultModel
        settingsCache.withLock { $0 = SettingsCacheEntry(identity: identity, model: model) }
        options.fileDiscoveryTracker?.recordAdmitted(identity)
        return model
    }

    // MARK: - Session Parsing

    public func parseSession(
        transcriptFile: URL,
        sessionId: String,
        fallbackModel: String,
        includeConversationBodies: Bool = true
    ) throws -> (usage: TokenUsage?, conversation: ConversationRecord?)? {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: transcriptFile)
        } catch {
            throw SessionContentReadError(underlying: error)
        }
        defer { try? handle.close() } // try?-ok(handle teardown)
        do {
            _ = try handle.read(upToCount: 1)
            try handle.seek(toOffset: 0)
        } catch {
            throw SessionContentReadError(underlying: error)
        }

        let mtime = (try? fileManager.attributesOfItem(atPath: transcriptFile.path)[.modificationDate]) as? Date // try?-ok(mtime read, Date() fallback)

        var acc = AntigravitySessionAccumulator()

        // Active accumulators for step-wise turn-by-turn context calculation
        var currentSystemChars = 0
        var currentUserChars = 0
        var currentToolOutputChars = 0
        var currentAssistantVisibleChars = 0
        var currentToolCallArgChars = 0
        var currentUserMsgCount = 0
        var currentAssistantMsgCount = 0

        var lastProcessedInputChars = 0
        var lastProcessedAssistantChars = 0

        var calculatedInputTokens = 0
        var calculatedCacheReadTokens = 0
        var calculatedCacheCreationTokens = 0
        var calculatedOutputTokens = 0

        for line in handle.readAllUTF8Lines() {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { // try?-ok(per-line decode, skip malformed)
                continue
            }

            let source = json["source"] as? String ?? ""
            let type = json["type"] as? String ?? ""
            let content = json["content"] as? String ?? ""
            let thinking = json["thinking"] as? String ?? ""
            let toolCalls = json["tool_calls"] as? [[String: Any]] ?? []
            let createdAtStr = json["created_at"] as? String

            // Timestamps
            if let createdAtStr,
               let date = ThreadSafeISO8601DateFormatter.parse(createdAtStr) {
                if acc.startTime == nil { acc.startTime = date }
                acc.endTime = date
            }

            // Categorize content into proper token buckets
            if source == "USER_EXPLICIT" || type == "USER_INPUT" {
                // User content
                currentUserChars += content.count
                currentUserMsgCount += 1

                acc.userVisibleChars += content.count
                acc.userMessageCount += 1

                if !content.isEmpty {
                    if includeConversationBodies {
                        acc.userWords += wordCount(content)
                        if acc.firstUserText == nil {
                            // Strip metadata tags to get the actual user prompt for the title
                            let cleanedPrompt = stripMetadataTags(content)
                            if !cleanedPrompt.isEmpty {
                                acc.firstUserText = String(cleanedPrompt.prefix(120))
                            }
                        }
                        appendText(&acc.fullText, content, isAssistant: false)
                    }
                }

                // Extract per-session model from USER_SETTINGS_CHANGE metadata
                if acc.sessionModel == nil {
                    acc.sessionModel = extractModelFromSettingsChange(content)
                }

                // Extract workspace/project name from user_information
                if acc.extractedProjectName == nil {
                    acc.extractedProjectName = extractProjectName(from: content)
                }

            } else if source == "SYSTEM" || type == "CONVERSATION_HISTORY" || type == "SYSTEM_MESSAGE" {
                // System messages
                currentSystemChars += content.count
                acc.systemChars += content.count

            } else if source == "MODEL" && type == "PLANNER_RESPONSE" {
                // Model response step — represents a separate API turn call

                // 1. Preceding context acts as the input context for this turn
                let turnInputChars = currentSystemChars + currentUserChars + currentToolOutputChars + currentAssistantVisibleChars + currentToolCallArgChars

                // 2. Output components generated during this turn
                let turnAssistantVisibleChars = content.count
                let turnThinkingChars = thinking.count
                var turnToolCallArgChars = 0
                for toolCall in toolCalls {
                    if let args = toolCall["args"] as? [String: Any] {
                        for (_, value) in args {
                            turnToolCallArgChars += Self.stringLength(of: value)
                        }
                    }
                    // Extract tool names for keyTools
                    if includeConversationBodies,
                       let toolName = toolCall["name"] as? String, !toolName.isEmpty {
                        acc.toolNames.insert(toolName)
                    }
                }

                // 3. Estimate tokens for this turn (turn context window + new assistant response)
                let estimated = TokenExtractionUtility.estimateFallbackTokens(
                    userVisibleChars: turnInputChars,
                    assistantVisibleChars: turnAssistantVisibleChars + turnToolCallArgChars,
                    assistantReasoningChars: turnThinkingChars,
                    userMessageCount: currentUserMsgCount,
                    assistantMessageCount: currentAssistantMsgCount
                )

                if lastProcessedInputChars == 0 {
                    // Turn 1: Entire input context is brand-new / cache creation
                    calculatedCacheCreationTokens += estimated.input
                } else {
                    // Subsequent turns: The preceding turn's total context is cached.
                    let cachedChars = lastProcessedInputChars + lastProcessedAssistantChars
                    let cachedTokens = TokenExtractionUtility.estimatedTokenCount(for: cachedChars, charsPerToken: 3.35)

                    let cacheRead = min(cachedTokens, estimated.input)
                    let cacheCreation = max(estimated.input - cacheRead, 0)

                    calculatedCacheReadTokens += cacheRead
                    calculatedCacheCreationTokens += cacheCreation
                }

                calculatedOutputTokens += estimated.output
                lastProcessedInputChars = turnInputChars
                lastProcessedAssistantChars = turnAssistantVisibleChars + turnToolCallArgChars

                // 4. Update the active context state for subsequent turns
                currentAssistantVisibleChars += turnAssistantVisibleChars
                currentToolCallArgChars += turnToolCallArgChars
                currentAssistantMsgCount += 1

                // 5. Update overall session metadata
                if !content.isEmpty {
                    if includeConversationBodies {
                        acc.lastAssistantText = content
                        acc.assistantWords += wordCount(content)
                        appendText(&acc.fullText, content, isAssistant: true)
                    }
                    acc.assistantMessageCount += 1
                }
                if !thinking.isEmpty {
                    acc.thinkingChars += thinking.count
                }
                acc.assistantVisibleChars += turnAssistantVisibleChars
                acc.toolCallArgChars += turnToolCallArgChars
                acc.messageCount += 1

            } else if source == "MODEL" {
                // Tool outputs
                currentToolOutputChars += content.count
                acc.toolOutputChars += content.count

                // Extract file paths from VIEW_FILE results for keyFiles
                if includeConversationBodies, type == "VIEW_FILE" {
                    if let filePath = extractFilePath(from: content) {
                        acc.filePaths.insert(filePath)
                    }
                }
            }
        }

        // Fallback to single-turn estimation if no PLANNER_RESPONSE was processed
        var inputTokens: Int
        var cacheCreationTokens: Int = 0
        var cacheReadTokens: Int = 0
        let outputTokens: Int
        if calculatedCacheCreationTokens > 0 || calculatedCacheReadTokens > 0 || calculatedOutputTokens > 0 {
            // Accumulate trailing characters that occurred after the final response
            let finalInputChars = currentSystemChars + currentUserChars + currentToolOutputChars + currentAssistantVisibleChars + currentToolCallArgChars
            if finalInputChars > lastProcessedInputChars {
                let newChars = finalInputChars - lastProcessedInputChars
                let trailingTokens = TokenExtractionUtility.estimatedTokenCount(for: newChars, charsPerToken: 3.35)
                calculatedInputTokens += trailingTokens
            }
            inputTokens = calculatedCacheCreationTokens + calculatedCacheReadTokens + calculatedInputTokens
            cacheCreationTokens = calculatedCacheCreationTokens
            cacheReadTokens = calculatedCacheReadTokens
            outputTokens = calculatedOutputTokens
        } else {
            let totalInputChars = currentSystemChars + currentUserChars + currentToolOutputChars
            let totalOutputVisibleChars = currentAssistantVisibleChars + currentToolCallArgChars
            let totalReasoningChars = acc.thinkingChars

            guard totalInputChars > 0 || totalOutputVisibleChars > 0 || totalReasoningChars > 0 else {
                return nil
            }

            let estimated = TokenExtractionUtility.estimateFallbackTokens(
                userVisibleChars: totalInputChars,
                assistantVisibleChars: totalOutputVisibleChars,
                assistantReasoningChars: totalReasoningChars,
                userMessageCount: currentUserMsgCount,
                assistantMessageCount: currentAssistantMsgCount
            )
            inputTokens = estimated.input
            cacheCreationTokens = 0
            cacheReadTokens = 0
            outputTokens = estimated.output
        }

        let model = acc.sessionModel ?? fallbackModel
        let pricing = ModelPricing.lookup(model: model)
        let cost = try pricing.cost(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheCreationTokens: cacheCreationTokens,
            cacheReadTokens: cacheReadTokens
        )

        let projectName = acc.extractedProjectName ?? "Antigravity"
        let finalStartTime = acc.startTime ?? mtime ?? Date()
        let finalEndTime = acc.endTime ?? mtime ?? Date()

        let usage = TokenUsage(
            provider: .antigravity,
            sessionId: sessionId,
            projectName: projectName,
            model: model,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheCreationTokens: cacheCreationTokens,
            cacheReadTokens: cacheReadTokens,
            costUSD: cost,
            startTime: finalStartTime,
            endTime: finalEndTime,
            provenanceMethod: .heuristicEstimate,
            provenanceConfidence: .highConfidenceEstimate,
            estimatorVersion: TokenExtractionUtility.currentEstimatorVersion
        )

        guard includeConversationBodies else { return (usage, nil) }

        let sortedFiles = Array(acc.filePaths.sorted().prefix(20))
        let sortedTools = Array(acc.toolNames.sorted().prefix(20))

        let conversation = ConversationRecord(
            id: ConversationRecord.stableId(provider: .antigravity, sessionId: sessionId),
            provider: .antigravity,
            sessionId: sessionId,
            projectName: projectName,
            startTime: finalStartTime,
            endTime: finalEndTime,
            messageCount: acc.messageCount,
            userWordCount: acc.userWords,
            assistantWordCount: acc.assistantWords,
            keyFiles: sortedFiles,
            keyCommands: [],
            keyTools: sortedTools,
            inferredTaskTitle: acc.firstUserText ?? "Antigravity Session",
            lastAssistantMessage: acc.lastAssistantText,
            fullText: acc.fullText,
            indexedAt: Date(),
            fileModifiedAt: mtime,
            summary: nil
        )

        return (usage, conversation)
    }

    // MARK: - Metadata Extraction

    /// Extracts the model name from `<USER_SETTINGS_CHANGE>` XML embedded in USER_INPUT content.
    /// Example: "The user changed setting `Model Selection` from None to Claude Opus 4.6 (Thinking)."
    private func extractModelFromSettingsChange(_ content: String) -> String? {
        guard content.contains("Model Selection") else { return nil }

        // Pattern: "from <old> to <new>. No need to comment"
        // or: "from <old> to <new>."
        guard let range = content.range(of: "Model Selection` from ", options: .caseInsensitive) else {
            return nil
        }

        let afterPrefix = content[range.upperBound...]
        guard let toRange = afterPrefix.range(of: " to ", options: .caseInsensitive) else {
            return nil
        }

        let afterTo = afterPrefix[toRange.upperBound...]
        var candidate = String(afterTo)
        if let tagEndRange = candidate.range(of: "</") {
            candidate = String(candidate[..<tagEndRange.lowerBound])
        }
        if let dotSpaceRange = candidate.range(of: ". ") {
            candidate = String(candidate[..<dotSpaceRange.lowerBound])
        } else if let dotNewline = candidate.range(of: ".\n") {
            candidate = String(candidate[..<dotNewline.lowerBound])
        } else if candidate.hasSuffix(".") {
            candidate = String(candidate.dropLast())
        }

        let model = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.isEmpty ? nil : model
    }

    /// Extracts the workspace project name from `<user_information>` or workspace URI in content.
    private func extractProjectName(from content: String) -> String? {
        // Look for workspace URIs like "/Users/.../Documents/Windsurf/BurnBar"
        // Pattern: workspaces defined by URI, format [URI] -> [CorpusName]
        if let corpusMatch = extractCorpusName(from: content) {
            return corpusMatch
        }

        // Fallback: extract from workspace path
        if let pathMatch = extractWorkspacePath(from: content) {
            return URL(fileURLWithPath: pathMatch).lastPathComponent
        }

        return nil
    }

    /// Extracts CorpusName from "[URI] -> [CorpusName]" format in user_information.
    private func extractCorpusName(from content: String) -> String? {
        // Look for pattern: /path/to/project -> Org/RepoName
        guard content.contains("->") else { return nil }

        let lines = content.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.contains("->") else { continue }
            let parts = trimmed.components(separatedBy: "->")
            guard parts.count == 2 else { continue }
            let corpus = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if !corpus.isEmpty && corpus.contains("/") {
                return corpus
            }
        }
        return nil
    }

    /// Extracts a workspace path from the content.
    private func extractWorkspacePath(from content: String) -> String? {
        // Look for: "active workspaces" section containing a file path
        guard content.contains("active workspace") || content.contains("Workspace") else { return nil }

        // Find lines containing absolute paths
        let lines = content.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("/Users/") || trimmed.hasPrefix("/home/") {
                // Extract just the path part (before any " -> " or other markers)
                let path = trimmed.components(separatedBy: " -> ").first?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? trimmed
                if !path.isEmpty {
                    return path
                }
            }
        }
        return nil
    }

    /// Strips `<tag>...</tag>` metadata blocks from user input to extract the actual user prompt.
    private func stripMetadataTags(_ content: String) -> String {
        var result = content

        // Remove common metadata tags
        let tagPatterns = [
            "USER_REQUEST", "ADDITIONAL_METADATA", "USER_SETTINGS_CHANGE",
            "user_information", "user_rules", "skills", "subagents",
            "slash_commands", "artifacts", "RULE\\[.*?\\]"
        ]

        for tag in tagPatterns {
            // Use simple string matching for exact tags, regex for patterns
            if tag.contains("\\") {
                // Regex pattern — skip for simplicity, these are rare in the title
                continue
            }
            // Remove <tag>...</tag> blocks
            while let openRange = result.range(of: "<\(tag)>", options: .caseInsensitive) {
                if let closeRange = result.range(of: "</\(tag)>", options: .caseInsensitive, range: openRange.upperBound..<result.endIndex) {
                    result.removeSubrange(openRange.lowerBound..<closeRange.upperBound)
                } else {
                    // No closing tag — remove from open tag to end
                    result.removeSubrange(openRange.lowerBound..<result.endIndex)
                }
            }
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Helpers

    /// Extracts file path from VIEW_FILE output like "File Path: `file:///path/to/file`"
    private func extractFilePath(from content: String) -> String? {
        guard let range = content.range(of: "File Path: `file:///") else { return nil }
        let afterPrefix = content[range.upperBound...]
        guard let endTick = afterPrefix.firstIndex(of: "`") else { return nil }
        let path = "/" + String(afterPrefix[..<endTick])
        // Return just the basename for keyFiles
        return URL(fileURLWithPath: path).lastPathComponent
    }

    /// Measures the string length of an arbitrary JSON value for tool call argument sizing.
    public static func stringLength(of value: Any) -> Int {
        switch value {
        case let str as String:
            return str.count
        case let array as [Any]:
            return array.reduce(0) { $0 + stringLength(of: $1) }
        case let dict as [String: Any]:
            return dict.reduce(0) { $0 + $1.key.count + stringLength(of: $1.value) }
        case let number as NSNumber:
            return "\(number)".count
        default:
            return 0
        }
    }

    private func appendText(_ full: inout String, _ chunk: String, isAssistant: Bool) {
        if !full.isEmpty { full += "\n\n" }
        full += SessionLogMarkdownFormatter.transcriptTurnMarkdown(isAssistant: isAssistant, body: chunk)
    }

    private func wordCount(_ s: String) -> Int {
        s.split { $0.isWhitespace || $0.isNewline }.filter { !$0.isEmpty }.count
    }
}

// MARK: - Session Accumulator

/// Accumulates content metrics across all transcript lines for a single Antigravity session.
private struct AntigravitySessionAccumulator {
    // Input token sources
    var userVisibleChars = 0
    var systemChars = 0
    var toolOutputChars = 0

    // Output token sources
    var assistantVisibleChars = 0
    var thinkingChars = 0
    var toolCallArgChars = 0

    // Conversation metadata
    var userWords = 0
    var assistantWords = 0
    var userMessageCount = 0
    var assistantMessageCount = 0
    var messageCount = 0
    var startTime: Date?
    var endTime: Date?
    var fullText = ""
    var firstUserText: String?
    var lastAssistantText = ""

    // Extracted metadata
    var sessionModel: String?
    var extractedProjectName: String?

    // Key files/tools for conversation record
    var filePaths: Set<String> = []
    var toolNames: Set<String> = []
}
