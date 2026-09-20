import Foundation
import OpenBurnBarKernel
import OpenBurnBarSQLiteReader

// MARK: Junie

public final class JunieParser: LogParser, Sendable {
    public let provider: AgentProvider = .junie
    private let sessionsOverride: URL?
    private let fileManager: FileManager
    private let cacheStore: ParserDiskCacheStore<JunieCacheEntry>
    private let sessionScanCount = Locked(0)
    private let sessionCacheHitCount = Locked(0)

    private struct JunieCacheEntry: Codable, Equatable, Sendable {
        var sessionSignature: FileSetSignature
        var usages: [CachedNamedUsage]
        var conversation: ConversationRecord?
    }

    public init(
        sessionsOverride: URL? = nil,
        fileManager: FileManager = .default,
        appPaths: OpenBurnBarAppPaths = .live()
    ) {
        self.sessionsOverride = sessionsOverride
        self.fileManager = fileManager
        self.cacheStore = ParserDiskCacheStore(
            cacheURL: LocalUsageParserSupport.idleCacheURL(
                overrideDirectory: sessionsOverride,
                live: appPaths.junieParserCacheURL,
                fileName: ".obb-junie-parser-cache.plist"
            ),
            fileManager: fileManager,
            schemaVersion: 2,
            logLabel: "JunieParser"
        )
    }

    public var lastSessionScanCount: Int { sessionScanCount.read() }
    public var lastSessionCacheHitCount: Int { sessionCacheHitCount.read() }

    public func parse() async throws -> ParseResult { try await parse(options: .default) }
    public func parse(options: LogParseOptions) async throws -> ParseResult {
        sessionScanCount.write(0)
        sessionCacheHitCount.write(0)
        let root = sessionsOverride ?? LocalUsageParserSupport.expanded(provider.logDirectory)
        guard fileManager.fileExists(atPath: root.path) else { return ParseResult(usages: [], conversations: []) }
        let gate = ParserFileReadGate(options: options, fileManager: fileManager)
        var parseCache = cacheStore.load()
        var activePaths = Set<String>()
        var cacheMutated = false
        defer { if cacheMutated { cacheStore.persist(parseCache) } }

        let index = root.appendingPathComponent("index.jsonl")
        let indexExists = fileManager.fileExists(atPath: index.path)
        let dirs = ((try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []).filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }

        if indexExists, dirs.isEmpty {
            _ = try gate.shouldRead([index])
            return ParseResult(usages: [], conversations: [])
        }

        var projects: [String: String] = [:]
        var indexLoaded = false
        func loadIndexProjects() throws {
            guard indexExists, !indexLoaded else { return }
            for object in try LocalUsageParserSupport.jsonLinesOrThrow(at: index) {
                if let id = LocalUsageParserSupport.firstString(object, keys: ["sessionId", "session_id", "id"]),
                   let project = LocalUsageParserSupport.firstString(
                       object,
                       keys: ["projectPath", "project_path", "cwd", "workingDirectory"]
                   ) {
                    projects[id] = project
                }
            }
            indexLoaded = true
        }

        var usages: [TokenUsage] = []
        var conversations: [ConversationRecord] = []
        for dir in dirs {
            let id = dir.lastPathComponent
            let events = dir.appendingPathComponent("events.jsonl")
            guard fileManager.fileExists(atPath: events.path) else { continue }
            let state = dir.appendingPathComponent("state.json")
            let stateExists = fileManager.fileExists(atPath: state.path)
            var sessionFiles = [events]
            if stateExists { sessionFiles.append(state) }
            var unitFiles = sessionFiles
            if indexExists { unitFiles.append(index) }

            let cacheKey = events.standardizedFileURL.path
            activePaths.insert(cacheKey)
            let sessionSignature = FileSetSignature(urls: sessionFiles, using: fileManager)

            for file in unitFiles {
                let attributes = try? fileManager.attributesOfItem(atPath: file.path)
                let identity = ParserDiscoveredFile.capture(for: file, attributes: attributes)
                _ = options.fileDiscoveryTracker?.record(identity)
                options.metrics?.recordMetadataStat()
            }

            func sessionInputIsNew() -> Bool {
                guard let tracker = options.fileDiscoveryTracker else { return false }
                return sessionFiles.contains { file in
                    let attributes = try? fileManager.attributesOfItem(atPath: file.path)
                    let identity = ParserDiscoveredFile.capture(for: file, attributes: attributes)
                    return !tracker.wasKnownAtCheckpoint(identity)
                }
            }
            func indexInputIsNew() -> Bool {
                guard indexExists, let tracker = options.fileDiscoveryTracker else { return false }
                let attributes = try? fileManager.attributesOfItem(atPath: index.path)
                let identity = ParserDiscoveredFile.capture(for: index, attributes: attributes)
                return !tracker.wasKnownAtCheckpoint(identity)
            }

            let cached = sessionSignature.flatMap { signature in
                parseCache.fileEntries[cacheKey].flatMap { $0.sessionSignature == signature ? $0 : nil }
            }
            let trackerPresent = options.fileDiscoveryTracker != nil
            if let cached {
                let needsBodyReparse = options.includeConversationBodies
                    && cached.conversation == nil
                    && (!trackerPresent || sessionInputIsNew())
                if !sessionInputIsNew() && !needsBodyReparse {
                    if indexInputIsNew() {
                        guard try gate.shouldRead([index], candidateAlreadyRecorded: true) else { continue }
                        do {
                            try loadIndexProjects()
                        } catch {
                            gate.recordContentReadFailure(for: [index])
                            continue
                        }
                    }
                    sessionCacheHitCount.withLock { $0 += 1 }
                    let project = projects[id]
                    let servedUsages = cached.usages.map { named -> TokenUsage in
                        let usage = named.makeUsage(provider: .junie)
                        return project.map { overlayProject($0, on: usage) } ?? usage
                    }
                    usages.append(contentsOf: servedUsages)
                    if options.includeConversationBodies, let conversation = cached.conversation {
                        conversations.append(project.map { overlayProject($0, on: conversation) } ?? conversation)
                    }
                    if let project {
                        parseCache.fileEntries[cacheKey] = JunieCacheEntry(
                            sessionSignature: cached.sessionSignature,
                            usages: servedUsages.map { CachedNamedUsage(sessionId: $0.sessionId, usage: $0) },
                            conversation: cached.conversation.map { overlayProject(project, on: $0) }
                        )
                        cacheMutated = true
                    }
                    continue
                }
            }

            guard try gate.shouldRead(unitFiles, candidateAlreadyRecorded: true) else { continue }
            sessionScanCount.withLock { $0 += 1 }
            let parsed: (usage: TokenUsage?, conversation: ConversationRecord?)
            do {
                if indexExists { try loadIndexProjects() }
                parsed = try parseSession(
                    id: id,
                    events: events,
                    state: stateExists ? state : nil,
                    projects: projects,
                    includeConversationBodies: options.includeConversationBodies
                )
            } catch {
                gate.recordContentReadFailure(for: unitFiles)
                continue
            }

            if let usage = parsed.usage {
                usages.append(usage)
            }
            if let conversation = parsed.conversation {
                conversations.append(conversation)
            }
            if let signature = sessionSignature {
                parseCache.fileEntries[cacheKey] = JunieCacheEntry(
                    sessionSignature: signature,
                    usages: parsed.usage.map { [CachedNamedUsage(sessionId: $0.sessionId, usage: $0)] } ?? [],
                    conversation: parsed.conversation
                )
                cacheMutated = true
            }
        }
        let stale = Set(parseCache.fileEntries.keys).subtracting(activePaths)
        if !stale.isEmpty {
            for key in stale { parseCache.fileEntries.removeValue(forKey: key) }
            cacheMutated = true
        }
        return ParseResult(usages: usages, conversations: conversations)
    }

