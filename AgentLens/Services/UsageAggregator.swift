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

        isRefreshing = false

        // Upload unsynced rows to Firestore (no-op if not signed in)
        await cloudSync?.uploadPending()
        await cloudSync?.uploadPendingConversations()
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
                // Strip "custom:" prefix that Factory prepends to user-configured models
                settingsModel = m.hasPrefix("custom:") ? String(m.dropFirst(7)) : m
            }
            if let tokenUsage = json["tokenUsage"] as? [String: Any] {
                let input = tokenUsage["inputTokens"] as? Int ?? 0
                let output = tokenUsage["outputTokens"] as? Int ?? 0
                let cc = tokenUsage["cacheCreationTokens"] as? Int ?? 0
                let cr = tokenUsage["cacheReadTokens"] as? Int ?? 0
                if input > 0 || output > 0 || cc > 0 || cr > 0 {
                    inputTokens = input
                    outputTokens = output
                    cacheCreationTokens = cc
                    cacheReadTokens = cr
                    usedSettingsTotals = true
                }
            }
        }

        var startTime: Date?
        var endTime: Date?
        // Character counts for estimation when no usage data is present in the logs
        var userCharCount = 0
        var assistantCharCount = 0

        while let line = handle.readLine(), !line.isEmpty {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            conv.ingest(jsonLine: json)

            if let message = json["message"] as? [String: Any],
               let content = message["content"] as? [[String: Any]] {
                let role = message["role"] as? String
                var charCount = 0
                for item in content {
                    if let text = item["text"] as? String {
                        charCount += text.count
                        if text.lowercased().contains("model:") {
                            if let range = text.range(of: "Model: ", options: .caseInsensitive) {
                                let afterModel = text[range.upperBound...]
                                let endIndex = afterModel.firstIndex(of: "\n") ?? afterModel.endIndex
                                let modelName = String(afterModel[..<endIndex]).trimmingCharacters(in: .whitespaces)
                                if modelName.lowercased().contains(modelPattern) {
                                    inlineModel = modelName
                                }
                            }
                        }
                    } else if let input = item["input"] {
                        charCount += String(describing: input).count
                    }
                }
                if role == "user" { userCharCount += charCount }
                else if role == "assistant" { assistantCharCount += charCount }
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
               message["role"] as? String == "assistant",
               let usage = message["usage"] as? [String: Any] {
                inputTokens += usage["input_tokens"] as? Int ?? usage["prompt_tokens"] as? Int ?? 0
                outputTokens += usage["output_tokens"] as? Int ?? usage["completion_tokens"] as? Int ?? 0
                cacheCreationTokens += usage["cache_creation_input_tokens"] as? Int ?? 0
                cacheReadTokens += usage["cache_read_input_tokens"] as? Int ?? 0

                if let ts = json["timestamp"] as? String {
                    let date = ISO8601DateFormatter().date(from: ts)
                    if startTime == nil { startTime = date }
                    endTime = date
                }
            }

        }

        conv.finalizeArrays()

        // Factory does not write MiniMax token usage to the JSONL or settings file.
        // Fall back to character-based estimation (~4 chars per token).
        if inputTokens == 0 && outputTokens == 0 && cacheCreationTokens == 0 && cacheReadTokens == 0 {
            guard userCharCount + assistantCharCount > 0 else { return nil }
            inputTokens = userCharCount / 4
            outputTokens = assistantCharCount / 4
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
}
