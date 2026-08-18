import Foundation
import OpenBurnBarKernel
import OpenBurnBarSQLiteReader

// Cross-platform lifts for provider stores that historically lived only in the
// macOS UsageAggregator. These parsers deliberately read local artifacts only;
// they never call provider APIs or infer a credential from the filesystem.

private struct LocalUsageJSONLineSequence: Sequence {
    let fileURL: URL

    func makeIterator() -> AnyIterator<[String: Any]> {
        let state = LocalUsageJSONLineIterator(fileURL: fileURL)
        return AnyIterator { state.next() }
    }
}

private final class LocalUsageJSONLineIterator {
    private let handle: FileHandle?
    private let reader: BufferedLineReader?
    private var isFinished = false

    init(fileURL: URL) {
        let handle = try? FileHandle(forReadingFrom: fileURL)
        self.handle = handle
        self.reader = handle.map { BufferedLineReader(fileHandle: $0) }
    }

    deinit {
        try? handle?.close()
    }

    func next() -> [String: Any]? {
        guard !isFinished, let reader else { return nil }
        while let line = reader.nextLine() {
            if let object = parserAutoReleasePool({ () -> [String: Any]? in
                try? JSONSerialization.jsonObject(with: Data(line.text.utf8)) as? [String: Any]
            }) {
                return object
            }
        }
        isFinished = true
        try? handle?.close()
        return nil
    }
}

private enum LocalUsageParserSupport {
    struct Turn: Sendable {
        let role: String
        let text: String
        let timestamp: Date?
    }

    static func idleCacheURL(overrideDirectory: URL?, live: URL, fileName: String) -> URL {
        if let overrideDirectory {
            return overrideDirectory.appendingPathComponent(fileName)
        }
        return live
    }

    static func expanded(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    static func files(in root: URL, extensions: Set<String>, recursive: Bool = true) -> [URL] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return [] }
        if !recursive {
            return (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: FileSignature.directoryListingPrefetchKeys))?
                .filter { extensions.contains($0.pathExtension.lowercased()) }
                .sorted { $0.path < $1.path } ?? []
        }
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: FileSignature.directoryListingPrefetchKeys,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return enumerator.compactMap { item in
            guard let url = item as? URL,
                  extensions.contains(url.pathExtension.lowercased()),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            else { return nil }
            return url
        }.sorted { $0.path < $1.path }
    }

    static func jsonObjects(at file: URL) -> [[String: Any]] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        if let object = try? JSONSerialization.jsonObject(with: data) {
            if let array = object as? [[String: Any]] { return array }
            if let dictionary = object as? [String: Any] { return [dictionary] }
        }
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            guard let lineData = String(line).data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
        }
    }

    static func jsonLines(at file: URL) -> LocalUsageJSONLineSequence {
        LocalUsageJSONLineSequence(fileURL: file)
    }

    static func int(_ value: Any?) -> Int {
        switch value {
        case let value as Int: return value
        case let value as Int64: return Int(clamping: value)
        case let value as Double: return Int(value.rounded())
        case let value as NSNumber: return value.intValue
        case let value as String: return Int(value) ?? Int(Double(value) ?? 0)
        default: return 0
        }
    }

    static func double(_ value: Any?) -> Double? {
        switch value {
        case let value as Double: return value
        case let value as Int: return Double(value)
        case let value as Int64: return Double(value)
        case let value as NSNumber: return value.doubleValue
        case let value as String: return Double(value)
        default: return nil
        }
    }

    static func string(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func dictionary(_ value: Any?) -> [String: Any]? { value as? [String: Any] }

    static func firstString(_ object: [String: Any], keys: [String]) -> String? {
        keys.lazy.compactMap { string(object[$0]) }.first
    }

    static func epoch(_ value: Any?) -> Double? {
        if let string = value as? String {
            if let number = Double(string) { return number }
            return ThreadSafeISO8601DateFormatter.parse(string)?.timeIntervalSince1970
        }
        return double(value)
    }

    static func date(_ value: Any?, fallback: Date? = nil) -> Date? {
        guard let raw = epoch(value) else { return fallback }
        return TimestampNormalizationUtility.date(fromEpoch: raw, fallback: fallback ?? Date())
    }

    static func modificationDate(_ file: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate]) as? Date
    }

    static func usage(
        provider: AgentProvider,
        sessionID: String,
        project: String,
        model: String,
        input: Int,
        output: Int,
        cacheCreation: Int = 0,
        cacheRead: Int = 0,
        reasoning: Int = 0,
        cost: Double,
        start: Date,
        end: Date,
        method: UsageProvenanceMethod,
        confidence: UsageProvenanceConfidence,
        estimatorVersion: String = ""
    ) -> TokenUsage? {
        guard input > 0 || output > 0 || cacheCreation > 0 || cacheRead > 0 || reasoning > 0 else { return nil }
        return TokenUsage(
            provider: provider,
            sessionId: sessionID,
            projectName: project,
            model: model,
            inputTokens: input,
            outputTokens: output,
            cacheCreationTokens: cacheCreation,
            cacheReadTokens: cacheRead,
            reasoningTokens: reasoning,
            costUSD: cost,
            startTime: start,
            endTime: end,
            provenanceMethod: method,
            provenanceConfidence: confidence,
            estimatorVersion: estimatorVersion
        )
    }

    static func transcript(
        provider: AgentProvider,
        sessionID: String,
        project: String,
        turns: [Turn],
        start: Date?,
        end: Date?,
        fileModifiedAt: Date?,
        workingDirectory: String? = nil
    ) -> ConversationRecord {
        let userTurns = turns.filter { $0.role == "user" || $0.role == "human" }
        let assistantTurns = turns.filter { $0.role == "assistant" || $0.role == "agent" || $0.role == "model" }
        let fullText = turns.map { turn in
            SessionLogMarkdownFormatter.transcriptTurnMarkdown(
                isAssistant: turn.role == "assistant" || turn.role == "agent" || turn.role == "model",
                body: turn.text
            )
        }.joined(separator: "\n\n")
        let firstUser = userTurns.first?.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return ConversationRecord(
            id: ConversationRecord.stableId(provider: provider, sessionId: sessionID),
            provider: provider,
            sessionId: sessionID,
            projectName: project,
            startTime: start,
            endTime: end,
            messageCount: turns.count,
            userWordCount: userTurns.reduce(0) { $0 + $1.text.split { $0.isWhitespace || $0.isNewline }.count },
            assistantWordCount: assistantTurns.reduce(0) { $0 + $1.text.split { $0.isWhitespace || $0.isNewline }.count },
            keyFiles: [],
            keyCommands: [],
            keyTools: [],
            inferredTaskTitle: String((firstUser.flatMap { $0.isEmpty ? nil : $0 } ?? project).prefix(120)),
            lastAssistantMessage: String((assistantTurns.last?.text ?? "").prefix(500)),
            fullText: fullText,
            indexedAt: Date(),
            workingDirectory: workingDirectory,
            fileModifiedAt: fileModifiedAt,
            summary: nil
        )
    }

    static func contentText(_ value: Any?) -> String {
        switch value {
        case let string as String: return string.trimmingCharacters(in: .whitespacesAndNewlines)
        case let array as [Any]: return array.map(contentText).filter { !$0.isEmpty }.joined(separator: "\n")
        case let object as [String: Any]:
            for key in ["text", "content", "value", "output"] where object[key] != nil {
                let text = contentText(object[key])
                if !text.isEmpty { return text }
            }
            return ""
        default: return ""
        }
    }

    static func usageDict(_ object: [String: Any]) -> [String: Any]? {
        if let usage = dictionary(object["usage"]) { return usage }
        if let usage = dictionary(object["tokenUsage"]) { return usage }
        if let message = dictionary(object["message"]) {
            return dictionary(message["usage"]) ?? dictionary(message["tokenUsage"])
        }
        return nil
    }

    static func extracted(_ object: [String: Any]) -> ExtractedTokenUsage {
        guard let usage = usageDict(object) else { return ExtractedTokenUsage(input: 0, output: 0, cacheCreation: 0, cacheRead: 0, reasoningTokens: 0) }
        return TokenExtractionUtility.extractUsageTokens(usage)
    }

    static func model(in object: [String: Any]) -> String? {
        if let model = firstString(object, keys: ["model", "modelName", "model_name", "modelId", "model_id"]) {
            return TokenExtractionUtility.normalizeModelName(model)
        }
        if let message = dictionary(object["message"]),
           let model = firstString(message, keys: ["model", "modelName", "model_name", "modelId", "model_id"]) {
            return TokenExtractionUtility.normalizeModelName(model)
        }
        return nil
    }
}

