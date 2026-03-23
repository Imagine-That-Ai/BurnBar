import Foundation
import GRDB

// MARK: - Parser Health

enum ParserHealth {
    case healthy(sessionCount: Int)
    case empty
    case failed(error: String)
    case notConfigured
}

// MARK: - Usage Aggregator

@Observable
@MainActor
final class UsageAggregator {
    private let dataStore: DataStore
    private let parsers: [AgentProvider: any LogParser]
    private weak var cloudSync: CloudSyncService?
    private let settingsManager: SettingsManager

    private(set) var isRefreshing = false
    private(set) var lastRefresh: Date?
    private(set) var errors: [AgentProvider: String] = [:]
    private(set) var parserHealth: [AgentProvider: ParserHealth] = [:]

    init(dataStore: DataStore, cloudSync: CloudSyncService? = nil, settingsManager: SettingsManager = .shared) {
        self.dataStore = dataStore
        self.cloudSync = cloudSync
        self.settingsManager = settingsManager
        // All parsers initialized - each handles missing directories gracefully
        self.parsers = [
            .factory: FactoryDroidParser(),
            .claudeCode: ClaudeCodeParser(),
            .copilot: CopilotParser(),
            .aider: AiderParser(),
            .cursor: CursorParser(),
            .codex: CodexParser(),
            .zai: ModelFilterParser(modelPattern: "zai", provider: .zai),
            .minimax: ModelFilterParser(modelPattern: "minimax", provider: .minimax),
            .kimi: KimiParser()
        ]
    }

    // MARK: - Refresh All

    func refreshAll() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        errors = [:]
        parserHealth = [:]

        var allUsages: [TokenUsage] = []

        // Process parsers sequentially for reliability.
        // Providers with .unsupported (Copilot, Aider, Cursor) are skipped — parsers are stubs until implemented.
        for (provider, parser) in parsers {
            // Mark unsupported providers without running them
            if provider.supportLevel == .unsupported {
                parserHealth[provider] = .notConfigured
                continue
            }

            do {
                let result = try await parser.parse()
                let usages = result.usages
                if usages.isEmpty {
                    parserHealth[provider] = .empty
                } else {
                    parserHealth[provider] = .healthy(sessionCount: usages.count)
                }
                allUsages.append(contentsOf: usages)
                if settingsManager.conversationIndexingEnabled {
                    do {
                        try ConversationIndexer.shared.index(result.conversations, in: dataStore)
                    } catch {
                        print("UsageAggregator: Conversation indexing failed for \(provider.rawValue): \(error.localizedDescription)")
                    }
                }
            } catch {
                parserHealth[provider] = .failed(error: error.localizedDescription)
                errors[provider] = error.localizedDescription
            }
        }

        // Store all usages
        do {
            try dataStore.insert(allUsages)
            dataStore.replaceUsages(allUsages)
            lastRefresh = Date()
        } catch {
            print("UsageAggregator: Failed to store usages: \(error)")
        }

        // Unblock scan UI immediately after local parsing/persistence completes.
        isRefreshing = false

        // Upload unsynced rows to Firestore (no-op if not signed in)
        await cloudSync?.uploadPending()
        await cloudSync?.uploadPendingConversations()
    }

    /// Clears local usage rows so the dashboard resets immediately, then re-parses all providers.
    func recountAll() async {
        guard !isRefreshing else { return }
        do {
            try dataStore.deleteAll()
        } catch {
            print("UsageAggregator: Failed to clear usage rows before recount: \(error)")
        }
        await refreshAll()
    }
    
    // MARK: - Refresh Single Provider
    
    func refresh(provider: AgentProvider) async {
        guard let parser = parsers[provider] else { return }
        
        do {
            let result = try await parser.parse()
            try dataStore.insert(result.usages)
            if settingsManager.conversationIndexingEnabled {
                do {
                    try ConversationIndexer.shared.index(result.conversations, in: dataStore)
                } catch {
                    print("UsageAggregator: Conversation indexing failed for \(provider.rawValue): \(error.localizedDescription)")
                }
            }
            dataStore.refresh()
            errors.removeValue(forKey: provider)
        } catch {
            errors[provider] = error.localizedDescription
        }
    }
}

// MARK: - Copilot Parser

final class CopilotParser: LogParser {
    let provider: AgentProvider = .copilot

