import Foundation
import OpenBurnBarKernel
import OpenBurnBarSQLiteReader

// MARK: - Goose Parser

/// Parses Goose (Block) sessions from the active Goose data directory.
/// Falls back to legacy JSONL files only when no SQLite database exists.
///
/// Idle usage ticks resume unchanged `sessions.db` / `*.jsonl` files from a
/// mtime+size disk cache (token totals only — never conversation bodies).
public final class GooseParser: LogParser, Sendable {
    public let provider: AgentProvider = .goose

    /// When set, the parser reads only this sessions directory (which holds
    /// `sessions.db` and/or legacy `*.jsonl`). Keeps tests hermetic and lets
    /// callers point at a non-default Goose data root. `nil` uses the standard
    /// discovery order (env override + known install locations).
    private let sessionDirectoriesOverride: [String]?
    private let fileManager: FileManager
    private let cacheStore: ParserDiskCacheStore<CachedUsageBundleEntry<FileSignature>>
    private let sessionScanCount = Locked(0)
    private let sessionCacheHitCount = Locked(0)
    typealias PricingCost = @Sendable (
        _ model: String,
        _ inputTokens: Int,
        _ outputTokens: Int,
        _ cacheCreationTokens: Int,
        _ cacheReadTokens: Int
    ) throws -> Double

    private let pricingCost: PricingCost

    private struct LegacyContentReadError: Error {
        let underlying: Error
    }

    public init(
        sessionDirectoryOverride: String? = nil,
        fileManager: FileManager = .default,
        appPaths: OpenBurnBarAppPaths = .live()
    ) {
        self.sessionDirectoriesOverride = sessionDirectoryOverride.map { [$0] }
        self.fileManager = fileManager
        self.pricingCost = Self.defaultPricingCost
        self.cacheStore = ParserDiskCacheStore(
            cacheURL: Self.cacheURL(sessionDirectoriesOverride: sessionDirectoryOverride.map { [$0] }, appPaths: appPaths),
            fileManager: fileManager,
            schemaVersion: 1,
            logLabel: "GooseParser"
        )
    }

    init(
        sessionDirectoriesOverride: [String],
        pricingCost: @escaping PricingCost = GooseParser.defaultPricingCost,
        fileManager: FileManager = .default,
        appPaths: OpenBurnBarAppPaths = .live()
    ) {
        self.sessionDirectoriesOverride = sessionDirectoriesOverride
        self.fileManager = fileManager
        self.pricingCost = pricingCost
        self.cacheStore = ParserDiskCacheStore(
            cacheURL: Self.cacheURL(sessionDirectoriesOverride: sessionDirectoriesOverride, appPaths: appPaths),
            fileManager: fileManager,
            schemaVersion: 1,
            logLabel: "GooseParser"
        )
    }

    var lastSessionScanCount: Int { sessionScanCount.read() }
    var lastSessionCacheHitCount: Int { sessionCacheHitCount.read() }

    private static func cacheURL(
        sessionDirectoriesOverride: [String]?,
        appPaths: OpenBurnBarAppPaths
    ) -> URL {
        if let override = sessionDirectoriesOverride, let first = override.first {
            return URL(fileURLWithPath: (first as NSString).expandingTildeInPath)
                .appendingPathComponent(".obb-goose-parser-cache.plist")
        }
        return appPaths.gooseParserCacheURL
    }

    private static let sqliteDateFormats: [DateFormatter] = {
        let formats = [
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd HH:mm:ss.SSS",
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd'T'HH:mm:ss.SSS"
        ]
        return formats.map { format in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            return formatter
        }
    }()

    public func parse() async throws -> ParseResult {
        try await parse(options: .default)
    }

