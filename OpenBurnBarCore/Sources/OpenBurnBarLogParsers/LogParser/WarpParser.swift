#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#endif
import Foundation
import OpenBurnBarKernel
import OpenBurnBarParserSupport

// MARK: - Warp Parser

/// Parses Warp local network logs for AI/agent activity.
///
/// Warp does not currently expose a documented local token ledger. This parser
/// preserves exact usage objects when present and otherwise emits conservative,
/// low-confidence estimates for agent prompt telemetry that includes text.
///
/// Idle usage ticks resume unchanged `warp_network*.log` files from a
/// mtime+size disk cache (token totals and computed session ids only —
/// never conversation bodies). Append-only growth resumes from the last
/// complete Body when the head digest still matches.
public final class WarpParser: LogParser, Sendable {
    public let provider: AgentProvider = .warp

    private let logDirectory: URL
    private let fileManager: FileManager
    private let cacheStore: ParserDiskCacheStore<WarpLogCacheEntry>
    private let sessionScanCount = Locked(0)
    private let sessionCacheHitCount = Locked(0)
    private let sessionAppendResumeCount = Locked(0)

    private static let headDigestSpan = 4096

    public init(
        logDirectory: URL? = nil,
        fileManager: FileManager = .default,
        appPaths: OpenBurnBarAppPaths = .live()
    ) {
        self.logDirectory = logDirectory ?? URL(
            fileURLWithPath: ("~/Library/Application Support/dev.warp.Warp-Stable" as NSString).expandingTildeInPath,
            isDirectory: true
        )
        self.fileManager = fileManager
        self.cacheStore = ParserDiskCacheStore(
            cacheURL: Self.cacheURL(
                logDirectory: self.logDirectory,
                usesDirectoryOverride: logDirectory != nil,
                appPaths: appPaths
            ),
            fileManager: fileManager,
            schemaVersion: 2,
            logLabel: "WarpParser"
        )
    }

    var lastSessionScanCount: Int { sessionScanCount.read() }
    var lastSessionCacheHitCount: Int { sessionCacheHitCount.read() }
    var lastSessionAppendResumeCount: Int { sessionAppendResumeCount.read() }

    private static func cacheURL(
        logDirectory: URL,
        usesDirectoryOverride: Bool,
        appPaths: OpenBurnBarAppPaths
    ) -> URL {
        guard usesDirectoryOverride else { return appPaths.warpParserCacheURL }
        let directory = logDirectory.pathExtension == "log"
            ? logDirectory.deletingLastPathComponent()
            : logDirectory
        return directory.appendingPathComponent(".obb-warp-parser-cache.plist")
    }

    public func parse() async throws -> ParseResult {
        try await parse(options: .default)
    }

