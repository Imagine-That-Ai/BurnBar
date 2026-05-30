import Foundation
import OpenBurnBarCore

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
final class CursorAgentParser: LogParser, Sendable {
    let provider: AgentProvider = .cursorAgent
    let logDirectoryOverride: String?

    init(logDirectoryOverride: String? = nil) {
        self.logDirectoryOverride = logDirectoryOverride
    }

    struct SettingsFile: Decodable {
        let model: String?
    }

    func parse() async throws -> ParseResult {
        let fm = FileManager.default
        let sessionsRoot = logDirectoryOverride ?? NSString(string: provider.logDirectory).expandingTildeInPath

        guard fm.fileExists(atPath: sessionsRoot) else {
            return ParseResult(usages: [], conversations: [])
        }

        var usages: [TokenUsage] = []
        var conversations: [ConversationRecord] = []

        let sessionsURL = URL(fileURLWithPath: sessionsRoot)
        let contents = (try? fm.contentsOfDirectory(at: sessionsURL, includingPropertiesForKeys: [.isDirectoryKey])) ?? []

        for item in contents {
            let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            
            if isDirectory {
                // Scenario 1: Nested Directory Mode
                let sessionId = item.lastPathComponent
                let transcriptJSONL = item.appendingPathComponent("transcript.jsonl")
                let chatHistoryJSONL = item.appendingPathComponent("chat_history.jsonl")
                let historyJSONL = item.appendingPathComponent("history.jsonl")
                
                let transcriptFile = fm.fileExists(atPath: transcriptJSONL.path) ? transcriptJSONL :
                                    (fm.fileExists(atPath: chatHistoryJSONL.path) ? chatHistoryJSONL :
                                    (fm.fileExists(atPath: historyJSONL.path) ? historyJSONL : nil))
                
                guard let file = transcriptFile else { continue }
                let summaryURL = item.appendingPathComponent("summary.json")
                
                if let pair = parseSession(file: file, sessionId: sessionId, summaryURL: summaryURL) {
                    if let usage = pair.usage { usages.append(usage) }
                    if let conv = pair.conversation { conversations.append(conv) }
                }
            } else if item.pathExtension == "jsonl" {
                // Scenario 2: Flat File Mode
                let sessionId = item.deletingPathExtension().lastPathComponent
                if let pair = parseSession(file: item, sessionId: sessionId, summaryURL: nil) {
                    if let usage = pair.usage { usages.append(usage) }
                    if let conv = pair.conversation { conversations.append(conv) }
                }
            }
        }

        return ParseResult(usages: usages, conversations: conversations)
    }

    // MARK: - Session Parsing

    private func parseSession(
        file: URL,
        sessionId: String,
        summaryURL: URL?
    ) -> (usage: TokenUsage?, conversation: ConversationRecord?)? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }

        let mtime = (try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate]) as? Date

        // Optional metadata from summary.json
        var summaryModel: String? = nil
        var summaryTitle: String? = nil
        var summaryProject: String? = nil
        var summaryCwd: String? = nil

        if let summaryURL,
           FileManager.default.fileExists(atPath: summaryURL.path),
           let data = try? Data(contentsOf: summaryURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
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

        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallbackDate = ISO8601DateFormatter()
        fallbackDate.formatOptions = [.withInternetDateTime]

        for line in handle.readAllUTF8Lines() {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            let role = (json["role"] as? String ?? json["source"] as? String ?? "").lowercased()
            let type = json["type"] as? String ?? ""
            let content = json["content"] as? String ?? json["message"] as? String ?? ""
            let thinking = json["thinking"] as? String ?? json["reasoning"] as? String ?? ""
            let toolCalls = json["tool_calls"] as? [[String: Any]] ?? json["toolCalls"] as? [[String: Any]] ?? []
            let timestampStr = json["timestamp"] as? String ?? json["created_at"] as? String

            if let timestampStr,
               let date = dateFormatter.date(from: timestampStr) ?? fallbackDate.date(from: timestampStr) {
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
                    acc.userWords += wordCount(content)
                    if acc.firstUserText == nil {
                        let cleaned = stripMetadataTags(content)
                        if !cleaned.isEmpty {
                            acc.firstUserText = String(cleaned.prefix(120))
                        }
                    }
                    appendText(&acc.fullText, content, isAssistant: false)
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
                    if let toolName = toolCall["name"] as? String, !toolName.isEmpty {
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
                    acc.lastAssistantText = content
                    acc.assistantMessageCount += 1
                    acc.assistantWords += wordCount(content)
                    appendText(&acc.fullText, content, isAssistant: true)
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

                if type == "VIEW_FILE" || content.contains("File Path: `file:///") {
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
        let cost = pricing.cost(
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