    func parse() async throws -> ParseResult {
        ParseResult(usages: [], conversations: [])
    }
}

// MARK: - Aider Parser

final class AiderParser: LogParser {
    let provider: AgentProvider = .aider

    func parse() async throws -> ParseResult {
        ParseResult(usages: [], conversations: [])
    }
}

// MARK: - Cursor Parser

final class CursorParser: LogParser {
    let provider: AgentProvider = .cursor

    func parse() async throws -> ParseResult {
        ParseResult(usages: [], conversations: [])
    }
}

// MARK: - Codex Parser

/// Reads aggregate token usage from Codex’s SQLite store. Conversation transcripts are not
/// available there yet, so `conversations` is always empty.
final class CodexParser: LogParser {
    let provider: AgentProvider = .codex

    func parse() async throws -> ParseResult {
        let basePath = (provider.logDirectory as NSString).expandingTildeInPath
        let dbPath = (basePath as NSString).appendingPathComponent("state_5.sqlite")

        guard FileManager.default.fileExists(atPath: dbPath) else {
            return ParseResult(usages: [], conversations: [])
        }

        let usages = try parseCodexDatabase(dbPath: dbPath)
        return ParseResult(usages: usages, conversations: [])
    }
    
    private func parseCodexDatabase(dbPath: String) throws -> [TokenUsage] {
        var usages: [TokenUsage] = []
        
        let db = try DatabaseQueue(path: dbPath)
        try db.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT 
                    id,
                    title,
                    model,
                    model_provider,
                    tokens_used,
                    created_at,
                    updated_at,
                    cwd
                FROM threads
                WHERE archived = 0
                ORDER BY created_at DESC
                LIMIT 500
            """)
            
            for row in rows {
                guard let threadId: String = row["id"],
                      let tokensUsed: Int = row["tokens_used"],
                      let createdAt: Int64 = row["created_at"],
                      let updatedAt: Int64 = row["updated_at"] else {
                    continue
                }
                
                let model: String = row["model"] ?? "unknown"
                let cwd: String = row["cwd"] ?? "~"
                
                // Extract project name from cwd
                let projectName = (cwd as NSString).lastPathComponent
                
                // Tokens are stored as total - estimate input/output split
                let inputTokens = tokensUsed / 2
                let outputTokens = tokensUsed / 2
                
                let pricing = ModelPricing.lookup(model: model)
                let cost = pricing.cost(inputTokens: inputTokens, outputTokens: outputTokens)
                
                let startTime = Date(timeIntervalSince1970: Double(createdAt))
                let endTime = Date(timeIntervalSince1970: Double(updatedAt))
                
                let usage = TokenUsage(
                    provider: .codex,
                    sessionId: threadId,
                    projectName: projectName,
                    model: model,
                    inputTokens: inputTokens,
                    outputTokens: outputTokens,
                    cacheCreationTokens: 0,
                    cacheReadTokens: 0,
                    costUSD: cost,
                    startTime: startTime,
                    endTime: endTime
                )
                usages.append(usage)
            }
            
        }
        
        return usages
    }
}

// MARK: - Model Filter Parser (for Zai/MiniMax which use Factory sessions)

final class ModelFilterParser: LogParser {
    let provider: AgentProvider
    private let modelPattern: String
    private let ignoredContentKeys: Set<String> = ["type", "role", "id", "tool_use_id", "name"]

    init(modelPattern: String, provider: AgentProvider) {
        self.modelPattern = modelPattern.lowercased()
        self.provider = provider
    }

    func parse() async throws -> ParseResult {
        let sessionsPath = "~/.factory/sessions"
        let sessionsURL = URL(fileURLWithPath: (sessionsPath as NSString).expandingTildeInPath)

        guard FileManager.default.fileExists(atPath: sessionsURL.path) else {
            return ParseResult(usages: [], conversations: [])
        }

        var usages: [TokenUsage] = []
        var conversations: [ConversationRecord] = []

        let projectDirs = try FileManager.default.contentsOfDirectory(at: sessionsURL, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }

        for projectDir in projectDirs {
            let projectName = decodeProjectName(projectDir.lastPathComponent)

            let files = try FileManager.default.contentsOfDirectory(at: projectDir, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "jsonl" }

            for jsonlFile in files {
                if let pair = try? parseSession(file: jsonlFile, projectName: projectName),
                   let usage = pair.usage {
                    usages.append(usage)
                    if let conv = pair.conversation {
                        conversations.append(conv)
                    }
                }
            }
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
        return decoded
    }

    private func parseSession(file: URL, projectName: String) throws -> (usage: TokenUsage?, conversation: ConversationRecord?)? {
        guard let handle = try? FileHandle(forReadingFrom: file) else {
            return nil
        }
        defer { try? handle.close() }

        let mtime = (try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate]) as? Date
        let conv = ClaudeConversationAccumulator()

        let baseName = file.deletingPathExtension().lastPathComponent
        let settingsURL = file.deletingLastPathComponent().appendingPathComponent("\(baseName).settings.json")

        var inlineModel: String?
        var inputTokens = 0
        var outputTokens = 0
        var cacheCreationTokens = 0
        var cacheReadTokens = 0
        var usedSettingsTotals = false
        var settingsModel: String?

        if let data = try? Data(contentsOf: settingsURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let m = json["model"] as? String {
                settingsModel = normalizeModelName(m)
            }
            if let tokenUsage = json["tokenUsage"] as? [String: Any] {
                let extracted = extractUsageTokens(
                    tokenUsage,
                    userCharHint: 0,
                    assistantCharHint: 0
                )
                if extracted.input > 0 || extracted.output > 0 || extracted.cacheCreation > 0 || extracted.cacheRead > 0 {
                    inputTokens = extracted.input
                    outputTokens = extracted.output
                    cacheCreationTokens = extracted.cacheCreation
                    cacheReadTokens = extracted.cacheRead
                    usedSettingsTotals = true
                }
            }
        }

        var startTime: Date?
        var endTime: Date?
        // Character counts for estimation when no usage data is present in the logs.
        // We include tool_result payloads and assistant reasoning signatures to avoid
        // severely undercounting sessions where providers omit explicit usage.
        var userCharCount = 0
        var assistantCharCount = 0
        var assistantReasoningCharCount = 0
        var userMessageCount = 0
        var assistantMessageCount = 0

        for line in handle.readAllUTF8Lines() {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            conv.ingest(jsonLine: json)

            if let message = json["message"] as? [String: Any] {
                let role = (message["role"] as? String)?.lowercased()
                if let content = message["content"] {
                    let metrics = contentMetrics(from: content)
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

                    if inlineModel == nil, let detectedModel = detectModelHint(from: content) {
                        inlineModel = normalizeModelName(detectedModel)
                    }
                }
            }

            if usedSettingsTotals {
                if let message = json["message"] as? [String: Any],
                   message["role"] as? String == "assistant",
                   let ts = json["timestamp"] as? String {
                    let date = ISO8601DateFormatter().date(from: ts)
                    if startTime == nil { startTime = date }
                    endTime = date
                }
                continue
            }

            if let message = json["message"] as? [String: Any],
               (message["role"] as? String)?.lowercased() == "assistant",
               let usage = message["usage"] as? [String: Any] {
                let extracted = extractUsageTokens(
                    usage,
                    userCharHint: userCharCount,
                    assistantCharHint: assistantCharCount + assistantReasoningCharCount
                )
                inputTokens += extracted.input
                outputTokens += extracted.output
                cacheCreationTokens += extracted.cacheCreation
                cacheReadTokens += extracted.cacheRead

                if let ts = json["timestamp"] as? String {
                    let date = ISO8601DateFormatter().date(from: ts)
                    if startTime == nil { startTime = date }
                    endTime = date
                }
            }

        }

        conv.finalizeArrays()

        // Factory does not consistently write usage for routed providers.
        // Fall back to content-aware estimation that includes tool results and
        // assistant reasoning signatures.
        if inputTokens == 0 && outputTokens == 0 && cacheCreationTokens == 0 && cacheReadTokens == 0 {
            guard userCharCount + assistantCharCount + assistantReasoningCharCount > 0 else { return nil }
            let estimated = estimateFallbackTokens(
                userVisibleChars: userCharCount,
                assistantVisibleChars: assistantCharCount,
                assistantReasoningChars: assistantReasoningCharCount,
                userMessageCount: userMessageCount,
                assistantMessageCount: assistantMessageCount
            )
            inputTokens = estimated.input
            outputTokens = estimated.output
        }

        let modelFromSettings = settingsModel.flatMap { m in
            m.lowercased().contains(modelPattern) ? m : nil
        }
        let resolvedModel = modelFromSettings ?? inlineModel
        guard let model = resolvedModel, model.lowercased().contains(modelPattern) else {
            return nil
        }

        guard inputTokens > 0 || outputTokens > 0 || cacheCreationTokens > 0 || cacheReadTokens > 0 else {
            return nil
        }

        let resolvedStart = startTime ?? conv.startTime ?? Date()
        let resolvedEnd = endTime ?? conv.endTime ?? resolvedStart

        let cost = ModelPricing.lookup(model: model).cost(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheCreationTokens: cacheCreationTokens,
            cacheReadTokens: cacheReadTokens
        )
        let sessionId = baseName

        let usage = TokenUsage(
            provider: provider,
            sessionId: sessionId,
            projectName: projectName,
            model: model,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheCreationTokens: cacheCreationTokens,
            cacheReadTokens: cacheReadTokens,
            costUSD: cost,
            startTime: resolvedStart,
            endTime: resolvedEnd
        )

        let conversation = ConversationRecord(
            id: ConversationRecord.stableId(provider: provider, sessionId: sessionId),
            provider: provider,
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

    private func normalizeModelName(_ model: String) -> String {
        model.hasPrefix("custom:") ? String(model.dropFirst(7)) : model
    }

    private func extractUsageTokens(
        _ usage: [String: Any],
        userCharHint: Int,
        assistantCharHint: Int
    ) -> (input: Int, output: Int, cacheCreation: Int, cacheRead: Int) {
        var input = firstIntValue(
            in: usage,
            paths: [
                ["input_tokens"],
                ["prompt_tokens"],
                ["inputTokens"],
                ["promptTokens"]
            ]
        ) ?? 0

        var output = firstIntValue(
            in: usage,
            paths: [
                ["output_tokens"],
                ["completion_tokens"],
                ["outputTokens"],
                ["completionTokens"]
            ]
        ) ?? 0

        let cacheCreation = firstIntValue(
            in: usage,
            paths: [
                ["cache_creation_input_tokens"],
                ["cache_creation_tokens"],
                ["cacheCreationTokens"]
            ]
        ) ?? 0

        let cacheRead = firstIntValue(
            in: usage,
            paths: [
                ["cache_read_input_tokens"],
                ["cache_read_tokens"],
                ["cacheReadTokens"],
                ["prompt_tokens_details", "cached_tokens"],
                ["promptTokensDetails", "cachedTokens"],
                ["cached_tokens"],
                ["cachedTokens"]
            ]
        ) ?? 0

        let thinking = firstIntValue(
            in: usage,
            paths: [
                ["thinking_tokens"],
                ["reasoning_tokens"],
                ["thinkingTokens"],
                ["reasoningTokens"],
                ["completion_tokens_details", "reasoning_tokens"],
                ["output_tokens_details", "reasoning_tokens"]
            ]
        ) ?? 0

        let total = firstIntValue(
            in: usage,
            paths: [
                ["total_tokens"],
                ["totalTokens"]
            ]
        ) ?? 0

        let explicitPayloadTotal = max(input, 0) + max(output, 0) + max(cacheCreation, 0) + max(cacheRead, 0)
        let normalizedTotal = max(total, explicitPayloadTotal)

        if normalizedTotal > 0 {
            let availableForInOut = max(normalizedTotal - cacheCreation - cacheRead, 0)

            if input == 0 && output == 0 && availableForInOut > 0 {
                let combinedHints = userCharHint + assistantCharHint
                let inputRatio = combinedHints > 0
                    ? Double(userCharHint) / Double(combinedHints)
                    : 0.62
                input = Int((Double(availableForInOut) * inputRatio).rounded())
                output = max(availableForInOut - input, 0)
            } else if input == 0 && output > 0 && availableForInOut > output {
                input = availableForInOut - output
            } else if output == 0 && input > 0 && availableForInOut > input {
                output = availableForInOut - input
            } else if input + output < availableForInOut {
                output += availableForInOut - (input + output)
            }
        }

        if thinking > 0 && total == 0 {
            output += thinking
        }

        return (
            input: max(input, 0),
            output: max(output, 0),
            cacheCreation: max(cacheCreation, 0),
            cacheRead: max(cacheRead, 0)
        )
    }

    private func firstIntValue(in dictionary: [String: Any], paths: [[String]]) -> Int? {
        for path in paths {
            if let value = nestedValue(in: dictionary, path: path),
               let intValue = parseInt(value) {
                return intValue
            }
        }
        return nil
    }

    private func nestedValue(in dictionary: [String: Any], path: [String]) -> Any? {
        var cursor: Any = dictionary
        for key in path {
            guard let dict = cursor as? [String: Any], let next = dict[key] else {
                return nil
            }
            cursor = next
        }
        return cursor
    }

    private func parseInt(_ value: Any?) -> Int? {
        guard let value else { return nil }
        if let intValue = value as? Int {
            return max(intValue, 0)
        }
        if let int64Value = value as? Int64 {
            return max(Int(int64Value), 0)
        }
        if let doubleValue = value as? Double {
            return max(Int(doubleValue.rounded()), 0)
        }
        if let numberValue = value as? NSNumber {
            return max(numberValue.intValue, 0)
        }
        if let stringValue = value as? String {
            let trimmed = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if let intValue = Int(trimmed) {
                return max(intValue, 0)
            }
            if let doubleValue = Double(trimmed) {
                return max(Int(doubleValue.rounded()), 0)
            }
        }
        return nil
    }

    private func detectModelHint(from value: Any) -> String? {
        switch value {
        case let text as String:
            guard text.lowercased().contains("model:") else { return nil }
            guard let range = text.range(of: "model:", options: .caseInsensitive) else { return nil }
            let afterModel = text[range.upperBound...]
            let endIndex = afterModel.firstIndex(of: "\n") ?? afterModel.endIndex
            let model = String(afterModel[..<endIndex]).trimmingCharacters(in: .whitespaces)
            return model.isEmpty ? nil : model
        case let array as [Any]:
            for item in array {
                if let found = detectModelHint(from: item) {
                    return found
                }
            }
            return nil
        case let dictionary as [String: Any]:
            for (_, nestedValue) in dictionary {
                if let found = detectModelHint(from: nestedValue) {
                    return found
                }
            }
            return nil
        default:
            return nil
        }
    }

    private func contentMetrics(from value: Any, key: String? = nil) -> (visibleChars: Int, reasoningChars: Int) {
        switch value {
        case let text as String:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return (0, 0) }
            if key == "signature" {
                return (0, trimmed.count)
            }
            if let key, ignoredContentKeys.contains(key) {
                return (0, 0)
            }
            return (trimmed.count, 0)
        case let array as [Any]:
            var visible = 0
            var reasoning = 0
            for item in array {
                let nested = contentMetrics(from: item)
                visible += nested.visibleChars
                reasoning += nested.reasoningChars
            }
            return (visible, reasoning)
        case let dictionary as [String: Any]:
            var visible = 0
            var reasoning = 0
            for (nestedKey, nestedValue) in dictionary {
                let nested = contentMetrics(from: nestedValue, key: nestedKey)
                visible += nested.visibleChars
                reasoning += nested.reasoningChars
            }
            return (visible, reasoning)
        default:
            return (0, 0)
        }
    }

    private func estimateFallbackTokens(
        userVisibleChars: Int,
        assistantVisibleChars: Int,
        assistantReasoningChars: Int,
        userMessageCount: Int,
        assistantMessageCount: Int
    ) -> (input: Int, output: Int) {
        let userTokens = estimatedTokenCount(for: userVisibleChars, charsPerToken: 3.35) + (userMessageCount * 9)
        let assistantVisibleTokens = estimatedTokenCount(for: assistantVisibleChars, charsPerToken: 3.35)
        let assistantReasoningTokens = estimatedTokenCount(for: assistantReasoningChars, charsPerToken: 2.45)
        let assistantTokens = assistantVisibleTokens + assistantReasoningTokens + (assistantMessageCount * 7)

        return (
            input: max(userTokens, 0),
            output: max(assistantTokens, 0)
        )
    }

    private func estimatedTokenCount(for characters: Int, charsPerToken: Double) -> Int {
        guard characters > 0 else { return 0 }
        return Int((Double(characters) / charsPerToken).rounded(.up))
    }
}
