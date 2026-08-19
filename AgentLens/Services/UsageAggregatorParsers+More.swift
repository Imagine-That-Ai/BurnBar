import Foundation
import CryptoKit
import GRDB
import OpenBurnBarCore

// Model-filter, OpenCode, and Pi-agent log parsers.
// Extracted from UsageAggregatorParsers.swift (god-file decomposition) — same module, verbatim.

/// Typed seam over a decoded JSON log line. Provider logs carry ad-hoc per-line
/// keys (`model`/`message.model`, `usage`/`message.usage`), so the storage stays
/// an untyped dictionary — but the boundary cast lives in exactly one accessor.
private typealias LogLineJSONObject = [String: Any]

private func logLineObject(_ value: Any?) -> LogLineJSONObject? {
    value as? LogLineJSONObject
}

final class ModelFilterParser: OpenBurnBarCore.LogParser, Sendable {
    let provider: AgentProvider
    private let modelPattern: String
    private let fileManager: FileManager
    private let appPaths: OpenBurnBarCore.OpenBurnBarAppPaths
    private let sessionsURL: URL
    private let cacheURL: URL
    private let cacheStore: OpenBurnBarCore.ParserDiskCacheStore<ModelFilterCacheEntry>
    private let fileHandleForReading: @Sendable (URL) throws -> FileHandle

    init(
        modelPattern: String,
        provider: AgentProvider,
        fileManager: FileManager = .default,
        appPaths: OpenBurnBarCore.OpenBurnBarAppPaths = .live(),
        sessionsDirectoryOverride: URL? = nil,
        fileHandleForReading: @escaping @Sendable (URL) throws -> FileHandle = { url in
            try FileHandle(forReadingFrom: url)
        }
    ) {
        self.modelPattern = modelPattern.lowercased()
        self.provider = provider
        self.fileManager = fileManager
        self.appPaths = appPaths
        self.sessionsURL = sessionsDirectoryOverride
            ?? URL(fileURLWithPath: ("~/.factory/sessions" as NSString).expandingTildeInPath)
        self.fileHandleForReading = fileHandleForReading

        let providerKey = provider.rawValue
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
        self.cacheURL = appPaths.supportDirectory
            .appendingPathComponent("model_filter_parser_\(providerKey).json")
        self.cacheStore = OpenBurnBarCore.ParserDiskCacheStore(
            cacheURL: cacheURL,
            fileManager: fileManager,
            schemaVersion: 2,
            logLabel: "ModelFilterParser (\(provider.rawValue))"
        )
        ParserSupportDirectoryWarmUp.prepare(fileManager: fileManager, appPaths: appPaths)
    }

    func parse() async throws -> OpenBurnBarCore.ParseResult {
        try await parse(options: .default)
    }

    func parse(options: OpenBurnBarCore.LogParseOptions) async throws -> OpenBurnBarCore.ParseResult {
        let includeConversationBodies = options.includeConversationBodies

        guard fileManager.fileExists(atPath: sessionsURL.path) else {
            return OpenBurnBarCore.ParseResult(usages: [], conversations: [])
        }

        let gate = OpenBurnBarCore.ParserFileReadGate(options: options, fileManager: fileManager)
        var usages: [TokenUsage] = []
        var conversations: [OpenBurnBarCore.ConversationRecord] = []
        var parseCache = cacheStore.load()
        var activePaths = Set<String>()
        var cacheMutated = false

        let projectDirs = try fileManager.contentsOfDirectory(at: sessionsURL, includingPropertiesForKeys: [.isDirectoryKey])
            // try?-ok(unreadable directory metadata excludes that entry)
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }

        for projectDir in projectDirs {
            let projectName = decodeProjectName(projectDir.lastPathComponent)
            let files = try fileManager.contentsOfDirectory(
                at: projectDir,
                includingPropertiesForKeys: OpenBurnBarCore.FileSignature.directoryListingPrefetchKeys
            )
                .filter { $0.pathExtension == "jsonl" }

            for jsonlFile in files {
                let baseName = jsonlFile.deletingPathExtension().lastPathComponent
                let settingsFile = projectDir.appendingPathComponent("\(baseName).settings.json")
                let metadataFile = projectDir.appendingPathComponent("\(baseName).metadata.json")
                let cacheKey = cachePath(for: jsonlFile)
                activePaths.insert(cacheKey)

                options.metrics?.recordCandidate()
                let signature = compositeSignature(
                    jsonlFile: jsonlFile,
                    settingsFile: settingsFile,
                    metadataFile: metadataFile
                )
                var sessionFiles = [jsonlFile]
                if fileManager.fileExists(atPath: settingsFile.path) { sessionFiles.append(settingsFile) }
                if fileManager.fileExists(atPath: metadataFile.path) { sessionFiles.append(metadataFile) }

                let cached = signature.flatMap { signature in
                    parseCache.fileEntries[cacheKey].flatMap { $0.signature == signature ? $0 : nil }
                }

                if let cached {
                    if includeConversationBodies, cached.conversation == nil {
                        let sessionAdmitted = try gate.shouldRead(sessionFiles, candidateAlreadyRecorded: true)
                        guard sessionAdmitted else {
                            appendCached(
                                cached,
                                includeConversation: false,
                                usages: &usages,
                                conversations: &conversations
                            )
                            continue
                        }

                        do {
                            let parsed = try parseSession(file: jsonlFile, projectName: projectName)
                            let refreshed = ModelFilterCacheEntry(
                                signature: cached.signature,
                                usage: cached.usage ?? parsed?.usage,
                                conversation: parsed?.conversation
                            )
                            if refreshed != cached {
                                parseCache.fileEntries[cacheKey] = refreshed
                                cacheMutated = true
                            }
                            appendCached(
                                refreshed,
                                includeConversation: true,
                                usages: &usages,
                                conversations: &conversations
                            )
                        } catch {
                            gate.recordContentReadFailure(for: sessionFiles)
                            appendCached(
                                cached,
                                includeConversation: false,
                                usages: &usages,
                                conversations: &conversations
                            )
                        }
                    } else {
                        try recordObservedFiles(sessionFiles, options: options)
                        appendCached(
                            cached,
                            includeConversation: includeConversationBodies,
                            usages: &usages,
                            conversations: &conversations
                        )
                        if !includeConversationBodies, cached.conversation != nil {
                            parseCache.fileEntries[cacheKey] = ModelFilterCacheEntry(
                                signature: cached.signature,
                                usage: cached.usage,
                                conversation: nil
                            )
                            cacheMutated = true
                        }
                    }
                    continue
                }

                let sessionAdmitted = try gate.shouldRead(sessionFiles, candidateAlreadyRecorded: true)
                guard sessionAdmitted else {
                    if let cached = parseCache.fileEntries[cacheKey] {
                        appendCached(
                            cached,
                            includeConversation: false,
                            usages: &usages,
                            conversations: &conversations
                        )
                    }
                    continue
                }

                do {
                    let parsed = try parseSession(file: jsonlFile, projectName: projectName)
                    appendParsed(
                        parsed,
                        includeConversation: includeConversationBodies,
                        usages: &usages,
                        conversations: &conversations
                    )

                    if let signature {
                        parseCache.fileEntries[cacheKey] = ModelFilterCacheEntry(
                            signature: signature,
                            usage: parsed?.usage,
                            conversation: includeConversationBodies ? parsed?.conversation : nil
                        )
                        cacheMutated = true
                    }
                } catch {
                    gate.recordContentReadFailure(for: sessionFiles)
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

        return OpenBurnBarCore.ParseResult(usages: usages, conversations: conversations)
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

    private func readOptionalSidecarJSON(_ file: URL) throws -> [String: Any]? {
        guard fileManager.fileExists(atPath: file.path) else { return nil }
        let handle = try fileHandleForReading(file)
        defer { try? handle.close() } // try?-ok(handle teardown)
        let data = try handle.readToEnd() ?? Data()
        do {
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            return nil
        }
    }

    private func parseSession(file: URL, projectName: String) throws -> (usage: TokenUsage?, conversation: OpenBurnBarCore.ConversationRecord?)? {
        let handle = try fileHandleForReading(file)
        defer { try? handle.close() } // try?-ok(handle teardown)

        let mtime = (try? fileManager.attributesOfItem(atPath: file.path)[.modificationDate]) as? Date // try?-ok(optional mtime)
        let conv = OpenBurnBarCore.ClaudeConversationAccumulator()

        let baseName = file.deletingPathExtension().lastPathComponent
        let settingsURL = file.deletingLastPathComponent().appendingPathComponent("\(baseName).settings.json")
        let metadataURL = file.deletingLastPathComponent().appendingPathComponent("\(baseName).metadata.json")

        var inlineModel: String?
        var inputTokens = 0
        var outputTokens = 0
        var cacheCreationTokens = 0
        var cacheReadTokens = 0
        var usedSettingsTotals = false
        var usedFallbackEstimate = false
        var settingsModel: String?

        if let json = try readOptionalSidecarJSON(settingsURL) {
            if let m = json["model"] as? String {
                settingsModel = OpenBurnBarCore.TokenExtractionUtility.normalizeModelName(m)
            }
            if let tokenUsage = json["tokenUsage"] as? [String: Any] {
                let extracted = OpenBurnBarCore.TokenExtractionUtility.extractUsageTokens(tokenUsage)
                if extracted.input > 0 || extracted.output > 0 || extracted.cacheCreation > 0 || extracted.cacheRead > 0 {
                    inputTokens = extracted.input
                    outputTokens = extracted.output
                    cacheCreationTokens = extracted.cacheCreation
                    cacheReadTokens = extracted.cacheRead
                    usedSettingsTotals = true
                }
            }
        }

        if !usedSettingsTotals,
           let json = try readOptionalSidecarJSON(metadataURL) {
            if settingsModel == nil, let m = json["model"] as? String {
                settingsModel = OpenBurnBarCore.TokenExtractionUtility.normalizeModelName(m)
            }
            if let tokenUsage = json["tokenUsage"] as? [String: Any] ?? json["usage"] as? [String: Any] {
                let extracted = OpenBurnBarCore.TokenExtractionUtility.extractUsageTokens(tokenUsage)
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
        var userCharCount = 0
        var assistantCharCount = 0
        var assistantReasoningCharCount = 0
        var userMessageCount = 0
        var assistantMessageCount = 0

        for line in handle.readAllUTF8Lines() {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { // try?-ok(per-line decode, skip)
                continue
            }

            conv.ingest(jsonLine: json)

            if let message = logLineObject(json["message"]) {
                let role = (message["role"] as? String)?.lowercased()
                if let content = message["content"] {
                    let metrics = OpenBurnBarCore.TokenExtractionUtility.contentMetrics(from: content)
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

                    if inlineModel == nil, let detectedModel = OpenBurnBarCore.TokenExtractionUtility.detectModelHint(from: content) {
                        inlineModel = OpenBurnBarCore.TokenExtractionUtility.normalizeModelName(detectedModel)
                    }
                }
            }

            if usedSettingsTotals {
                if let message = logLineObject(json["message"]),
                   message["role"] as? String == "assistant",
                   let ts = json["timestamp"] as? String {
                    // Shared lenient parser: accepts fractional seconds and skips
                    // the per-line ISO8601DateFormatter allocation.
                    let date = ThreadSafeISO8601DateFormatter.parse(ts)
                    if startTime == nil { startTime = date }
                    endTime = date
                }
                continue
            }

            if let message = logLineObject(json["message"]),
               let usage = message["usage"] as? [String: Any] {
                let extracted = OpenBurnBarCore.TokenExtractionUtility.extractUsageTokens(
                    usage,
                    inputHint: userCharCount,
                    outputHint: assistantCharCount + assistantReasoningCharCount
                )
                inputTokens += extracted.input
                outputTokens += extracted.output
                cacheCreationTokens += extracted.cacheCreation
                cacheReadTokens += extracted.cacheRead

                if let ts = json["timestamp"] as? String {
                    // Shared lenient parser: accepts fractional seconds and skips
                    // the per-line ISO8601DateFormatter allocation.
                    let date = ThreadSafeISO8601DateFormatter.parse(ts)
                    if startTime == nil { startTime = date }
                    endTime = date
                }
            }
        }

        conv.finalizeArrays()

        if inputTokens == 0 && outputTokens == 0 && cacheCreationTokens == 0 && cacheReadTokens == 0 {
            guard userCharCount + assistantCharCount + assistantReasoningCharCount > 0 else { return nil }
            let estimated = OpenBurnBarCore.TokenExtractionUtility.estimateFallbackTokens(
                userVisibleChars: userCharCount,
                assistantVisibleChars: assistantCharCount,
                assistantReasoningChars: assistantReasoningCharCount,
                userMessageCount: userMessageCount,
                assistantMessageCount: assistantMessageCount
            )
            inputTokens = estimated.input
            outputTokens = estimated.output
            usedFallbackEstimate = true
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

        let cost = try OpenBurnBarCore.ModelPricing.lookup(model: model).cost(
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
            endTime: resolvedEnd,
            provenanceMethod: usedFallbackEstimate ? .heuristicEstimate : .providerLog,
            provenanceConfidence: usedFallbackEstimate ? .lowConfidenceEstimate : .exact,
            estimatorVersion: usedFallbackEstimate ? OpenBurnBarCore.TokenExtractionUtility.currentEstimatorVersion : ""
        )

        let conversation = OpenBurnBarCore.ConversationRecord(
            id: OpenBurnBarCore.ConversationRecord.stableId(provider: provider, sessionId: sessionId),
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

    private func cachePath(for file: URL) -> String {
        file.standardizedFileURL.path
    }

    private func appendCached(
        _ cached: ModelFilterCacheEntry,
        includeConversation: Bool,
        usages: inout [TokenUsage],
        conversations: inout [OpenBurnBarCore.ConversationRecord]
    ) {
        if let usage = cached.usage {
            usages.append(usage)
        }
        if includeConversation, let conversation = cached.conversation {
            conversations.append(conversation)
        }
    }

    private func appendParsed(
        _ parsed: (usage: TokenUsage?, conversation: OpenBurnBarCore.ConversationRecord?)?,
        includeConversation: Bool,
        usages: inout [TokenUsage],
        conversations: inout [OpenBurnBarCore.ConversationRecord]
    ) {
        guard let parsed else { return }
        if let usage = parsed.usage {
            usages.append(usage)
        }
        if includeConversation, let conversation = parsed.conversation {
            conversations.append(conversation)
        }
    }

    private func recordObservedFiles(
        _ files: [URL],
        options: OpenBurnBarCore.LogParseOptions
    ) throws {
        guard let tracker = options.fileDiscoveryTracker else { return }
        try options.resourceGovernor?.checkpoint()
        for file in files {
            options.metrics?.recordMetadataStat()
            let attributes = try fileManager.attributesOfItem(atPath: file.path)
            _ = tracker.record(OpenBurnBarCore.ParserDiscoveredFile(
                path: file.standardizedFileURL.path,
                fileSizeBytes: (attributes[.size] as? NSNumber)?.int64Value,
                modificationDate: normalizedCheckpointDate(attributes[.modificationDate] as? Date),
                creationDate: normalizedCheckpointDate(attributes[.creationDate] as? Date),
                fileSystemNumber: (attributes[.systemNumber] as? NSNumber)?.uint64Value,
                fileNumber: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
            ))
        }
    }

    private func normalizedCheckpointDate(_ date: Date?) -> Date? {
        guard let date else { return nil }
        let milliseconds = (date.timeIntervalSince1970 * 1_000).rounded()
        return Date(timeIntervalSince1970: milliseconds / 1_000)
    }

    private func compositeSignature(
        jsonlFile: URL,
        settingsFile: URL,
        metadataFile: URL
    ) -> OpenBurnBarCore.CompositeFileSignature<OpenBurnBarCore.FileSignature>? {
        guard let jsonl = OpenBurnBarCore.FileSignature(for: jsonlFile) else { return nil }
        let settings = OpenBurnBarCore.FileSignature(for: settingsFile)
        let metadata = OpenBurnBarCore.FileSignature(for: metadataFile)
        return OpenBurnBarCore.CompositeFileSignature(primary: jsonl, settings: settings, metadata: metadata)
    }
}

struct ModelFilterCacheEntry: Codable, Equatable {
    let signature: OpenBurnBarCore.CompositeFileSignature<OpenBurnBarCore.FileSignature>
    let usage: TokenUsage?
    let conversation: OpenBurnBarCore.ConversationRecord?
}

/// Parses OpenCode sessions from the local SQLite store (`~/.local/share/opencode/opencode.db`).
///
/// OpenCode persists three tables — `session`, `message`, and `part` — where each row stores a
/// JSON `data` blob. Messages carry role / token / cost / model metadata; parts carry the text
/// content. This parser stitches them into per-session `TokenUsage` rows plus full
/// `OpenBurnBarCore.ConversationRecord` transcripts so OpenCode conversations back up and search like every
/// other CLI agent. Schema discovery is defensive (column and JSON-key fallbacks) so future
/// OpenCode storage tweaks degrade gracefully instead of dropping data.
final class OpenCodeParser: OpenBurnBarCore.LogParser, Sendable {
    let provider: AgentProvider = .openCode

    /// When set, the parser reads this exact `opencode.db` path instead of
    /// discovering it from the environment / default install locations. Keeps
    /// tests hermetic and supports non-default OpenCode data homes.
    private let databasePathOverride: String?
    private let fileManager: FileManager
    private let cacheStore: OpenBurnBarCore.ParserDiskCacheStore<OpenBurnBarCore.CachedUsageBundleEntry<OpenBurnBarCore.FileSetSignature>>
    private let sessionScanCount = OpenBurnBarCore.Locked(0)
    private let sessionCacheHitCount = OpenBurnBarCore.Locked(0)
    private let partReadCount = OpenBurnBarCore.Locked(0)

    init(
        databasePathOverride: String? = nil,
        fileManager: FileManager = .default,
        appPaths: OpenBurnBarCore.OpenBurnBarAppPaths = .live()
    ) {
        self.databasePathOverride = databasePathOverride
        self.fileManager = fileManager
        let cacheURL: URL
        if let databasePathOverride {
            cacheURL = URL(fileURLWithPath: databasePathOverride)
                .deletingLastPathComponent()
                .appendingPathComponent(".obb-mac-opencode-parser-cache.plist")
        } else {
            cacheURL = appPaths.macOpenCodeParserCacheURL
        }
        self.cacheStore = OpenBurnBarCore.ParserDiskCacheStore(
            cacheURL: cacheURL,
            fileManager: fileManager,
            schemaVersion: 1,
            logLabel: "MacOpenCodeParser"
        )
        ParserSupportDirectoryWarmUp.prepare(fileManager: fileManager, appPaths: appPaths)
    }

    var lastSessionScanCount: Int { sessionScanCount.read() }
    var lastSessionCacheHitCount: Int { sessionCacheHitCount.read() }
    var lastPartReadCount: Int { partReadCount.read() }

    func parse(options: OpenBurnBarCore.LogParseOptions) async throws -> OpenBurnBarCore.ParseResult {
        sessionScanCount.write(0)
        sessionCacheHitCount.write(0)
        partReadCount.write(0)
        let fm = fileManager
        let resolved = databasePathOverride.map { ($0 as NSString).expandingTildeInPath }
            ?? Self.resolvedDatabasePath()
        guard let dbPath = resolved, fm.fileExists(atPath: dbPath) else {
            return OpenBurnBarCore.ParseResult(usages: [], conversations: [])
        }
        let dbURL = URL(fileURLWithPath: dbPath)
        let cacheKey = dbURL.standardizedFileURL.path
        var parseCache = cacheStore.load()
        var cacheMutated = false
        defer {
            if cacheMutated {
                cacheStore.persist(parseCache)
            }
        }
        guard try OpenBurnBarCore.ParserFileReadGate(options: options, fileManager: fm).shouldRead(dbURL) else {
            return OpenBurnBarCore.ParseResult(
                usages: parseCache.fileEntries[cacheKey]?.sessions.map { $0.makeUsage(provider: .openCode) } ?? [],
                conversations: []
            )
        }
        let signature = OpenBurnBarCore.FileSetSignature(databaseURL: dbURL, using: fm)
        if !options.includeConversationBodies,
           let signature,
           let cached = parseCache.fileEntries[cacheKey],
           cached.signature == signature {
            sessionCacheHitCount.withLock { $0 += 1 }
            return OpenBurnBarCore.ParseResult(
                usages: cached.sessions.map { $0.makeUsage(provider: .openCode) },
                conversations: []
            )
        }
        sessionScanCount.withLock { $0 += 1 }
        let result = try parseDatabase(
            dbPath: dbPath,
            includeConversationBodies: options.includeConversationBodies
        )
        if let signature {
            parseCache.fileEntries = [
                cacheKey: OpenBurnBarCore.CachedUsageBundleEntry(signature: signature, usages: result.usages)
            ]
            cacheMutated = true
        }
        return options.includeConversationBodies
            ? result
            : OpenBurnBarCore.ParseResult(usages: result.usages, conversations: [])
    }

    static func resolvedDatabasePath() -> String? {
        let env = ProcessInfo.processInfo.environment
        if let explicit = env["OPENCODE_DB_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty {
            return (explicit as NSString).expandingTildeInPath
        }
        if let dataHome = env["OPENCODE_DATA_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines), !dataHome.isEmpty {
            return ((dataHome as NSString).appendingPathComponent("opencode.db") as NSString).expandingTildeInPath
        }
        if let xdg = env["XDG_DATA_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines), !xdg.isEmpty {
            return ((xdg as NSString).appendingPathComponent("opencode/opencode.db") as NSString).expandingTildeInPath
        }
        return ("~/.local/share/opencode/opencode.db" as NSString).expandingTildeInPath
    }

    private struct SessionMeta {
        var title: String?
        var directory: String?
        var created: Date?
        var updated: Date?
    }

    private struct MessageRow {
        let messageID: String
        let role: String
        let time: Double
        var model: String?
        var input = 0
        var output = 0
        var cacheCreation = 0
        var cacheRead = 0
        var cost: Double?
    }

    private func parseDatabase(dbPath: String, includeConversationBodies: Bool) throws -> OpenBurnBarCore.ParseResult {
        var config = Configuration()
        config.readonly = true
        let db = try DatabaseQueue(path: dbPath, configuration: config)

        var sessionMeta: [String: SessionMeta] = [:]
        var messagesBySession: [String: [MessageRow]] = [:]
        var textByMessage: [String: String] = [:]

        try db.read { db in
            let tables = Set(try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table'"))

            if tables.contains("session") {
                for row in try Row.fetchAll(db, sql: "SELECT * FROM session") {
                    guard let json = Self.dataJSON(row) else { continue }
                    let id = Self.identifier(row, json, keys: ["id", "sessionID", "session_id", "sessionId"])
                    guard let sessionID = id else { continue }
                    var meta = SessionMeta()
                    meta.title = (json["title"] as? String)?.nonEmpty
                    meta.directory = (json["directory"] as? String
                        ?? json["cwd"] as? String
                        ?? json["worktree"] as? String)?.nonEmpty
                    let time = json["time"] as? [String: Any]
                    meta.created = Self.date(time?["created"] ?? json["created"] ?? Self.columnValue(row, "time_created"))
                    meta.updated = Self.date(time?["updated"] ?? json["updated"] ?? Self.columnValue(row, "time_updated"))
                    sessionMeta[sessionID] = meta
                }
            }

            if tables.contains("message") {
                for row in try Row.fetchAll(db, sql: "SELECT * FROM message") {
                    guard let json = Self.dataJSON(row),
                          let sessionID = Self.identifier(row, json, keys: ["sessionID", "session_id", "sessionId"]) else { continue }
                    let messageID = Self.identifier(row, json, keys: ["id", "messageID", "message_id", "messageId"]) ?? UUID().uuidString
                    let role = (json["role"] as? String ?? "").lowercased()
                    let time = json["time"] as? [String: Any]
                    let created = Self.epoch(time?["created"] ?? json["created"] ?? Self.columnValue(row, "time_created")) ?? 0
                    var message = MessageRow(messageID: messageID, role: role, time: created)
                    if let tokens = Self.openCodeTokens(json) {
                        message.input = tokens.input
                        message.output = tokens.output
                        message.cacheCreation = tokens.cacheCreation
                        message.cacheRead = tokens.cacheRead
                    }
                    message.cost = Self.doubleValue(json["cost"])
                    message.model = Self.resolvedModel(json)
                    messagesBySession[sessionID, default: []].append(message)
                }
            }

            if tables.contains("part") {
                let heuristicMessageIDs = Set(messagesBySession.flatMap { _, raw -> [String] in
                    let input = raw.reduce(0) { $0 + $1.input }
                    let output = raw.reduce(0) { $0 + $1.output }
                    let cacheCreation = raw.reduce(0) { $0 + $1.cacheCreation }
                    let cacheRead = raw.reduce(0) { $0 + $1.cacheRead }
                    guard input == 0 && output == 0 && cacheCreation == 0 && cacheRead == 0 else {
                        return []
                    }
                    return raw.map(\.messageID)
                })
                let scopedIDs: Set<String>? = includeConversationBodies ? nil : heuristicMessageIDs
                if includeConversationBodies || !heuristicMessageIDs.isEmpty {
                    for row in try fetchOpenCodePartRows(db: db, messageIDs: scopedIDs) {
                        guard let json = Self.dataJSON(row) else { continue }
                        let type = (json["type"] as? String ?? "text").lowercased()
                        guard type == "text" || type == "reasoning" else { continue }
                        guard let messageID = Self.identifier(row, json, keys: ["messageID", "message_id", "messageId"]) else { continue }
                        if let scopedIDs, !scopedIDs.contains(messageID) { continue }
                        let text = (json["text"] as? String ?? json["content"] as? String ?? "")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { continue }
                        if var existing = textByMessage[messageID] {
                            existing += "\n\n" + text
                            textByMessage[messageID] = existing
                        } else {
                            textByMessage[messageID] = text
                        }
                    }
                }
            }
        }

        var usages: [TokenUsage] = []
        var conversations: [OpenBurnBarCore.ConversationRecord] = []

        for (sessionID, rawMessages) in messagesBySession {
            let messages = rawMessages.sorted { $0.time < $1.time }
            let meta = sessionMeta[sessionID] ?? SessionMeta()

            var input = 0, output = 0, cacheCreation = 0, cacheRead = 0
            var cost = 0.0
            var model = "opencode"
            for message in messages {
                input += message.input
                output += message.output
                cacheCreation += message.cacheCreation
                cacheRead += message.cacheRead
                if let messageCost = message.cost { cost += messageCost }
                if let messageModel = message.model?.nonEmpty { model = messageModel }
            }

            let directory = meta.directory ?? "~"
            let projectName = (directory as NSString).lastPathComponent.nonEmpty
                ?? meta.title?.nonEmpty
                ?? sessionID
            let firstTime = messages.first?.time ?? 0
            let lastTime = messages.last?.time ?? firstTime
            let startTime = meta.created ?? Self.date(fromEpoch: firstTime) ?? Date()
            let endTime = meta.updated ?? Self.date(fromEpoch: lastTime) ?? startTime

            var usedFallback = false
            if input == 0 && output == 0 && cacheCreation == 0 && cacheRead == 0 {
                let userChars = messages
                    .filter { $0.role == "user" }
                    .reduce(0) { $0 + (textByMessage[$1.messageID]?.count ?? 0) }
                let assistantChars = messages
                    .filter { $0.role == "assistant" }
                    .reduce(0) { $0 + (textByMessage[$1.messageID]?.count ?? 0) }
                guard userChars + assistantChars > 0 else { continue }
                let estimated = OpenBurnBarCore.TokenExtractionUtility.estimateFallbackTokens(
                    userVisibleChars: userChars,
                    assistantVisibleChars: assistantChars,
                    assistantReasoningChars: 0,
                    userMessageCount: max(messages.filter { $0.role == "user" }.count, 1),
                    assistantMessageCount: max(messages.filter { $0.role == "assistant" }.count, 1)
                )
                input = estimated.input
                output = estimated.output
                usedFallback = true
            }

            if cost <= 0 {
                cost = try OpenBurnBarCore.ModelPricing.lookup(model: model).cost(
                    inputTokens: input,
                    outputTokens: output,
                    cacheCreationTokens: cacheCreation,
                    cacheReadTokens: cacheRead
                )
            }

            usages.append(
                TokenUsage(
                    provider: .openCode,
                    sessionId: sessionID,
                    projectName: projectName,
                    model: model,
                    inputTokens: input,
                    outputTokens: output,
                    cacheCreationTokens: cacheCreation,
                    cacheReadTokens: cacheRead,
                    costUSD: cost,
                    startTime: startTime,
                    endTime: endTime,
                    provenanceMethod: usedFallback ? .heuristicEstimate : .providerLog,
                    provenanceConfidence: usedFallback ? .lowConfidenceEstimate : .exact,
                    estimatorVersion: usedFallback ? OpenBurnBarCore.TokenExtractionUtility.currentEstimatorVersion : ""
                )
            )

            var fullText = ""
            var firstUser: String?
            var lastAssistant = ""
            var userWords = 0
            var assistantWords = 0
            var renderedMessages = 0
            for message in messages {
                guard let text = textByMessage[message.messageID]?.nonEmpty else { continue }
                let isAssistant = message.role == "assistant"
                if isAssistant {
                    assistantWords += text.split { $0.isWhitespace || $0.isNewline }.count
                    lastAssistant = text
                } else {
                    userWords += text.split { $0.isWhitespace || $0.isNewline }.count
                    if firstUser == nil { firstUser = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120)) }
                }
                if !fullText.isEmpty { fullText += "\n\n" }
                fullText += OpenBurnBarCore.SessionLogMarkdownFormatter.transcriptTurnMarkdown(isAssistant: isAssistant, body: text)
                renderedMessages += 1
            }

            conversations.append(
                OpenBurnBarCore.ConversationRecord(
                    id: OpenBurnBarCore.ConversationRecord.stableId(provider: .openCode, sessionId: sessionID),
                    provider: .openCode,
                    sessionId: sessionID,
                    projectName: projectName,
                    startTime: startTime,
                    endTime: endTime,
                    messageCount: renderedMessages,
                    userWordCount: userWords,
                    assistantWordCount: assistantWords,
                    keyFiles: [],
                    keyCommands: [],
                    keyTools: [],
                    inferredTaskTitle: meta.title?.nonEmpty ?? firstUser ?? sessionID,
                    lastAssistantMessage: String(lastAssistant.prefix(500)),
                    fullText: fullText,
                    indexedAt: Date(),
                    workingDirectory: meta.directory,
                    fileModifiedAt: endTime,
                    summary: nil
                )
            )
        }

        return OpenBurnBarCore.ParseResult(usages: usages, conversations: conversations)
    }

    private func fetchOpenCodePartRows(db: Database, messageIDs: Set<String>?) throws -> [Row] {
        let columns = Set(
            try Row.fetchAll(db, sql: "PRAGMA table_info(part)").compactMap { $0["name"] as? String }
        )
        let selectList = OpenBurnBarCore.OpenCodePartQuery.selectList(existingColumns: columns)
        let rows: [Row]
        if let messageIDs {
            if let idColumn = OpenBurnBarCore.OpenCodePartQuery.idColumn(in: columns) {
                rows = try Self.queryBoundedOpenCodePartRows(
                    db: db,
                    whereSQL: { OpenBurnBarCore.OpenCodePartQuery.idColumnWhereSQL(idColumn: idColumn, placeholderCount: $0) },
                    messageIDs: messageIDs,
                    selectList: OpenBurnBarCore.OpenCodePartQuery.selectList(
                        existingColumns: columns,
                        required: [idColumn]
                    )
                )
            } else if let payloadColumn = OpenBurnBarCore.OpenCodePartQuery.payloadColumn(in: columns),
                      Self.sqliteSupportsJSONExtract(db) {
                let bounded = try Self.queryBoundedOpenCodePartRows(
                    db: db,
                    whereSQL: { OpenBurnBarCore.OpenCodePartQuery.jsonExtractWhereSQL(payloadColumn: payloadColumn, placeholderCount: $0) },
                    messageIDs: messageIDs,
                    selectList: selectList
                )
                rows = bounded.isEmpty
                    ? try Row.fetchAll(db, sql: "SELECT \(selectList) FROM part")
                    : bounded
            } else {
                rows = try Row.fetchAll(db, sql: "SELECT \(selectList) FROM part")
            }
        } else {
            rows = try Row.fetchAll(db, sql: "SELECT \(selectList) FROM part")
        }
        partReadCount.withLock { $0 += rows.count }
        return rows
    }

    private static func sqliteSupportsJSONExtract(_ db: Database) -> Bool {
        do {
            guard let row = try Row.fetchOne(db, sql: OpenBurnBarCore.OpenCodePartQuery.jsonExtractProbeSQL) else {
                return false
            }
            let probe = Self.columnValue(row, "probe")
            return OpenBurnBarCore.OpenCodePartQuery.jsonExtractProbeSucceeded(
                intValue: probe as? Int64,
                textValue: probe as? String
            )
        } catch {
            return false
        }
    }

    private static func queryBoundedOpenCodePartRows(
        db: Database,
        whereSQL: (Int) -> String?,
        messageIDs: Set<String>,
        selectList: String
    ) throws -> [Row] {
        guard !messageIDs.isEmpty else { return [] }
        var collected: [Row] = []
        let ordered = Array(messageIDs)
        var index = 0
        while index < ordered.count {
            let end = min(index + OpenBurnBarCore.OpenCodePartQuery.chunkSize, ordered.count)
            let chunk = Array(ordered[index..<end])
            guard let clause = whereSQL(chunk.count) else { return [] }
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT \(selectList) FROM part WHERE \(clause)",
                arguments: StatementArguments(chunk)
            )
            collected.append(contentsOf: rows)
            index = end
        }
        return collected
    }

    // MARK: - JSON / column helpers

    private static func dataJSON(_ row: Row) -> [String: Any]? {
        for column in ["data", "json", "value", "content", "payload"] {
            if let text: String = row[column],
               let data = text.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { // try?-ok(column decode, try next)
                return json
            }
        }
        return nil
    }

    private static func columnValue(_ row: Row, _ column: String) -> Any? {
        // Read through `DatabaseValue` so a type mismatch (e.g. a TEXT epoch
        // column) never trips GRDB's force-decode `fatalError`.
        guard let dbValue: DatabaseValue = row[column] else { return nil }
        switch dbValue.storage {
        case .int64(let value): return value
        case .double(let value): return value
        case .string(let value): return value
        case .null, .blob: return nil
        }
    }

    private static func identifier(_ row: Row, _ json: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value: String = row[key], !value.isEmpty { return value }
        }
        for key in keys {
            if let value = json[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    private static func resolvedModel(_ json: [String: Any]) -> String? {
        let modelID = (json["modelID"] as? String ?? json["model"] as? String ?? json["model_id"] as? String)?.nonEmpty
        if let modelID { return OpenBurnBarCore.TokenExtractionUtility.normalizeModelName(modelID) }
        if let provider = (json["providerID"] as? String ?? json["provider"] as? String)?.nonEmpty {
            return OpenBurnBarCore.TokenExtractionUtility.normalizeModelName(provider)
        }
        return nil
    }

    private static func openCodeTokens(_ json: [String: Any]) -> (input: Int, output: Int, cacheCreation: Int, cacheRead: Int)? {
        guard let tokens = json["tokens"] as? [String: Any] else {
            if let usage = json["usage"] as? [String: Any] {
                let extracted = OpenBurnBarCore.TokenExtractionUtility.extractUsageTokens(usage)
                return (extracted.input, extracted.output, extracted.cacheCreation, extracted.cacheRead)
            }
            return nil
        }
        let input = intValue(tokens["input"])
        let output = intValue(tokens["output"])
        var cacheRead = intValue(tokens["cache_read"])
        var cacheWrite = intValue(tokens["cache_write"])
        if let cache = tokens["cache"] as? [String: Any] {
            cacheRead = intValue(cache["read"])
            cacheWrite = intValue(cache["write"])
        }
        return (input, output, cacheWrite, cacheRead)
    }

    private static func intValue(_ value: Any?) -> Int {
        switch value {
        case let int as Int: return int
        case let int as Int64: return Int(int)
        case let double as Double: return Int(double.rounded())
        case let number as NSNumber: return number.intValue
        case let string as String: return Int(string) ?? Int(Double(string) ?? 0)
        default: return 0
        }
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        switch value {
        case let double as Double: return double
        case let int as Int: return Double(int)
        case let number as NSNumber: return number.doubleValue
        case let string as String: return Double(string)
        default: return nil
        }
    }

    private static func epoch(_ value: Any?) -> Double? {
        switch value {
        case let double as Double: return double
        case let int as Int: return Double(int)
        case let int as Int64: return Double(int)
        case let number as NSNumber: return number.doubleValue
        case let string as String:
            if let double = Double(string) { return double }
            return ThreadSafeISO8601DateFormatter.parse(string)?.timeIntervalSince1970
        default: return nil
        }
    }

    private static func date(_ value: Any?) -> Date? {
        if let string = value as? String, let parsed = ThreadSafeISO8601DateFormatter.parse(string) {
            return parsed
        }
        guard let epoch = epoch(value) else { return nil }
        return date(fromEpoch: epoch)
    }

    private static func date(fromEpoch epoch: Double) -> Date? {
        guard epoch > 0 else { return nil }
        return OpenBurnBarCore.TimestampNormalizationUtility.date(fromEpoch: epoch)
    }
}

/// Parses Pi Agent workspace logs from `~/.pi/sessions/*.jsonl`.
///
/// Pi writes one JSONL file per session with user/assistant turns and optional inline `usage`
/// blocks. This parser extracts exact tokens when present, estimates from transcript volume
/// otherwise, and always emits a full `OpenBurnBarCore.ConversationRecord` so Pi conversations back up and
/// search alongside every other agent.
final class PiAgentParser: OpenBurnBarCore.LogParser, Sendable {
    let provider: AgentProvider = .piAgent
    private static let cacheCheckpointFileInterval = 16
    private static let cancellationCheckpointLineInterval = 1_024
    private let fileManager: FileManager
    private let sessionsDirectoryOverride: URL?
    private let cacheStore: OpenBurnBarCore.ParserDiskCacheStore<OpenBurnBarCore.CachedUsageBundleEntry<OpenBurnBarCore.FileSignature>>
    private let sessionScanCount = OpenBurnBarCore.Locked(0)
    private let sessionCacheHitCount = OpenBurnBarCore.Locked(0)
    private let contentExtractionLineCount = OpenBurnBarCore.Locked(0)

    init(
        fileManager: FileManager = .default,
        sessionsDirectoryOverride: URL? = nil,
        appPaths: OpenBurnBarCore.OpenBurnBarAppPaths = .live()
    ) {
        self.fileManager = fileManager
        self.sessionsDirectoryOverride = sessionsDirectoryOverride
        let cacheURL: URL
        if let sessionsDirectoryOverride {
            cacheURL = sessionsDirectoryOverride.appendingPathComponent(".obb-mac-pi-parser-cache.plist")
        } else {
            cacheURL = appPaths.macPiAgentParserCacheURL
        }
        self.cacheStore = OpenBurnBarCore.ParserDiskCacheStore(
            cacheURL: cacheURL,
            fileManager: fileManager,
            schemaVersion: 1,
            logLabel: "MacPiAgentParser"
        )
        ParserSupportDirectoryWarmUp.prepare(fileManager: fileManager, appPaths: appPaths)
    }

    var lastSessionScanCount: Int { sessionScanCount.read() }
    var lastSessionCacheHitCount: Int { sessionCacheHitCount.read() }
    var lastContentExtractionLineCount: Int { contentExtractionLineCount.read() }

    func parse(options: OpenBurnBarCore.LogParseOptions) async throws -> OpenBurnBarCore.ParseResult {
        sessionScanCount.write(0)
        sessionCacheHitCount.write(0)
        contentExtractionLineCount.write(0)
        let fm = fileManager
        let gate = OpenBurnBarCore.ParserFileReadGate(options: options, fileManager: fm)
        let sessionsPath = sessionsDirectoryOverride?.path
            ?? (provider.logDirectory as NSString).expandingTildeInPath
        guard fm.fileExists(atPath: sessionsPath) else {
            return OpenBurnBarCore.ParseResult(usages: [], conversations: [])
        }

        let sessionsURL = URL(fileURLWithPath: sessionsPath)
        // try?-ok(unreadable Pi sessions directory yields no JSONL files)
        let jsonlFiles = (try? fm.contentsOfDirectory(
            at: sessionsURL,
            includingPropertiesForKeys: OpenBurnBarCore.FileSignature.directoryListingPrefetchKeys
        ))?
            .filter { $0.pathExtension == "jsonl" } ?? []

        var usages: [TokenUsage] = []
        var conversations: [OpenBurnBarCore.ConversationRecord] = []
        var parseCache = cacheStore.load()
        var activePaths = Set<String>()
        var pendingCacheMutations = 0
        defer {
            if pendingCacheMutations > 0 {
                cacheStore.persist(parseCache)
            }
        }

        for file in jsonlFiles {
            let cacheKey = file.standardizedFileURL.path
            activePaths.insert(cacheKey)
            guard try gate.shouldRead(file) else { continue }
            let signature = OpenBurnBarCore.FileSignature(for: file, using: fm)
            if !options.includeConversationBodies,
               let signature,
               let cached = parseCache.fileEntries[cacheKey],
               cached.signature == signature {
                sessionCacheHitCount.withLock { $0 += 1 }
                usages.append(contentsOf: cached.sessions.map { $0.makeUsage(provider: .piAgent) })
                continue
            }
            sessionScanCount.withLock { $0 += 1 }
            let sessionId = file.deletingPathExtension().lastPathComponent
            if let pair = try parseSession(
                file: file,
                sessionId: sessionId,
                includeConversationBodies: options.includeConversationBodies,
                resourceGovernor: options.resourceGovernor
            ) {
                contentExtractionLineCount.withLock { $0 += pair.contentExtractionLineCount }
                if let usage = pair.usage { usages.append(usage) }
                if options.includeConversationBodies, let conversation = pair.conversation {
                    conversations.append(conversation)
                }
                if let signature {
                    parseCache.fileEntries[cacheKey] = OpenBurnBarCore.CachedUsageBundleEntry(
                        signature: signature,
                        usages: pair.usage.map { [$0] } ?? []
                    )
                    pendingCacheMutations += 1
                    if pendingCacheMutations >= Self.cacheCheckpointFileInterval {
                        cacheStore.persist(parseCache)
                        pendingCacheMutations = 0
                    }
                }
            }
        }

        let stalePaths = Set(parseCache.fileEntries.keys).subtracting(activePaths)
        if !stalePaths.isEmpty {
            for stalePath in stalePaths {
                parseCache.fileEntries.removeValue(forKey: stalePath)
            }
            pendingCacheMutations += stalePaths.count
        }

        return OpenBurnBarCore.ParseResult(usages: usages, conversations: conversations)
    }

    private func parseSession(
        file: URL,
        sessionId: String,
        includeConversationBodies: Bool,
        resourceGovernor: OpenBurnBarCore.ParserResourceGovernor?
    ) throws -> (
        usage: TokenUsage?,
        conversation: OpenBurnBarCore.ConversationRecord?,
        contentExtractionLineCount: Int
    )? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil } // try?-ok(log open, skip if absent)
        defer { try? handle.close() } // try?-ok(handle teardown)

        let mtime = (try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate]) as? Date // try?-ok(optional mtime)

        var inputTokens = 0
        var outputTokens = 0
        var cacheCreationTokens = 0
        var cacheReadTokens = 0
        var model = "pi"
        var startTime: Date?
        var endTime: Date?
        var workingDirectory: String?
        var userChars = 0
        var assistantChars = 0
        var userWords = 0
        var assistantWords = 0
        var messageCount = 0
        var transcriptParts: [String] = []
        var firstUser: String?
        var lastAssistant = ""
        var lineCount = 0
        var contentExtractionLineCount = 0

        for line in handle.readAllUTF8Lines() {
            lineCount += 1
            if lineCount % Self.cancellationCheckpointLineInterval == 0 {
                try Task.checkCancellation()
                try resourceGovernor?.checkpoint()
            }

            OpenBurnBarCore.parserAutoReleasePool {
                // try?-ok(per-line decode, skip)
                guard let json = logLineObject(try? JSONSerialization.jsonObject(
                    with: Data(line.utf8)
                )) else {
                    return
                }

                if let ts = json["timestamp"] as? String ?? json["time"] as? String,
                   let date = ThreadSafeISO8601DateFormatter.parse(ts) {
                    if startTime == nil { startTime = date }
                    endTime = date
                }
                if let m = (json["model"] as? String ?? logLineObject(json["message"])?["model"] as? String)?.nonEmpty {
                    model = OpenBurnBarCore.TokenExtractionUtility.normalizeModelName(m)
                }
                if let cwd = (json["cwd"] as? String ?? json["workingDirectory"] as? String ?? json["directory"] as? String)?.nonEmpty {
                    workingDirectory = cwd
                }

                if let usage = logLineObject(json["usage"])
                    ?? logLineObject(logLineObject(json["message"])?["usage"]) {
                    let extracted = OpenBurnBarCore.TokenExtractionUtility.extractUsageTokens(usage)
                    inputTokens += extracted.input
                    outputTokens += extracted.output
                    cacheCreationTokens += extracted.cacheCreation
                    cacheReadTokens += extracted.cacheRead
                }

                guard includeConversationBodies else { return }
                contentExtractionLineCount += 1

                let message = logLineObject(json["message"])
                let role = (json["role"] as? String ?? message?["role"] as? String ?? json["type"] as? String ?? "").lowercased()
                let content = Self.contentText(json["content"] ?? message?["content"] ?? json["text"])

                guard !content.isEmpty else { return }

                if role == "user" || role == "human" || role == "user_message" {
                    userChars += content.count
                    messageCount += 1
                    userWords += content.split { $0.isWhitespace || $0.isNewline }.count
                    if firstUser == nil {
                        firstUser = String(content.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
                    }
                    transcriptParts.append(
                        OpenBurnBarCore.SessionLogMarkdownFormatter.transcriptTurnMarkdown(
                            isAssistant: false,
                            body: content
                        )
                    )
                } else if role == "assistant" || role == "ai" || role == "assistant_message" {
                    assistantChars += content.count
                    messageCount += 1
                    assistantWords += content.split { $0.isWhitespace || $0.isNewline }.count
                    lastAssistant = String(content.prefix(500))
                    transcriptParts.append(
                        OpenBurnBarCore.SessionLogMarkdownFormatter.transcriptTurnMarkdown(
                            isAssistant: true,
                            body: content
                        )
                    )
                }
            }
        }
        try Task.checkCancellation()
        try resourceGovernor?.checkpoint()

        let hasUsage = inputTokens > 0 || outputTokens > 0 || cacheCreationTokens > 0 || cacheReadTokens > 0
        var usedFallback = false
        if !hasUsage {
            if !includeConversationBodies {
                let fallback = try Self.fallbackContentMetrics(
                    file: file,
                    resourceGovernor: resourceGovernor
                )
                userChars = fallback.userChars
                assistantChars = fallback.assistantChars
                messageCount = fallback.messageCount
                contentExtractionLineCount += fallback.lineCount
            }
            guard userChars + assistantChars > 0 else {
                return (nil, nil, contentExtractionLineCount)
            }
            let estimated = OpenBurnBarCore.TokenExtractionUtility.estimateFallbackTokens(
                userVisibleChars: userChars,
                assistantVisibleChars: assistantChars,
                assistantReasoningChars: 0,
                userMessageCount: max(messageCount / 2, 1),
                assistantMessageCount: max(messageCount / 2, 1)
            )
            inputTokens = estimated.input
            outputTokens = estimated.output
            usedFallback = true
        }

        guard inputTokens > 0 || outputTokens > 0 || cacheCreationTokens > 0 || cacheReadTokens > 0 else {
            return (nil, nil, contentExtractionLineCount)
        }

        guard let cost = AppLogger.shared.silentlyOptional("domain_core_pricing_cost", try OpenBurnBarCore.ModelPricing.lookup(model: model).cost(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheCreationTokens: cacheCreationTokens,
            cacheReadTokens: cacheReadTokens
        )) else {
            return (nil, nil, contentExtractionLineCount)
        }
        let projectName = workingDirectory.map { ($0 as NSString).lastPathComponent.nonEmpty ?? $0 } ?? sessionId

        let usage = TokenUsage(
            provider: .piAgent,
            sessionId: sessionId,
            projectName: projectName,
            model: model,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheCreationTokens: cacheCreationTokens,
            cacheReadTokens: cacheReadTokens,
            costUSD: cost,
            startTime: startTime ?? mtime ?? Date(),
            endTime: endTime ?? mtime ?? Date(),
            provenanceMethod: usedFallback ? .heuristicEstimate : .providerLog,
            provenanceConfidence: usedFallback ? .lowConfidenceEstimate : .exact,
            estimatorVersion: usedFallback ? OpenBurnBarCore.TokenExtractionUtility.currentEstimatorVersion : ""
        )

        let conversation = includeConversationBodies
            ? OpenBurnBarCore.ConversationRecord(
            id: OpenBurnBarCore.ConversationRecord.stableId(provider: .piAgent, sessionId: sessionId),
            provider: .piAgent,
            sessionId: sessionId,
            projectName: projectName,
            startTime: startTime ?? usage.startTime,
            endTime: endTime ?? usage.endTime,
            messageCount: messageCount,
            userWordCount: userWords,
            assistantWordCount: assistantWords,
            keyFiles: [],
            keyCommands: [],
            keyTools: [],
            inferredTaskTitle: firstUser ?? sessionId,
            lastAssistantMessage: lastAssistant,
            fullText: transcriptParts.joined(separator: "\n\n"),
            indexedAt: Date(),
            workingDirectory: workingDirectory,
            fileModifiedAt: mtime,
            summary: nil
        )
            : nil

        return (usage, conversation, contentExtractionLineCount)
    }

    private static func fallbackContentMetrics(
        file: URL,
        resourceGovernor: OpenBurnBarCore.ParserResourceGovernor?
    ) throws -> (userChars: Int, assistantChars: Int, messageCount: Int, lineCount: Int) {
        // try?-ok(unreadable file falls back to zeroed metrics)
        guard let handle = try? FileHandle(forReadingFrom: file) else {
            return (0, 0, 0, 0)
        }
        defer { try? handle.close() } // try?-ok(handle teardown)

        var userChars = 0
        var assistantChars = 0
        var messageCount = 0
        var lineCount = 0
        for line in handle.readAllUTF8Lines() {
            lineCount += 1
            if lineCount % cancellationCheckpointLineInterval == 0 {
                try Task.checkCancellation()
                try resourceGovernor?.checkpoint()
            }
            OpenBurnBarCore.parserAutoReleasePool {
                // try?-ok(per-line decode, skip)
                guard let json = logLineObject(try? JSONSerialization.jsonObject(
                    with: Data(line.utf8)
                )) else {
                    return
                }
                let message = logLineObject(json["message"])
                let role = (
                    json["role"] as? String
                        ?? message?["role"] as? String
                        ?? json["type"] as? String
                        ?? ""
                ).lowercased()
                let content = contentText(
                    json["content"] ?? message?["content"] ?? json["text"]
                )
                guard !content.isEmpty else { return }
                if role == "user" || role == "human" || role == "user_message" {
                    userChars += content.count
                    messageCount += 1
                } else if role == "assistant" || role == "ai" || role == "assistant_message" {
                    assistantChars += content.count
                    messageCount += 1
                }
            }
        }
        try Task.checkCancellation()
        try resourceGovernor?.checkpoint()
        return (userChars, assistantChars, messageCount, lineCount)
    }

    /// Flattens Pi content that may be a plain string or an array of `{type, text}` blocks.
    private static func contentText(_ raw: Any?) -> String {
        if let string = raw as? String { return string }
        if let blocks = raw as? [[String: Any]] {
            let parts = blocks.compactMap { block -> String? in
                let type = (block["type"] as? String ?? "text").lowercased()
                guard type == "text" || type == "reasoning" || type.isEmpty else { return nil }
                return (block["text"] as? String ?? block["content"] as? String)?.nonEmpty
            }
            return parts.joined(separator: "\n\n")
        }
        return ""
    }
}