    public func parse(options: LogParseOptions) async throws -> ParseResult {
        sessionScanCount.write(0)
        sessionCacheHitCount.write(0)
        sessionAppendResumeCount.write(0)
        guard fileManager.fileExists(atPath: logDirectory.path) else {
            return ParseResult(usages: [], conversations: [])
        }

        let logFiles = candidateLogFiles()
        guard !logFiles.isEmpty else {
            return ParseResult(usages: [], conversations: [])
        }

        let gate = ParserFileReadGate(options: options, fileManager: fileManager)
        var usages: [TokenUsage] = []
        var conversations: [ConversationRecord] = []
        var seenUsageKeys = Set<String>()
        var seenConversationIDs = Set<String>()
        var parseCache = cacheStore.load()
        var activePaths = Set<String>()
        var cacheMutated = false
        defer {
            if cacheMutated {
                cacheStore.persist(parseCache)
            }
        }

        for file in logFiles {
            let cacheKey = file.standardizedFileURL.path
            activePaths.insert(cacheKey)
            guard try gate.shouldRead(file) else { continue }
            let signature = FileSignature(for: file, using: fileManager)
            if !options.includeConversationBodies,
               let signature,
               let cached = parseCache.fileEntries[cacheKey],
               cached.signature == signature {
                sessionCacheHitCount.withLock { $0 += 1 }
                for session in cached.sessions {
                    let usage = session.makeUsage(provider: .warp)
                    let key = "\(usage.sessionId)|\(usage.model)|\(usage.startTime.timeIntervalSince1970)|\(usage.totalTokens)"
                    guard seenUsageKeys.insert(key).inserted else { continue }
                    usages.append(usage)
                }
                continue
            }

            if !options.includeConversationBodies,
               let signature,
               let cached = parseCache.fileEntries[cacheKey],
               let resumed = try resumeAppendIfPossible(
                   file: file,
                   signature: signature,
                   cached: cached
               ) {
                sessionScanCount.withLock { $0 += 1 }
                sessionAppendResumeCount.withLock { $0 += 1 }
                for usage in resumed.usages {
                    let key = "\(usage.sessionId)|\(usage.model)|\(usage.startTime.timeIntervalSince1970)|\(usage.totalTokens)"
                    guard seenUsageKeys.insert(key).inserted else { continue }
                    usages.append(usage)
                }
                parseCache.fileEntries[cacheKey] = resumed.entry
                cacheMutated = true
                continue
            }

            sessionScanCount.withLock { $0 += 1 }
            guard let parsed = try parseLogFile(
                file,
                signature: signature,
                includeConversationBodies: options.includeConversationBodies
            ) else {
                continue
            }
            for usage in parsed.usages {
                let key = "\(usage.sessionId)|\(usage.model)|\(usage.startTime.timeIntervalSince1970)|\(usage.totalTokens)"
                guard seenUsageKeys.insert(key).inserted else { continue }
                usages.append(usage)
            }
            for conversation in parsed.conversations {
                guard seenConversationIDs.insert(conversation.id).inserted else { continue }
                conversations.append(conversation)
            }
            if let entry = parsed.entry {
                parseCache.fileEntries[cacheKey] = entry
                cacheMutated = true
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

    private func resumeAppendIfPossible(
        file: URL,
        signature: FileSignature,
        cached: WarpLogCacheEntry
    ) throws -> (usages: [TokenUsage], entry: WarpLogCacheEntry)? {
        guard signature.sizeBytes >= cached.signature.sizeBytes,
              cached.byteOffset >= 0,
              cached.byteOffset <= signature.sizeBytes,
              cached.headDigestLength > 0,
              cached.headDigestLength <= Self.headDigestSpan,
              Int64(cached.headDigestLength) <= signature.sizeBytes else {
            return nil
        }
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil } // try?-ok(append probe)
        defer { try? handle.close() } // try?-ok(handle teardown)

        let observedHead = ParserScanDigest.headDigestHex(handle: handle, length: cached.headDigestLength)
        guard observedHead == cached.headDigest else { return nil }

        let fileModifiedAt = Date(timeIntervalSince1970: signature.modifiedAt)
        if cached.byteOffset == signature.sizeBytes {
            return (
                cached.sessions.map { $0.makeUsage(provider: .warp) },
                WarpLogCacheEntry(
                    signature: signature,
                    sessions: cached.sessions,
                    byteOffset: cached.byteOffset,
                    headDigest: cached.headDigest,
                    headDigestLength: cached.headDigestLength
                )
            )
        }

        do {
            try handle.seek(toOffset: UInt64(cached.byteOffset))
        } catch {
            return nil
        }
        guard let tailData = try? handle.readToEnd(),
              let tail = String(data: tailData, encoding: .utf8) else {
            return nil
        }
        let scan = Self.extractBodyJSONScan(from: tail)
        var fileUsages = cached.sessions.map { $0.makeUsage(provider: .warp) }
        for object in scan.objects {
            let records = try parseBodyObject(object, sourceFile: file, fileModifiedAt: fileModifiedAt)
            fileUsages.append(contentsOf: records.usages)
        }
        let consumed = scan.objects.isEmpty ? 0 : scan.endUTF8Offset
        return (
            fileUsages,
            WarpLogCacheEntry(
                signature: signature,
                usages: fileUsages,
                byteOffset: cached.byteOffset + Int64(consumed),
                headDigest: cached.headDigest,
                headDigestLength: cached.headDigestLength
            )
        )
    }

    private func parseLogFile(
        _ file: URL,
        signature: FileSignature?,
        includeConversationBodies: Bool
    ) throws -> (usages: [TokenUsage], conversations: [ConversationRecord], entry: WarpLogCacheEntry?)? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil } // try?-ok(log open)
        defer { try? handle.close() } // try?-ok(handle teardown)
        let fileSize = signature?.sizeBytes
            ?? Int64((try? fileManager.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0)
        let headDigestLength = Int(min(Int64(Self.headDigestSpan), max(fileSize, 0)))
        let headDigest = ParserScanDigest.headDigestHex(handle: handle, length: headDigestLength)
        try? handle.seek(toOffset: 0) // try?-ok(rewind after head digest)
        guard let data = try? handle.readToEnd(),
              let content = String(data: data, encoding: .utf8) else {
            return nil
        }
        let fileModifiedAt = signature.map { Date(timeIntervalSince1970: $0.modifiedAt) }
            ?? (try? fileManager.attributesOfItem(atPath: file.path)[.modificationDate]) as? Date
        var fileUsages: [TokenUsage] = []
        var conversations: [ConversationRecord] = []
        let scan = Self.extractBodyJSONScan(from: content)
        for object in scan.objects {
            let records = try parseBodyObject(object, sourceFile: file, fileModifiedAt: fileModifiedAt)
            fileUsages.append(contentsOf: records.usages)
            guard includeConversationBodies else { continue }
            conversations.append(contentsOf: records.conversations)
        }
        let entry = signature.map {
            WarpLogCacheEntry(
                signature: $0,
                usages: fileUsages,
                byteOffset: Int64(scan.endUTF8Offset),
                headDigest: headDigest,
                headDigestLength: headDigestLength
            )
        }
        return (fileUsages, conversations, entry)
    }

    // MARK: - File Discovery

    private func candidateLogFiles() -> [URL] {
        if logDirectory.pathExtension == "log" {
            return [logDirectory]
        }

        let files = (try? fileManager.contentsOfDirectory( // try?-ok(empty on read fail)
            at: logDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return files
            .filter { file in
                let name = file.lastPathComponent
                return name.hasPrefix("warp_network") && name.hasSuffix(".log")
            }
            .sorted {
                let lhs = ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) // try?-ok(sort fallback date)
                let rhs = ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) // try?-ok(sort fallback date)
                return lhs < rhs
            }
    }

    // MARK: - Body Parsing

    private func parseBodyObject(
        _ object: [String: Any],
        sourceFile: URL,
        fileModifiedAt: Date?
    ) throws -> (usages: [TokenUsage], conversations: [ConversationRecord]) {
        var usages: [TokenUsage] = []
        var conversations: [ConversationRecord] = []

        if let batch = object["batch"] as? [[String: Any]] {
            for item in batch {
                let parsed = try parseEventDictionary(item, sourceFile: sourceFile, fileModifiedAt: fileModifiedAt)
                usages.append(contentsOf: parsed.usages)
                conversations.append(contentsOf: parsed.conversations)
            }
            return (usages, conversations)
        }

        let parsed = try parseEventDictionary(object, sourceFile: sourceFile, fileModifiedAt: fileModifiedAt)
        usages.append(contentsOf: parsed.usages)
        conversations.append(contentsOf: parsed.conversations)
        return (usages, conversations)
    }

    private func parseEventDictionary(
        _ event: [String: Any],
        sourceFile: URL,
        fileModifiedAt: Date?
    ) throws -> (usages: [TokenUsage], conversations: [ConversationRecord]) {
        let context = WarpParseContext.from(event)
        let exactUsages = try collectExactUsages(in: event, context: context)

        if !exactUsages.isEmpty {
            let conversations = exactUsages.compactMap { usage in
                makeConversation(
                    sessionId: usage.sessionId,
                    projectName: usage.projectName,
                    startTime: usage.startTime,
                    endTime: usage.endTime,
                    userText: context.userText,
                    assistantText: context.assistantText,
                    title: context.title,
                    sourceFile: sourceFile,
                    fileModifiedAt: fileModifiedAt
                )
            }
            return (exactUsages, conversations)
        }

        guard context.isAgentRelated, context.hasTranscriptText else {
            return ([], [])
        }

        let usage = try makeEstimatedUsage(context: context, sourceFile: sourceFile)
        let conversation = makeConversation(
            sessionId: usage.sessionId,
            projectName: usage.projectName,
            startTime: usage.startTime,
            endTime: usage.endTime,
            userText: context.userText,
            assistantText: context.assistantText,
            title: context.title,
            sourceFile: sourceFile,
            fileModifiedAt: fileModifiedAt
        )

        return (conversation.map { ([usage], [$0]) } ?? ([usage], []))
    }

    private func collectExactUsages(
        in dictionary: [String: Any],
        context: WarpParseContext
    ) throws -> [TokenUsage] {
        var records: [TokenUsage] = []
        try collectExactUsages(in: dictionary, context: context, records: &records)
        return records
    }

    private func collectExactUsages(
        in dictionary: [String: Any],
        context: WarpParseContext,
        records: inout [TokenUsage]
    ) throws {
        let mergedContext = context.merging(WarpParseContext.from(dictionary))

        if let usageDictionary = Self.usageDictionary(from: dictionary) {
            let extracted = TokenExtractionUtility.extractUsageTokens(
                usageDictionary,
                inputHint: mergedContext.userText.count,
                outputHint: mergedContext.assistantText.count
            )
            if extracted.hasNoExplicitBuckets == false {
                records.append(try makeExactUsage(from: extracted, context: mergedContext, source: dictionary))
            }
        } else if Self.containsUsageKeys(dictionary) {
            let extracted = TokenExtractionUtility.extractUsageTokens(
                dictionary,
                inputHint: mergedContext.userText.count,
                outputHint: mergedContext.assistantText.count
            )
            if extracted.hasNoExplicitBuckets == false {
                records.append(try makeExactUsage(from: extracted, context: mergedContext, source: dictionary))
            }
        }

        for value in dictionary.values {
            if let nested = value as? [String: Any] {
                try collectExactUsages(in: nested, context: mergedContext, records: &records)
            } else if let array = value as? [[String: Any]] {
                for item in array {
                    try collectExactUsages(in: item, context: mergedContext, records: &records)
                }
            }
        }
    }

    private func makeExactUsage(
        from extracted: ExtractedTokenUsage,
        context: WarpParseContext,
        source: [String: Any]
    ) throws -> TokenUsage {
        let timestamp = context.timestamp ?? Date()
        let model = context.model ?? "warp"
        let sessionId = context.sessionId ?? Self.stableHash([
            "exact",
            model,
            String(timestamp.timeIntervalSince1970),
            String(extracted.input),
            String(extracted.output),
            String(extracted.cacheRead)
        ].joined(separator: "|"))
        let confidence: UsageProvenanceConfidence = extracted.hasExplicitPrimaryBucket ? .exact : .derivedExact
        let cost = try ModelPricing.lookup(model: model).cost(
            inputTokens: extracted.input,
            outputTokens: extracted.output,
            cacheCreationTokens: extracted.cacheCreation,
            cacheReadTokens: extracted.cacheRead
        )

        return TokenUsage(
            provider: .warp,
            sessionId: sessionId,
            projectName: context.projectName ?? "Warp",
            model: model,
            inputTokens: extracted.input,
            outputTokens: extracted.output,
            cacheCreationTokens: extracted.cacheCreation,
            cacheReadTokens: extracted.cacheRead,
            reasoningTokens: extracted.reasoningTokens,
            costUSD: cost,
            startTime: timestamp,
            endTime: timestamp,
            provenanceMethod: .providerLog,
            provenanceConfidence: confidence,
            estimatorVersion: ""
        )
    }

    private func makeEstimatedUsage(context: WarpParseContext, sourceFile: URL) throws -> TokenUsage {
        let timestamp = context.timestamp ?? Date()
        let userChars = context.userText.count
        let assistantChars = context.assistantText.count
        let inputTokens = TokenExtractionUtility.estimatedTokenCount(for: max(userChars, 1), charsPerToken: 3.8)
        let outputTokens = TokenExtractionUtility.estimatedTokenCount(for: assistantChars, charsPerToken: 3.8)
        let model = context.model ?? context.agentName ?? "warp-agent"
        let sessionId = context.sessionId ?? Self.stableHash([
            "estimate",
            sourceFile.path,
            String(timestamp.timeIntervalSince1970),
            model,
            context.userText,
            context.assistantText
        ].joined(separator: "|"))
        let cost = try ModelPricing.lookup(model: model).cost(inputTokens: inputTokens, outputTokens: outputTokens)

        return TokenUsage(
            provider: .warp,
            sessionId: sessionId,
            projectName: context.projectName ?? "Warp",
            model: model,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            costUSD: cost,
            startTime: timestamp,
            endTime: timestamp,
            provenanceMethod: .heuristicEstimate,
            provenanceConfidence: .lowConfidenceEstimate,
            estimatorVersion: "warp-v1"
        )
    }

    private func makeConversation(
        sessionId: String,
        projectName: String,
        startTime: Date,
        endTime: Date,
        userText: String,
        assistantText: String,
        title: String?,
        sourceFile: URL,
        fileModifiedAt: Date?
    ) -> ConversationRecord? {
        let sections = [
            userText.isEmpty ? nil : "User: \(userText)",
            assistantText.isEmpty ? nil : "Assistant: \(assistantText)"
        ].compactMap { $0 }
        guard !sections.isEmpty else { return nil }

        let fullText = sections.joined(separator: "\n\n")
        return ConversationRecord(
            id: ConversationRecord.stableId(provider: .warp, sessionId: sessionId),
            provider: .warp,
            sessionId: sessionId,
            projectName: projectName,
            startTime: startTime,
            endTime: endTime,
            messageCount: sections.count,
            userWordCount: Self.wordCount(userText),
            assistantWordCount: Self.wordCount(assistantText),
            keyFiles: [],
            keyCommands: [],
            keyTools: [],
            inferredTaskTitle: title ?? String(userText.prefix(80)).trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Warp Agent Session",
            lastAssistantMessage: assistantText,
            fullText: fullText,
            fileModifiedAt: fileModifiedAt
        )
    }

    // MARK: - JSON Body Extraction

    public static func extractBodyJSONObjects(from content: String) -> [[String: Any]] {
        extractBodyJSONScan(from: content).objects
    }

    static func extractBodyJSONScan(from content: String) -> (objects: [[String: Any]], endUTF8Offset: Int) {
        var objects: [[String: Any]] = []
        var searchStart = content.startIndex
        var lastCompleteUTF8Offset = 0

        while let markerRange = content.range(of: "Body ", range: searchStart..<content.endIndex) {
            var index = markerRange.upperBound
            while index < content.endIndex, content[index].isWhitespace {
                index = content.index(after: index)
            }
            guard index < content.endIndex, content[index] == "{" || content[index] == "[" else {
                searchStart = markerRange.upperBound
                continue
            }

            guard let end = balancedJSONEnd(in: content, from: index) else {
                searchStart = markerRange.upperBound
                continue
            }

            let jsonText = String(content[index...end])
            if let data = jsonText.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) { // try?-ok(skip malformed JSON)
                if let dictionary = json as? [String: Any] {
                    objects.append(dictionary)
                } else if let array = json as? [[String: Any]] {
                    objects.append(contentsOf: array)
                }
            }

            let completeEnd = content.index(after: end)
            lastCompleteUTF8Offset = content[..<completeEnd].utf8.count
            searchStart = completeEnd
        }

        return (objects, lastCompleteUTF8Offset)
    }