    private func parseSession(
        id: String,
        events: URL,
        state: URL?,
        projects: [String: String],
        includeConversationBodies: Bool
    ) throws -> (usage: TokenUsage?, conversation: ConversationRecord?) {
        let objects = try LocalUsageParserSupport.jsonLinesOrThrow(at: events)
        var stateObject: LocalUsageJSONObject?
        if let state {
            stateObject = try LocalUsageParserSupport.jsonObjectOrThrow(at: state)
        }

        var input = 0, output = 0, cacheCreation = 0, cacheRead = 0, reasoning = 0
        var userChars = 0, assistantChars = 0
        var eventModel: String?
        var start: Date?, end: Date?
        var turns: [LocalUsageParserSupport.Turn] = []
        for raw in objects {
            let payload = LocalUsageParserSupport.unwrapEnvelope(raw)
            let message = LocalUsageParserSupport.dictionary(payload["message"]) ?? payload
            let timestamp = LocalUsageParserSupport.date(
                raw["timestamp"] ?? payload["timestamp"]
            )
            start = start ?? timestamp
            end = timestamp ?? end
            if let model = LocalUsageParserSupport.model(in: payload)
                ?? LocalUsageParserSupport.model(in: raw),
               !LocalUsageParserSupport.isPlaceholderModel(model) {
                eventModel = eventModel ?? model
            }
            let tokens = LocalUsageParserSupport.extracted(payload)
            input += tokens.input
            output += tokens.output
            cacheCreation += tokens.cacheCreation
            cacheRead += tokens.cacheRead
            reasoning += tokens.reasoningTokens
            let role = (
                LocalUsageParserSupport.string(message["role"])
                    ?? LocalUsageParserSupport.string(message["author"])
                    ?? LocalUsageParserSupport.string(message["sender"])
                    ?? ""
            ).lowercased()
            let text = LocalUsageParserSupport.contentText(
                message["content"] ?? message["text"] ?? message["parts"]
            )
            if !text.isEmpty, ["user", "assistant", "agent", "model"].contains(role) {
                let canonical = role == "user" ? "user" : "assistant"
                turns.append(.init(role: canonical, text: text, timestamp: timestamp))
                if canonical == "user" {
                    userChars += text.count
                } else {
                    assistantChars += text.count
                }
            }
        }

        var stateModel: String?
        var stateProject: String?
        var stateUsageApplied = false
        if let stateObject {
            if let model = LocalUsageParserSupport.model(in: stateObject),
               !LocalUsageParserSupport.isPlaceholderModel(model) {
                stateModel = model
            }
            stateProject = LocalUsageParserSupport.firstString(
                stateObject,
                keys: ["projectPath", "project_path", "cwd", "workingDirectory"]
            )
            if let usage = LocalUsageParserSupport.dictionary(stateObject["usage"])
                ?? LocalUsageParserSupport.dictionary(stateObject["tokenUsage"]) {
                let tokens = TokenExtractionUtility.extractUsageTokens(usage)
                if tokens.input > 0 || tokens.output > 0 || tokens.cacheCreation > 0
                    || tokens.cacheRead > 0 || tokens.reasoningTokens > 0 {
                    input = tokens.input
                    output = tokens.output
                    cacheCreation = tokens.cacheCreation
                    cacheRead = tokens.cacheRead
                    reasoning = tokens.reasoningTokens
                    stateUsageApplied = true
                }
            }
        }

        var method: UsageProvenanceMethod = .providerLog
        var confidence: UsageProvenanceConfidence = .exact
        if !stateUsageApplied,
           input == 0 && output == 0 && cacheCreation == 0 && cacheRead == 0 && reasoning == 0 {
            guard userChars + assistantChars > 0 else {
                return (nil, nil)
            }
            let estimate = TokenExtractionUtility.estimateFallbackTokens(
                userVisibleChars: userChars,
                assistantVisibleChars: assistantChars,
                assistantReasoningChars: 0,
                userMessageCount: 1,
                assistantMessageCount: 1
            )
            input = estimate.input
            output = estimate.output
            method = .heuristicEstimate
            confidence = .lowConfidenceEstimate
        }
        let model = eventModel ?? stateModel ?? "unknown"
        let project = projects[id] ?? stateProject ?? "Junie"
        let mtime = LocalUsageParserSupport.modificationDate(events) ?? Date()
        let startTime = start ?? mtime
        let endTime = end ?? startTime
        let cost = (try? ModelPricing.lookup(model: model, providerID: "junie").cost(
            inputTokens: input,
            outputTokens: output,
            cacheCreationTokens: cacheCreation,
            cacheReadTokens: cacheRead
        )) ?? 0
        let estimatorVersion = method == .heuristicEstimate
            ? TokenExtractionUtility.currentEstimatorVersion
            : ""
        let usage = LocalUsageParserSupport.usage(
            provider: .junie,
            sessionID: id,
            project: project,
            model: model,
            input: input,
            output: output,
            cacheCreation: cacheCreation,
            cacheRead: cacheRead,
            reasoning: reasoning,
            cost: cost,
            start: startTime,
            end: endTime,
            method: method,
            confidence: confidence,
            estimatorVersion: estimatorVersion
        )
        let conversation: ConversationRecord?
        if includeConversationBodies, !turns.isEmpty {
            conversation = LocalUsageParserSupport.transcript(
                provider: .junie,
                sessionID: id,
                project: project,
                turns: turns,
                start: startTime,
                end: endTime,
                fileModifiedAt: mtime,
                workingDirectory: projects[id] ?? stateProject
            )
        } else {
            conversation = nil
        }
        return (usage, conversation)
    }

    private func overlayProject(_ project: String, on usage: TokenUsage) -> TokenUsage {
        guard usage.projectName != project else { return usage }
        return TokenUsage(
            provider: usage.provider,
            sessionId: usage.sessionId,
            projectName: project,
            model: usage.model,
            inputTokens: usage.inputTokens,
            outputTokens: usage.outputTokens,
            cacheCreationTokens: usage.cacheCreationTokens,
            cacheReadTokens: usage.cacheReadTokens,
            reasoningTokens: usage.reasoningTokens,
            costUSD: usage.costUSD,
            startTime: usage.startTime,
            endTime: usage.endTime,
            provenanceMethod: usage.provenanceMethod,
            provenanceConfidence: usage.provenanceConfidence,
            estimatorVersion: usage.estimatorVersion
        )
    }

    private func overlayProject(_ project: String, on conversation: ConversationRecord) -> ConversationRecord {
        guard conversation.projectName != project || conversation.workingDirectory != project else {
            return conversation
        }
        return ConversationRecord(
            id: conversation.id,
            provider: conversation.provider,
            sessionId: conversation.sessionId,
            projectName: project,
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
            workingDirectory: project,
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
}