// MARK: Aider

private struct AiderSessionAggregate {
    var input: Int = 0
    var output: Int = 0
    var cost: Double = 0
    var model: String = "unknown"
    var start: Date?
    var end: Date?
    var count: Int = 0
}

public final class AiderParser: LogParser, Sendable {
    public let provider: AgentProvider = .aider
    private let rootOverride: URL?
    private let fileManager: FileManager
    private let cacheStore: ParserDiskCacheStore<CachedUsageBundleEntry<FileSetSignature>>
    private let sessionScanCount = Locked(0)
    private let sessionCacheHitCount = Locked(0)

    public init(
        rootOverride: URL? = nil,
        fileManager: FileManager = .default,
        appPaths: OpenBurnBarAppPaths = .live()
    ) {
        self.rootOverride = rootOverride
        self.fileManager = fileManager
        self.cacheStore = ParserDiskCacheStore(
            cacheURL: LocalUsageParserSupport.idleCacheURL(
                overrideDirectory: rootOverride,
                live: appPaths.aiderParserCacheURL,
                fileName: ".obb-aider-parser-cache.plist"
            ),
            fileManager: fileManager,
            schemaVersion: 1,
            logLabel: "AiderParser"
        )
    }

    var lastSessionScanCount: Int { sessionScanCount.read() }
    var lastSessionCacheHitCount: Int { sessionCacheHitCount.read() }

    public func parse() async throws -> ParseResult { try await parse(options: .default) }

    public func parse(options: LogParseOptions) async throws -> ParseResult {
        sessionScanCount.write(0)
        sessionCacheHitCount.write(0)
        let root = rootOverride ?? LocalUsageParserSupport.expanded(provider.logDirectory)
        let files = [root.appendingPathComponent("analytics.jsonl"), root.appendingPathComponent("analytics.json")]
            .filter { fileManager.fileExists(atPath: $0.path) }
        guard !files.isEmpty else { return ParseResult(usages: [], conversations: []) }

        let gate = ParserFileReadGate(options: options, fileManager: fileManager)
        var parseCache = cacheStore.load()
        var cacheMutated = false
        defer {
            if cacheMutated {
                cacheStore.persist(parseCache)
            }
        }
        let cacheKey = root.standardizedFileURL.path
        let signature = FileSetSignature(urls: files, using: fileManager)
        let admitted = try gate.shouldRead(files)
        if !admitted {
            return ParseResult(usages: [], conversations: [])
        }
        if !options.includeConversationBodies,
           let signature,
           let cached = parseCache.fileEntries[cacheKey],
           cached.signature == signature {
            sessionCacheHitCount.withLock { $0 += 1 }
            return ParseResult(
                usages: cached.sessions.map { $0.makeUsage(provider: .aider) },
                conversations: []
            )
        }

        sessionScanCount.withLock { $0 += 1 }
        var sessions: [AiderSessionAggregate] = []
        var current = AiderSessionAggregate()
        func flush() {
            guard current.input > 0 || current.output > 0 else { return }
            sessions.append(current)
            current = AiderSessionAggregate()
        }
        for file in files {
            for object in LocalUsageParserSupport.jsonObjects(at: file) {
                let event = LocalUsageParserSupport.string(object["event"])?.lowercased() ?? ""
                let props = LocalUsageParserSupport.dictionary(object["properties"]) ?? object
                let timestamp = LocalUsageParserSupport.date(object["time"])
                if event == "launched" || event == "cli session" { flush(); current.start = timestamp; current.model = LocalUsageParserSupport.string(props["main_model"]) ?? current.model }
                if event == "message_send" || event == "message sent" {
                    current.input += LocalUsageParserSupport.int(props["prompt_tokens"] ?? props["input_tokens"])
                    current.output += LocalUsageParserSupport.int(props["completion_tokens"] ?? props["output_tokens"])
                    current.cost += LocalUsageParserSupport.double(props["cost"]) ?? 0
                    current.count += 1
                    current.start = current.start ?? timestamp
                    current.end = timestamp ?? current.end
                    if let model = LocalUsageParserSupport.string(props["main_model"] ?? props["model"]) { current.model = model }
                }
                if event == "exit" { current.end = timestamp ?? current.end; flush() }
            }
        }
        flush()
        let usages = sessions.enumerated().compactMap { index, session -> TokenUsage? in
            let model = TokenExtractionUtility.normalizeModelName(session.model)
            let start = session.start ?? LocalUsageParserSupport.modificationDate(files.first ?? root) ?? Date()
            let end = session.end ?? start
            let cost = session.cost > 0 ? session.cost : (try? ModelPricing.lookup(model: model).cost(inputTokens: session.input, outputTokens: session.output)) ?? 0
            return LocalUsageParserSupport.usage(provider: .aider, sessionID: "aider-\(index)-\(Int(start.timeIntervalSince1970))", project: "Aider", model: model, input: session.input, output: session.output, cost: cost, start: start, end: end, method: .providerLog, confidence: .exact)
        }
        if let signature {
            parseCache.fileEntries = [cacheKey: CachedUsageBundleEntry(signature: signature, usages: usages)]
            cacheMutated = true
        }
        return ParseResult(usages: usages, conversations: [])
    }
}

// MARK: Cursor SQLite tracking

public final class CursorParser: LogParser, Sendable {
    public let provider: AgentProvider = .cursor
    private let databaseOverride: URL?
    private let fileManager: FileManager
    private let cacheStore: ParserDiskCacheStore<CachedUsageBundleEntry<FileSetSignature>>
    private let sessionScanCount = Locked(0)
    private let sessionCacheHitCount = Locked(0)

    public init(
        databaseOverride: URL? = nil,
        fileManager: FileManager = .default,
        appPaths: OpenBurnBarAppPaths = .live()
    ) {
        self.databaseOverride = databaseOverride
        self.fileManager = fileManager
        self.cacheStore = ParserDiskCacheStore(
            cacheURL: LocalUsageParserSupport.idleCacheURL(
                overrideDirectory: databaseOverride?.deletingLastPathComponent(),
                live: appPaths.cursorParserCacheURL,
                fileName: ".obb-cursor-parser-cache.plist"
            ),
            fileManager: fileManager,
            schemaVersion: 1,
            logLabel: "CursorParser"
        )
    }

    var lastSessionScanCount: Int { sessionScanCount.read() }
    var lastSessionCacheHitCount: Int { sessionCacheHitCount.read() }

    public func parse() async throws -> ParseResult { try await parse(options: .default) }
    public func parse(options: LogParseOptions) async throws -> ParseResult {
        sessionScanCount.write(0)
        sessionCacheHitCount.write(0)
        let path = databaseOverride ?? LocalUsageParserSupport.expanded("~/.cursor/ai-tracking/ai-code-tracking.db")
        guard fileManager.fileExists(atPath: path.path) else { return ParseResult(usages: [], conversations: []) }
        let gate = ParserFileReadGate(options: options, fileManager: fileManager)
        var parseCache = cacheStore.load()
        var cacheMutated = false
        defer {
            if cacheMutated { cacheStore.persist(parseCache) }
        }
        let cacheKey = path.standardizedFileURL.path
        guard try gate.shouldRead(path) else { return ParseResult(usages: [], conversations: []) }
        let signature = FileSetSignature(databaseURL: path, using: fileManager)
        if !options.includeConversationBodies,
           let signature,
           let cached = parseCache.fileEntries[cacheKey],
           cached.signature == signature {
            sessionCacheHitCount.withLock { $0 += 1 }
            return ParseResult(usages: cached.sessions.map { $0.makeUsage(provider: .cursor) }, conversations: [])
        }
        sessionScanCount.withLock { $0 += 1 }
        let db = try SQLiteConnection.openReadOnly(path: path.path)
        defer { db.close() }
        guard try db.tableNames().contains("ai_code_hashes") else { return ParseResult(usages: [], conversations: []) }
        let rows = try db.query("""
            SELECT conversationId, model, COUNT(*) AS hash_count, MIN(createdAt) AS first_seen, MAX(createdAt) AS last_seen
            FROM ai_code_hashes WHERE conversationId IS NOT NULL AND conversationId != ''
            GROUP BY conversationId, model ORDER BY last_seen DESC LIMIT 500
            """)
        let usages = rows.compactMap { row -> TokenUsage? in
            guard let session = row.string("conversationId"), let count = row.int("hash_count"), count > 0 else { return nil }
            let model = TokenExtractionUtility.normalizeModelName(row.string("model") ?? "cursor")
            let start = TimestampNormalizationUtility.date(fromEpoch: row.double("first_seen"))
            let end = max(start, TimestampNormalizationUtility.date(fromEpoch: row.double("last_seen"), fallback: start))
            let input = count * 500
            let output = count * 150
            let cost = (try? ModelPricing.lookup(model: model).cost(inputTokens: input, outputTokens: output)) ?? 0
            return LocalUsageParserSupport.usage(provider: .cursor, sessionID: session, project: "Cursor", model: model, input: input, output: output, cost: cost, start: start, end: end, method: .heuristicEstimate, confidence: .lowConfidenceEstimate, estimatorVersion: "cursor-hash-count-v1")
        }
        if let signature {
            parseCache.fileEntries = [cacheKey: CachedUsageBundleEntry(signature: signature, usages: usages)]
            cacheMutated = true
        }
        return ParseResult(usages: usages, conversations: [])
    }
}

