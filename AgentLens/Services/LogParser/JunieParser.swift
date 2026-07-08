import Foundation
import OpenBurnBarCore

// MARK: - Junie Parser

/// JunieParser extracts token usage from JetBrains Junie CLI sessions.
///
/// On-disk layout (documented by Junie's own `junie-cli-user-disk-storage`
/// reference and verified against a live install):
///
///     ~/.junie/sessions/index.jsonl              — session index, one JSON per line
///     ~/.junie/sessions/<sessionId>/events.jsonl — session event stream (the transcript)
///     ~/.junie/sessions/<sessionId>/state.json   — latest saved agent state
///
/// Session ids look like `session-260701-191559-1tv1`. The project a session
/// belongs to is carried as a `projectPath` field (index records and the
/// `~/.junie/processes/*.json` latches), not by directory nesting, so the
/// parser reads the index first and falls back to per-session state.
///
/// Field names inside `events.jsonl` vary across Junie builds, so extraction
/// is defensive: explicit usage buckets win wherever they appear (top level,
/// event payload, or message), and sessions without explicit usage fall back
/// to `TokenExtractionUtility.estimateFallbackTokens` — the same ladder the
/// Factory Droid parser uses.
final class JunieParser: LogParser, Sendable {
    let provider: AgentProvider = .junie
    private let fileManager: FileManager
    private let appPaths: OpenBurnBarAppPaths
    private let cacheURL: URL
    private let cacheStore: ParserDiskCacheStore<JunieCacheEntry>
    private let sessionsDirectoryOverride: URL?

    init(
        fileManager: FileManager = .default,
        appPaths: OpenBurnBarAppPaths = .live(),
        sessionsDirectoryOverride: URL? = nil
    ) {
        self.fileManager = fileManager
        self.appPaths = appPaths
        self.sessionsDirectoryOverride = sessionsDirectoryOverride
        self.cacheURL = appPaths.junieParserCacheURL
        self.cacheStore = ParserDiskCacheStore(
            cacheURL: cacheURL,
            fileManager: fileManager,
            schemaVersion: 1,
            logLabel: "JunieParser"
        )
        _ = try? OpenBurnBarMigration.prepareSupportDirectory(fileManager: fileManager, paths: appPaths) // try?-ok(best-effort dir prep)
    }

    func parse() async throws -> ParseResult {
        try await parse(options: .default)
    }

    func parse(options: LogParseOptions) async throws -> ParseResult {
        let sessionsURL = sessionsDirectoryOverride
            ?? URL(fileURLWithPath: NSString(string: provider.logDirectory).expandingTildeInPath)

        guard fileManager.fileExists(atPath: sessionsURL.path) else {
            return ParseResult(usages: [], conversations: [])
        }

        var usages: [TokenUsage] = []
        var conversations: [ConversationRecord] = []
        var parseCache = cacheStore.load()
        var activePaths = Set<String>()
        var cacheMutated = false

        let indexProjects = sessionIndexProjects(sessionsURL: sessionsURL)

        let sessionDirs = (try? fileManager.contentsOfDirectory(at: sessionsURL, includingPropertiesForKeys: [.isDirectoryKey])) // try?-ok(unreadable sessions root yields empty result)
            .map { $0.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true } } // try?-ok(non-dir filtered out)
            ?? []