    public func parse(options: LogParseOptions) async throws -> ParseResult {
        sessionScanCount.write(0)
        sessionCacheHitCount.write(0)
        let gate = ParserFileReadGate(options: options, fileManager: fileManager)
        let sessionDirectories = resolvedSessionDirectories()

        var databasePaths: [String] = []
        for sessionsPath in sessionDirectories where fileManager.fileExists(atPath: sessionsPath) {
            let dbPath = (sessionsPath as NSString).appendingPathComponent("sessions.db")
            if fileManager.fileExists(atPath: dbPath) {
                databasePaths.append(dbPath)
            }
        }

        var parseCache = cacheStore.load()
        var activePaths = Set<String>()
        var cacheMutated = false
        defer {
            if cacheMutated {
                cacheStore.persist(parseCache)
            }
        }

        if !databasePaths.isEmpty {
            var usagesBySessionId: [String: TokenUsage] = [:]
            var conversationsById: [String: ConversationRecord] = [:]
            for dbPath in databasePaths {
                let dbURL = URL(fileURLWithPath: dbPath)
                let cacheKey = dbURL.standardizedFileURL.path
                activePaths.insert(cacheKey)
                guard try gate.shouldRead(dbURL) else { continue }

                let signature = FileSignature(for: dbURL, using: fileManager)
                if !options.includeConversationBodies,
                   let signature,
                   let cached = parseCache.fileEntries[cacheKey],
                   cached.signature == signature {
                    sessionCacheHitCount.withLock { $0 += 1 }
                    for session in cached.sessions {
                        usagesBySessionId[session.sessionId] = session.makeUsage(provider: .goose)
                    }
                    continue
                }

                sessionScanCount.withLock { $0 += 1 }
                do {
                    let result = try parseSQLiteDatabase(dbPath: dbPath)
                    for usage in result.usages {
                        usagesBySessionId[usage.sessionId] = usage
                    }
                    if options.includeConversationBodies {
                        for conversation in result.conversations {
                            conversationsById[conversation.id] = conversation
                        }
                    }
                    if let signature {
                        parseCache.fileEntries[cacheKey] = CachedUsageBundleEntry(
                            signature: signature,
                            usages: result.usages
                        )
                        cacheMutated = true
                    }
                } catch let error as SQLiteError {
                    gate.recordContentReadFailure(for: dbURL)
                    ParserDiagnostics.silentFailure(
                        "goose_sqlite_unreadable path=\(dbPath)",
                        error: error
                    )
                }
            }

            let stalePaths = Set(parseCache.fileEntries.keys).subtracting(activePaths)
            if !stalePaths.isEmpty {
                for stalePath in stalePaths {
                    parseCache.fileEntries.removeValue(forKey: stalePath)
                }
                cacheMutated = true
            }

            return ParseResult(
                usages: Array(usagesBySessionId.values),
                conversations: Array(conversationsById.values)
            )
        }

        var usages: [TokenUsage] = []
        var conversations: [ConversationRecord] = []

        for sessionsPath in sessionDirectories where fileManager.fileExists(atPath: sessionsPath) {
            let sessionsURL = URL(fileURLWithPath: sessionsPath)
            let jsonlFiles = (try? fileManager.contentsOfDirectory(
                at: sessionsURL,
                includingPropertiesForKeys: FileSignature.directoryListingPrefetchKeys
            ))?.filter {
                $0.pathExtension == "jsonl"
            } ?? []

            for file in jsonlFiles {
                let cacheKey = file.standardizedFileURL.path
                activePaths.insert(cacheKey)
                guard try gate.shouldRead(file) else { continue }
                let sessionId = file.deletingPathExtension().lastPathComponent

                let signature = FileSignature(for: file, using: fileManager)
                if !options.includeConversationBodies,
                   let signature,
                   let cached = parseCache.fileEntries[cacheKey],
                   cached.signature == signature {
                    sessionCacheHitCount.withLock { $0 += 1 }
                    for session in cached.sessions {
                        usages.append(session.makeUsage(provider: .goose))
                    }
                    continue
                }

                sessionScanCount.withLock { $0 += 1 }
                do {
                    if let pair = try parseJsonlSession(
                        file: file,
                        sessionId: sessionId,
                        includeConversationBodies: options.includeConversationBodies
                    ),
                       let usage = pair.usage {
                        usages.append(usage)
                        if options.includeConversationBodies, let conv = pair.conversation {
                            conversations.append(conv)
                        }
                        if let signature {
                            parseCache.fileEntries[cacheKey] = CachedUsageBundleEntry(
                                signature: signature,
                                usages: [usage]
                            )
                            cacheMutated = true
                        }
                    }
                } catch let error as LegacyContentReadError {
                    gate.recordContentReadFailure(for: file)
                    ParserDiagnostics.silentFailure(
                        "goose_jsonl_unreadable path=\(file.path)",
                        error: error.underlying
                    )
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

    // MARK: - SQLite Parsing

    private func parseSQLiteDatabase(dbPath: String) throws -> ParseResult {
        var usages: [TokenUsage] = []
        var conversations: [ConversationRecord] = []

        let reader = try SQLiteConnection.openReadOnly(path: dbPath)
        defer { reader.close() }

        let tables = try reader.tableNames()
        guard tables.contains("sessions") else {
            return ParseResult(usages: usages, conversations: conversations)
        }

        // Pull transcript turns from whichever message table this Goose build
        // ships (schema has shifted across versions), keyed by session id.
        let transcripts = try Self.loadTranscripts(reader: reader, tables: tables)

        let columnNames = Set(try reader.columnNames(ofTable: "sessions"))

        var selectFields = ["id"]
        let preferredFields = [
            "model",
            "provider",
            "provider_name",
            "model_config_json",
            "description",
            "title",
            "name",
            "working_dir",
            "working_directory",
            "cwd",
            "input_tokens",
            "accumulated_input_tokens",
            "output_tokens",
            "accumulated_output_tokens",
            "accumulated_total_tokens",
            "cache_read_tokens",
            "cache_write_tokens",
            "reasoning_tokens",
            "total_tokens",
            "tokens_used",
            "created_at",
            "updated_at"
        ]

        for field in preferredFields where columnNames.contains(field) {
            selectFields.append(field)
        }

        let orderColumn = columnNames.contains("created_at") ? "created_at"
            : (columnNames.contains("updated_at") ? "updated_at" : "id")
        let sql = """
            SELECT \(selectFields.joined(separator: ", "))
            FROM sessions
            ORDER BY \(orderColumn) DESC
        """
        let rows = try reader.query(sql)

        for row in rows {
            guard let sessionId = stringValue(row, column: "id") else { continue }

            var inputTokens = integerValue(row, column: "accumulated_input_tokens")
            if inputTokens == 0 {
                inputTokens = integerValue(row, column: "input_tokens")
            }

            var outputTokens = integerValue(row, column: "accumulated_output_tokens")
            if outputTokens == 0 {
                outputTokens = integerValue(row, column: "output_tokens")
            }

            let cacheReadTokens = integerValue(row, column: "cache_read_tokens")
            let cacheWriteTokens = integerValue(row, column: "cache_write_tokens")

            if inputTokens == 0 && outputTokens == 0 && cacheReadTokens == 0 && cacheWriteTokens == 0 {
                let total = firstNonZero(
                    integerValue(row, column: "accumulated_total_tokens"),
                    integerValue(row, column: "total_tokens"),
                    integerValue(row, column: "tokens_used")
                )
                if total > 0 {
                    inputTokens = Int(Double(total) * 0.85)
                    outputTokens = max(total - inputTokens, 0)
                }
            }

            guard inputTokens > 0 || outputTokens > 0 || cacheReadTokens > 0 || cacheWriteTokens > 0 else {
                continue
            }

            let model = resolvedModel(from: row)
            let cwd = stringValue(row, column: "working_dir")
                ?? stringValue(row, column: "working_directory")
                ?? stringValue(row, column: "cwd")
                ?? "~"
            let projectName = (cwd as NSString).lastPathComponent.isEmpty ? cwd : (cwd as NSString).lastPathComponent

            let startTime = timestamp(from: row, column: "created_at") ?? Date()
            let endTime = timestamp(from: row, column: "updated_at") ?? startTime

            let cost = try pricingCost(
                model,
                inputTokens,
                outputTokens,
                cacheWriteTokens,
                cacheReadTokens
            )

            usages.append(
                TokenUsage(
                    provider: .goose,
                    sessionId: sessionId,
                    projectName: projectName,
                    model: model,
                    inputTokens: inputTokens,
                    outputTokens: outputTokens,
                    cacheCreationTokens: cacheWriteTokens,
                    cacheReadTokens: cacheReadTokens,
                    costUSD: cost,
                    startTime: startTime,
                    endTime: endTime,
                    provenanceMethod: .providerLog,
                    provenanceConfidence: .exact
                )
            )

            let description = stringValue(row, column: "description")
                ?? stringValue(row, column: "title")
                ?? stringValue(row, column: "name")
            let turns = transcripts[sessionId] ?? []
            if let conversation = Self.buildConversation(
                sessionId: sessionId,
                projectName: projectName,
                description: description,
                workingDirectory: cwd == "~" ? nil : cwd,
                startTime: startTime,
                endTime: endTime,
                turns: turns
            ) {
                conversations.append(conversation)
            }
        }

        return ParseResult(usages: usages, conversations: conversations)
    }

    private static func defaultPricingCost(
        model: String,
        inputTokens: Int,
        outputTokens: Int,
        cacheCreationTokens: Int,
        cacheReadTokens: Int
    ) throws -> Double {
        try ModelPricing.lookup(model: model).cost(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheCreationTokens: cacheCreationTokens,
            cacheReadTokens: cacheReadTokens
        )
    }

    // MARK: - SQLite Transcript Extraction

    private struct GooseTurn {
        let role: String
        let text: String
        let order: Double
    }

    /// Loads message turns from whichever message table the Goose SQLite build exposes.
    /// Returns `[sessionId: [GooseTurn]]` so the session loop can attach transcripts.
    private static func loadTranscripts(reader: SQLiteReading, tables: Set<String>) throws -> [String: [GooseTurn]] {
        let candidateTables = ["messages", "conversation_messages", "session_messages", "message"]
        guard let table = candidateTables.first(where: { tables.contains($0) }) else { return [:] }

        let columnNames = Set(try reader.columnNames(ofTable: table))

        guard let sessionColumn = ["session_id", "sessionId", "session"].first(where: { columnNames.contains($0) }),
              let roleColumn = ["role", "type", "sender"].first(where: { columnNames.contains($0) }),
              let contentColumn = ["content", "text", "body", "message", "parts"].first(where: { columnNames.contains($0) }) else {
            return [:]
        }
        let orderColumn = ["created_at", "created_timestamp", "timestamp", "id", "rowid"].first(where: { columnNames.contains($0) }) ?? "rowid"

        let rows = try reader.query("SELECT \(sessionColumn), \(roleColumn), \(contentColumn), \(orderColumn) FROM \(table)")

        var transcripts: [String: [GooseTurn]] = [:]
        for row in rows {
            guard let sessionId = row.string(sessionColumn) else { continue }
            let roleRaw = row.string(roleColumn)
            let role = (roleRaw ?? "").lowercased()
            let contentRaw = row.string(contentColumn)
            guard let text = flattenContent(contentRaw)?.nonEmpty else { continue }
            let fallbackOrder = Double(transcripts[sessionId]?.count ?? 0)
            let order: Double
            switch row.value(orderColumn) {
            case .integer(let value)?: order = Double(value)
            case .real(let value)?: order = value
            case .text(let value)?: order = Double(value) ?? fallbackOrder
            default: order = fallbackOrder
            }
            transcripts[sessionId, default: []].append(GooseTurn(role: role, text: text, order: order))
        }
        return transcripts
    }

    /// Flattens Goose message content that may be plain text or a JSON array of
    /// `{type, text}` content blocks into a single transcript string.
    private static func flattenContent(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if raw.hasPrefix("[") || raw.hasPrefix("{"),
           let data = raw.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) { // try?-ok(log JSON, raw fallback)
            if let blocks = json as? [[String: Any]] {
                let parts = blocks.compactMap { block -> String? in
                    let type = (block["type"] as? String ?? "text").lowercased()
                    guard type == "text" || type == "reasoning" || type.isEmpty else { return nil }
                    return (block["text"] as? String ?? block["content"] as? String)?.nonEmpty
                }
                return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
            }
            if let dict = json as? [String: Any] {
                return (dict["text"] as? String ?? dict["content"] as? String)?.nonEmpty
            }
        }
        return raw
    }

    private static func buildConversation(
        sessionId: String,
        projectName: String,
        description: String?,
        workingDirectory: String?,
        startTime: Date,
        endTime: Date,
        turns: [GooseTurn]
    ) -> ConversationRecord? {
        let sorted = turns.sorted { $0.order < $1.order }

        var fullText = ""
        var firstUser: String?
        var lastAssistant = ""
        var userWords = 0
        var assistantWords = 0
        var messageCount = 0

        for turn in sorted {
            let isAssistant = turn.role == "assistant" || turn.role == "ai"
            let isUser = turn.role == "user" || turn.role == "human"
            guard isAssistant || isUser else { continue }
            if isAssistant {
                assistantWords += turn.text.split { $0.isWhitespace || $0.isNewline }.count
                lastAssistant = turn.text
            } else {
                userWords += turn.text.split { $0.isWhitespace || $0.isNewline }.count
                if firstUser == nil { firstUser = String(turn.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120)) }
            }
            if !fullText.isEmpty { fullText += "\n\n" }
            fullText += SessionLogMarkdownFormatter.transcriptTurnMarkdown(isAssistant: isAssistant, body: turn.text)
            messageCount += 1
        }

        let title = description?.nonEmpty ?? firstUser ?? projectName
        // Metadata-only records (no transcript table) still back up and stay searchable by title/project.
        return ConversationRecord(
            id: ConversationRecord.stableId(provider: .goose, sessionId: sessionId),
            provider: .goose,
            sessionId: sessionId,
            projectName: projectName,
            startTime: startTime,
            endTime: endTime,
            messageCount: messageCount,
            userWordCount: userWords,
            assistantWordCount: assistantWords,
            keyFiles: [],
            keyCommands: [],
            keyTools: [],
            inferredTaskTitle: title,
            lastAssistantMessage: String(lastAssistant.prefix(500)),
            fullText: fullText,
            indexedAt: Date(),
            workingDirectory: workingDirectory,
            fileModifiedAt: endTime,
            summary: nil
        )
    }

    private func integerValue(_ row: SQLiteRow, column: String) -> Int {
        if let value = row.int(column) { return value }
        if let value = row.int64(column) { return Int(value) }
        if let value = row.double(column) { return Int(value.rounded()) }
        if let value = row.string(column), let parsed = Int(value) { return parsed }
        if let value = row.string(column), let parsed = Double(value) { return Int(parsed.rounded()) }
        return 0
    }

    private func stringValue(_ row: SQLiteRow, column: String) -> String? {
        if let value = row.string(column), !value.isEmpty {
            return value
        }
        if let value = row.int64(column) {
            return String(value)
        }
        if let value = row.int(column) {
            return String(value)
        }
        return nil
    }

    private func resolvedModel(from row: SQLiteRow) -> String {
        if let model = stringValue(row, column: "model") {
            return TokenExtractionUtility.normalizeModelName(model)
        }

        if let configJSON = stringValue(row, column: "model_config_json"),
           let data = configJSON.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { // try?-ok(config JSON, model fallback)
            let candidates = [
                json["model_name"],
                json["model"],
                json["modelName"],
                json["name"],
                json["provider_model"]
            ]
            for candidate in candidates {
                if let model = candidate as? String, !model.isEmpty {
                    return TokenExtractionUtility.normalizeModelName(model)
                }
            }
        }

        if let providerName = stringValue(row, column: "provider_name") {
            return TokenExtractionUtility.normalizeModelName(providerName)
        }

        if let provider = stringValue(row, column: "provider") {
            return TokenExtractionUtility.normalizeModelName(provider)
        }

        return "goose"
    }

    private func timestamp(from row: SQLiteRow, column: String) -> Date? {
        switch row.value(column) {
        case .integer(let value)?:
            return TimestampNormalizationUtility.date(fromEpoch: Double(value))
        case .real(let value)?:
            return TimestampNormalizationUtility.date(fromEpoch: value)
        case .text(let value)?:
            if let parsed = ThreadSafeISO8601DateFormatter.parse(value) { return parsed }
            for formatter in Self.sqliteDateFormats {
                if let parsed = formatter.date(from: value) {
                    return parsed
                }
            }
            return nil
        default:
            return nil
        }
    }

    private func resolvedSessionDirectories() -> [String] {
        if let overrides = sessionDirectoriesOverride {
            var seen: Set<String> = []
            return overrides.compactMap { override in
                let trimmed = override.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                let expanded = (trimmed as NSString).expandingTildeInPath
                return seen.insert(expanded).inserted ? expanded : nil
            }
        }

        var candidates: [String] = []
        let env = ProcessInfo.processInfo.environment["GOOSE_PATH_ROOT"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let env, !env.isEmpty {
            candidates.append(((env as NSString).appendingPathComponent("data/sessions") as NSString).expandingTildeInPath)
        }

        candidates.append(("~/Library/Application Support/Block/goose/sessions" as NSString).expandingTildeInPath)
        candidates.append(("~/.local/share/goose/sessions" as NSString).expandingTildeInPath)
        candidates.append(("~/.goose/sessions" as NSString).expandingTildeInPath)
        candidates.append(("~/.config/goose/sessions" as NSString).expandingTildeInPath)
        candidates.append((provider.logDirectory as NSString).expandingTildeInPath)

        var seen: Set<String> = []
        return candidates.filter { seen.insert($0).inserted }
    }

    private func firstNonZero(_ values: Int...) -> Int {
        values.first(where: { $0 > 0 }) ?? 0
    }

    // MARK: - Legacy JSONL Parsing

    private func parseJsonlSession(
        file: URL,
        sessionId: String,
        includeConversationBodies: Bool
    ) throws -> (usage: TokenUsage?, conversation: ConversationRecord?)? {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: file)
        } catch {
            throw LegacyContentReadError(underlying: error)
        }
        defer { try? handle.close() } // try?-ok(handle teardown)
        do {
            _ = try handle.read(upToCount: 1)
            try handle.seek(toOffset: 0)
        } catch {
            throw LegacyContentReadError(underlying: error)
        }

        let mtime = (try? fileManager.attributesOfItem(atPath: file.path)[.modificationDate]) as? Date // try?-ok(mtime read, nil ok)

        var inputTokens = 0
        var outputTokens = 0
        var cacheCreationTokens = 0
        var cacheReadTokens = 0
        var model = "goose"
        var usedFallback = false
        var startTime: Date?
        var endTime: Date?
        var userChars = 0
        var assistantChars = 0
        var messageCount = 0
        var fullText = ""
        var firstUser: String?
        var lastAssistant = ""
        var userWords = 0
        var assistantWords = 0

        for line in handle.readAllUTF8Lines() {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { // try?-ok(log line JSON, skip)
                continue
            }

            if let ts = json["timestamp"] as? String,
               let date = ThreadSafeISO8601DateFormatter.parse(ts) {
                if startTime == nil { startTime = date }
                endTime = date
            }

            if let m = json["model"] as? String, !m.isEmpty {
                model = TokenExtractionUtility.normalizeModelName(m)
            }

            if let usage = json["usage"] as? [String: Any] {
                let extracted = TokenExtractionUtility.extractUsageTokens(usage)
                inputTokens += extracted.input
                outputTokens += extracted.output
                cacheCreationTokens += extracted.cacheCreation
                cacheReadTokens += extracted.cacheRead
            }
            if let message = json["message"] as? [String: Any],
               let usage = message["usage"] as? [String: Any] {
                let extracted = TokenExtractionUtility.extractUsageTokens(usage)
                inputTokens += extracted.input
                outputTokens += extracted.output
                cacheCreationTokens += extracted.cacheCreation
                cacheReadTokens += extracted.cacheRead
            }

            let role = (json["role"] as? String ?? (json["message"] as? [String: Any])?["role"] as? String ?? "").lowercased()
            let content = json["content"] as? String ?? (json["message"] as? [String: Any])?["content"] as? String ?? ""

            if role == "user" && !content.isEmpty {
                userChars += content.count
                messageCount += 1
                if includeConversationBodies {
                    userWords += content.split { $0.isWhitespace || $0.isNewline }.count
                    if firstUser == nil {
                        firstUser = String(content.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
                    }
                    if !fullText.isEmpty { fullText += "\n\n" }
                    fullText += SessionLogMarkdownFormatter.transcriptTurnMarkdown(isAssistant: false, body: content)
                }
            } else if role == "assistant" && !content.isEmpty {
                assistantChars += content.count
                messageCount += 1
                if includeConversationBodies {
                    assistantWords += content.split { $0.isWhitespace || $0.isNewline }.count
                    lastAssistant = content
                    if !fullText.isEmpty { fullText += "\n\n" }
                    fullText += SessionLogMarkdownFormatter.transcriptTurnMarkdown(isAssistant: true, body: content)
                }
            }
        }

        let hasUsage = inputTokens > 0 || outputTokens > 0 || cacheCreationTokens > 0 || cacheReadTokens > 0

        if !hasUsage {
            guard userChars + assistantChars > 0 else { return nil }
            let estimated = TokenExtractionUtility.estimateFallbackTokens(
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

        guard inputTokens > 0 || outputTokens > 0 || cacheCreationTokens > 0 || cacheReadTokens > 0 else { return nil }

        let pricing = ModelPricing.lookup(model: model)
        let cost = try pricing.cost(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheCreationTokens: cacheCreationTokens,
            cacheReadTokens: cacheReadTokens
        )

        let usage = TokenUsage(
            provider: .goose,
            sessionId: sessionId,
            projectName: sessionId,
            model: model,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheCreationTokens: cacheCreationTokens,
            cacheReadTokens: cacheReadTokens,
            costUSD: cost,
            startTime: startTime ?? Date(),
            endTime: endTime ?? Date(),
            provenanceMethod: usedFallback ? .heuristicEstimate : .providerLog,
            provenanceConfidence: usedFallback ? .lowConfidenceEstimate : .exact,
            estimatorVersion: usedFallback ? TokenExtractionUtility.currentEstimatorVersion : ""
        )

        guard includeConversationBodies else { return (usage, nil) }

        let conversation = ConversationRecord(
            id: ConversationRecord.stableId(provider: .goose, sessionId: sessionId),
            provider: .goose,
            sessionId: sessionId,
            projectName: sessionId,
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
            fullText: fullText,
            indexedAt: Date(),
            fileModifiedAt: mtime,
            summary: nil
        )

        return (usage, conversation)
    }
}
