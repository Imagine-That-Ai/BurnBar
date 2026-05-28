import Foundation

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
final class AntigravityParser: LogParser, Sendable {
    let provider: AgentProvider = .antigravity

    struct SettingsFile: Decodable {
        let model: String?
    }

    func parse() async throws -> ParseResult {
        let fm = FileManager.default
        let basePath = ("~/.gemini/antigravity-cli" as NSString).expandingTildeInPath
        let brainPath = (basePath as NSString).appendingPathComponent("brain")

        guard fm.fileExists(atPath: brainPath) else {
            return ParseResult(usages: [], conversations: [])
        }

        // Fetch settings for active model (fallback when per-session model unavailable)
        let settingsURL = URL(fileURLWithPath: basePath).appendingPathComponent("settings.json")
        let fallbackModelName: String = {
            guard let data = try? Data(contentsOf: settingsURL),
                  let settings = try? JSONDecoder().decode(SettingsFile.self, from: data),
                  let model = settings.model, !model.isEmpty else {
                return "Claude Opus 4.6 (Thinking)"
            }
            return model
        }()

        var usages: [TokenUsage] = []
        var conversations: [ConversationRecord] = []

        let brainURL = URL(fileURLWithPath: brainPath)
        let conversationDirs = (try? fm.contentsOfDirectory(at: brainURL, includingPropertiesForKeys: [.isDirectoryKey]))?.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        } ?? []

        for conversationDir in conversationDirs {
            let sessionId = conversationDir.lastPathComponent
            let logsDir = conversationDir
                .appendingPathComponent(".system_generated")
                .appendingPathComponent("logs")

            // Prefer transcript_full.jsonl (untruncated) — truncated version can lose ~40% of content
            let fullTranscript = logsDir.appendingPathComponent("transcript_full.jsonl")
            let truncatedTranscript = logsDir.appendingPathComponent("transcript.jsonl")
            let transcriptFile = fm.fileExists(atPath: fullTranscript.path) ? fullTranscript : truncatedTranscript

            guard fm.fileExists(atPath: transcriptFile.path) else { continue }

            if let pair = parseSession(
                transcriptFile: transcriptFile,
                sessionId: sessionId,
                fallbackModel: fallbackModelName
            ) {
                if let usage = pair.usage { usages.append(usage) }
                if let conv = pair.conversation { conversations.append(conv) }
            }
        }

        return ParseResult(usages: usages, conversations: conversations)
    }

    // MARK: - Session Parsing

    func parseSession(
        transcriptFile: URL,
        sessionId: String,
        fallbackModel: String
    ) -> (usage: TokenUsage?, conversation: ConversationRecord?)? {
        guard let handle = try? FileHandle(forReadingFrom: transcriptFile) else { return nil }
        defer { try? handle.close() }

        let mtime = (try? FileManager.default.attributesOfItem(atPath: transcriptFile.path)[.modificationDate]) as? Date

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

        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let fallbackDateFormatter = ISO8601DateFormatter()
        fallbackDateFormatter.formatOptions = [.withInternetDateTime]

        for line in handle.readAllUTF8Lines() {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
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
               let date = dateFormatter.date(from: createdAtStr) ?? fallbackDateFormatter.date(from: createdAtStr) {
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
                    if let toolName = toolCall["name"] as? String, !toolName.isEmpty {
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

            } else if source == "MODEL" {
                // Tool outputs
                currentToolOutputChars += content.count
                acc.toolOutputChars += content.count

                // Extract file paths from VIEW_FILE results for keyFiles
                if type == "VIEW_FILE" {
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
        let cost = pricing.cost(
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

        // The model name ends at a period followed by whitespace/end, NOT a bare period
        // (model names like "Claude Opus 4.6 (Thinking)" contain dots in version numbers)
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
    static func stringLength(of value: Any) -> Int {
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