// MARK: OpenCode SQLite store

public final class OpenCodeParser: LogParser, Sendable {
    public let provider: AgentProvider = .openCode
    private let databaseOverride: URL?
    private let fileManager: FileManager
    private let cacheStore: ParserDiskCacheStore<CachedUsageBundleEntry<FileSetSignature>>
    private let sessionScanCount = Locked(0)
    private let sessionCacheHitCount = Locked(0)
    private let partReadCount = Locked(0)

    public init(
        databaseOverride: URL? = nil,
        fileManager: FileManager = .default,
        appPaths: OpenBurnBarAppPaths = .live()
    ) {
        self.databaseOverride = databaseOverride
        self.fileManager = fileManager
        self.cacheStore = ParserDiskCacheStore(
            cacheURL: LocalUsageParserSupport.idleCacheURL(
                overrideDirectory: databaseOverride?.deletingLastPathComponent(),
                live: appPaths.openCodeParserCacheURL,
                fileName: ".obb-opencode-parser-cache.plist"
            ),
            fileManager: fileManager,
            schemaVersion: 1,
            logLabel: "OpenCodeParser"
        )
    }

    var lastSessionScanCount: Int { sessionScanCount.read() }
    var lastSessionCacheHitCount: Int { sessionCacheHitCount.read() }
    var lastPartReadCount: Int { partReadCount.read() }

