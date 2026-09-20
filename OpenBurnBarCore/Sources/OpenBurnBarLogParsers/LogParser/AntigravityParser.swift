import Foundation
import OpenBurnBarKernel

// MARK: - Antigravity Parser

/// Parses Antigravity CLI sessions from ~/.gemini/antigravity-cli/brain/<conversationId>/.system_generated/logs/transcript.jsonl
///
/// Token estimation counts unique content once (not per growing turn):
///   - **Input tokens**: user content + system messages + tool output
///   - **Output tokens**: assistant visible text + thinking/reasoning + tool call arguments
///   - CONVERSATION_HISTORY is the largest snapshot once; CHECKPOINT and
///     self-transcript views are skipped so a long Flash session cannot
///     invent tens of billions of tokens.
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
            schemaVersion: Self.parserCacheSchemaVersion,
            logLabel: "AntigravityParser"
        )
    }

    /// Bump when token/model identity changes so idle-cache rows cannot keep
    /// a ghost Opus total next to a later Gemini row for the same session.
    static let parserCacheSchemaVersion = 2

    /// Live Antigravity CLI default when `settings.json` has no `model` key.
    /// Alberto's machines pin Gemini 3.8 Flash (High); the previous Opus
    /// hardcoded default is what made Charts invent a second model.
    public static let defaultFallbackModel = "Gemini 3.8 Flash (High)"

    public var lastSessionScanCount: Int { sessionScanCount.read() }
    public var lastSessionCacheHitCount: Int { sessionCacheHitCount.read() }

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

    public func parse() async throws -> ParseResult {
        try await parse(options: .default)
    }

    public func parse(options: LogParseOptions) async throws -> ParseResult {
        sessionScanCount.write(0)
        sessionCacheHitCount.write(0)
        let gate = ParserFileReadGate(options: options, fileManager: fileManager)
        let basePath = ((logDirectoryOverride ?? "~/.gemini/antigravity-cli") as NSString).expandingTildeInPath
        let brainPath = (basePath as NSString).appendingPathComponent("brain")

        guard fileManager.fileExists(atPath: brainPath) else {
            return ParseResult(usages: [], conversations: [])
        }

        let settingsURL = URL(fileURLWithPath: basePath).appendingPathComponent("settings.json")
        let fallbackModelName = try configuredFallbackModel(
            at: settingsURL,
            options: options,
            fileManager: fileManager,
            readGate: gate
        )

        var usages: [TokenUsage] = []
        var conversations: [ConversationRecord] = []
        var sessionIDsToReplace = Set<String>()
        var parseCache = cacheStore.load()
        var activePaths = Set<String>()
        var cacheMutated = false
        defer {
            if cacheMutated {
                cacheStore.persist(parseCache)
            }
        }

        let brainURL = URL(fileURLWithPath: brainPath)
        let conversationDirs = (try? fileManager.contentsOfDirectory(at: brainURL, includingPropertiesForKeys: [.isDirectoryKey]))?.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        } ?? []

        for conversationDir in conversationDirs {
            let sessionId = conversationDir.lastPathComponent
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
                // Drop any prior (provider, sessionId, old-model) row before
                // insert. Upsert identity includes `model`, so a
                // fallback→extracted flip otherwise leaves both Opus and
                // Gemini billed for the same session.
                sessionIDsToReplace.insert(sessionId)
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
                        sessionIDsToReplace.insert(sessionId)
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

        let stalePaths = Set(parseCache.fileEntries.keys).subtracting(activePaths)
        if !stalePaths.isEmpty {
            for stalePath in stalePaths {
                parseCache.fileEntries.removeValue(forKey: stalePath)
            }
            cacheMutated = true
        }

        return ParseResult(
            usages: usages,
            conversations: conversations,
            usageSessionIDsToDelete: sessionIDsToReplace.sorted()
        )
    }

    private func configuredFallbackModel(
        at settingsURL: URL,
        options: LogParseOptions,
        fileManager: FileManager,
        readGate: ParserFileReadGate
    ) throws -> String {
        let defaultModel = Self.defaultFallbackModel
        guard fileManager.fileExists(atPath: settingsURL.path) else {
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

            // Unique content once. Replaying history on every PLANNER_RESPONSE
            // (and folding those cache buckets back into inputTokens) is what
            // turned a day's Gemini Flash work into tens of billions of tokens.
            if source == "USER_EXPLICIT" || type == "USER_INPUT" {
                acc.userVisibleChars += content.count
                acc.userMessageCount += 1

                if !content.isEmpty {
                    if includeConversationBodies {
                        acc.userWords += wordCount(content)
                        if acc.firstUserText == nil {
                            let cleanedPrompt = stripMetadataTags(content)
                            if !cleanedPrompt.isEmpty {
                                acc.firstUserText = String(cleanedPrompt.prefix(120))
                            }
                        }
                        appendText(&acc.fullText, content, isAssistant: false)
                    }
                }

                if let changed = extractModelFromSettingsChange(content) {
                    acc.sessionModel = changed
                }
                // Last explicit signal wins — a later `agy --model` must
                // override an earlier leftover Opus settings change.
                if let cliModel = extractCLIModel(from: content) {
                    acc.sessionModel = cliModel
                }
                if acc.extractedProjectName == nil {
                    acc.extractedProjectName = extractProjectName(from: content)
                }

            } else if type == "CHECKPOINT" {
                continue
            } else if type == "CONVERSATION_HISTORY" {
                // One snapshot, not a running sum — re-emitted history is
                // the same window growing, not new unique input.
                acc.historySnapshotChars = max(acc.historySnapshotChars, content.count)
            } else if source == "SYSTEM" || type == "SYSTEM_MESSAGE" {
                acc.systemChars += content.count

            } else if source == "MODEL" && type == "PLANNER_RESPONSE" {
                let turnAssistantVisibleChars = content.count
                var turnToolCallArgChars = 0
                for toolCall in toolCalls {
                    if let args = toolCall["args"] as? [String: Any] {
                        for (_, value) in args {
                            turnToolCallArgChars += Self.stringLength(of: value)
                        }
                    }
                    if includeConversationBodies,
                       let toolName = toolCall["name"] as? String, !toolName.isEmpty {
                        acc.toolNames.insert(toolName)
                    }
                }

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
                if !Self.isSelfTranscriptToolOutput(content) {
                    acc.toolOutputChars += content.count
                }
                if includeConversationBodies, type == "VIEW_FILE" {
                    if let filePath = extractFilePath(from: content) {
                        acc.filePaths.insert(filePath)
                    }
                }
            }
        }

        let totalInputChars = acc.systemChars + acc.userVisibleChars + acc.toolOutputChars + acc.historySnapshotChars
        let totalOutputVisibleChars = acc.assistantVisibleChars + acc.toolCallArgChars
        let totalReasoningChars = acc.thinkingChars

        guard totalInputChars > 0 || totalOutputVisibleChars > 0 || totalReasoningChars > 0 else {
            return nil
        }

        let estimated = TokenExtractionUtility.estimateFallbackTokens(
            userVisibleChars: totalInputChars,
            assistantVisibleChars: totalOutputVisibleChars,
            assistantReasoningChars: totalReasoningChars,
            userMessageCount: acc.userMessageCount,
            assistantMessageCount: acc.assistantMessageCount
        )
        let inputTokens = estimated.input
        let outputTokens = estimated.output
        let cacheCreationTokens = 0
        let cacheReadTokens = 0

        let model = Self.canonicalizeModelName(acc.sessionModel ?? fallbackModel)
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

    /// Last `Model Selection` change in the block. First-wins pinned sessions
    /// that later switched to Gemini Flash to the leftover Opus label.
    private func extractModelFromSettingsChange(_ content: String) -> String? {
        guard content.localizedCaseInsensitiveContains("Model Selection") else { return nil }

        var searchStart = content.startIndex
        var lastModel: String?
        while let range = content.range(
            of: "Model Selection` from ",
            options: .caseInsensitive,
            range: searchStart..<content.endIndex
        ) {
            let afterPrefix = content[range.upperBound...]
            guard let toRange = afterPrefix.range(of: " to ", options: .caseInsensitive) else {
                searchStart = range.upperBound
                continue
            }

            let afterTo = afterPrefix[toRange.upperBound...]
            let modelEnd: String.Index
            if let dotSpaceRange = afterTo.range(of: ". ") {
                modelEnd = dotSpaceRange.lowerBound
            } else if let dotNewline = afterTo.range(of: ".\n") {
                modelEnd = dotNewline.lowerBound
            } else if afterTo.hasSuffix(".") {
                modelEnd = afterTo.index(before: afterTo.endIndex)
            } else {
                modelEnd = afterTo.endIndex
            }

            let model = String(afterTo[..<modelEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !model.isEmpty {
                lastModel = model
            }
            searchStart = range.upperBound
        }
        return lastModel
    }

    /// `agy --model gemini-3.8-flash-high` in the user prompt (CLI override).
    /// Ignores other tools' `--model` flags (muse-spark, `--model pin`, …)
    /// that show up in pasted docs.
    private func extractCLIModel(from content: String) -> String? {
        guard let regex = Self.cliModelRegex else { return nil }
        let ns = content as NSString
        let matches = regex.matches(in: content, range: NSRange(location: 0, length: ns.length))
        guard let match = matches.last, match.numberOfRanges >= 2 else { return nil }
        let raw = ns.substring(with: match.range(at: 1))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? nil : Self.canonicalizeModelName(raw)
    }

    private static let cliModelRegex = try? NSRegularExpression(
        pattern: #"(?:^|[^\w-])agy\b[^\n]*?--model(?:\s+|=)((?:gemini|claude|gpt-oss)[A-Za-z0-9._:-]*)"#
    )

    /// Map CLI ids (`gemini-3.8-flash-high`) onto the Antigravity display names
    /// Charts already shows. Unknown strings pass through trimmed.
    public static func canonicalizeModelName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        let key = trimmed.lowercased().replacingOccurrences(of: "_", with: "-")
        switch key {
        case "gemini-3.8-flash-high", "gemini-3.8-flash":
            return "Gemini 3.8 Flash (High)"
        case "gemini-3.8-flash-medium":
            return "Gemini 3.8 Flash (Medium)"
        case "gemini-3.7-flash-high":
            return "Gemini 3.7 Flash (High)"
        case "gemini-3.7-flash-medium":
            return "Gemini 3.7 Flash (Medium)"
        case "gemini-3.5-flash-high":
            return "Gemini 3.5 Flash (High)"
        case "gemini-3.5-flash-medium":
            return "Gemini 3.5 Flash (Medium)"
        case "claude-opus-4.6", "claude-opus-4-6", "claude-opus-4.6-thinking":
            return "Claude Opus 4.6 (Thinking)"
        case "claude-sonnet-4.6", "claude-sonnet-4-6", "claude-sonnet-4.6-thinking":
            return "Claude Sonnet 4.6 (Thinking)"
        default:
            return trimmed
        }
    }

    /// VIEW_FILE of this session's own transcript.jsonl — counting it as tool
    /// output re-ingests the growing log on every later turn.
    public static func isSelfTranscriptToolOutput(_ content: String) -> Bool {
        content.contains("/.system_generated/logs/transcript")
            && (content.contains("transcript.jsonl") || content.contains("transcript_full.jsonl"))
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
    var historySnapshotChars = 0
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
