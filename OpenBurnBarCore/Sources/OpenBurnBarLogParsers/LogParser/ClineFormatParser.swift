import Foundation
import OpenBurnBarKernel

// MARK: - Cline Format Parser

/// Shared parser for Cline-family VS Code extensions (Cline, Kilo Code, Roo Code).
/// All three use the same `tasks/*/api_conversation_history.json` format.
///
/// Idle usage ticks resume unchanged task histories from a mtime+size disk cache
/// (token totals only — never conversation bodies).
public final class ClineFormatParser: LogParser, Sendable {
    public let provider: AgentProvider
    private let storagePaths: [String]
    private let fileManager: FileManager
    private let cacheStore: ParserDiskCacheStore<CachedUsageEntry<FileSignature>>
    private let sessionScanCount = Locked(0)
    private let sessionCacheHitCount = Locked(0)

    public init(
        provider: AgentProvider,
        storagePaths: [String],
        fileManager: FileManager = .default,
        appPaths: OpenBurnBarAppPaths = .live()
    ) {
        self.provider = provider
        self.storagePaths = storagePaths
        self.fileManager = fileManager
        let cacheURL: URL
        if storagePaths.count == 1, let path = storagePaths.first {
            cacheURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                .appendingPathComponent(".obb-parser-cache.plist")
        } else {
            cacheURL = appPaths.clineFormatParserCacheURL(for: provider)
        }
        self.cacheStore = ParserDiskCacheStore(
            cacheURL: cacheURL,
            fileManager: fileManager,
            schemaVersion: 1,
            logLabel: "ClineFormatParser.\(provider.persistedToken)"
        )
    }

    var lastSessionScanCount: Int { sessionScanCount.read() }
    var lastSessionCacheHitCount: Int { sessionCacheHitCount.read() }

    public func parse() async throws -> ParseResult {
        try await parse(options: .default)
    }