    public static func resolvedDatabasePath(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let explicit = environment["OPENCODE_DB_PATH"], !explicit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return LocalUsageParserSupport.expanded(explicit) }
        if let home = environment["OPENCODE_DATA_HOME"], !home.isEmpty { return LocalUsageParserSupport.expanded("\(home)/opencode.db") }
        let dataHome = environment["XDG_DATA_HOME"] ?? "~/.local/share"
        return LocalUsageParserSupport.expanded("\(dataHome)/opencode/opencode.db")
    }
    public func parse() async throws -> ParseResult { try await parse(options: .default) }
    public func parse(options: LogParseOptions) async throws -> ParseResult {
        sessionScanCount.write(0)
        sessionCacheHitCount.write(0)
        partReadCount.write(0)
        let path = databaseOverride ?? Self.resolvedDatabasePath()
        guard fileManager.fileExists(atPath: path.path) else { return ParseResult(usages: [], conversations: []) }
        let gate = ParserFileReadGate(options: options, fileManager: fileManager)
        var parseCache = cacheStore.load()
        var cacheMutated = false
        defer { if cacheMutated { cacheStore.persist(parseCache) } }
        let cacheKey = path.standardizedFileURL.path
        guard try gate.shouldRead(path) else { return ParseResult(usages: [], conversations: []) }
        let signature = FileSetSignature(databaseURL: path, using: fileManager)
        if !options.includeConversationBodies,
           let signature,
           let cached = parseCache.fileEntries[cacheKey],
           cached.signature == signature {
            sessionCacheHitCount.withLock { $0 += 1 }
            return ParseResult(usages: cached.sessions.map { $0.makeUsage(provider: .openCode) }, conversations: [])
        }
        sessionScanCount.withLock { $0 += 1 }
        let db = try SQLiteConnection.openReadOnly(path: path.path)
        defer { db.close() }
        let tables = try db.tableNames()
        struct Message { let id: String; let session: String; let role: String; let time: Double; let model: String?; let tokens: ExtractedTokenUsage; let cost: Double? }
        var metadata: [String: (title: String?, directory: String?, created: Date?, updated: Date?)] = [:]
        var messages: [String: [Message]] = [:]
        var texts: [String: String] = [:]
        if tables.contains("session") {
            for row in try db.query("SELECT * FROM session") {
                guard let json = Self.data(from: row), let id = row.string("id") ?? LocalUsageParserSupport.firstString(json, keys: ["id", "sessionID", "sessionId"]) else { continue }
                let time = LocalUsageParserSupport.dictionary(json["time"])
                metadata[id] = (
                    LocalUsageParserSupport.string(json["title"]),
                    LocalUsageParserSupport.firstString(json, keys: ["directory", "cwd", "worktree"]),
                    LocalUsageParserSupport.date(time?["created"] ?? json["created"] ?? row.double("time_created")),
                    LocalUsageParserSupport.date(time?["updated"] ?? json["updated"] ?? row.double("time_updated"))
                )
            }
        }
        if tables.contains("message") {
            for row in try db.query("SELECT * FROM message") {
                guard let json = Self.data(from: row), let session = row.string("sessionID") ?? row.string("session_id") ?? LocalUsageParserSupport.firstString(json, keys: ["sessionID", "sessionId", "session_id"]) else { continue }
                let id = row.string("id") ?? LocalUsageParserSupport.firstString(json, keys: ["id", "messageID", "messageId"]) ?? UUID().uuidString
                let time = LocalUsageParserSupport.dictionary(json["time"])
                let timestamp = LocalUsageParserSupport.epoch(time?["created"] ?? json["created"] ?? row.double("time_created")) ?? 0
                let tokens: ExtractedTokenUsage
                if let tokenObject = LocalUsageParserSupport.dictionary(json["tokens"]) {
                    let cacheObject = LocalUsageParserSupport.dictionary(tokenObject["cache"])
                    tokens = ExtractedTokenUsage(
                        input: LocalUsageParserSupport.int(tokenObject["input"]),
                        output: LocalUsageParserSupport.int(tokenObject["output"]),
                        cacheCreation: LocalUsageParserSupport.int(
                            tokenObject["cache_write"] ?? cacheObject?["write"]
                        ),
                        cacheRead: LocalUsageParserSupport.int(
                            tokenObject["cache_read"] ?? cacheObject?["read"]
                        ),
                        reasoningTokens: 0
                    )
                } else {
                    tokens = TokenExtractionUtility.extractUsageTokens(
                        LocalUsageParserSupport.dictionary(json["usage"]) ?? [:]
                    )
                }
                messages[session, default: []].append(Message(
                    id: id,
                    session: session,
                    role: LocalUsageParserSupport.string(json["role"])?.lowercased() ?? "",
                    time: timestamp,
                    model: LocalUsageParserSupport.model(in: json),
                    tokens: tokens,
                    cost: LocalUsageParserSupport.double(json["cost"])
                ))
            }
        }
        let heuristicMessageIDs = Set(messages.flatMap { _, raw -> [String] in
            let input = raw.reduce(0) { $0 + $1.tokens.input }
            let output = raw.reduce(0) { $0 + $1.tokens.output }
            guard input == 0 && output == 0 else { return [] }
            return raw.map(\.id)
        })
        if tables.contains("part") {
            let scopedIDs: Set<String>? = options.includeConversationBodies ? nil : heuristicMessageIDs
            if options.includeConversationBodies || !heuristicMessageIDs.isEmpty {
                for row in try fetchOpenCodePartRows(db: db, messageIDs: scopedIDs) {
                    guard let json = Self.data(from: row),
                          ["text", "reasoning"].contains(
                              LocalUsageParserSupport.string(json["type"])?.lowercased() ?? "text"
                          ),
                          let id = row.string("messageID")
                            ?? row.string("message_id")
                            ?? LocalUsageParserSupport.firstString(
                                json,
                                keys: ["messageID", "messageId", "message_id"]
                            ),
                          let text = LocalUsageParserSupport.string(json["text"] ?? json["content"])
                    else { continue }
                    if let scopedIDs, !scopedIDs.contains(id) { continue }
                    texts[id, default: ""] += ((texts[id]?.isEmpty ?? true) ? "" : "\n\n") + text
                }
            }
        }
        var usages: [TokenUsage] = []
        var conversations: [ConversationRecord] = []
        for (session, raw) in messages {
            let ordered = raw.sorted { $0.time < $1.time }
            let meta = metadata[session]
            var input = ordered.reduce(0) { $0 + $1.tokens.input }
            var output = ordered.reduce(0) { $0 + $1.tokens.output }
            let cacheCreation = ordered.reduce(0) { $0 + $1.tokens.cacheCreation }
            let cacheRead = ordered.reduce(0) { $0 + $1.tokens.cacheRead }
            let model = ordered.compactMap(\.model).last ?? "opencode"
            let turns = ordered.compactMap { message -> LocalUsageParserSupport.Turn? in
                guard let text = texts[message.id], !text.isEmpty else { return nil }
                return .init(role: message.role, text: text, timestamp: TimestampNormalizationUtility.date(fromEpoch: message.time))
            }
            var method: UsageProvenanceMethod = .providerLog
            var confidence: UsageProvenanceConfidence = .exact
            if input == 0 && output == 0 {
                let userChars = turns.filter { $0.role == "user" }.reduce(0) { $0 + $1.text.count }
                let assistantChars = turns.filter { $0.role == "assistant" }.reduce(0) { $0 + $1.text.count }
                guard userChars + assistantChars > 0 else { continue }
                let estimate = TokenExtractionUtility.estimateFallbackTokens(userVisibleChars: userChars, assistantVisibleChars: assistantChars, assistantReasoningChars: 0, userMessageCount: 1, assistantMessageCount: 1)
                input = estimate.input; output = estimate.output; method = .heuristicEstimate; confidence = .lowConfidenceEstimate
            }
            let start = meta?.created ?? TimestampNormalizationUtility.date(fromEpoch: ordered.first?.time)
            let end = meta?.updated ?? TimestampNormalizationUtility.date(fromEpoch: ordered.last?.time, fallback: start)
            let costFromRows = ordered.compactMap(\.cost).reduce(0, +)
            let cost = costFromRows > 0 ? costFromRows : ((try? ModelPricing.lookup(model: model).cost(inputTokens: input, outputTokens: output, cacheCreationTokens: cacheCreation, cacheReadTokens: cacheRead)) ?? 0)
            let project = meta?.directory.map { URL(fileURLWithPath: $0).lastPathComponent } ?? session
            let estimatorVersion = method == .heuristicEstimate
                ? TokenExtractionUtility.currentEstimatorVersion
                : ""
            if let usage = LocalUsageParserSupport.usage(
                provider: .openCode,
                sessionID: session,
                project: project,
                model: model,
                input: input,
                output: output,
                cacheCreation: cacheCreation,
                cacheRead: cacheRead,
                cost: cost,
                start: start,
                end: end,
                method: method,
                confidence: confidence,
                estimatorVersion: estimatorVersion
            ) {
                usages.append(usage)
            }
            if options.includeConversationBodies && !turns.isEmpty {
                conversations.append(LocalUsageParserSupport.transcript(
                    provider: .openCode,
                    sessionID: session,
                    project: project,
                    turns: turns,
                    start: start,
                    end: end,
                    fileModifiedAt: end,
                    workingDirectory: meta?.directory
                ))
            }
        }
        if let signature {
            parseCache.fileEntries = [cacheKey: CachedUsageBundleEntry(signature: signature, usages: usages)]
            cacheMutated = true
        }
        return ParseResult(usages: usages, conversations: conversations)
    }

    /// Usage-only ticks query `part` only for sessions that lack explicit
    /// token buckets. Conversation-body passes still read every text part.
    /// When `messageIDs` is nil the full table is scanned. JSON-only schemas
    /// (no message-id column) bound via `json_extract` on an existing payload
    /// column — that column is not invented.
    private func fetchOpenCodePartRows(
        db: SQLiteReading,
        messageIDs: Set<String>?
    ) throws -> [SQLiteRow] {
        let columns = Set(try db.columnNames(ofTable: "part"))
        let selectList = OpenCodePartQuery.selectList(existingColumns: columns)
        let rows: [SQLiteRow]
        if let messageIDs {
            if let idColumn = OpenCodePartQuery.idColumn(in: columns) {
                rows = try Self.queryBoundedPartRows(
                    db: db,
                    whereSQL: { OpenCodePartQuery.idColumnWhereSQL(idColumn: idColumn, placeholderCount: $0) },
                    messageIDs: messageIDs,
                    selectList: OpenCodePartQuery.selectList(existingColumns: columns, required: [idColumn])
                )
            } else if let payloadColumn = OpenCodePartQuery.payloadColumn(in: columns),
                      Self.sqliteSupportsJSONExtract(db) {
                let bounded = try Self.queryBoundedPartRows(
                    db: db,
                    whereSQL: { OpenCodePartQuery.jsonExtractWhereSQL(payloadColumn: payloadColumn, placeholderCount: $0) },
                    messageIDs: messageIDs,
                    selectList: selectList
                )
                // Empty extract is fail-closed to the full named-column scan so
                // a JSON1 quirk cannot drop heuristic char-count totals.
                rows = bounded.isEmpty
                    ? try db.query("SELECT \(selectList) FROM part")
                    : bounded
            } else {
                rows = try db.query("SELECT \(selectList) FROM part")
            }
        } else {
            rows = try db.query("SELECT \(selectList) FROM part")
        }
        partReadCount.withLock { $0 += rows.count }
        return rows
    }

    private static func sqliteSupportsJSONExtract(_ db: SQLiteReading) -> Bool {
        do {
            let rows = try db.query(OpenCodePartQuery.jsonExtractProbeSQL)
            let probe = rows.first
            return OpenCodePartQuery.jsonExtractProbeSucceeded(
                intValue: probe?.int64("probe"),
                textValue: probe?.string("probe")
            )
        } catch {
            return false
        }
    }

    private static func queryBoundedPartRows(
        db: SQLiteReading,
        whereSQL: (Int) -> String?,
        messageIDs: Set<String>,
        selectList: String
    ) throws -> [SQLiteRow] {
        guard !messageIDs.isEmpty else { return [] }
        var collected: [SQLiteRow] = []
        let ordered = Array(messageIDs)
        var index = 0
        while index < ordered.count {
            let end = min(index + OpenCodePartQuery.chunkSize, ordered.count)
            let chunk = Array(ordered[index..<end])
            guard let clause = whereSQL(chunk.count) else { return [] }
            let rows = try db.query(
                "SELECT \(selectList) FROM part WHERE \(clause)",
                arguments: chunk.map { .text($0) }
            )
            collected.append(contentsOf: rows)
            index = end
        }
        return collected
    }

    private static func decode(_ value: String) -> [String: Any]? { try? JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any] }

    private static func data(from row: SQLiteRow) -> [String: Any]? {
        for column in ["data", "json", "value", "content", "payload"] {
            if let value = row.string(column), let object = decode(value) { return object }
        }
        return nil
    }
}

// MARK: Pi Agent