        for sessionDir in sessionDirs {
            let sessionId = sessionDir.lastPathComponent
            let eventsFile = sessionDir.appendingPathComponent("events.jsonl")
            let stateFile = sessionDir.appendingPathComponent("state.json")
            guard fileManager.fileExists(atPath: eventsFile.path) else { continue }

            let cacheKey = eventsFile.standardizedFileURL.path
            activePaths.insert(cacheKey)

            let signature = compositeSignature(eventsFile: eventsFile, stateFile: stateFile)
            if let signature, let cached = parseCache.fileEntries[cacheKey], cached.signature == signature {
                let cached = updateCacheEntry(
                    cached,
                    signature: signature,
                    sessionId: sessionId,
                    eventsFile: eventsFile,
                    stateFile: stateFile,
                    indexProjectPath: indexProjects[sessionId],
                    includeConversationBodies: options.includeConversationBodies,
                    parseCache: &parseCache,
                    cacheKey: cacheKey,
                    cacheMutated: &cacheMutated
                )
                appendEntry(
                    usage: cached.usage,
                    conversation: cached.conversation,
                    includeConversation: options.includeConversationBodies,
                    usages: &usages,
                    conversations: &conversations
                )
            } else {
                // try?-ok(best-effort session parse)
                let parsed = try? parseSession(
                    sessionId: sessionId,
                    eventsFile: eventsFile,
                    stateFile: stateFile,
                    indexProjectPath: indexProjects[sessionId]
                )
                appendEntry(
                    usage: parsed?.usage,
                    conversation: parsed?.conversation,
                    includeConversation: options.includeConversationBodies,
                    usages: &usages,
                    conversations: &conversations
                )
                if let signature {
                    parseCache.fileEntries[cacheKey] = JunieCacheEntry(
                        signature: signature,
                        usage: parsed?.usage,
                        conversation: options.includeConversationBodies ? parsed?.conversation : nil
                    )
                    cacheMutated = true
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

        if cacheMutated {
            cacheStore.persist(parseCache)
        }

        return ParseResult(usages: usages, conversations: conversations)
    }

    // MARK: Session index

    /// Reads `sessions/index.jsonl` and maps session id → project path.
    /// Index records are the durable source for the session ↔ project
    /// association (the `processes/*.json` latches only exist while a
    /// session is alive).
    private func sessionIndexProjects(sessionsURL: URL) -> [String: String] {
        let indexURL = sessionsURL.appendingPathComponent("index.jsonl")
        guard let handle = try? FileHandle(forReadingFrom: indexURL) else { return [:] } // try?-ok(missing index falls back to state.json)
        defer { try? handle.close() } // try?-ok(handle teardown)

        var projects: [String: String] = [:]
        for line in handle.readAllUTF8Lines() {
            guard let data = line.data(using: .utf8),
                  let json = Self.decodeJSONObject(from: data) else { // try?-ok(bad index line skipped)
                continue
            }
            guard let sessionId = firstString(in: json, keys: ["sessionId", "session_id", "id"]) else { continue }
            if let projectPath = firstString(in: json, keys: ["projectPath", "project_path", "projectDir", "project", "cwd", "workingDirectory"]) {
                projects[sessionId] = projectPath
            }
        }
        return projects
    }

    // MARK: Session parsing

    /// Token totals and session metadata accumulated while parsing one session.
    private struct SessionTokenData {
        var input: Int = 0
        var output: Int = 0
        var cacheCreation: Int = 0
        var cacheRead: Int = 0
        var model: String = "unknown"
    }

    private func parseSession(
        sessionId: String,
        eventsFile: URL,
        stateFile: URL,
        indexProjectPath: String?
    ) throws -> (usage: TokenUsage?, conversation: ConversationRecord?)? {
        var tokenData = SessionTokenData()
        var usedExplicitUsage = false
        var userCharCount = 0
        var assistantCharCount = 0
        var assistantReasoningCharCount = 0
        var userMessageCount = 0
        var assistantMessageCount = 0
        var inlineModel: String?
        var projectPath = indexProjectPath
        var stateJSONProvidedTotals = false

        // state.json carries the latest agent state; harvest the model and
        // project path defensively. Some env values inside are encrypted
        // (EnvEncryptionService) — those are opaque strings we never touch.
        if let data = try? Data(contentsOf: stateFile), // try?-ok(missing state skipped)
           let json = Self.decodeJSONObject(from: data) { // try?-ok(malformed state skipped)
            if let model = firstString(in: json, keys: ["model", "modelId", "model_id", "modelForLaunch", "selectedModel", "llmModel"]) {
                tokenData.model = TokenExtractionUtility.normalizeModelName(model)
            }
            if projectPath == nil {
                projectPath = firstString(in: json, keys: ["projectPath", "project_path", "projectDir", "cwd", "workingDirectory"])
            }
            if let usageDict = firstDictionary(in: json, keys: ["usage", "tokenUsage", "token_usage", "llmUsage", "totalUsage"]) {
                let extracted = TokenExtractionUtility.extractUsageTokens(usageDict)
                if Self.hasExplicitUsageBuckets(extracted) {
                    tokenData.input = extracted.input
                    tokenData.output = extracted.output
                    tokenData.cacheCreation = extracted.cacheCreation
                    tokenData.cacheRead = extracted.cacheRead
                    usedExplicitUsage = true
                    stateJSONProvidedTotals = true
                }
            }
        }

        let mtime = modificationDate(of: eventsFile)
        let conv = ClaudeConversationAccumulator()

        if let handle = try? FileHandle(forReadingFrom: eventsFile) { // try?-ok(unreadable log skipped)
            defer { try? handle.close() } // try?-ok(handle teardown)
            for line in handle.readAllUTF8Lines() {
                guard let data = line.data(using: .utf8),
                      let json = Self.decodeJSONObject(from: data) else { // try?-ok(bad log line skipped)
                    continue
                }

                // Junie event records wrap their payload; unwrap the common
                // envelope keys and fall back to the record itself.
                let envelopePayload = firstDictionary(in: json, keys: ["event", "payload", "data", "body"])
                let payload = envelopePayload ?? json

                let message = firstDictionary(in: payload, keys: ["message", "chatMessage"]) ?? payload
                let role = firstString(in: message, keys: ["role", "author", "sender"])?.lowercased()
                if let content = message["content"] ?? message["text"] ?? message["parts"] {
                    let metrics = TokenExtractionUtility.contentMetrics(from: content)
                    if role == "user" {
                        let chars = metrics.visibleChars + metrics.reasoningChars
                        if chars > 0 {
                            userCharCount += chars
                            userMessageCount += 1
                        }
                    } else if role == "assistant" || role == "agent" || role == "model" {
                        let chars = metrics.visibleChars + metrics.reasoningChars
                        if chars > 0 {
                            assistantMessageCount += 1
                        }
                        assistantCharCount += metrics.visibleChars
                        assistantReasoningCharCount += metrics.reasoningChars
                    }

                    if inlineModel == nil, let detectedModel = TokenExtractionUtility.detectModelHint(from: content) {
                        inlineModel = TokenExtractionUtility.normalizeModelName(detectedModel)
                    }
                }

                if inlineModel == nil,
                   let eventModel = firstString(in: payload, keys: ["model", "modelId", "model_id", "llmModel"]) {
                    inlineModel = TokenExtractionUtility.normalizeModelName(eventModel)
                }

                // Explicit usage buckets win wherever Junie writes them.
                if let usageDict = firstDictionary(in: payload, keys: ["usage", "tokenUsage", "token_usage", "llmUsage"])
                    ?? firstDictionary(in: message, keys: ["usage", "tokenUsage", "token_usage", "llmUsage"]) {
                    let extracted = TokenExtractionUtility.extractUsageTokens(
                        usageDict,
                        inputHint: userCharCount,
                        outputHint: assistantCharCount + assistantReasoningCharCount
                    )
                    if Self.hasExplicitUsageBuckets(extracted) {
                        if usedExplicitUsage == false {
                            // First explicit usage supersedes any state.json totals of zero.
                            usedExplicitUsage = true
                        }
                        if stateJSONProvidedTotals == false {
                            tokenData.input += extracted.input
                            tokenData.output += extracted.output
                            tokenData.cacheCreation += extracted.cacheCreation
                            tokenData.cacheRead += extracted.cacheRead
                        }
                    }
                }

                // The conversation accumulator understands Claude-style lines
                // whose top-level `type` is "user"/"assistant". Junie's event
                // type tokens are its own, so when a roled message is present
                // synthesize that shape; otherwise pass the line through for
                // timeline extraction.
                if let role, role == "user" || role == "assistant" || role == "agent" || role == "model" {
                    let canonicalRole = role == "user" ? "user" : "assistant"
                    var normalizedMessage = message
                    normalizedMessage["role"] = .string(canonicalRole)
                    var normalized: [String: BurnBarJSONValue] = [
                        "type": .string(canonicalRole),
                        "message": .object(normalizedMessage)
                    ]
                    for key in ["timestamp", "created_at", "createdAt"] {
                        if let value = json[key] ?? payload[key] {
                            normalized[key] = value
                        }
                    }
                    conv.ingest(jsonLine: normalized)
                } else {
                    conv.ingest(jsonLine: json)
                    if let envelopePayload {
                        conv.ingest(jsonLine: envelopePayload)
                    }
                }
            }
        }

        conv.finalizeArrays()

        if tokenData.input == 0 && tokenData.output == 0 && tokenData.cacheCreation == 0 && tokenData.cacheRead == 0 {
            let totalChars = userCharCount + assistantCharCount + assistantReasoningCharCount
            guard totalChars > 0 else { return nil }
            let estimated = TokenExtractionUtility.estimateFallbackTokens(
                userVisibleChars: userCharCount,
                assistantVisibleChars: assistantCharCount,
                assistantReasoningChars: assistantReasoningCharCount,
                userMessageCount: userMessageCount,
                assistantMessageCount: assistantMessageCount
            )
            tokenData.input = estimated.input
            tokenData.output = estimated.output
        }

        tokenData.model = resolveModel(structuredModel: tokenData.model, inlineModel: inlineModel)

        // When the event stream has no parseable timestamps, use the log
        // file's modification time — not Date(), or every re-scan lands in "Today".
        let fallbackActivity = mtime ?? Date()
        let startTime = conv.startTime ?? fallbackActivity
        let endTime = conv.endTime ?? startTime

        guard tokenData.input > 0
            || tokenData.output > 0
            || tokenData.cacheCreation > 0
            || tokenData.cacheRead > 0 else { return nil }

        let projectName = displayProjectName(projectPath)

        let pricing = ModelPricing.lookup(model: tokenData.model, providerID: "junie")
        let cost = pricing.cost(
            inputTokens: tokenData.input,
            outputTokens: tokenData.output,
            cacheCreationTokens: tokenData.cacheCreation,
            cacheReadTokens: tokenData.cacheRead
        )

        let usage = TokenUsage(
            provider: .junie,
            sessionId: sessionId,
            projectName: projectName,
            model: tokenData.model,
            inputTokens: tokenData.input,
            outputTokens: tokenData.output,
            cacheCreationTokens: tokenData.cacheCreation,
            cacheReadTokens: tokenData.cacheRead,
            costUSD: cost,
            startTime: startTime,
            endTime: endTime,
            provenanceMethod: .providerLog,
            provenanceConfidence: usedExplicitUsage ? .exact : .lowConfidenceEstimate
        )

        let conversation = ConversationRecord(
            id: ConversationRecord.stableId(provider: .junie, sessionId: sessionId),
            provider: .junie,
            sessionId: sessionId,
            projectName: projectName,
            startTime: startTime,
            endTime: endTime,
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
            workingDirectory: projectPath,
            fileModifiedAt: mtime,
            summary: nil
        )

        return (usage, conversation)
    }

    // MARK: Helpers

    private func displayProjectName(_ projectPath: String?) -> String {
        guard let projectPath, !projectPath.isEmpty else { return "Junie" }
        let home = NSHomeDirectory()
        if !home.isEmpty, projectPath.hasPrefix(home) {
            return "~" + projectPath.dropFirst(home.count)
        }
        return projectPath
    }

    private static func decodeJSONObject(from data: Data) -> [String: BurnBarJSONValue]? {
        try? JSONDecoder().decode([String: BurnBarJSONValue].self, from: data)
    }

    private func firstString(in dictionary: [String: BurnBarJSONValue], keys: [String]) -> String? {
        for key in keys {
            if case .string(let value)? = dictionary[key], !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private func firstDictionary(in dictionary: [String: BurnBarJSONValue], keys: [String]) -> [String: BurnBarJSONValue]? {
        for key in keys {
            if case .object(let value)? = dictionary[key], !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private func modificationDate(of url: URL) -> Date? {
        (try? fileManager.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date // try?-ok(mtime fallback to now)
    }

    private func resolveModel(structuredModel: String, inlineModel: String?) -> String {
        let structured = TokenExtractionUtility.normalizeModelName(structuredModel)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedInline = inlineModel.map {
            TokenExtractionUtility.normalizeModelName($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let inline = normalizedInline, !inline.isEmpty else {
            return structured.isEmpty ? "unknown" : structured
        }

        if structured.isEmpty || structured == "unknown" {
            return inline
        }

        if ModelPricing.hasCatalogPricing(model: structured, providerID: "junie")
            || ModelPricing.hasCatalogPricing(model: structured, providerID: nil) {
            return structured
        }

        if ModelPricing.hasCatalogPricing(model: inline, providerID: "junie")
            || ModelPricing.hasCatalogPricing(model: inline, providerID: nil) {
            return inline
        }

        return structured
    }

    private func compositeSignature(
        eventsFile: URL,
        stateFile: URL
    ) -> CompositeFileSignature<FileSignature>? {
        guard let events = FileSignature(for: eventsFile) else { return nil }
        let state = FileSignature(for: stateFile)
        return CompositeFileSignature(primary: events, settings: state, metadata: nil)
    }

    private static func hasExplicitUsageBuckets(_ usage: ExtractedTokenUsage) -> Bool {
        usage.input > 0
            || usage.output > 0
            || usage.cacheCreation > 0
            || usage.cacheRead > 0
            || usage.reasoningTokens > 0
    }

    private func appendEntry(
        usage: TokenUsage?,
        conversation: ConversationRecord?,
        includeConversation: Bool,
        usages: inout [TokenUsage],
        conversations: inout [ConversationRecord]
    ) {
        if let usage {
            usages.append(usage)
        }
        if includeConversation, let conversation {
            conversations.append(conversation)
        }
    }

    private func updateCacheEntry(
        _ cached: JunieCacheEntry,
        signature: CompositeFileSignature<FileSignature>,
        sessionId: String,
        eventsFile: URL,
        stateFile: URL,
        indexProjectPath: String?,
        includeConversationBodies: Bool,
        parseCache: inout ParserDiskCache<JunieCacheEntry>,
        cacheKey: String,
        cacheMutated: inout Bool
    ) -> JunieCacheEntry {
        if !includeConversationBodies {
            guard cached.conversation != nil else { return cached }
            let stripped = JunieCacheEntry(
                signature: cached.signature,
                usage: cached.usage,
                conversation: nil
            )
            parseCache.fileEntries[cacheKey] = stripped
            cacheMutated = true
            return stripped
        }

        guard cached.conversation == nil else { return cached }
        let parsed = try? parseSession( // try?-ok(best-effort conversation cache rewarm)
            sessionId: sessionId,
            eventsFile: eventsFile,
            stateFile: stateFile,
            indexProjectPath: indexProjectPath
        )
        let refreshed = JunieCacheEntry(
            signature: signature,
            usage: cached.usage ?? parsed?.usage,
            conversation: parsed?.conversation
        )
        if refreshed != cached {
            parseCache.fileEntries[cacheKey] = refreshed
            cacheMutated = true
        }
        return refreshed
    }
}

private struct JunieCacheEntry: Codable, Equatable {
    let signature: CompositeFileSignature<FileSignature>
    let usage: TokenUsage?
    let conversation: ConversationRecord?
}