    private static func balancedJSONEnd(in content: String, from start: String.Index) -> String.Index? {
        var stack: [Character] = []
        var index = start
        var inString = false
        var isEscaped = false

        while index < content.endIndex {
            let char = content[index]

            if inString {
                if isEscaped {
                    isEscaped = false
                } else if char == "\\" {
                    isEscaped = true
                } else if char == "\"" {
                    inString = false
                }
            } else {
                switch char {
                case "\"":
                    inString = true
                case "{", "[":
                    stack.append(char == "{" ? "}" : "]")
                case "}", "]":
                    guard stack.last == char else { return nil }
                    stack.removeLast()
                    if stack.isEmpty {
                        return index
                    }
                default:
                    break
                }
            }

            index = content.index(after: index)
        }

        return nil
    }

    // MARK: - Usage Field Helpers

    private static func usageDictionary(from dictionary: [String: Any]) -> [String: Any]? {
        for key in ["usage", "token_usage", "tokenUsage", "token_counts", "tokenCounts"] {
            if let usage = dictionary[key] as? [String: Any],
               containsUsageKeys(usage) {
                return usage
            }
        }
        return nil
    }

    private static func containsUsageKeys(_ dictionary: [String: Any]) -> Bool {
        let keys = Set(dictionary.keys.map { $0.lowercased() })
        return !keys.isDisjoint(with: [
            "input_tokens",
            "prompt_tokens",
            "inputtokens",
            "prompttokens",
            "output_tokens",
            "completion_tokens",
            "outputtokens",
            "completiontokens",
            "cache_read_input_tokens",
            "cache_creation_input_tokens",
            "total_tokens",
            "totaltokens"
        ])
    }

