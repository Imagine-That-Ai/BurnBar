import Foundation
import OpenBurnBarKernel
import OpenBurnBarParserSupport

// MARK: - Cursor Agent Parser

/// Parses Cursor Agent CLI sessions from `~/.cursor-agent/sessions/`.
///
/// Supports dual session logging schemas:
///   1. **Nested directories**: `~/.cursor-agent/sessions/<session-id>/` containing
///      `transcript.jsonl` (or `chat_history.jsonl`) and optional `summary.json` (similar to Grok Build / Antigravity).
///   2. **Flat files**: `~/.cursor-agent/sessions/<session-id>.jsonl` (similar to Pi Agent).
///
/// Computes accurate, fine-grained token counts:
///   - **Input tokens**: User prompts + system prompts + tool output returns (context size).
///   - **Output tokens**: Assistant text + thinking/reasoning blocks + tool call arguments.
/// Idle usage ticks resume unchanged transcripts from a mtime+size disk cache
/// (token totals only — never conversation bodies). Nested `summary.json`
/// participates in the signature so a sidecar model/title change busts the hit.
public final class CursorAgentParser: LogParser, Sendable {
    public let provider: AgentProvider = .cursorAgent
    let logDirectoryOverride: String?
    private let fileManager: FileManager
    private let cacheStore: ParserDiskCacheStore<CachedUsageEntry<CompositeFileSignature<FileSignature>>>
    private let sessionScanCount = Locked(0)
    private let sessionCacheHitCount = Locked(0)

    public init(
        logDirectoryOverride: String? = nil,
        fileManager: FileManager = .default,
        appPaths: OpenBurnBarAppPaths = .live()
    ) {
        self.logDirectoryOverride = logDirectoryOverride
        self.fileManager = fileManager
        let cacheURL: URL
        if let override = logDirectoryOverride {
            cacheURL = URL(fileURLWithPath: override).appendingPathComponent(".obb-cursor-agent-parser-cache.plist")
        } else {
            cacheURL = appPaths.cursorAgentParserCacheURL
        }
        self.cacheStore = ParserDiskCacheStore(
            cacheURL: cacheURL,
            fileManager: fileManager,
            schemaVersion: 1,
            logLabel: "CursorAgentParser"
        )
    }

    var lastSessionScanCount: Int { sessionScanCount.read() }
    var lastSessionCacheHitCount: Int { sessionCacheHitCount.read() }

    struct SettingsFile: Decodable {
        let model: String?
    }

    public func parse() async throws -> ParseResult {
        try parseSynchronously(options: .default)
    }

    public func parse(options: LogParseOptions) async throws -> ParseResult {
        try parseSynchronously(options: options)
    }