public final class PiAgentParser: LogParser, Sendable {
    public let provider: AgentProvider = .piAgent
    private static let cacheCheckpointFileInterval = 16
    private static let cancellationCheckpointLineInterval = 1_024
    private let sessionsOverride: URL?
    private let fileManager: FileManager
    private let cacheStore: ParserDiskCacheStore<CachedUsageBundleEntry<FileSignature>>
    private let sessionScanCount = Locked(0)
    private let sessionCacheHitCount = Locked(0)
    private let contentExtractionLineCount = Locked(0)

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
                live: appPaths.piAgentParserCacheURL,
                fileName: ".obb-pi-parser-cache.plist"
            ),
            fileManager: fileManager,
            schemaVersion: 1,
            logLabel: "PiAgentParser"
        )
    }

    var lastSessionScanCount: Int { sessionScanCount.read() }
    var lastSessionCacheHitCount: Int { sessionCacheHitCount.read() }
    var lastContentExtractionLineCount: Int { contentExtractionLineCount.read() }

    public func parse() async throws -> ParseResult { try await parse(options: .default) }
    public func parse(options: LogParseOptions) async throws -> ParseResult {
        sessionScanCount.write(0)
        sessionCacheHitCount.write(0)
        contentExtractionLineCount.write(0)
        let root = sessionsOverride ?? LocalUsageParserSupport.expanded(provider.logDirectory)
        let gate = ParserFileReadGate(options: options, fileManager: fileManager)
        var usages: [TokenUsage] = []; var conversations: [ConversationRecord] = []
        var parseCache = cacheStore.load()
        var activePaths = Set<String>()
        var pendingCacheMutations = 0
        defer {
            if pendingCacheMutations > 0 {
                cacheStore.persist(parseCache)
            }
        }
        for file in LocalUsageParserSupport.files(in: root, extensions: ["jsonl"]) {
            let cacheKey = file.standardizedFileURL.path
            activePaths.insert(cacheKey)
            guard try gate.shouldRead(file) else { continue }
            let signature = FileSignature(for: file, using: fileManager)
            if !options.includeConversationBodies,
               let signature,
               let cached = parseCache.fileEntries[cacheKey],
               cached.signature == signature {
                sessionCacheHitCount.withLock { $0 += 1 }
                usages.append(contentsOf: cached.sessions.map { $0.makeUsage(provider: .piAgent) })
                continue
            }
            sessionScanCount.withLock { $0 += 1 }
            let id = file.deletingPathExtension().lastPathComponent
            let parsed = try Self.parse(
                file: file,
                sessionID: id,
                provider: .piAgent,
                includeConversationBodies: options.includeConversationBodies,
                resourceGovernor: options.resourceGovernor
            )
            contentExtractionLineCount.withLock { $0 += parsed.contentExtractionLineCount }
            if let usage = parsed.usage {
                usages.append(usage)
            }
            if let signature {
                parseCache.fileEntries[cacheKey] = CachedUsageBundleEntry(
                    signature: signature,
                    usages: parsed.usage.map { [$0] } ?? []
                )
                pendingCacheMutations += 1
                if pendingCacheMutations >= Self.cacheCheckpointFileInterval {
                    cacheStore.persist(parseCache)
                    pendingCacheMutations = 0
                }
            }
            if options.includeConversationBodies, let conversation = parsed.conversation { conversations.append(conversation) }
        }
        let stale = Set(parseCache.fileEntries.keys).subtracting(activePaths)
        if !stale.isEmpty {
            for key in stale { parseCache.fileEntries.removeValue(forKey: key) }
            pendingCacheMutations += stale.count
        }
        return ParseResult(usages: usages, conversations: conversations)
    }

    fileprivate static func parse(
        file: URL,
        sessionID: String,
        provider: AgentProvider,
        includeConversationBodies: Bool,
        resourceGovernor: ParserResourceGovernor?
    ) throws -> (
        usage: TokenUsage?,
        conversation: ConversationRecord?,
        contentExtractionLineCount: Int
    ) {
        let mtime = LocalUsageParserSupport.modificationDate(file) ?? Date()
        var input = 0, output = 0, cacheCreation = 0, cacheRead = 0, userChars = 0, assistantChars = 0
        var model = "pi", cwd: String?, start: Date?, end: Date?
        var turns: [LocalUsageParserSupport.Turn] = []
        var contentExtractionLineCount = 0
        try scanJSONLines(file: file, resourceGovernor: resourceGovernor) { object in
            let timestamp = LocalUsageParserSupport.date(object["timestamp"] ?? object["time"])
            start = start ?? timestamp; end = timestamp ?? end
            model = LocalUsageParserSupport.model(in: object) ?? model
            cwd = LocalUsageParserSupport.firstString(object, keys: ["cwd", "workingDirectory", "directory"]) ?? cwd
            let tokens = LocalUsageParserSupport.extracted(object); input += tokens.input; output += tokens.output; cacheCreation += tokens.cacheCreation; cacheRead += tokens.cacheRead
            guard includeConversationBodies else { return }
            contentExtractionLineCount += 1
            let message = LocalUsageParserSupport.dictionary(object["message"])
            let role = (LocalUsageParserSupport.string(object["role"]) ?? LocalUsageParserSupport.string(message?["role"]) ?? LocalUsageParserSupport.string(object["type"]) ?? "").lowercased()
            let text = LocalUsageParserSupport.contentText(object["content"] ?? message?["content"] ?? object["text"])
            guard !text.isEmpty else { return }
            if role == "user" || role == "human" {
                userChars += text.count
                turns.append(.init(role: "user", text: text, timestamp: timestamp))
            }
            if role == "assistant" || role == "ai" || role == "model" {
                assistantChars += text.count
                turns.append(.init(role: "assistant", text: text, timestamp: timestamp))
            }
        }
        var method: UsageProvenanceMethod = .providerLog; var confidence: UsageProvenanceConfidence = .exact
        let hasExplicitUsage = input > 0 || output > 0 || cacheCreation > 0 || cacheRead > 0
        if !hasExplicitUsage {
            if !includeConversationBodies {
                let fallback = try fallbackContentMetrics(
                    file: file,
                    resourceGovernor: resourceGovernor
                )
                userChars = fallback.userChars
                assistantChars = fallback.assistantChars
                contentExtractionLineCount += fallback.lineCount
            }
            guard userChars + assistantChars > 0 else {
                return (nil, nil, contentExtractionLineCount)
            }
            let estimate = TokenExtractionUtility.estimateFallbackTokens(userVisibleChars: userChars, assistantVisibleChars: assistantChars, assistantReasoningChars: 0, userMessageCount: 1, assistantMessageCount: 1)
            input = estimate.input; output = estimate.output; method = .heuristicEstimate; confidence = .lowConfidenceEstimate
        }
        let startTime = start ?? mtime, endTime = end ?? startTime
        let cost = (try? ModelPricing.lookup(model: model).cost(inputTokens: input, outputTokens: output, cacheCreationTokens: cacheCreation, cacheReadTokens: cacheRead)) ?? 0
        let project = cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? sessionID
        let estimatorVersion = method == .heuristicEstimate
            ? TokenExtractionUtility.currentEstimatorVersion
            : ""
        let usage = LocalUsageParserSupport.usage(
            provider: provider,
            sessionID: sessionID,
            project: project,
            model: model,
            input: input,
            output: output,
            cacheCreation: cacheCreation,
            cacheRead: cacheRead,
            cost: cost,
            start: startTime,
            end: endTime,
            method: method,
            confidence: confidence,
            estimatorVersion: estimatorVersion
        )
        let conversation = !includeConversationBodies || turns.isEmpty
            ? nil
            : LocalUsageParserSupport.transcript(
                provider: provider,
                sessionID: sessionID,
                project: cwd ?? sessionID,
                turns: turns,
                start: startTime,
                end: endTime,
                fileModifiedAt: mtime,
                workingDirectory: cwd
            )
        return (usage, conversation, contentExtractionLineCount)
    }

    private static func fallbackContentMetrics(
        file: URL,
        resourceGovernor: ParserResourceGovernor?
    ) throws -> (userChars: Int, assistantChars: Int, lineCount: Int) {
        var userChars = 0
        var assistantChars = 0
        var lineCount = 0
        try scanJSONLines(file: file, resourceGovernor: resourceGovernor) { object in
            lineCount += 1
            let message = LocalUsageParserSupport.dictionary(object["message"])
            let role = (
                LocalUsageParserSupport.string(object["role"])
                    ?? LocalUsageParserSupport.string(message?["role"])
                    ?? LocalUsageParserSupport.string(object["type"])
                    ?? ""
            ).lowercased()
            let text = LocalUsageParserSupport.contentText(
                object["content"] ?? message?["content"] ?? object["text"]
            )
            guard !text.isEmpty else { return }
            if role == "user" || role == "human" {
                userChars += text.count
            } else if role == "assistant" || role == "ai" || role == "model" {
                assistantChars += text.count
            }
        }
        return (userChars, assistantChars, lineCount)
    }

    private static func scanJSONLines(
        file: URL,
        resourceGovernor: ParserResourceGovernor?,
        body: ([String: Any]) throws -> Void
    ) throws {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return }
        defer { try? handle.close() }

        let reader = BufferedLineReader(fileHandle: handle)
        var physicalLineCount = 0
        while let line = reader.nextLine() {
            physicalLineCount += 1
            if physicalLineCount.isMultiple(of: cancellationCheckpointLineInterval) {
                try Task.checkCancellation()
                try resourceGovernor?.checkpoint()
            }
            guard let object = parserAutoReleasePool({ () -> [String: Any]? in
                try? JSONSerialization.jsonObject(with: Data(line.text.utf8)) as? [String: Any]
            }) else {
                continue
            }
            try body(object)
        }
        try Task.checkCancellation()
        try resourceGovernor?.checkpoint()
    }
}

// MARK: Oh My Pi (OMP)

