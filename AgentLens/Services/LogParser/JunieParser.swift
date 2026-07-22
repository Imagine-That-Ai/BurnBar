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
///
/// TODO(junie-schema-pin): The `events.jsonl` field inventory has never been
/// pinned from a REAL authenticated Junie session — JetBrains does not
/// publicly document the on-disk event schema (checked junie.jetbrains.com
/// docs + JetBrains/junie repo, 2026-07). The variants handled below (envelope
/// keys, role aliases, usage-bucket spellings, snake_case index fields) are
/// the defensive superset from PR #1136's live-install inspection.
/// When an authenticated Junie session is available: capture a real
/// `index.jsonl` + `<sessionId>/events.jsonl` + `state.json` triple, freeze
/// timestamps, promote it into the ParserContract corpus
/// (AgentLensTests/Fixtures/ParserContract, `pc-junie-*`), and regenerate the
/// parser-output golden per docs/windows-port/PARSER_OUTPUT_CONTRACT.md.
/// The JunieParserTests inline fixtures pin the best-known shape until then.
final class JunieParser: LogParser, Sendable {
    let provider: AgentProvider = .junie
    private let fileManager: FileManager
    private let appPaths: OpenBurnBarAppPaths
    private let cacheURL: URL
    private let cacheStore: ParserDiskCacheStore<JunieCacheEntry>
    private let sessionsDirectoryOverride: URL?
    private let fileHandleForReading: @Sendable (URL) throws -> FileHandle

    init(
        fileManager: FileManager = .default,
        appPaths: OpenBurnBarAppPaths = .live(),
        sessionsDirectoryOverride: URL? = nil,
        fileHandleForReading: @escaping @Sendable (URL) throws -> FileHandle = { url in
            try FileHandle(forReadingFrom: url)
        }
    ) {
        self.fileManager = fileManager
        self.appPaths = appPaths
        self.sessionsDirectoryOverride = sessionsDirectoryOverride
        self.fileHandleForReading = fileHandleForReading
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

        let gate = ParserFileReadGate(options: options, fileManager: fileManager)
        var usages: [TokenUsage] = []
        var conversations: [ConversationRecord] = []
        var parseCache = cacheStore.load()
        var activePaths = Set<String>()
        var cacheMutated = false

        let indexURL = sessionsURL.appendingPathComponent("index.jsonl")
        let indexExists = fileManager.fileExists(atPath: indexURL.path)
        let currentIndexSignature = indexExists ? FileSignature(for: indexURL, using: fileManager) : nil
        var indexProjects: [String: String]?
        var indexReadAttempted = false
        var indexObserved = false

        func loadIndexIfAdmitted(allowDependencyFallback: Bool) throws -> Bool {
            if indexProjects != nil { return true }
            guard indexExists, !indexReadAttempted else { return false }

            let deferredBefore = options.resourceGovernor?.deferredFileCount
            var readGate = gate
            var admitted = try gate.shouldRead(indexURL)
            indexObserved = true

            let admissionRecordedDeferral = deferredBefore.map {
                options.resourceGovernor?.deferredFileCount != $0
            } ?? false
            if !admitted, allowDependencyFallback, !admissionRecordedDeferral {
                var dependencyOptions = options
                dependencyOptions.minimumFileModificationDate = nil
                dependencyOptions.fileDiscoveryTracker = nil
                readGate = ParserFileReadGate(options: dependencyOptions, fileManager: fileManager)
                admitted = try readGate.shouldRead([indexURL], candidateAlreadyRecorded: true)
            }

            guard admitted else {
                if admissionRecordedDeferral
                    || deferredBefore.map({ options.resourceGovernor?.deferredFileCount != $0 }) == true {
                    indexReadAttempted = true
                }
                return false
            }

            indexReadAttempted = true
            do {
                indexProjects = try sessionIndexProjects(indexURL: indexURL)
                return true
            } catch {
                readGate.recordContentReadFailure(for: indexURL)
                return false
            }
        }

        func sessionAdmissionFiles(_ sessionFiles: [URL]) -> (files: [URL], includesIndex: Bool) {
            let includesIndex = indexExists && indexProjects == nil && !indexReadAttempted
            return (
                includesIndex ? sessionFiles + [indexURL] : sessionFiles,
                includesIndex
            )
        }

        func loadPreAdmittedIndexIfNeeded(_ includesIndex: Bool) -> Bool {
            guard includesIndex else { return true }
            indexObserved = true
            indexReadAttempted = true
            do {
                indexProjects = try sessionIndexProjects(indexURL: indexURL)
                return true
            } catch {
                gate.recordContentReadFailure(for: indexURL)
                return false
            }
        }

        // try?-ok(absent or unreadable session root yields no sessions)
        let sessionDirs = (try? fileManager.contentsOfDirectory(at: sessionsURL, includingPropertiesForKeys: [.isDirectoryKey]))
            // try?-ok(unreadable directory metadata excludes that entry)
            .map { $0.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true } }
            ?? []

