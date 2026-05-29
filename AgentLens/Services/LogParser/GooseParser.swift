import Foundation
import OpenBurnBarCore
import GRDB

// MARK: - Goose Parser

/// Parses Goose (Block) sessions from the active Goose data directory.
/// Falls back to legacy JSONL files only when no SQLite database exists.
final class GooseParser: LogParser, Sendable {
    let provider: AgentProvider = .goose

    /// When set, the parser reads only this sessions directory (which holds
    /// `sessions.db` and/or legacy `*.jsonl`). Keeps tests hermetic and lets
    /// callers point at a non-default Goose data root. `nil` uses the standard
    /// discovery order (env override + known install locations).
    private let sessionDirectoryOverride: String?

    init(sessionDirectoryOverride: String? = nil) {
        self.sessionDirectoryOverride = sessionDirectoryOverride
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

    func parse() async throws -> ParseResult {
        let fm = FileManager.default
        let sessionDirectories = resolvedSessionDirectories()

        var databasePaths: [String] = []
        for sessionsPath in sessionDirectories where fm.fileExists(atPath: sessionsPath) {
            let dbPath = (sessionsPath as NSString).appendingPathComponent("sessions.db")
            if fm.fileExists(atPath: dbPath) {
                databasePaths.append(dbPath)
            }
        }

        if !databasePaths.isEmpty {
            var usagesBySessionId: [String: TokenUsage] = [:]
            var conversationsById: [String: ConversationRecord] = [:]
            for dbPath in databasePaths {
                let result = try parseSQLiteDatabase(dbPath: dbPath)
                for usage in result.usages {
                    usagesBySessionId[usage.sessionId] = usage
                }
                for conversation in result.conversations {
                    conversationsById[conversation.id] = conversation
                }
            }
            return ParseResult(
                usages: Array(usagesBySessionId.values),
                conversations: Array(conversationsById.values)
            )
        }

        var usages: [TokenUsage] = []
        var conversations: [ConversationRecord] = []

        for sessionsPath in sessionDirectories where fm.fileExists(atPath: sessionsPath) {
            let sessionsURL = URL(fileURLWithPath: sessionsPath)
            let jsonlFiles = (try? fm.contentsOfDirectory(at: sessionsURL, includingPropertiesForKeys: nil))?.filter {
                $0.pathExtension == "jsonl"
            } ?? []

            for file in jsonlFiles {
                let sessionId = file.deletingPathExtension().lastPathComponent
                if let pair = parseJsonlSession(file: file, sessionId: sessionId),
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

    // MARK: - SQLite Parsing

    private func parseSQLiteDatabase(dbPath: String) throws -> ParseResult {
        var usages: [TokenUsage] = []
        var conversations: [ConversationRecord] = []

        var config = Configuration()
        config.readonly = true
        let db = try DatabaseQueue(path: dbPath, configuration: config)

        try db.read { db in
            let tables = Set(try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table'"))
            guard tables.contains("sessions") else { return }

            // Pull transcript turns from whichever message table this Goose build
            // ships (schema has shifted across versions), keyed by session id.
            let transcripts = try Self.loadTranscripts(db: db, tables: tables)

            let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(sessions)")
            let columnNames = Set(columns.compactMap { $0["name"] as? String })

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
            let rows = try Row.fetchAll(db, sql: sql)

            for row in rows {
                guard let sessionId: String = row["id"] else { continue }

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

                let pricing = ModelPricing.lookup(model: model)
                let cost = pricing.cost(
                    inputTokens: inputTokens,
                    outputTokens: outputTokens,
                    cacheCreationTokens: cacheWriteTokens,
                    cacheReadTokens: cacheReadTokens
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
        }

        return ParseResult(usages: usages, conversations: conversations)
    }

    // MARK: - SQLite Transcript Extraction

    private struct GooseTurn {
        let role: String
        let text: String
        let order: Double
    }

    /// Loads message turns from whichever message table the Goose SQLite build exposes.
    /// Returns `[sessionId: [GooseTurn]]` so the session loop can attach transcripts.
    private static func loadTranscripts(db: Database, tables: Set<String>) throws -> [String: [GooseTurn]] {
        let candidateTables = ["messages", "conversation_messages", "session_messages", "message"]
        guard let table = candidateTables.first(where: { tables.contains($0) }) else { return [:] }

        let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))")
        let columnNames = Set(columns.compactMap { $0["name"] as? String })

        guard let sessionColumn = ["session_id", "sessionId", "session"].first(where: { columnNames.contains($0) }),
              let roleColumn = ["role", "type", "sender"].first(where: { columnNames.contains($0) }),
              let contentColumn = ["content", "text", "body", "message", "parts"].first(where: { columnNames.contains($0) }) else {
            return [:]
        }
        let orderColumn = ["created_at", "created_timestamp", "timestamp", "id", "rowid"].first(where: { columnNames.contains($0) }) ?? "rowid"

        let rows = try Row.fetchAll(db, sql: "SELECT \(sessionColumn), \(roleColumn), \(contentColumn), \(orderColumn) FROM \(table)")

        var transcripts: [String: [GooseTurn]] = [:]
        for row in rows {
            guard let sessionId: String = row[sessionColumn] else { continue }
            let roleRaw: String? = row[roleColumn]
            let role = (roleRaw ?? "").lowercased()
            let contentRaw: String? = row[contentColumn]
            guard let text = flattenContent(contentRaw)?.nonEmpty else { continue }
            let fallbackOrder = Double(transcripts[sessionId]?.count ?? 0)
            let orderValue: DatabaseValue? = row[orderColumn]
            let order: Double
            switch orderValue?.storage {
            case .int64(let value): order = Double(value)
            case .double(let value): order = value
            case .string(let value): order = Double(value) ?? fallbackOrder
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
           let json = try? JSONSerialization.jsonObject(with: data) {
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

    // Reads through `DatabaseValue` so a column whose stored type differs from
    // the expected one (e.g. a TEXT `created_at`) never trips GRDB's force-decode
    // `fatalError`. Missing columns and NULLs resolve to the zero/`nil` default.
    private func integerValue(_ row: Row, column: String) -> Int {
        guard let dbValue: DatabaseValue = row[column] else { return 0 }
        switch dbValue.storage {
        case .int64(let value): return Int(value)
        case .double(let value): return Int(value.rounded())
        case .string(let value): return Int(value) ?? Int(Double(value) ?? 0)
        case .null, .blob: return 0
        }
    }

    private func stringValue(_ row: Row, column: String) -> String? {
        guard let dbValue: DatabaseValue = row[column], case .string(let value) = dbValue.storage, !value.isEmpty else {
            return nil
        }
        return value
    }

    private func resolvedModel(from row: Row) -> String {
        if let model = stringValue(row, column: "model") {
            return TokenExtractionUtility.normalizeModelName(model)
        }

        if let configJSON = stringValue(row, column: "model_config_json"),
           let data = configJSON.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
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

    private func timestamp(from row: Row, column: String) -> Date? {
        guard let dbValue: DatabaseValue = row[column] else { return nil }
        switch dbValue.storage {
        case .int64(let value):
            return TimestampNormalizationUtility.date(fromEpoch: Double(value))
        case .double(let value):
            return TimestampNormalizationUtility.date(fromEpoch: value)
        case .string(let value):
            if let parsed = ThreadSafeISO8601DateFormatter.parse(value) { return parsed }
            for formatter in Self.sqliteDateFormats {
                if let parsed = formatter.date(from: value) {
                    return parsed
                }
            }
            return nil
        case .null, .blob:
            return nil
        }
    }

    private func resolvedSessionDirectories() -> [String] {
        if let override = sessionDirectoryOverride?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            return [(override as NSString).expandingTildeInPath]
        }

        var candidates: [String] = []
        let env = ProcessInfo.processInfo.environment["GOOSE_PATH_ROOT"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let env, !env.isEmpty {
            candidates.append(((env as NSString).appendingPathComponent("data/sessions") as NSString).expandingTildeInPath)
        }

        candidates.append(("~/Library/Application Support/Block/goose/sessions" as NSString).expandingTildeInPath)
        candidates.append(("~/.local/share/goose/sessions" as NSString).expandingTildeInPath)
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
        sessionId: String
    ) -> (usage: TokenUsage?, conversation: ConversationRecord?)? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }

        let mtime = (try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate]) as? Date

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
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
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
                userWords += content.split { $0.isWhitespace || $0.isNewline }.count
                if firstUser == nil {
                    firstUser = String(content.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
                }
                if !fullText.isEmpty { fullText += "\n\n" }
                fullText += SessionLogMarkdownFormatter.transcriptTurnMarkdown(isAssistant: false, body: content)
                messageCount += 1
            } else if role == "assistant" && !content.isEmpty {
                assistantChars += content.count
                assistantWords += content.split { $0.isWhitespace || $0.isNewline }.count
                lastAssistant = content
                if !fullText.isEmpty { fullText += "\n\n" }
                fullText += SessionLogMarkdownFormatter.transcriptTurnMarkdown(isAssistant: true, body: content)
                messageCount += 1
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
        let cost = pricing.cost(
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