/// OMP uses the Pi-compatible nested JSONL envelope; share its parser logic.
public final class OMPParser: LogParser, Sendable {
    public let provider: AgentProvider = .omp
    private static let cacheCheckpointFileInterval = 16
    private let sessionsOverride: URL?
    private let fileManager: FileManager
    private let cacheStore: ParserDiskCacheStore<CachedUsageBundleEntry<FileSignature>>
    private let sessionScanCount = Locked(0)
    private let sessionCacheHitCount = Locked(0)
    private let contentExtractionLineCount = Locked(0)

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
                live: appPaths.ompParserCacheURL,
                fileName: ".obb-omp-parser-cache.plist"
            ),
            fileManager: fileManager,
            schemaVersion: 1,
            logLabel: "OMPParser"
        )
    }

    var lastSessionScanCount: Int { sessionScanCount.read() }
    var lastSessionCacheHitCount: Int { sessionCacheHitCount.read() }
    var lastContentExtractionLineCount: Int { contentExtractionLineCount.read() }

    public func parse() async throws -> ParseResult { try await parse(options: .default) }

    public func parse(options: LogParseOptions) async throws -> ParseResult {
        sessionScanCount.write(0)
        sessionCacheHitCount.write(0)
        contentExtractionLineCount.write(0)
        let root = sessionsOverride ?? LocalUsageParserSupport.expanded(provider.logDirectory)
        let gate = ParserFileReadGate(options: options, fileManager: fileManager)
        var usages: [TokenUsage] = []
        var conversations: [ConversationRecord] = []
        var parseCache = cacheStore.load()
        var activePaths = Set<String>()
        var pendingCacheMutations = 0
        defer {
            if pendingCacheMutations > 0 {
                cacheStore.persist(parseCache)
            }
        }
        for file in LocalUsageParserSupport.files(in: root, extensions: ["jsonl"]) {
            let cacheKey = file.standardizedFileURL.path
            activePaths.insert(cacheKey)
            guard try gate.shouldRead(file) else { continue }
            let signature = FileSignature(for: file, using: fileManager)
            if !options.includeConversationBodies,
               let signature,
               let cached = parseCache.fileEntries[cacheKey],
               cached.signature == signature {
                sessionCacheHitCount.withLock { $0 += 1 }
                usages.append(contentsOf: cached.sessions.map { $0.makeUsage(provider: .omp) })
                continue
            }
            sessionScanCount.withLock { $0 += 1 }
            let id = file.deletingPathExtension().lastPathComponent
            let parsed = try PiAgentParser.parse(
                file: file,
                sessionID: id,
                provider: .omp,
                includeConversationBodies: options.includeConversationBodies,
                resourceGovernor: options.resourceGovernor
            )
            contentExtractionLineCount.withLock { $0 += parsed.contentExtractionLineCount }
            if let usage = parsed.usage {
                usages.append(usage)
            }
            if let signature {
                parseCache.fileEntries[cacheKey] = CachedUsageBundleEntry(
                    signature: signature,
                    usages: parsed.usage.map { [$0] } ?? []
                )
                pendingCacheMutations += 1
                if pendingCacheMutations >= Self.cacheCheckpointFileInterval {
                    cacheStore.persist(parseCache)
                    pendingCacheMutations = 0
                }
            }
            if options.includeConversationBodies, let conversation = parsed.conversation {
                conversations.append(conversation)
            }
        }
        let stale = Set(parseCache.fileEntries.keys).subtracting(activePaths)
        if !stale.isEmpty {
            for key in stale { parseCache.fileEntries.removeValue(forKey: key) }
            pendingCacheMutations += stale.count
        }
        return ParseResult(usages: usages, conversations: conversations)
    }
}

// MARK: OpenClaw

public final class OpenClawParser: LogParser, Sendable {
    public let provider: AgentProvider = .openClaw
    private let sessionsOverride: URL?
    private let fileManager: FileManager
    private let cacheStore: ParserDiskCacheStore<CachedUsageBundleEntry<FileSignature>>
    private let sessionScanCount = Locked(0)
    private let sessionCacheHitCount = Locked(0)

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
                live: appPaths.openClawParserCacheURL,
                fileName: ".obb-openclaw-parser-cache.plist"
            ),
            fileManager: fileManager,
            schemaVersion: 1,
            logLabel: "OpenClawParser"
        )
    }

    var lastSessionScanCount: Int { sessionScanCount.read() }
    var lastSessionCacheHitCount: Int { sessionCacheHitCount.read() }

    public func parse() async throws -> ParseResult { try await parse(options: .default) }
    public func parse(options: LogParseOptions) async throws -> ParseResult {
        sessionScanCount.write(0)
        sessionCacheHitCount.write(0)
        let root = sessionsOverride ?? LocalUsageParserSupport.expanded(provider.logDirectory)
        let gate = ParserFileReadGate(options: options, fileManager: fileManager)
        var usages: [TokenUsage] = []; var conversations: [ConversationRecord] = []
        var parseCache = cacheStore.load()
        var activePaths = Set<String>()
        var cacheMutated = false
        defer { if cacheMutated { cacheStore.persist(parseCache) } }
        for file in LocalUsageParserSupport.files(in: root, extensions: ["json", "jsonl", "log"]) {
            let cacheKey = file.standardizedFileURL.path
            activePaths.insert(cacheKey)
            guard try gate.shouldRead(file) else { continue }
            let signature = FileSignature(for: file, using: fileManager)
            if !options.includeConversationBodies,
               let signature,
               let cached = parseCache.fileEntries[cacheKey],
               cached.signature == signature {
                sessionCacheHitCount.withLock { $0 += 1 }
                usages.append(contentsOf: cached.sessions.map { $0.makeUsage(provider: .openClaw) })
                continue
            }
            sessionScanCount.withLock { $0 += 1 }
            let objects = LocalUsageParserSupport.jsonObjects(at: file)
            guard !objects.isEmpty else { continue }
            var input = 0, output = 0, cacheRead = 0; var model = "openclaw"; var start: Date?, end: Date?; var turns: [LocalUsageParserSupport.Turn] = []
            for object in objects {
                let timestamp = LocalUsageParserSupport.date(object["timestamp"] ?? object["createdAt"] ?? object["time"]); start = start ?? timestamp; end = timestamp ?? end
                model = LocalUsageParserSupport.model(in: object) ?? model
                let tokens = LocalUsageParserSupport.extracted(object)
                input += tokens.input
                output += tokens.output
                cacheRead += tokens.cacheRead
                let message = LocalUsageParserSupport.dictionary(object["message"])
                let role = (
                    LocalUsageParserSupport.string(object["role"])
                        ?? LocalUsageParserSupport.string(message?["role"])
                        ?? ""
                ).lowercased()
                let text = LocalUsageParserSupport.contentText(
                    object["content"] ?? message?["content"] ?? object["text"]
                )
                if !text.isEmpty, ["user", "human", "assistant", "agent", "model"].contains(role) {
                    let canonical = role == "user" || role == "human" ? "user" : "assistant"
                    turns.append(.init(role: canonical, text: text, timestamp: timestamp))
                }
            }
            guard !turns.isEmpty else { continue }
            let mtime = LocalUsageParserSupport.modificationDate(file) ?? Date()
            let startTime = start ?? mtime
            let endTime = end ?? startTime
            var method: UsageProvenanceMethod = .providerLog
            var confidence: UsageProvenanceConfidence = .exact
            if input == 0 && output == 0 {
                let userChars = turns.filter { $0.role == "user" }.reduce(0) { $0 + $1.text.count }
                let assistantChars = turns.filter { $0.role == "assistant" }
                    .reduce(0) { $0 + $1.text.count }
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
            let cost = (try? ModelPricing.lookup(model: model).cost(
                inputTokens: input,
                outputTokens: output,
                cacheReadTokens: cacheRead
            )) ?? 0
            let session = file.deletingPathExtension().lastPathComponent
            let estimatorVersion = method == .heuristicEstimate
                ? TokenExtractionUtility.currentEstimatorVersion
                : ""
            if let usage = LocalUsageParserSupport.usage(
                provider: .openClaw,
                sessionID: session,
                project: "OpenClaw",
                model: model,
                input: input,
                output: output,
                cacheRead: cacheRead,
                cost: cost,
                start: startTime,
                end: endTime,
                method: method,
                confidence: confidence,
                estimatorVersion: estimatorVersion
            ) {
                usages.append(usage)
                if let signature {
                    parseCache.fileEntries[cacheKey] = CachedUsageBundleEntry(signature: signature, usages: [usage])
                    cacheMutated = true
                }
            }
            if options.includeConversationBodies {
                conversations.append(LocalUsageParserSupport.transcript(
                    provider: .openClaw,
                    sessionID: session,
                    project: "OpenClaw",
                    turns: turns,
                    start: startTime,
                    end: endTime,
                    fileModifiedAt: mtime
                ))
            }
        }
        let stale = Set(parseCache.fileEntries.keys).subtracting(activePaths)
        if !stale.isEmpty {
            for key in stale { parseCache.fileEntries.removeValue(forKey: key) }
            cacheMutated = true
        }
        return ParseResult(usages: usages, conversations: conversations)
    }
}