    private static func stableHash(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func wordCount(_ text: String) -> Int {
        text.split { $0.isWhitespace || $0.isNewline }.count
    }
}

private struct WarpLogCacheEntry: Codable, Equatable, Sendable {
    let signature: FileSignature
    let sessions: [CachedNamedUsage]
    let byteOffset: Int64
    let headDigest: String
    let headDigestLength: Int

    init(
        signature: FileSignature,
        sessions: [CachedNamedUsage],
        byteOffset: Int64,
        headDigest: String,
        headDigestLength: Int
    ) {
        self.signature = signature
        self.sessions = sessions
        self.byteOffset = byteOffset
        self.headDigest = headDigest
        self.headDigestLength = headDigestLength
    }

    init(
        signature: FileSignature,
        usages: [TokenUsage],
        byteOffset: Int64,
        headDigest: String,
        headDigestLength: Int
    ) {
        self.init(
            signature: signature,
            sessions: usages.map { CachedNamedUsage(sessionId: $0.sessionId, usage: $0) },
            byteOffset: byteOffset,
            headDigest: headDigest,
            headDigestLength: headDigestLength
        )
    }
}

private struct WarpParseContext {
    var sessionId: String?
    var projectName: String?
    var model: String?
    var agentName: String?
    var timestamp: Date?
    var userText = ""
    var assistantText = ""
    var title: String?
    var isAgentRelated = false