        for sessionDir in sessionDirs {
            let sessionId = sessionDir.lastPathComponent
            let eventsFile = sessionDir.appendingPathComponent("events.jsonl")
            let stateFile = sessionDir.appendingPathComponent("state.json")
            guard fileManager.fileExists(atPath: eventsFile.path) else { continue }

            let cacheKey = eventsFile.standardizedFileURL.path
            activePaths.insert(cacheKey)
            options.metrics?.recordCandidate()

            let signature = compositeSignature(eventsFile: eventsFile, stateFile: stateFile)
            var sessionFiles = [eventsFile]
            if fileManager.fileExists(atPath: stateFile.path) { sessionFiles.append(stateFile) }

            let cached = signature.flatMap { signature in
                parseCache.fileEntries[cacheKey].flatMap { $0.signature == signature ? $0 : nil }
            }

            if var cached, let signature {
                let indexChanged = cached.indexSignature != currentIndexSignature
                if indexChanged, try loadIndexIfAdmitted(allowDependencyFallback: false) {
                    cached = refreshingIndexAttribution(
                        cached,
                        projectPath: indexProjects?[sessionId],
                        indexSignature: currentIndexSignature
                    )
                    if parseCache.fileEntries[cacheKey] != cached {
                        parseCache.fileEntries[cacheKey] = cached
                        cacheMutated = true
                    }
                } else if indexExists, !indexObserved {
                    try recordObservedFiles([indexURL], options: options, candidateAlreadyRecorded: false)
                    indexObserved = true
                }

                if options.includeConversationBodies, cached.conversation == nil {
                    let admission = sessionAdmissionFiles(sessionFiles)
                    let sessionAdmitted = try gate.shouldRead(
                        admission.files,
                        candidateAlreadyRecorded: true
                    )
                    guard sessionAdmitted else {
                        appendEntry(
                            usage: cached.usage,
                            conversation: nil,
                            includeConversation: false,
                            usages: &usages,
                            conversations: &conversations
                        )
                        continue
                    }
                    guard loadPreAdmittedIndexIfNeeded(admission.includesIndex) else {
                        gate.discardAdmission(for: sessionFiles)
                        appendEntry(
                            usage: cached.usage,
                            conversation: nil,
                            includeConversation: false,
                            usages: &usages,
                            conversations: &conversations
                        )
                        continue
                    }

                    let state: SessionStateMetadata
                    do {
                        state = try readStateMetadata(from: stateFile)
                    } catch {
                        gate.recordContentReadFailure(for: sessionFiles)
                        appendEntry(
                            usage: cached.usage,
                            conversation: nil,
                            includeConversation: false,
                            usages: &usages,
                            conversations: &conversations
                        )
                        continue
                    }
                    var indexProjectPath = indexProjects?[sessionId]
                    if indexProjectPath == nil, state.projectPath == nil, indexExists {
                        let deferredBefore = options.resourceGovernor?.deferredFileCount
                        guard try loadIndexIfAdmitted(allowDependencyFallback: true),
                              let loadedProjectPath = indexProjects?[sessionId] else {
                            gate.discardAdmission(for: sessionFiles)
                            recordMissingAttributionDeferralIfNeeded(previousDeferredCount: deferredBefore, options: options)
                            appendEntry(
                                usage: cached.usage,
                                conversation: nil,
                                includeConversation: false,
                                usages: &usages,
                                conversations: &conversations
                            )
                            continue
                        }
                        indexProjectPath = loadedProjectPath
                    }

                    do {
                        let parsed = try parseSession(
                            sessionId: sessionId,
                            eventsFile: eventsFile,
                            state: state,
                            indexProjectPath: indexProjectPath
                        )
                        var refreshed = JunieCacheEntry(
                            signature: signature,
                            indexSignature: indexProjects != nil ? currentIndexSignature : cached.indexSignature,
                            usage: cached.usage ?? parsed?.usage,
                            conversation: parsed?.conversation
                        )
                        if indexProjects != nil {
                            refreshed = refreshingIndexAttribution(
                                refreshed,
                                projectPath: indexProjects?[sessionId],
                                indexSignature: currentIndexSignature
                            )
                        }
                        if refreshed != cached {
                            parseCache.fileEntries[cacheKey] = refreshed
                            cacheMutated = true
                        }
                        appendEntry(
                            usage: refreshed.usage,
                            conversation: refreshed.conversation,
                            includeConversation: true,
                            usages: &usages,
                            conversations: &conversations
                        )
                    } catch {
                        gate.recordContentReadFailure(for: sessionFiles)
                        appendEntry(
                            usage: cached.usage,
                            conversation: nil,
                            includeConversation: false,
                            usages: &usages,
                            conversations: &conversations
                        )
                    }
                    continue
                }

                try recordObservedFiles(sessionFiles, options: options, candidateAlreadyRecorded: true)
                if !options.includeConversationBodies, cached.conversation != nil {
                    cached = JunieCacheEntry(
                        signature: cached.signature,
                        indexSignature: cached.indexSignature,
                        usage: cached.usage,
                        conversation: nil
                    )
                    parseCache.fileEntries[cacheKey] = cached
                    cacheMutated = true
                }
                appendEntry(
                    usage: cached.usage,
                    conversation: cached.conversation,
                    includeConversation: options.includeConversationBodies,
                    usages: &usages,
                    conversations: &conversations
                )
                continue
            }

            let admission = sessionAdmissionFiles(sessionFiles)
            let sessionAdmitted = try gate.shouldRead(
                admission.files,
                candidateAlreadyRecorded: true
            )
            guard sessionAdmitted else {
                if let cached = parseCache.fileEntries[cacheKey] {
                    appendEntry(
                        usage: cached.usage,
                        conversation: nil,
                        includeConversation: false,
                        usages: &usages,
                        conversations: &conversations
                    )
                }
                continue
            }
            guard loadPreAdmittedIndexIfNeeded(admission.includesIndex) else {
                gate.discardAdmission(for: sessionFiles)
                continue
            }

            let state: SessionStateMetadata
            do {
                state = try readStateMetadata(from: stateFile)
            } catch {
                gate.recordContentReadFailure(for: sessionFiles)
                continue
            }
            var indexProjectPath = indexProjects?[sessionId]
            if indexProjectPath == nil, state.projectPath == nil, indexExists {
                let deferredBefore = options.resourceGovernor?.deferredFileCount
                guard try loadIndexIfAdmitted(allowDependencyFallback: true),
                      let loadedProjectPath = indexProjects?[sessionId] else {
                    gate.discardAdmission(for: sessionFiles)
                    recordMissingAttributionDeferralIfNeeded(previousDeferredCount: deferredBefore, options: options)
                    continue
                }
                indexProjectPath = loadedProjectPath
            }

            do {
                let parsed = try parseSession(
                    sessionId: sessionId,
                    eventsFile: eventsFile,
                    state: state,
                    indexProjectPath: indexProjectPath
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
                        indexSignature: currentIndexSignature,
                        usage: parsed?.usage,
                        conversation: options.includeConversationBodies ? parsed?.conversation : nil
                    )
                    cacheMutated = true
                }
            } catch {
                gate.recordContentReadFailure(for: sessionFiles)
            }
        }

        if indexExists, !indexObserved {
            try recordObservedFiles([indexURL], options: options, candidateAlreadyRecorded: false)
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
    private func sessionIndexProjects(indexURL: URL) throws -> [String: String] {
        let handle = try fileHandleForReading(indexURL)
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
        var reasoning: Int = 0
        var model: String = "unknown"

        var hasAnyTokens: Bool {
            input > 0 || output > 0 || cacheCreation > 0 || cacheRead > 0 || reasoning > 0
        }
    }
    private struct SessionStateMetadata {
        var tokenData = SessionTokenData()
        var projectPath: String?
        var providedUsageTotals = false
        var usedExplicitUsage = false
    }

    private func readStateMetadata(from stateFile: URL) throws -> SessionStateMetadata {
        var state = SessionStateMetadata()
        guard fileManager.fileExists(atPath: stateFile.path) else { return state }
        let handle = try fileHandleForReading(stateFile)
        defer { try? handle.close() } // try?-ok(handle teardown)
        let data = try handle.readToEnd() ?? Data()
        guard let json = Self.decodeJSONObject(from: data) else {
            return state
        }

        if let model = firstString(in: json, keys: ["model", "modelId", "model_id", "modelForLaunch", "selectedModel", "llmModel"]) {
            state.tokenData.model = TokenExtractionUtility.normalizeModelName(model)
        }
        state.projectPath = firstString(
            in: json,
            keys: ["projectPath", "project_path", "projectDir", "cwd", "workingDirectory"]
        )
        if let usageDict = firstDictionary(in: json, keys: ["usage", "tokenUsage", "token_usage", "llmUsage", "totalUsage"]) {
            let extracted = TokenExtractionUtility.extractUsageTokens(usageDict)
            if Self.hasExplicitUsageBuckets(extracted) {
                state.tokenData.input = extracted.input
                state.tokenData.output = extracted.output
                state.tokenData.cacheCreation = extracted.cacheCreation
                state.tokenData.cacheRead = extracted.cacheRead
                state.tokenData.reasoning = extracted.reasoningTokens
                state.providedUsageTotals = true
                state.usedExplicitUsage = true
            }
        }
        return state
    }

    private func parseSession(
        sessionId: String,
        eventsFile: URL,
        state: SessionStateMetadata,
        indexProjectPath: String?
    ) throws -> (usage: TokenUsage?, conversation: ConversationRecord?)? {
        var tokenData = state.tokenData
        var usedExplicitUsage = state.usedExplicitUsage
        var userCharCount = 0
        var assistantCharCount = 0
        var assistantReasoningCharCount = 0
        var userMessageCount = 0
        var assistantMessageCount = 0
        var inlineModel: String?
        let projectPath = indexProjectPath ?? state.projectPath
        let stateJSONProvidedTotals = state.providedUsageTotals

        let mtime = modificationDate(of: eventsFile)
        let conv = ClaudeConversationAccumulator()

        let handle = try fileHandleForReading(eventsFile)
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
                            // VAL-TOKEN-006: reasoning stays a distinct bucket;
                            // dropping it here silently undercounted sessions
                            // whose usage reports thinking/reasoning tokens.
                            tokenData.reasoning += extracted.reasoningTokens
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

        conv.finalizeArrays()

        if tokenData.hasAnyTokens == false {
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

        guard tokenData.hasAnyTokens else { return nil }

        let projectName = displayProjectName(projectPath)

        let pricing = ModelPricing.lookup(model: tokenData.model, providerID: "junie")
        let cost = try pricing.cost(
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
            reasoningTokens: tokenData.reasoning,
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
        try? JSONDecoder().decode([String: BurnBarJSONValue].self, from: data) // try?-ok(malformed Junie metadata skipped)
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

    private func recordObservedFiles(
        _ files: [URL],
        options: LogParseOptions,
        candidateAlreadyRecorded: Bool
    ) throws {
        guard let tracker = options.fileDiscoveryTracker else { return }
        try options.resourceGovernor?.checkpoint()
        if !candidateAlreadyRecorded {
            options.metrics?.recordCandidate()
        }
        for file in files {
            options.metrics?.recordMetadataStat()
            let attributes = try fileManager.attributesOfItem(atPath: file.path)
            _ = tracker.record(discoveredFile(for: file, attributes: attributes))
        }
    }

    private func discoveredFile(
        for file: URL,
        attributes: [FileAttributeKey: Any]?
    ) -> ParserDiscoveredFile {
        ParserDiscoveredFile(
            path: file.standardizedFileURL.path,
            fileSizeBytes: (attributes?[.size] as? NSNumber)?.int64Value,
            modificationDate: normalizedCheckpointDate(attributes?[.modificationDate] as? Date),
            creationDate: normalizedCheckpointDate(attributes?[.creationDate] as? Date),
            fileSystemNumber: (attributes?[.systemNumber] as? NSNumber)?.uint64Value,
            fileNumber: (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value
        )
    }

    private func normalizedCheckpointDate(_ date: Date?) -> Date? {
        guard let date else { return nil }
        let milliseconds = (date.timeIntervalSince1970 * 1_000).rounded()
        return Date(timeIntervalSince1970: milliseconds / 1_000)
    }

    private func recordMissingAttributionDeferralIfNeeded(
        previousDeferredCount: Int?,
        options: LogParseOptions
    ) {
        if let previousDeferredCount,
           options.resourceGovernor?.deferredFileCount != previousDeferredCount {
            return
        }
        options.resourceGovernor?.recordDeferredFile()
        options.metrics?.recordDeferred(.metadataUnavailable)
    }

    private func refreshingIndexAttribution(
        _ cached: JunieCacheEntry,
        projectPath: String?,
        indexSignature: FileSignature?
    ) -> JunieCacheEntry {
        guard let projectPath else {
            return JunieCacheEntry(
                signature: cached.signature,
                indexSignature: indexSignature,
                usage: cached.usage,
                conversation: cached.conversation
            )
        }

        let projectName = displayProjectName(projectPath)
        return JunieCacheEntry(
            signature: cached.signature,
            indexSignature: indexSignature,
            usage: cached.usage.map { usage in
                TokenUsage(
                    id: usage.id,
                    provider: usage.provider,
                    sessionId: usage.sessionId,
                    projectName: projectName,
                    model: usage.model,
                    inputTokens: usage.inputTokens,
                    outputTokens: usage.outputTokens,
                    cacheCreationTokens: usage.cacheCreationTokens,
                    cacheReadTokens: usage.cacheReadTokens,
                    reasoningTokens: usage.reasoningTokens,
                    costUSD: usage.costUSD,
                    startTime: usage.startTime,
                    endTime: usage.endTime,
                    createdAt: usage.createdAt,
                    usageSource: usage.usageSource,
                    deviceId: usage.deviceId,
                    sourceDeviceId: usage.sourceDeviceId,
                    sourceDeviceName: usage.sourceDeviceName,
                    isRemote: usage.isRemote,
                    providerID: usage.providerID,
                    providerAccountID: usage.providerAccountID,
                    providerAccountLabel: usage.providerAccountLabel,
                    providerAccountSource: usage.providerAccountSource,
                    currency: usage.currency,
                    recordedAt: usage.recordedAt,
                    eventKind: usage.eventKind,
                    idempotencyKey: usage.idempotencyKey,
                    provenanceMethod: usage.provenanceMethod,
                    provenanceConfidence: usage.provenanceConfidence,
                    estimatorVersion: usage.estimatorVersion,
                    parentRequestID: usage.parentRequestID
                )
            },
            conversation: cached.conversation.map { conversation in
                ConversationRecord(
                    id: conversation.id,
                    provider: conversation.provider,
                    sessionId: conversation.sessionId,
                    projectName: projectName,
                    startTime: conversation.startTime,
                    endTime: conversation.endTime,
                    messageCount: conversation.messageCount,
                    userWordCount: conversation.userWordCount,
                    assistantWordCount: conversation.assistantWordCount,
                    keyFiles: conversation.keyFiles,
                    keyCommands: conversation.keyCommands,
                    keyTools: conversation.keyTools,
                    inferredTaskTitle: conversation.inferredTaskTitle,
                    lastAssistantMessage: conversation.lastAssistantMessage,
                    fullText: conversation.fullText,
                    indexedAt: conversation.indexedAt,
                    workingDirectory: projectPath,
                    fileModifiedAt: conversation.fileModifiedAt,
                    summary: conversation.summary,
                    summaryTitle: conversation.summaryTitle,
                    summaryUpdatedAt: conversation.summaryUpdatedAt,
                    summaryProvider: conversation.summaryProvider,
                    summaryModel: conversation.summaryModel,
                    sourceType: conversation.sourceType,
                    sourceDeviceId: conversation.sourceDeviceId,
                    sourceDeviceName: conversation.sourceDeviceName,
                    isRemote: conversation.isRemote,
                    deletedAt: conversation.deletedAt,
                    version: conversation.version
                )
            }
        )
    }
}

private struct JunieCacheEntry: Codable, Equatable {
    let signature: CompositeFileSignature<FileSignature>
    let indexSignature: FileSignature?
    let usage: TokenUsage?
    let conversation: ConversationRecord?
}