// MARK: Ollama local server logs

public final class OllamaParser: LogParser, Sendable {
    public let provider: AgentProvider = .ollama
    private let logsOverride: URL?
    private let fileManager: FileManager
    private let cacheStore: ParserDiskCacheStore<CachedUsageBundleEntry<FileSignature>>
    private let sessionScanCount = Locked(0)
    private let sessionCacheHitCount = Locked(0)

    public init(
        logsOverride: URL? = nil,
        fileManager: FileManager = .default,
        appPaths: OpenBurnBarAppPaths = .live()
    ) {
        self.logsOverride = logsOverride
        self.fileManager = fileManager
        self.cacheStore = ParserDiskCacheStore(
            cacheURL: LocalUsageParserSupport.idleCacheURL(
                overrideDirectory: logsOverride,
                live: appPaths.ollamaParserCacheURL,
                fileName: ".obb-ollama-parser-cache.plist"
            ),
            fileManager: fileManager,
            schemaVersion: 1,
            logLabel: "OllamaParser"
        )
    }

    var lastSessionScanCount: Int { sessionScanCount.read() }
    var lastSessionCacheHitCount: Int { sessionCacheHitCount.read() }

    public func parse() async throws -> ParseResult { try await parse(options: .default) }
    public func parse(options: LogParseOptions) async throws -> ParseResult {
        sessionScanCount.write(0)
        sessionCacheHitCount.write(0)
        let root = logsOverride ?? LocalUsageParserSupport.expanded(provider.logDirectory)
        let gate = ParserFileReadGate(options: options, fileManager: fileManager)
        var usages: [TokenUsage] = []
        var parseCache = cacheStore.load()
        var activePaths = Set<String>()
        var cacheMutated = false
        defer { if cacheMutated { cacheStore.persist(parseCache) } }
        for file in LocalUsageParserSupport.files(in: root, extensions: ["log", "jsonl"]) {
            let cacheKey = file.standardizedFileURL.path
            activePaths.insert(cacheKey)
            guard try gate.shouldRead(file) else { continue }
            let signature = FileSignature(for: file, using: fileManager)
            if !options.includeConversationBodies,
               let signature,
               let cached = parseCache.fileEntries[cacheKey],
               cached.signature == signature {
                sessionCacheHitCount.withLock { $0 += 1 }
                usages.append(contentsOf: cached.sessions.map { $0.makeUsage(provider: .ollama) })
                continue
            }
            sessionScanCount.withLock { $0 += 1 }
            var input = 0, output = 0, model = "ollama"; var start: Date?; var end: Date?
            for object in LocalUsageParserSupport.jsonLines(at: file) {
                model = LocalUsageParserSupport.model(in: object) ?? model
                let tokens = LocalUsageParserSupport.extracted(object)
                if tokens.input > 0 || tokens.output > 0 || tokens.cacheCreation > 0 || tokens.cacheRead > 0 {
                    input += tokens.input; output += tokens.output
                } else {
                    input += LocalUsageParserSupport.int(object["prompt_eval_count"] ?? object["promptEvalCount"])
                    output += LocalUsageParserSupport.int(object["eval_count"] ?? object["evalCount"])
                }
                let timestamp = LocalUsageParserSupport.date(object["timestamp"] ?? object["time"]); start = start ?? timestamp; end = timestamp ?? end
            }
            guard input > 0 || output > 0 else { continue }
            let mtime = LocalUsageParserSupport.modificationDate(file) ?? Date(); let startTime = start ?? mtime; let endTime = end ?? startTime
            let cost = (try? ModelPricing.lookup(model: model).cost(inputTokens: input, outputTokens: output)) ?? 0
            let session = "ollama-\(file.deletingPathExtension().lastPathComponent)"
            if let usage = LocalUsageParserSupport.usage(provider: .ollama, sessionID: session, project: "Ollama", model: model, input: input, output: output, cost: cost, start: startTime, end: endTime, method: .providerLog, confidence: .exact) {
                usages.append(usage)
                if let signature {
                    parseCache.fileEntries[cacheKey] = CachedUsageBundleEntry(signature: signature, usages: [usage])
                    cacheMutated = true
                }
            }
        }
        let stale = Set(parseCache.fileEntries.keys).subtracting(activePaths)
        if !stale.isEmpty {
            for key in stale { parseCache.fileEntries.removeValue(forKey: key) }
            cacheMutated = true
        }
        return ParseResult(usages: usages, conversations: [])
    }
}

// MARK: Junie

public final class JunieParser: LogParser, Sendable {
    public let provider: AgentProvider = .junie
    private let sessionsOverride: URL?
    private let fileManager: FileManager
    private let cacheStore: ParserDiskCacheStore<CachedUsageBundleEntry<FileSetSignature>>
    private let sessionScanCount = Locked(0)
    private let sessionCacheHitCount = Locked(0)

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
            schemaVersion: 1,
            logLabel: "JunieParser"
        )
    }

    var lastSessionScanCount: Int { sessionScanCount.read() }
    var lastSessionCacheHitCount: Int { sessionCacheHitCount.read() }

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
        var projects: [String: String] = [:]
        let index = root.appendingPathComponent("index.jsonl")
        for object in LocalUsageParserSupport.jsonLines(at: index) {
            if let id = LocalUsageParserSupport.firstString(object, keys: ["sessionId", "session_id", "id"]),
               let project = LocalUsageParserSupport.firstString(
                   object,
                   keys: ["projectPath", "project_path", "cwd", "workingDirectory"]
               ) {
                projects[id] = project
            }
        }
        let dirs = (try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey]
        ))?.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true } ?? []
        var usages: [TokenUsage] = []
        var conversations: [ConversationRecord] = []
        for dir in dirs {
            let id = dir.lastPathComponent
            let events = dir.appendingPathComponent("events.jsonl")
            guard fileManager.fileExists(atPath: events.path) else { continue }
            let cacheKey = events.standardizedFileURL.path
            activePaths.insert(cacheKey)
            var signatureURLs = [events]
            if fileManager.fileExists(atPath: index.path) { signatureURLs.append(index) }
            let signature = FileSetSignature(urls: signatureURLs, using: fileManager)
            guard try gate.shouldRead(signatureURLs) else { continue }
            if !options.includeConversationBodies,
               let signature,
               let cached = parseCache.fileEntries[cacheKey],
               cached.signature == signature {
                sessionCacheHitCount.withLock { $0 += 1 }
                usages.append(contentsOf: cached.sessions.map { $0.makeUsage(provider: .junie) })
                continue
            }
            sessionScanCount.withLock { $0 += 1 }
            let objects = LocalUsageParserSupport.jsonLines(at: events)
            var input = 0, output = 0, cacheCreation = 0, cacheRead = 0, reasoning = 0
            var userChars = 0, assistantChars = 0
            var model = "unknown"
            var start: Date?, end: Date?
            var turns: [LocalUsageParserSupport.Turn] = []
            for raw in objects {
                let payload = LocalUsageParserSupport.dictionary(raw["event"])
                    ?? LocalUsageParserSupport.dictionary(raw["payload"])
                    ?? raw
                let message = LocalUsageParserSupport.dictionary(payload["message"]) ?? payload
                let timestamp = LocalUsageParserSupport.date(
                    raw["timestamp"] ?? payload["timestamp"]
                )
                start = start ?? timestamp
                end = timestamp ?? end
                model = LocalUsageParserSupport.model(in: payload) ?? model
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
            var method: UsageProvenanceMethod = .providerLog
            var confidence: UsageProvenanceConfidence = .exact
            if input == 0 && output == 0 && cacheCreation == 0 && cacheRead == 0 && reasoning == 0 {
                guard userChars + assistantChars > 0 else { continue }
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
            let mtime = LocalUsageParserSupport.modificationDate(events) ?? Date()
            let startTime = start ?? mtime
            let endTime = end ?? startTime
            let project = projects[id] ?? "Junie"
            let cost = (try? ModelPricing.lookup(model: model, providerID: "junie").cost(
                inputTokens: input,
                outputTokens: output,
                cacheCreationTokens: cacheCreation,
                cacheReadTokens: cacheRead
            )) ?? 0
            let estimatorVersion = method == .heuristicEstimate
                ? TokenExtractionUtility.currentEstimatorVersion
                : ""
            if let usage = LocalUsageParserSupport.usage(
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
            ) {
                usages.append(usage)
                if let signature {
                    parseCache.fileEntries[cacheKey] = CachedUsageBundleEntry(signature: signature, usages: [usage])
                    cacheMutated = true
                }
            }
            if options.includeConversationBodies, !turns.isEmpty {
                conversations.append(LocalUsageParserSupport.transcript(
                    provider: .junie,
                    sessionID: id,
                    project: project,
                    turns: turns,
                    start: startTime,
                    end: endTime,
                    fileModifiedAt: mtime,
                    workingDirectory: projects[id]
                ))
            }
        }
        let stale = Set(parseCache.fileEntries.keys).subtracting(activePaths)
        if !stale.isEmpty {
            for key in stale { parseCache.fileEntries.removeValue(forKey: key) }
            cacheMutated = true
        }
        return ParseResult(usages: usages, conversations: conversations)
    }
}