    public func parseSynchronously(options: LogParseOptions = .default) throws -> ParseResult {
        sessionScanCount.write(0)
        sessionCacheHitCount.write(0)
        let gate = ParserFileReadGate(options: options, fileManager: fileManager)
        let sessionsRoot = logDirectoryOverride ?? NSString(string: provider.logDirectory).expandingTildeInPath

        guard fileManager.fileExists(atPath: sessionsRoot) else {
            return ParseResult(usages: [], conversations: [])
        }

        var usages: [TokenUsage] = []
        var conversations: [ConversationRecord] = []
        var parseCache = cacheStore.load()
        var activePaths = Set<String>()
        var cacheMutated = false
        defer {
            if cacheMutated {
                cacheStore.persist(parseCache)
            }
        }

        let sessionsURL = URL(fileURLWithPath: sessionsRoot)
        let contents = (try? fileManager.contentsOfDirectory(at: sessionsURL, includingPropertiesForKeys: [.isDirectoryKey])) ?? []

        for item in contents {
            let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true

            if isDirectory {
                let sessionId = item.lastPathComponent
                let transcriptJSONL = item.appendingPathComponent("transcript.jsonl")
                let chatHistoryJSONL = item.appendingPathComponent("chat_history.jsonl")
                let historyJSONL = item.appendingPathComponent("history.jsonl")

                let transcriptFile = fileManager.fileExists(atPath: transcriptJSONL.path) ? transcriptJSONL :
                                    (fileManager.fileExists(atPath: chatHistoryJSONL.path) ? chatHistoryJSONL :
                                    (fileManager.fileExists(atPath: historyJSONL.path) ? historyJSONL : nil))

                guard let file = transcriptFile else { continue }
                let summaryURL = item.appendingPathComponent("summary.json")
                var sessionFiles = [file]
                let hasSummary = fileManager.fileExists(atPath: summaryURL.path)
                if hasSummary {
                    sessionFiles.append(summaryURL)
                }
                let cacheKey = file.standardizedFileURL.path
                activePaths.insert(cacheKey)
                guard try gate.shouldRead(sessionFiles) else { continue }

                if try appendCachedOrParsed(
                    file: file,
                    sessionId: sessionId,
                    summaryURL: hasSummary ? summaryURL : nil,
                    options: options,
                    parseCache: &parseCache,
                    cacheKey: cacheKey,
                    cacheMutated: &cacheMutated,
                    usages: &usages,
                    conversations: &conversations
                ) {
                    continue
                }
            } else if item.pathExtension == "jsonl" {
                let cacheKey = item.standardizedFileURL.path
                activePaths.insert(cacheKey)
                guard try gate.shouldRead(item) else { continue }
                let sessionId = item.deletingPathExtension().lastPathComponent
                _ = try appendCachedOrParsed(
                    file: item,
                    sessionId: sessionId,
                    summaryURL: nil,
                    options: options,
                    parseCache: &parseCache,
                    cacheKey: cacheKey,
                    cacheMutated: &cacheMutated,
                    usages: &usages,
                    conversations: &conversations
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

        return ParseResult(usages: usages, conversations: conversations)
    }

    private func appendCachedOrParsed(
        file: URL,
        sessionId: String,
        summaryURL: URL?,
        options: LogParseOptions,
        parseCache: inout ParserDiskCache<CachedUsageEntry<CompositeFileSignature<FileSignature>>>,
        cacheKey: String,
        cacheMutated: inout Bool,
        usages: inout [TokenUsage],
        conversations: inout [ConversationRecord]
    ) throws -> Bool {
        let signature = sessionSignature(transcript: file, summaryURL: summaryURL)
        if !options.includeConversationBodies,
           let signature,
           let cached = parseCache.fileEntries[cacheKey],
           cached.signature == signature {
            sessionCacheHitCount.withLock { $0 += 1 }
            usages.append(cached.totals.makeUsage(provider: .cursorAgent, sessionId: sessionId))
            return true
        }

        sessionScanCount.withLock { $0 += 1 }
        if let pair = try parseSession(
            file: file,
            sessionId: sessionId,
            summaryURL: summaryURL,
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
        return true
    }

    private func sessionSignature(
        transcript: URL,
        summaryURL: URL?
    ) -> CompositeFileSignature<FileSignature>? {
        guard let primary = FileSignature(for: transcript, using: fileManager) else { return nil }
        let settings = summaryURL.flatMap { FileSignature(for: $0, using: fileManager) }
        if summaryURL != nil, settings == nil { return nil }
        return CompositeFileSignature(primary: primary, settings: settings)
    }

    // MARK: - Session Parsing

    private func parseSession(
        file: URL,
        sessionId: String,
        summaryURL: URL?,
        includeConversationBodies: Bool
    ) throws -> (usage: TokenUsage?, conversation: ConversationRecord?)? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil } // try?-ok(open fail skip session)
        defer { try? handle.close() } // try?-ok(handle teardown)

        let mtime = (try? fileManager.attributesOfItem(atPath: file.path)[.modificationDate]) as? Date // try?-ok(mtime fallback Date)

        // Optional metadata from summary.json
        var summaryModel: String?
        var summaryTitle: String?
        var summaryProject: String?
        var summaryCwd: String?

        if let summaryURL,
           fileManager.fileExists(atPath: summaryURL.path),
           let data = try? Data(contentsOf: summaryURL), // try?-ok(optional sidecar read)
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { // try?-ok(optional summary decode)
            summaryModel = json["model"] as? String ?? (json["current_model_id"] as? String)
            summaryTitle = json["title"] as? String ?? (json["generated_title"] as? String) ?? (json["session_summary"] as? String)
            summaryProject = json["projectName"] as? String ?? (json["project"] as? String)

            if let info = json["info"] as? [String: Any] {
                if summaryModel == nil { summaryModel = info["model"] as? String }
                if summaryTitle == nil { summaryTitle = info["title"] as? String }
                summaryCwd = info["cwd"] as? String
            }
        }

        var acc = CursorAgentSessionAccumulator()

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
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { // try?-ok(malformed line skip)
                continue
            }

            let role = (json["role"] as? String ?? json["source"] as? String ?? "").lowercased()
            let type = json["type"] as? String ?? ""
            let content = json["content"] as? String ?? json["message"] as? String ?? ""
            let thinking = json["thinking"] as? String ?? json["reasoning"] as? String ?? ""
            let toolCalls = json["tool_calls"] as? [[String: Any]] ?? json["toolCalls"] as? [[String: Any]] ?? []
            let timestampStr = json["timestamp"] as? String ?? json["created_at"] as? String

            if let timestampStr,
               let date = ThreadSafeISO8601DateFormatter.parse(timestampStr) {
                if acc.startTime == nil { acc.startTime = date }
                acc.endTime = date
            }

            // Categorize content
            if role == "user" || type == "USER_INPUT" {
                currentUserChars += content.count
                currentUserMsgCount += 1

                acc.userVisibleChars += content.count
                acc.userMessageCount += 1

                if !content.isEmpty {
                    if includeConversationBodies {
                        acc.userWords += wordCount(content)
                        if acc.firstUserText == nil {
                            let cleaned = stripMetadataTags(content)
                            if !cleaned.isEmpty {
                                acc.firstUserText = String(cleaned.prefix(120))
                            }
                        }
                        appendText(&acc.fullText, content, isAssistant: false)
                    }
                }

                if acc.sessionModel == nil {
                    acc.sessionModel = extractModelFromSettingsChange(content)
                }
                if acc.extractedProjectName == nil {
                    acc.extractedProjectName = extractProjectName(from: content)
                }
            } else if role == "system" || type == "CONVERSATION_HISTORY" || type == "SYSTEM_MESSAGE" {
                currentSystemChars += content.count
                acc.systemChars += content.count
            } else if role == "assistant" || type == "PLANNER_RESPONSE" {
                let turnInputChars = currentSystemChars + currentUserChars + currentToolOutputChars + currentAssistantVisibleChars + currentToolCallArgChars
                let turnAssistantVisibleChars = content.count
                let turnThinkingChars = thinking.count
                var turnToolCallArgChars = 0

                for toolCall in toolCalls {
                    if let args = toolCall["args"] as? [String: Any] {
                        for (_, val) in args {
                            turnToolCallArgChars += Self.stringLength(of: val)
                        }
                    }
                    if let toolName = toolCall["name"] as? String,
                       includeConversationBodies,
                       !toolName.isEmpty {
                        acc.toolNames.insert(toolName)
                    }
                }

                let estimated = TokenExtractionUtility.estimateFallbackTokens(
                    userVisibleChars: turnInputChars,
                    assistantVisibleChars: turnAssistantVisibleChars + turnToolCallArgChars,
                    assistantReasoningChars: turnThinkingChars,
                    userMessageCount: currentUserMsgCount,
                    assistantMessageCount: currentAssistantMsgCount
                )

                if lastProcessedInputChars == 0 {
                    calculatedCacheCreationTokens += estimated.input
                } else {
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

                currentAssistantVisibleChars += turnAssistantVisibleChars
                currentToolCallArgChars += turnToolCallArgChars
                currentAssistantMsgCount += 1

                if !content.isEmpty {
                    if includeConversationBodies {
                        acc.lastAssistantText = content
                        acc.assistantMessageCount += 1
                        acc.assistantWords += wordCount(content)
                        appendText(&acc.fullText, content, isAssistant: true)
                    }
                }
                if !thinking.isEmpty {
                    acc.thinkingChars += thinking.count
                }
                acc.assistantVisibleChars += turnAssistantVisibleChars
                acc.toolCallArgChars += turnToolCallArgChars
                acc.messageCount += 1
            } else if role == "tool" || type == "TOOL_OUTPUT" || role == "model" {
                currentToolOutputChars += content.count
                acc.toolOutputChars += content.count

                if includeConversationBodies,
                   type == "VIEW_FILE" || content.contains("File Path: `file:///") {
                    if let path = extractFilePath(from: content) {
                        acc.filePaths.insert(path)
                    }
                }
            }
        }

        var inputTokens: Int
        var cacheCreationTokens = 0
        var cacheReadTokens = 0
        let outputTokens: Int

        if calculatedCacheCreationTokens > 0 || calculatedCacheReadTokens > 0 || calculatedOutputTokens > 0 {
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
            outputTokens = estimated.output
        }

        let model = summaryModel ?? acc.sessionModel ?? "cursor-agent-pro"
        let pricing = ModelPricing.lookup(model: model)
        let cost = try pricing.cost(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheCreationTokens: cacheCreationTokens,
            cacheReadTokens: cacheReadTokens
        )

        let resolvedProject = summaryProject ?? acc.extractedProjectName ?? summaryCwd.flatMap { URL(fileURLWithPath: $0).lastPathComponent } ?? "Cursor Agent"
        let finalStartTime = acc.startTime ?? mtime ?? Date()
        let finalEndTime = acc.endTime ?? mtime ?? Date()

        let usage = TokenUsage(
            provider: .cursorAgent,
            sessionId: sessionId,
            projectName: resolvedProject,
            model: model,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheCreationTokens: cacheCreationTokens,
            cacheReadTokens: cacheReadTokens,
            costUSD: cost,
            startTime: finalStartTime,
            endTime: finalEndTime,
            provenanceMethod: .providerLog,
            provenanceConfidence: .exact,
            estimatorVersion: ""
        )

        guard includeConversationBodies else {
            return (usage, nil)
        }

        let sortedFiles = Array(acc.filePaths.sorted().prefix(20))
        let sortedTools = Array(acc.toolNames.sorted().prefix(20))

        let conversation = ConversationRecord(
            id: ConversationRecord.stableId(provider: .cursorAgent, sessionId: sessionId),
            provider: .cursorAgent,
            sessionId: sessionId,
            projectName: resolvedProject,
            startTime: finalStartTime,
            endTime: finalEndTime,
            messageCount: acc.messageCount,
            userWordCount: acc.userWords,
            assistantWordCount: acc.assistantWords,
            keyFiles: sortedFiles,
            keyCommands: [],
            keyTools: sortedTools,
            inferredTaskTitle: summaryTitle ?? acc.firstUserText ?? "Cursor Agent Session",
            lastAssistantMessage: acc.lastAssistantText,
            fullText: acc.fullText,
            indexedAt: Date(),
            fileModifiedAt: mtime,
            summary: summaryTitle
        )

        return (usage, conversation)
    }

    // MARK: - Metadata Extraction Helpers

    private func extractModelFromSettingsChange(_ content: String) -> String? {
        guard content.contains("Model Selection") else { return nil }
        guard let range = content.range(of: "Model Selection` from ", options: .caseInsensitive) else { return nil }
        let tail = content[range.upperBound...]
        guard let toRange = tail.range(of: " to ", options: .caseInsensitive) else { return nil }
        let modelString = tail[toRange.upperBound...]

        let endIdx: String.Index
        if let dotSpace = modelString.range(of: ". ") {
            endIdx = dotSpace.lowerBound
        } else if let dotNewline = modelString.range(of: ".\n") {
            endIdx = dotNewline.lowerBound
        } else if modelString.hasSuffix(".") {
            endIdx = modelString.index(before: modelString.endIndex)
        } else {
            endIdx = modelString.endIndex
        }

        let model = String(modelString[..<endIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
        return model.isEmpty ? nil : model
    }

    private func extractProjectName(from content: String) -> String? {
        if let match = extractCorpusName(from: content) {
            return match
        }
        if let match = extractWorkspacePath(from: content) {
            return URL(fileURLWithPath: match).lastPathComponent
        }
        return nil
    }

    private func extractCorpusName(from content: String) -> String? {
        guard content.contains("->") else { return nil }
        let lines = content.components(separatedBy: .newlines)
        for line in lines {
            let tr = line.trimmingCharacters(in: .whitespaces)
            guard tr.contains("->") else { continue }
            let parts = tr.components(separatedBy: "->")
            guard parts.count == 2 else { continue }
            let corpus = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if !corpus.isEmpty && corpus.contains("/") {
                return corpus
            }
        }
        return nil
    }

    private func extractWorkspacePath(from content: String) -> String? {
        guard content.contains("active workspace") || content.contains("Workspace") else { return nil }
        let lines = content.components(separatedBy: .newlines)
        for line in lines {
            let tr = line.trimmingCharacters(in: .whitespaces)
            if tr.hasPrefix("/Users/") || tr.hasPrefix("/home/") {
                let path = tr.components(separatedBy: " -> ").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? tr
                if !path.isEmpty { return path }
            }
        }
        return nil
    }

    private func stripMetadataTags(_ content: String) -> String {
        var res = content
        let tags = [
            "USER_REQUEST", "ADDITIONAL_METADATA", "USER_SETTINGS_CHANGE",
            "user_information", "user_rules", "skills", "subagents",
            "slash_commands", "artifacts", "RULE\\[.*?\\]"
        ]
        for tag in tags {
            while let openRange = res.range(of: "<\(tag)>", options: .caseInsensitive) {
                if let closeRange = res.range(of: "</\(tag)>", options: .caseInsensitive, range: openRange.upperBound..<res.endIndex) {
                    res.removeSubrange(openRange.lowerBound..<closeRange.upperBound)
                } else {
                    res.removeSubrange(openRange.lowerBound..<res.endIndex)
                }
            }
        }
        return res.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractFilePath(from content: String) -> String? {
        guard let range = content.range(of: "File Path: `file:///") else { return nil }
        let after = content[range.upperBound...]
        guard let endTick = after.firstIndex(of: "`") else { return nil }
        let path = "/" + String(after[..<endTick])
        return URL(fileURLWithPath: path).lastPathComponent
    }

    static func stringLength(of value: Any) -> Int {
        switch value {
        case let str as String:
            return str.count
        case let arr as [Any]:
            return arr.reduce(0) { $0 + stringLength(of: $1) }
        case let dict as [String: Any]:
            return dict.reduce(0) { $0 + $1.key.count + stringLength(of: $1.value) }
        case let num as NSNumber:
            return "\(num)".count
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

private struct CursorAgentSessionAccumulator {
    var userVisibleChars = 0
    var systemChars = 0
    var toolOutputChars = 0
    var assistantVisibleChars = 0
    var thinkingChars = 0
    var toolCallArgChars = 0

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

    var sessionModel: String?
    var extractedProjectName: String?

    var filePaths: Set<String> = []
    var toolNames: Set<String> = []
}