    var hasTranscriptText: Bool {
        !userText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        !assistantText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func from(_ dictionary: [String: Any]) -> WarpParseContext {
        var context = WarpParseContext()
        let event = Self.string(in: dictionary, keys: ["event", "type", "operationName"])
        context.isAgentRelated = event.map(Self.isAgentEvent(_:)) ?? false

        context.sessionId = Self.string(in: dictionary, keys: [
            "session_id", "sessionId", "conversation_id", "conversationId", "thread_id", "threadId",
            "request_id", "requestId", "trace_id", "traceId", "terminal_session_id", "terminalSessionId"
        ])
        if context.sessionId == nil,
           let integrations = dictionary["integrations"] as? [String: Any],
           let amplitude = integrations["Amplitude"] as? [String: Any] {
            context.sessionId = Self.string(in: amplitude, keys: ["session_id", "sessionId"])
        }

        context.model = Self.string(in: dictionary, keys: ["model", "model_name", "modelName", "model_id", "modelId"])
        context.agentName = Self.string(in: dictionary, keys: ["agent_name", "agentName", "agent", "name"])
        context.projectName = Self.projectName(from: dictionary)
        context.timestamp = Self.date(in: dictionary, keys: ["originalTimestamp", "timestamp", "created_at", "createdAt", "time"])
        context.title = Self.string(in: dictionary, keys: ["title", "summary", "name"])

        let userText = Self.text(in: dictionary, keys: [
            "prompt", "query", "input", "input_buffer", "inputBuffer", "user_input", "userInput",
            "message", "text", "content", "command"
        ])
        let assistantText = Self.text(in: dictionary, keys: [
            "response", "answer", "completion", "output", "assistant_message", "assistantMessage"
        ])
        context.userText = userText ?? ""
        context.assistantText = assistantText ?? ""

        if let properties = dictionary["properties"] as? [String: Any] {
            context = context.merging(Self.from(properties))
        }
        if let payload = dictionary["payload"] as? [String: Any] {
            context = context.merging(Self.from(payload))
        }
        if let variables = dictionary["variables"] as? [String: Any] {
            context = context.merging(Self.from(variables))
        }

        return context
    }

    func merging(_ other: WarpParseContext) -> WarpParseContext {
        WarpParseContext(
            sessionId: other.sessionId ?? sessionId,
            projectName: other.projectName ?? projectName,
            model: other.model ?? model,
            agentName: other.agentName ?? agentName,
            timestamp: other.timestamp ?? timestamp,
            userText: other.userText.isEmpty ? userText : other.userText,
            assistantText: other.assistantText.isEmpty ? assistantText : other.assistantText,
            title: other.title ?? title,
            isAgentRelated: isAgentRelated || other.isAgentRelated
        )
    }

    private static let agentEventPattern = try? NSRegularExpression( // try?-ok(literal regex pattern)
        pattern: #"(^|[._:\-\s])([Aa][Gg][Ee][Nn][Tt])($|[._:\-\s]|[A-Z])"#
    )

    private static func isAgentEvent(_ event: String) -> Bool {
        let range = NSRange(event.startIndex..<event.endIndex, in: event)
        return agentEventPattern?.firstMatch(in: event, range: range) != nil
    }

    private static func string(in dictionary: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = dictionary[key] {
                if let string = value as? String {
                    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { return trimmed }
                }
                if let number = value as? NSNumber {
                    return number.stringValue
                }
            }
        }
        return nil
    }