// MARK: Factory model-filtered providers (Z.ai / MiniMax)

public final class ModelFilterParser: LogParser, Sendable {
    public let provider: AgentProvider
    private let modelPattern: String
    private let sessionsOverride: URL?
    private let fileManager: FileManager
    private let cacheStore: ParserDiskCacheStore<CachedUsageBundleEntry<CompositeFileSignature<FileSignature>>>
    private let sessionScanCount = Locked(0)
    private let sessionCacheHitCount = Locked(0)

    public init(
        modelPattern: String,
        provider: AgentProvider,
        sessionsOverride: URL? = nil,
        fileManager: FileManager = .default,
        appPaths: OpenBurnBarAppPaths = .live()
    ) {
        self.modelPattern = modelPattern.lowercased()
        self.provider = provider
        self.sessionsOverride = sessionsOverride
        self.fileManager = fileManager
        self.cacheStore = ParserDiskCacheStore(
            cacheURL: LocalUsageParserSupport.idleCacheURL(
                overrideDirectory: sessionsOverride,
                live: appPaths.modelFilterParserCacheURL(for: provider),
                fileName: ".obb-\(provider.persistedToken)-parser-cache.plist"
            ),
            fileManager: fileManager,
            schemaVersion: 1,
            logLabel: "ModelFilterParser"
        )
    }

    var lastSessionScanCount: Int { sessionScanCount.read() }
    var lastSessionCacheHitCount: Int { sessionCacheHitCount.read() }

    public func parse() async throws -> ParseResult { try await parse(options: .default) }
    public func parse(options: LogParseOptions) async throws -> ParseResult {
        sessionScanCount.write(0)
        sessionCacheHitCount.write(0)
        let root = sessionsOverride ?? LocalUsageParserSupport.expanded("~/.factory/sessions")
        let gate = ParserFileReadGate(options: options, fileManager: fileManager)
        var usages: [TokenUsage] = []; var conversations: [ConversationRecord] = []
        var parseCache = cacheStore.load()
        var activePaths = Set<String>()
        var cacheMutated = false
        defer { if cacheMutated { cacheStore.persist(parseCache) } }
        for file in LocalUsageParserSupport.files(in: root, extensions: ["jsonl"]) {
            let cacheKey = file.standardizedFileURL.path
            activePaths.insert(cacheKey)
            let stem = file.deletingPathExtension()
            let settingsURL = stem.appendingPathExtension("settings.json")
            let metadataURL = stem.appendingPathExtension("metadata.json")
            var gateFiles = [file]
            if fileManager.fileExists(atPath: settingsURL.path) { gateFiles.append(settingsURL) }
            if fileManager.fileExists(atPath: metadataURL.path) { gateFiles.append(metadataURL) }
            guard try gate.shouldRead(gateFiles) else { continue }
            let signature = FileSignature(for: file, using: fileManager).map { primary in
                CompositeFileSignature(
                    primary: primary,
                    settings: FileSignature(for: settingsURL, using: fileManager),
                    metadata: FileSignature(for: metadataURL, using: fileManager)
                )
            }
            if !options.includeConversationBodies,
               let signature,
               let cached = parseCache.fileEntries[cacheKey],
               cached.signature == signature {
                sessionCacheHitCount.withLock { $0 += 1 }
                usages.append(contentsOf: cached.sessions.map { $0.makeUsage(provider: provider) })
                continue
            }
            sessionScanCount.withLock { $0 += 1 }
            let objects = LocalUsageParserSupport.jsonLines(at: file); var input = 0, output = 0, cacheCreation = 0, cacheRead = 0, userChars = 0, assistantChars = 0; var model: String?; var start: Date?, end: Date?; var turns: [LocalUsageParserSupport.Turn] = []
            for sidecar in [stem.appendingPathExtension("settings.json"), stem.appendingPathExtension("metadata.json")] {
                guard let sidecarData = try? Data(contentsOf: sidecar),
                      let sidecarObject = try? JSONSerialization.jsonObject(with: sidecarData) as? [String: Any]
                else { continue }
                model = model ?? LocalUsageParserSupport.model(in: sidecarObject)
                if let usage = LocalUsageParserSupport.dictionary(sidecarObject["tokenUsage"] ?? sidecarObject["usage"]) {
                    let tokens = TokenExtractionUtility.extractUsageTokens(usage)
                    input += tokens.input; output += tokens.output; cacheCreation += tokens.cacheCreation; cacheRead += tokens.cacheRead
                }
            }
            for object in objects {
                let timestamp = LocalUsageParserSupport.date(object["timestamp"])
                start = start ?? timestamp
                end = timestamp ?? end
                model = model ?? LocalUsageParserSupport.model(in: object)
                let tokens = LocalUsageParserSupport.extracted(object)
                input += tokens.input
                output += tokens.output
                cacheCreation += tokens.cacheCreation
                cacheRead += tokens.cacheRead
                let message = LocalUsageParserSupport.dictionary(object["message"])
                let role = (LocalUsageParserSupport.string(message?["role"]) ?? "").lowercased()
                let text = LocalUsageParserSupport.contentText(message?["content"])
                if !text.isEmpty, ["user", "assistant"].contains(role) {
                    turns.append(.init(role: role, text: text, timestamp: timestamp))
                    if role == "user" {
                        userChars += text.count
                    } else {
                        assistantChars += text.count
                    }
                }
            }
            func persist(_ fileUsages: [TokenUsage]) {
                if let signature {
                    parseCache.fileEntries[cacheKey] = CachedUsageBundleEntry(
                        signature: signature,
                        usages: fileUsages
                    )
                    cacheMutated = true
                }
            }
            guard let resolvedModel = model, resolvedModel.lowercased().contains(modelPattern) else {
                persist([])
                continue
            }
            var method: UsageProvenanceMethod = .providerLog
            var confidence: UsageProvenanceConfidence = .exact
            if input == 0 && output == 0 {
                guard userChars + assistantChars > 0 else {
                    persist([])
                    continue
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
            let mtime = LocalUsageParserSupport.modificationDate(file) ?? Date()
            let startTime = start ?? mtime
            let endTime = end ?? startTime
            let project = file.deletingLastPathComponent().lastPathComponent
            let cost = (try? ModelPricing.lookup(model: resolvedModel).cost(
                inputTokens: input,
                outputTokens: output,
                cacheCreationTokens: cacheCreation,
                cacheReadTokens: cacheRead
            )) ?? 0
            let id = file.deletingPathExtension().lastPathComponent
            let estimatorVersion = method == .heuristicEstimate
                ? TokenExtractionUtility.currentEstimatorVersion
                : ""
            if let usage = LocalUsageParserSupport.usage(
                provider: provider,
                sessionID: id,
                project: project,
                model: resolvedModel,
                input: input,
                output: output,
                cacheCreation: cacheCreation,
                cacheRead: cacheRead,
                cost: cost,
                start: startTime,
                end: endTime,
                method: method,
                confidence: confidence,
                estimatorVersion: estimatorVersion
            ) {
                usages.append(usage)
                persist([usage])
            } else {
                persist([])
            }
            if options.includeConversationBodies, !turns.isEmpty {
                conversations.append(LocalUsageParserSupport.transcript(
                    provider: provider,
                    sessionID: id,
                    project: project,
                    turns: turns,
                    start: startTime,
                    end: endTime,
                    fileModifiedAt: mtime
                ))
            }
        }
        let stale = Set(parseCache.fileEntries.keys).subtracting(activePaths)
        if !stale.isEmpty {
            for key in stale { parseCache.fileEntries.removeValue(forKey: key) }
            cacheMutated = true
        }
        return ParseResult(usages: usages, conversations: conversations)
    }
}
