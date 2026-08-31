import Foundation
import OpenBurnBarKernel

// MARK: - Gemini CLI Parser

/// Parses Gemini CLI sessions from ~/.gemini/tmp/<project_hash>/chats/session-*.json (and .jsonl).
/// Gemini CLI stores sessions with message_update records containing input_tokens, output_tokens, cached_tokens.
///
/// Idle usage ticks resume unchanged session files from a mtime+size disk cache
/// (token totals, model, and window only — never conversation bodies). Usage-only
/// ticks also skip transcript markdown assembly.
public final class GeminiCLIParser: LogParser, Sendable {
    public let provider: AgentProvider = .geminiCLI
    private let logDirectoryOverride: String?
    private let fileManager: FileManager
    private let cacheStore: ParserDiskCacheStore<GeminiUsageCacheEntry>
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
            cacheURL = URL(fileURLWithPath: override).appendingPathComponent(".obb-gemini-parser-cache.plist")
        } else {
            cacheURL = appPaths.geminiCLIParserCacheURL
        }
        self.cacheStore = ParserDiskCacheStore(
            cacheURL: cacheURL,
            fileManager: fileManager,
            schemaVersion: 1,
            logLabel: "GeminiCLIParser"
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
        let basePath = logDirectoryOverride ?? ("~/.gemini/tmp" as NSString).expandingTildeInPath

        guard fileManager.fileExists(atPath: basePath) else {
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

        let baseURL = URL(fileURLWithPath: basePath)
        let projectDirs = (try? fileManager.contentsOfDirectory(at: baseURL, includingPropertiesForKeys: [.isDirectoryKey]))?.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        } ?? []

        for projectDir in projectDirs {
            let projectName = projectDir.lastPathComponent
            let chatsDir = projectDir.appendingPathComponent("chats")

            guard fileManager.fileExists(atPath: chatsDir.path) else { continue }

            let chatFiles = (try? fileManager.contentsOfDirectory(
                at: chatsDir,
                includingPropertiesForKeys: FileSignature.directoryListingPrefetchKeys
            ))?.filter {
                let name = $0.lastPathComponent
                return name.hasPrefix("session-") && ($0.pathExtension == "json" || $0.pathExtension == "jsonl")
            } ?? []

            for chatFile in chatFiles {
                let cacheKey = chatFile.standardizedFileURL.path
                activePaths.insert(cacheKey)
                guard try gate.shouldRead(chatFile) else { continue }
                let sessionId = chatFile.deletingPathExtension().lastPathComponent
                let signature = FileSignature(for: chatFile, using: fileManager)

                if !options.includeConversationBodies,
                   let signature,
                   let cached = parseCache.fileEntries[cacheKey],
                   cached.signature == signature {
                    sessionCacheHitCount.withLock { $0 += 1 }
                    usages.append(cached.makeUsage(sessionId: sessionId, projectName: projectName))
                    continue
                }

                sessionScanCount.withLock { $0 += 1 }
                let pair: (usage: TokenUsage?, conversation: ConversationRecord?)?
                if chatFile.pathExtension == "jsonl" {
                    pair = try parseJsonlSession(
                        file: chatFile,
                        sessionId: sessionId,
                        projectName: projectName,
                        includeConversationBodies: options.includeConversationBodies
                    )
                } else {
                    pair = try parseJsonSession(
                        file: chatFile,
                        sessionId: sessionId,
                        projectName: projectName,
                        includeConversationBodies: options.includeConversationBodies
                    )
                }

                if let pair, let usage = pair.usage {
                    usages.append(usage)
                    if options.includeConversationBodies, let conv = pair.conversation {
                        conversations.append(conv)
                    }
                    if let signature {
                        parseCache.fileEntries[cacheKey] = GeminiUsageCacheEntry(signature: signature, usage: usage)
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

    // MARK: - JSONL Session Parsing

    private func parseJsonlSession(
        file: URL,
        sessionId: String,
        projectName: String,
        includeConversationBodies: Bool
    ) throws -> (usage: TokenUsage?, conversation: ConversationRecord?)? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil } // try?-ok(open file, guard nil)
        defer { try? handle.close() } // try?-ok(handle teardown)

        let mtime = modificationDate(of: file)
        var acc = GeminiSessionAccumulator()

        for line in handle.readAllUTF8Lines() {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { // try?-ok(optional JSON decode, skip line)
                continue
            }
            ingestLine(json, into: &acc, includeConversationBodies: includeConversationBodies)
        }

        return try buildResult(
            acc: acc,
            sessionId: sessionId,
            projectName: projectName,
            mtime: mtime,
            includeConversationBodies: includeConversationBodies
        )
    }

    // MARK: - JSON Session Parsing

    private func parseJsonSession(
        file: URL,
        sessionId: String,
        projectName: String,
        includeConversationBodies: Bool
    ) throws -> (usage: TokenUsage?, conversation: ConversationRecord?)? {
        guard let data = try? Data(contentsOf: file) else { return nil } // try?-ok(file read, guard nil)

        let mtime = modificationDate(of: file)
        var acc = GeminiSessionAccumulator()

        // Try array of messages
        if let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] { // try?-ok(optional JSON decode, fallback)
            for message in array {
                ingestLine(message, into: &acc, includeConversationBodies: includeConversationBodies)
            }
        }
        // Try single object with messages array
        else if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], // try?-ok(optional JSON decode, fallback)
                let messages = obj["messages"] as? [[String: Any]] {
            for message in messages {
                ingestLine(message, into: &acc, includeConversationBodies: includeConversationBodies)
            }
        }

        return try buildResult(
            acc: acc,
            sessionId: sessionId,
            projectName: projectName,
            mtime: mtime,
            includeConversationBodies: includeConversationBodies
        )
    }

    // MARK: - Shared Ingestion

    private func ingestLine(
        _ json: [String: Any],
        into acc: inout GeminiSessionAccumulator,
        includeConversationBodies: Bool
    ) {
        // Timestamp
        if let ts = json["timestamp"] as? String {
            let date = ThreadSafeISO8601DateFormatter.parseBasic(ts)
            if acc.startTime == nil { acc.startTime = date }
            acc.endTime = date
        } else if let ts = json["timestamp"] as? Double {
            let date = Date(timeIntervalSince1970: ts)
            if acc.startTime == nil { acc.startTime = date }
            acc.endTime = date
        } else if let ts = json["createTime"] as? String {
            let date = ThreadSafeISO8601DateFormatter.parseBasic(ts)
            if acc.startTime == nil { acc.startTime = date }
            acc.endTime = date
        }

        // Model
        if let m = json["model"] as? String, !m.isEmpty {
            acc.model = TokenExtractionUtility.normalizeModelName(m)
        }
        // Token usage — check multiple locations
        if let tokens = json["tokens"] as? [String: Any] {
            accumulateUsage(tokens, into: &acc)
        }
        if let usage = json["usage"] as? [String: Any] {
            accumulateUsage(usage, into: &acc)
        }
        if let usage = json["usageMetadata"] as? [String: Any] {
            accumulateUsage(usage, into: &acc)
        }
        if let message = json["message"] as? [String: Any],
           let usage = message["usage"] as? [String: Any] {
            accumulateUsage(usage, into: &acc)
        }
        // Content for conversation record
        let role = (json["role"] as? String ?? (json["message"] as? [String: Any])?["role"] as? String ?? json["type"] as? String ?? "").lowercased()
        let content = extractContent(from: json)

        if !content.isEmpty {
            let isAssistant = role == "model" || role == "assistant" || role == "gemini"
            if role == "user" {
                acc.userChars += content.count
                acc.userWords += content.split { $0.isWhitespace || $0.isNewline }.count
                acc.messageCount += 1
                if includeConversationBodies {
                    if acc.firstUserText == nil {
                        acc.firstUserText = String(content.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
                    }
                    if !acc.fullText.isEmpty { acc.fullText += "\n\n" }
                    acc.fullText += SessionLogMarkdownFormatter.transcriptTurnMarkdown(isAssistant: false, body: content)
                }
            } else if isAssistant {
                acc.assistantChars += content.count
                acc.assistantWords += content.split { $0.isWhitespace || $0.isNewline }.count
                acc.messageCount += 1
                if includeConversationBodies {
                    acc.lastAssistantText = content
                    if !acc.fullText.isEmpty { acc.fullText += "\n\n" }
                    acc.fullText += SessionLogMarkdownFormatter.transcriptTurnMarkdown(isAssistant: true, body: content)
                }
            } else if includeConversationBodies {
                if !acc.fullText.isEmpty { acc.fullText += "\n\n" }
                acc.fullText += content
            }
        }
    }

    private func accumulateUsage(_ usage: [String: Any], into acc: inout GeminiSessionAccumulator) {
        // Gemini uses promptTokenCount/candidatesTokenCount or standard names
        let input = TokenExtractionUtility.firstIntValue(in: usage, paths: [
            ["input"], ["input_tokens"], ["prompt_tokens"], ["promptTokenCount"],
            ["inputTokens"], ["promptTokens"]
        ]) ?? 0
        let output = TokenExtractionUtility.firstIntValue(in: usage, paths: [
            ["output"], ["output_tokens"], ["completion_tokens"], ["candidatesTokenCount"],
            ["outputTokens"], ["completionTokens"]
        ]) ?? 0
        let exclusiveCached = TokenExtractionUtility.firstIntValue(in: usage, paths: [
            ["cache_read_input_tokens"]
        ]) ?? 0
        let inclusiveCached = TokenExtractionUtility.firstIntValue(in: usage, paths: [
            ["cached"], ["cached_tokens"], ["cachedContentTokenCount"]
        ]) ?? 0
        let cacheRead = exclusiveCached > 0 ? exclusiveCached : inclusiveCached
        let ledgerInput = inclusiveCached > 0 && exclusiveCached == 0 ? max(input - inclusiveCached, 0) : input

        if ledgerInput > 0 || output > 0 || cacheRead > 0 {
            acc.inputTokens += ledgerInput
            acc.outputTokens += output
            acc.cacheReadTokens += cacheRead
        }
    }

    private func extractContent(from json: [String: Any]) -> String {
        // Direct content field
        if let text = json["content"] as? String { return text }
        // Nested message.content
        if let message = json["message"] as? [String: Any] {
            if let text = message["content"] as? String { return text }
            if let parts = message["content"] as? [[String: Any]] {
                return parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
            }
        }
        // Gemini parts format
        if let parts = json["parts"] as? [[String: Any]] {
            return parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        return ""
    }

    // MARK: - Build Result

    private func buildResult(
        acc: GeminiSessionAccumulator,
        sessionId: String,
        projectName: String,
        mtime: Date?,
        includeConversationBodies: Bool
    ) throws -> (usage: TokenUsage?, conversation: ConversationRecord?)? {
        var inputTokens = acc.inputTokens
        var outputTokens = acc.outputTokens

        let hasUsage = inputTokens > 0 || outputTokens > 0 || acc.cacheReadTokens > 0

        // Fallback estimation
        if !hasUsage {
            guard acc.userChars + acc.assistantChars > 0 else { return nil }
            let estimated = TokenExtractionUtility.estimateFallbackTokens(
                userVisibleChars: acc.userChars,
                assistantVisibleChars: acc.assistantChars,
                assistantReasoningChars: 0,
                userMessageCount: max(acc.messageCount / 2, 1),
                assistantMessageCount: max(acc.messageCount / 2, 1)
            )
            inputTokens = estimated.input
            outputTokens = estimated.output
        }

        guard inputTokens > 0 || outputTokens > 0 || acc.cacheReadTokens > 0 else { return nil }

        let model = acc.model ?? "gemini"
        let pricing = ModelPricing.lookup(model: model)
        let cost = try pricing.cost(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: acc.cacheReadTokens
        )

        let startTime = acc.startTime ?? Date()
        let endTime = acc.endTime ?? startTime

        let usage = TokenUsage(
            provider: .geminiCLI,
            sessionId: sessionId,
            projectName: projectName,
            model: model,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheCreationTokens: 0,
            cacheReadTokens: acc.cacheReadTokens,
            costUSD: cost,
            startTime: startTime,
            endTime: endTime,
            provenanceMethod: .providerLog,
            provenanceConfidence: .exact
        )

        let conversation = includeConversationBodies
            ? ConversationRecord(
                id: ConversationRecord.stableId(provider: .geminiCLI, sessionId: sessionId),
                provider: .geminiCLI,
                sessionId: sessionId,
                projectName: projectName,
                startTime: startTime,
                endTime: endTime,
                messageCount: acc.messageCount,
                userWordCount: acc.userWords,
                assistantWordCount: acc.assistantWords,
                keyFiles: [],
                keyCommands: [],
                keyTools: [],
                inferredTaskTitle: acc.firstUserText ?? projectName,
                lastAssistantMessage: acc.lastAssistantText,
                fullText: acc.fullText,
                indexedAt: Date(),
                fileModifiedAt: mtime,
                summary: nil
            )
            : nil

        return (usage, conversation)
    }

    private func modificationDate(of url: URL) -> Date? {
        (try? fileManager.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date // try?-ok(optional mtime read)
    }
}

private struct GeminiUsageCacheEntry: Codable, Equatable, Sendable {
    let signature: FileSignature
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let model: String
    let startTime: Date
    let endTime: Date
    let costUSD: Double

    init(signature: FileSignature, usage: TokenUsage) {
        self.signature = signature
        self.inputTokens = usage.inputTokens
        self.outputTokens = usage.outputTokens
        self.cacheReadTokens = usage.cacheReadTokens
        self.model = usage.model
        self.startTime = usage.startTime
        self.endTime = usage.endTime
        self.costUSD = usage.costUSD
    }

    func makeUsage(sessionId: String, projectName: String) -> TokenUsage {
        TokenUsage(
            provider: .geminiCLI,
            sessionId: sessionId,
            projectName: projectName,
            model: model,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheCreationTokens: 0,
            cacheReadTokens: cacheReadTokens,
            costUSD: costUSD,
            startTime: startTime,
            endTime: endTime,
            provenanceMethod: .providerLog,
            provenanceConfidence: .exact
        )
    }
}

private struct GeminiSessionAccumulator {
    var inputTokens = 0
    var outputTokens = 0
    var cacheReadTokens = 0
    var model: String?
    var startTime: Date?
    var endTime: Date?
    var userChars = 0
    var assistantChars = 0
    var userWords = 0
    var assistantWords = 0
    var messageCount = 0
    var fullText = ""
    var firstUserText: String?
    var lastAssistantText = ""
}