    private static func text(in dictionary: [String: Any], keys: [String]) -> String? {
        guard let text = string(in: dictionary, keys: keys) else { return nil }
        let lower = text.lowercased()
        if lower.hasPrefix("v0.20") || lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            return nil
        }
        return text
    }

    private static func projectName(from dictionary: [String: Any]) -> String? {
        if let cwd = string(in: dictionary, keys: ["cwd", "workspace", "workspace_path", "workspacePath", "project_path", "projectPath"]) {
            return URL(fileURLWithPath: cwd).lastPathComponent.nilIfEmpty ?? cwd
        }
        return string(in: dictionary, keys: ["project", "project_name", "projectName", "repo", "repository"])
    }

    private static func date(in dictionary: [String: Any], keys: [String]) -> Date? {
        for key in keys {
            guard let value = dictionary[key] else { continue }
            if let string = value as? String {
                if let date = ThreadSafeISO8601DateFormatter.parseBasic(string) {
                    return date
                }
                if let double = Double(string) {
                    return TimestampNormalizationUtility.date(fromEpoch: double)
                }
            } else if let double = value as? Double {
                return TimestampNormalizationUtility.date(fromEpoch: double)
            } else if let int = value as? Int {
                return TimestampNormalizationUtility.date(fromEpoch: Double(int))
            }
        }
        return nil
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