    public func parse(options: LogParseOptions) async throws -> ParseResult {
        sessionScanCount.write(0)
        sessionCacheHitCount.write(0)
        let gate = ParserFileReadGate(options: options, fileManager: fileManager)
        var usages: [TokenUsage] = []
        var conversations: [ConversationRecord] = []
        var seenTaskIds = Set<String>()
        var parseCache = cacheStore.load()
        var activePaths = Set<String>()
        var cacheMutated = false
        defer {
            if cacheMutated {
                cacheStore.persist(parseCache)
            }
        }

        for storagePath in storagePaths {
            let expanded = (storagePath as NSString).expandingTildeInPath
            guard fileManager.fileExists(atPath: expanded) else { continue }

            let tasksURL = URL(fileURLWithPath: expanded)
            guard let taskDirs = try? fileManager.contentsOfDirectory(
                at: tasksURL,
                includingPropertiesForKeys: [.isDirectoryKey]
            ) else { continue }

            let dirs = taskDirs.filter {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }

            for taskDir in dirs {
                let taskId = taskDir.lastPathComponent
                let historyFile = taskDir.appendingPathComponent("api_conversation_history.json")
                guard fileManager.fileExists(atPath: historyFile.path) else { continue }
                let cacheKey = historyFile.standardizedFileURL.path
                activePaths.insert(cacheKey)
                guard seenTaskIds.insert(taskId).inserted else { continue }
                guard try gate.shouldRead(historyFile) else { continue }

                let signature = FileSignature(for: historyFile, using: fileManager)
                if !options.includeConversationBodies,
                   let signature,
                   let cached = parseCache.fileEntries[cacheKey],
                   cached.signature == signature {
                    sessionCacheHitCount.withLock { $0 += 1 }
                    usages.append(cached.totals.makeUsage(provider: provider, sessionId: taskId))
                    continue
                }

                sessionScanCount.withLock { $0 += 1 }
                if let pair = try parseTask(
                    taskId: taskId,
                    historyFile: historyFile,
                    includeConversationBodies: options.includeConversationBodies
                ), let usage = pair.usage {
                    usages.append(usage)
                    if options.includeConversationBodies, let conv = pair.conversation {
                        conversations.append(conv)
                    }
                    if let signature {
                        parseCache.fileEntries[cacheKey] = CachedUsageEntry(signature: signature, usage: usage)
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

        return ParseResult(usages: usages, conversations: conversations)
    }

    // MARK: - Task Parsing

    private func parseTask(
        taskId: String,
        historyFile: URL,
        includeConversationBodies: Bool
    ) throws -> (usage: TokenUsage?, conversation: ConversationRecord?)? {
        guard let data = try? Data(contentsOf: historyFile), // try?-ok(skip unreadable log)
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { // try?-ok(malformed log skip)
            return nil
        }

        let mtime = modificationDate(of: historyFile)

        var inputTokens = 0
        var outputTokens = 0
        var cacheCreationTokens = 0
        var cacheReadTokens = 0
        var models = Set<String>()
        var firstTimestamp: Date?
        var lastTimestamp: Date?

        var fullText = ""
        var firstUserText: String?
        var lastAssistantText = ""
        var userWords = 0
        var assistantWords = 0
        var messageCount = 0

        for message in array {
            let role = (message["role"] as? String ?? "").lowercased()

            // Timestamp: ts is milliseconds since epoch
            if let ts = message["ts"] as? Double {
                let date = Date(timeIntervalSince1970: ts / 1000.0)
                if firstTimestamp == nil { firstTimestamp = date }
                lastTimestamp = date
            } else if let ts = message["ts"] as? Int {
                let date = Date(timeIntervalSince1970: Double(ts) / 1000.0)
                if firstTimestamp == nil { firstTimestamp = date }
                lastTimestamp = date
            }

            // Model detection
            if let model = message["model"] as? String, !model.isEmpty {
                models.insert(TokenExtractionUtility.normalizeModelName(model))
            }

            // Token usage on assistant messages
            if role == "assistant", let usage = message["usage"] as? [String: Any] {
                let extracted = TokenExtractionUtility.extractUsageTokens(
                    usage,
                    inputHint: inputTokens,
                    outputHint: outputTokens
                )
                inputTokens += extracted.input
                outputTokens += extracted.output
                cacheCreationTokens += extracted.cacheCreation
                cacheReadTokens += extracted.cacheRead
            }

            // Content extraction for conversation record
            let contentText = extractText(from: message["content"])
            guard !contentText.isEmpty else { continue }

            let words = contentText.split { $0.isWhitespace || $0.isNewline }.count

            if role == "user" {
                userWords += words
                messageCount += 1
                if includeConversationBodies {
                    if firstUserText == nil {
                        firstUserText = String(contentText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
                    }
                    appendText(&fullText, contentText)
                }
            } else if role == "assistant" {
                assistantWords += words
                messageCount += 1
                if includeConversationBodies {
                    lastAssistantText = contentText
                    appendText(&fullText, contentText)
                }
            }
        }

        var hasUsage = inputTokens > 0 || outputTokens > 0 || cacheCreationTokens > 0 || cacheReadTokens > 0

        // Check ui_messages.json for exact token telemetry if not present in conversation history
        if !hasUsage {
            let uiMessagesFile = historyFile.deletingLastPathComponent().appendingPathComponent("ui_messages.json")
            if let uiData = try? Data(contentsOf: uiMessagesFile),
               let uiArray = try? JSONSerialization.jsonObject(with: uiData) as? [[String: Any]] {
                for msg in uiArray {
                    if let say = msg["say"] as? String, say == "api_req_started" || say == "api_req_finished",
                       let text = msg["text"] as? String,
                       let textData = text.data(using: .utf8),
                       let reqJson = try? JSONSerialization.jsonObject(with: textData) as? [String: Any] {
                        if let tIn = reqJson["tokensIn"] as? Int { inputTokens += tIn }
                        if let tOut = reqJson["tokensOut"] as? Int { outputTokens += tOut }
                        if let cW = reqJson["cacheWrites"] as? Int { cacheCreationTokens += cW }
                        if let cR = reqJson["cacheReads"] as? Int { cacheReadTokens += cR }
                    }
                }
                hasUsage = inputTokens > 0 || outputTokens > 0 || cacheCreationTokens > 0 || cacheReadTokens > 0
            }
        }

        // Fallback estimation if still no usage data
        if !hasUsage {
            let userChars = userWords * 5
            let assistantChars = assistantWords * 5
            guard userChars + assistantChars > 0 else { return nil }
            let estimated = TokenExtractionUtility.estimateFallbackTokens(
                userVisibleChars: userChars,
                assistantVisibleChars: assistantChars,
                assistantReasoningChars: 0,
                userMessageCount: messageCount / 2,
                assistantMessageCount: messageCount / 2
            )
            inputTokens = estimated.input
            outputTokens = estimated.output
        }

        guard inputTokens > 0 || outputTokens > 0 || cacheCreationTokens > 0 || cacheReadTokens > 0 else { return nil }

        let model = models.first ?? "unknown"
        let pricing = ModelPricing.lookup(model: model)
        let cost = try pricing.cost(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheCreationTokens: cacheCreationTokens,
            cacheReadTokens: cacheReadTokens
        )

        let startTime = firstTimestamp ?? Date()
        let endTime = lastTimestamp ?? startTime

        let usage = TokenUsage(
            provider: provider,
            sessionId: taskId,
            projectName: taskId,
            model: model,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheCreationTokens: cacheCreationTokens,
            cacheReadTokens: cacheReadTokens,
            costUSD: cost,
            startTime: startTime,
            endTime: endTime,
            provenanceMethod: .providerLog,
            provenanceConfidence: .exact
        )

        let conversation = includeConversationBodies
            ? ConversationRecord(
                id: ConversationRecord.stableId(provider: provider, sessionId: taskId),
                provider: provider,
                sessionId: taskId,
                projectName: taskId,
                startTime: startTime,
                endTime: endTime,
                messageCount: messageCount,
                userWordCount: userWords,
                assistantWordCount: assistantWords,
                keyFiles: [],
                keyCommands: [],
                keyTools: [],
                inferredTaskTitle: firstUserText ?? taskId,
                lastAssistantMessage: lastAssistantText,
                fullText: fullText,
                indexedAt: Date(),
                fileModifiedAt: mtime,
                summary: nil
            )
            : nil

        return (usage, conversation)
    }

    // MARK: - Helpers

    /// Extract plain text from a content field that may be a String or array of content blocks.
    private func extractText(from content: Any?) -> String {
        if let text = content as? String {
            return text
        }
        if let blocks = content as? [[String: Any]] {
            return blocks.compactMap { block -> String? in
                guard (block["type"] as? String) == "text" else { return nil }
                return block["text"] as? String
            }.joined(separator: "\n")
        }
        return ""
    }

    private func appendText(_ full: inout String, _ chunk: String) {
        if !full.isEmpty { full += "\n\n" }
        full += chunk
    }

    private func modificationDate(of url: URL) -> Date? {
        // try?-ok(optional mtime metadata)
        (try? fileManager.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }
}
