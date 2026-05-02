import Foundation
import OpenBurnBarCore
import GRDB

// MARK: - Forge Dev Parser

/// Parses Forge sessions from local SQLite databases, with JSONL as a last resort.
final class ForgeDevParser: LogParser, Sendable {
    let provider: AgentProvider = .forgeDev

    private static let sqliteDateFormats: [DateFormatter] = {
        let formats = [
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd HH:mm:ss.SSSSSS",
            "yyyy-MM-dd HH:mm:ss.SSS",
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
        let databasePaths = discoverDatabasePaths()

        if !databasePaths.isEmpty {
            var usagesBySessionId: [String: TokenUsage] = [:]
            var conversationsBySessionId: [String: ConversationRecord] = [:]
            var parsedReadableDatabase = false

            for dbPath in databasePaths {
                let result: ParseResult
                do {
                    result = try parseDatabase(at: dbPath)
                } catch {
                    continue
                }
                parsedReadableDatabase = true
                for usage in result.usages {
                    usagesBySessionId[usage.sessionId] = usage
                }
                for conversation in result.conversations {
                    conversationsBySessionId[conversation.sessionId] = conversation
                }
            }

            if parsedReadableDatabase {
                return ParseResult(
                    usages: Array(usagesBySessionId.values),
                    conversations: Array(conversationsBySessionId.values)
                )
            }
        }

        let sessionsPath = (provider.logDirectory as NSString).expandingTildeInPath
        guard fm.fileExists(atPath: sessionsPath) else {
            return ParseResult(usages: [], conversations: [])
        }

        let sessionsURL = URL(fileURLWithPath: sessionsPath)
        var usages: [TokenUsage] = []
        var conversations: [ConversationRecord] = []

        let contents = (try? fm.contentsOfDirectory(at: sessionsURL, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        let jsonlFiles = contents.filter { $0.pathExtension == "jsonl" }
        let projectDirs = contents.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }

        for jsonlFile in jsonlFiles {
            let sessionId = jsonlFile.deletingPathExtension().lastPathComponent
            if let pair = parseJsonlSession(file: jsonlFile, sessionId: sessionId, projectName: sessionId),
               let usage = pair.usage {
                usages.append(usage)
                if let conversation = pair.conversation {
                    conversations.append(conversation)
                }
            }
        }

        for projectDir in projectDirs {
            let projectName = projectDir.lastPathComponent
            let files = (try? fm.contentsOfDirectory(at: projectDir, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension == "jsonl" {
                let sessionId = file.deletingPathExtension().lastPathComponent
                if let pair = parseJsonlSession(file: file, sessionId: sessionId, projectName: projectName),
                   let usage = pair.usage {
                    usages.append(usage)
                    if let conversation = pair.conversation {
                        conversations.append(conversation)
                    }
                }
            }
        }

        return ParseResult(usages: usages, conversations: conversations)
    }

    // MARK: - SQLite

    private func parseDatabase(at dbPath: String) throws -> ParseResult {
        if shouldParseFromSnapshot(dbPath: dbPath) {
            return try parseSnapshotDatabase(at: dbPath)
        }

        var config = Configuration()
        config.readonly = true
        let dbQueue = try DatabaseQueue(path: dbPath, configuration: config)
        return try parseDatabase(dbQueue: dbQueue)
    }

    private func parseSnapshotDatabase(at dbPath: String) throws -> ParseResult {
        let fm = FileManager.default
        let snapshotRoot = fm.temporaryDirectory.appendingPathComponent("openburnbar-forge-parser", isDirectory: true)
        try fm.createDirectory(at: snapshotRoot, withIntermediateDirectories: true)
        let snapshotDir = snapshotRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: snapshotDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: snapshotDir) }

        let sourceURL = URL(fileURLWithPath: dbPath)
        let snapshotURL = snapshotDir.appendingPathComponent(sourceURL.lastPathComponent)
        try fm.copyItem(at: sourceURL, to: snapshotURL)

        for suffix in ["-wal", "-shm"] {
            let sourceSidecar = dbPath + suffix
            guard fm.fileExists(atPath: sourceSidecar) else { continue }
            try fm.copyItem(
                atPath: sourceSidecar,
                toPath: snapshotURL.path + suffix
            )
        }

        let dbQueue = try DatabaseQueue(path: snapshotURL.path)
        return try parseDatabase(dbQueue: dbQueue)
    }

    private func shouldParseFromSnapshot(dbPath: String) -> Bool {
        let walPath = dbPath + "-wal"
        return !FileManager.default.fileExists(atPath: walPath)
    }

    private func parseDatabase(dbQueue: DatabaseQueue) throws -> ParseResult {
        var usages: [TokenUsage] = []
        var conversations: [ConversationRecord] = []

        try dbQueue.read { db in
            let tables = Set(try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table'"))
            guard tables.contains("conversations") else { return }

            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT conversation_id, title, workspace_id, context, created_at, updated_at, metrics
                    FROM conversations
                    ORDER BY created_at DESC
                """
            )

            for row in rows {
                guard let sessionId = stringValue(row, column: "conversation_id"), !sessionId.isEmpty else { continue }

                let title = stringValue(row, column: "title")
                let workspaceId = stringValue(row, column: "workspace_id") ?? "unknown-workspace"
                let contextJSON = jsonObject(from: stringValue(row, column: "context"))
                let metricsJSON = jsonObject(from: stringValue(row, column: "metrics"))

                let messages = (contextJSON?["messages"] as? [Any]) ?? []
                let summary = parseContextMessages(messages)

                let model = TokenExtractionUtility.normalizeModelName(summary.model ?? "forge")
                let projectPath = inferProjectPath(from: metricsJSON)
                let projectName = projectPath.map { ($0 as NSString).lastPathComponent }
                    ?? title
                    ?? "workspace-\(workspaceId)"

                let metricsStart = dateValue(metricsJSON?["started_at"])
                let createdAt = dateValue(rawValue(row, column: "created_at"))
                let updatedAt = dateValue(rawValue(row, column: "updated_at"))
                let startTime = metricsStart ?? createdAt ?? Date()
                let endTime = updatedAt ?? startTime

                if let usage = usage(
                    sessionId: sessionId,
                    projectName: projectName,
                    model: model,
                    inputTokens: summary.inputTokens,
                    outputTokens: summary.outputTokens,
                    cacheReadTokens: summary.cacheReadTokens,
                    startTime: startTime,
                    endTime: endTime
                ) {
                    usages.append(usage)
                }

                if let conversation = conversation(
                    sessionId: sessionId,
                    projectName: projectName,
                    title: title ?? summary.firstUser ?? projectName,
                    summary: summary,
                    keyFiles: collectFilePaths(from: metricsJSON),
                    startTime: startTime,
                    endTime: endTime,
                    fileModifiedAt: nil
                ) {
                    conversations.append(conversation)
                }
            }
        }

        return ParseResult(usages: usages, conversations: conversations)
    }

    private func parseContextMessages(_ messages: [Any]) -> ForgeSummary {
        var summary = ForgeSummary()

        for entry in messages {
            guard let json = entry as? [String: Any] else { continue }
            let message = json["message"] as? [String: Any]
            let text = message?["text"] as? [String: Any]
            let tool = message?["tool"] as? [String: Any]

            if let usageJSON = json["usage"] as? [String: Any] {
                let prompt = nestedActualInt(in: usageJSON, path: ["prompt_tokens"])
                let completion = nestedActualInt(in: usageJSON, path: ["completion_tokens"])
                let cached = nestedActualInt(in: usageJSON, path: ["cached_tokens"])
                let total = nestedActualInt(in: usageJSON, path: ["total_tokens"])
                let normalized = normalizeUsage(prompt: prompt, completion: completion, cached: cached, total: total)
                summary.inputTokens += normalized.input
                summary.outputTokens += normalized.output
                summary.cacheReadTokens += normalized.cacheRead
            }

            if let model = text?["model"] as? String, !model.isEmpty {
                summary.model = model
            }

            if let toolName = tool?["name"] as? String, !toolName.isEmpty {
                summary.keyTools.insert(toolName)
            }

            guard let role = (text?["role"] as? String)?.lowercased(),
                  let content = (text?["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !content.isEmpty else {
                continue
            }

            summary.consume(role: role, content: content)
        }

        return summary
    }

    private func normalizeUsage(prompt: Int, completion: Int, cached: Int, total: Int) -> (input: Int, output: Int, cacheRead: Int) {
        guard total > 0 else {
            return (max(prompt, 0), max(completion, 0), max(cached, 0))
        }

        if prompt > 0, completion >= 0, cached > 0, prompt + completion == total {
            return (max(prompt - cached, 0), max(completion, 0), max(cached, 0))
        }

        if prompt > 0, completion >= 0, cached >= 0, prompt + completion + cached == total {
            return (max(prompt, 0), max(completion, 0), max(cached, 0))
        }

        if prompt == 0 {
            return (max(total - completion - cached, 0), max(completion, 0), max(cached, 0))
        }

        let adjustedPrompt = cached > 0 && prompt + completion > total ? max(prompt - cached, 0) : prompt
        return (max(adjustedPrompt, 0), max(completion, 0), max(cached, 0))
    }

    private func nestedActualInt(in dictionary: [String: Any], path: [String]) -> Int {
        var current: Any? = dictionary
        for key in path {
            current = (current as? [String: Any])?[key]
        }

        if let nested = current as? [String: Any] {
            if let actual = nested["actual"] as? Int { return actual }
            if let actual = nested["actual"] as? Double { return Int(actual.rounded()) }
            if let actual = nested["actual"] as? String { return Int(actual) ?? 0 }
        }

        if let value = current as? Int { return value }
        if let value = current as? Double { return Int(value.rounded()) }
        if let value = current as? String { return Int(value) ?? 0 }
        return 0
    }

    private func inferProjectPath(from metricsJSON: [String: Any]?) -> String? {
        let filePaths = collectFilePaths(from: metricsJSON)
        guard !filePaths.isEmpty else { return nil }

        let splitPaths = filePaths.map { ($0 as NSString).pathComponents }
        guard var common = splitPaths.first else { return nil }

        for components in splitPaths.dropFirst() {
            var nextCommon: [String] = []
            for (lhs, rhs) in zip(common, components) {
                guard lhs == rhs else { break }
                nextCommon.append(lhs)
            }
            common = nextCommon
            if common.isEmpty { break }
        }

        if common.count > 1 {
            return NSString.path(withComponents: common)
        }

        return (filePaths.first! as NSString).deletingLastPathComponent
    }

    private func collectFilePaths(from metricsJSON: [String: Any]?) -> [String] {
        guard let metricsJSON else { return [] }

        var paths: [String] = []
        if let filesChanged = metricsJSON["files_changed"] as? [String: Any] {
            paths.append(contentsOf: filesChanged.keys)
        }
        if let filesAccessed = metricsJSON["files_accessed"] as? [String] {
            paths.append(contentsOf: filesAccessed)
        }

        var seen: Set<String> = []
        return paths.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    // MARK: - Legacy JSONL Fallback

    private func parseJsonlSession(
        file: URL,
        sessionId: String,
        projectName: String
    ) -> (usage: TokenUsage?, conversation: ConversationRecord?)? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }

        let mtime = modificationDate(of: file)
        var summary = ForgeSummary()
        var startTime: Date?
        var endTime: Date?

        for line in handle.readAllUTF8Lines() {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            let message = json["message"] as? [String: Any]
            let role = ((message?["role"] as? String) ?? (json["role"] as? String) ?? "").lowercased()
            let content = ((message?["content"] as? String) ?? (json["content"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if let timestamp = dateValue(json["timestamp"]) {
                if startTime == nil { startTime = timestamp }
                endTime = timestamp
            }

            if let model = (message?["model"] as? String) ?? (json["model"] as? String), !model.isEmpty {
                summary.model = model
            }

            if let usageJSON = (message?["usage"] as? [String: Any]) ?? (json["usage"] as? [String: Any]) {
                let extracted = TokenExtractionUtility.extractUsageTokens(usageJSON)
                summary.inputTokens += extracted.input
                summary.outputTokens += extracted.output
                summary.cacheReadTokens += extracted.cacheRead
            }

            summary.consume(role: role, content: content)
        }

        if summary.inputTokens == 0 && summary.outputTokens == 0 {
            let estimated = TokenExtractionUtility.estimateFallbackTokens(
                userVisibleChars: summary.userChars,
                assistantVisibleChars: summary.assistantChars,
                assistantReasoningChars: 0,
                userMessageCount: max(summary.messageCount / 2, 1),
                assistantMessageCount: max(summary.messageCount / 2, 1)
            )
            summary.inputTokens = estimated.input
            summary.outputTokens = estimated.output
        }

        let usage = usage(
            sessionId: sessionId,
            projectName: projectName,
            model: TokenExtractionUtility.normalizeModelName(summary.model ?? "forge"),
            inputTokens: summary.inputTokens,
            outputTokens: summary.outputTokens,
            cacheReadTokens: summary.cacheReadTokens,
            startTime: startTime ?? mtime ?? Date(),
            endTime: endTime ?? mtime ?? Date()
        )

        let conversation = conversation(
            sessionId: sessionId,
            projectName: projectName,
            title: summary.firstUser ?? projectName,
            summary: summary,
            keyFiles: [],
            startTime: startTime ?? mtime,
            endTime: endTime ?? mtime,
            fileModifiedAt: mtime
        )

        return (usage, conversation)
    }

    // MARK: - Builders

    private func usage(
        sessionId: String,
        projectName: String,
        model: String,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int,
        startTime: Date,
        endTime: Date
    ) -> TokenUsage? {
        guard inputTokens > 0 || outputTokens > 0 || cacheReadTokens > 0 else { return nil }

        let pricing = ModelPricing.lookup(model: model)
        let cost = pricing.cost(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: cacheReadTokens
        )

        return TokenUsage(
            provider: .forgeDev,
            sessionId: sessionId,
            projectName: projectName,
            model: model,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: cacheReadTokens,
            costUSD: cost,
            startTime: startTime,
            endTime: endTime,
            provenanceMethod: .providerLog,
            provenanceConfidence: .exact
        )
    }

    private func conversation(
        sessionId: String,
        projectName: String,
        title: String,
        summary: ForgeSummary,
        keyFiles: [String],
        startTime: Date?,
        endTime: Date?,
        fileModifiedAt: Date?
    ) -> ConversationRecord? {
        guard !summary.fullText.isEmpty || summary.messageCount > 0 else { return nil }

        return ConversationRecord(
            id: ConversationRecord.stableId(provider: .forgeDev, sessionId: sessionId),
            provider: .forgeDev,
            sessionId: sessionId,
            projectName: projectName,
            startTime: startTime,
            endTime: endTime,
            messageCount: summary.messageCount,
            userWordCount: summary.userWords,
            assistantWordCount: summary.assistantWords,
            keyFiles: keyFiles,
            keyCommands: [],
            keyTools: Array(summary.keyTools).sorted(),
            inferredTaskTitle: title,
            lastAssistantMessage: summary.lastAssistant,
            fullText: summary.fullText,
            indexedAt: Date(),
            fileModifiedAt: fileModifiedAt,
            summary: nil
        )
    }

    // MARK: - Discovery / Utilities

    private func discoverDatabasePaths() -> [String] {
        let fm = FileManager.default
        let homeURL = fm.homeDirectoryForCurrentUser
        var candidates: [String] = []

        candidates.append(((provider.logDirectory as NSString).expandingTildeInPath as NSString).appendingPathComponent(".forge.db"))
        candidates.append((("~/.forge" as NSString).expandingTildeInPath as NSString).appendingPathComponent(".forge.db"))
        candidates.append((homeURL.path as NSString).appendingPathComponent(".forge.db"))

        if let children = try? fm.contentsOfDirectory(at: homeURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for child in children {
                let isDirectory = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                guard isDirectory else { continue }
                candidates.append(child.appendingPathComponent(".forge.db").path)
            }
        }

        var seen: Set<String> = []
        return candidates.filter { path in
            guard seen.insert(path).inserted else { return false }
            return fm.fileExists(atPath: path)
        }
    }

    private func jsonObject(from raw: String?) -> [String: Any]? {
        guard let raw, let data = raw.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func rawValue(_ row: Row, column: String) -> Any? {
        guard let value = row[column] else { return nil }
        if let string = value as? String { return string }
        if let integer = value as? Int64 { return integer }
        if let integer = value as? Int { return integer }
        if let double = value as? Double { return double }
        if let bool = value as? Bool { return bool }
        return nil
    }

    private func stringValue(_ row: Row, column: String) -> String? {
        switch rawValue(row, column: column) {
        case let value as String:
            return value.isEmpty ? nil : value
        case let value as Int64:
            return String(value)
        case let value as Int:
            return String(value)
        case let value as Double:
            if value.rounded(.towardZero) == value {
                return String(Int64(value))
            }
            return String(value)
        default:
            return nil
        }
    }

    private func dateValue(_ raw: Any?) -> Date? {
        switch raw {
        case let value as Int:
            return TimestampNormalizationUtility.date(fromEpoch: Double(value))
        case let value as Int64:
            return TimestampNormalizationUtility.date(fromEpoch: Double(value))
        case let value as Double:
            return TimestampNormalizationUtility.date(fromEpoch: value)
        case let value as String:
            if let date = ThreadSafeISO8601DateFormatter.parse(value) {
                return date
            }
            for formatter in Self.sqliteDateFormats {
                if let date = formatter.date(from: value) {
                    return date
                }
            }
            return nil
        default:
            return nil
        }
    }

    private func modificationDate(of file: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate]) as? Date
    }
}

private struct ForgeSummary {
    var model: String?
    var inputTokens = 0
    var outputTokens = 0
    var cacheReadTokens = 0
    var userChars = 0
    var assistantChars = 0
    var messageCount = 0
    var userWords = 0
    var assistantWords = 0
    var firstUser: String?
    var lastAssistant = ""
    var fullText = ""
    var keyTools: Set<String> = []

    mutating func consume(role: String, content: String) {
        switch role {
        case "user":
            userChars += content.count
            userWords += content.split { $0.isWhitespace || $0.isNewline }.count
            if firstUser == nil {
                firstUser = String(content.prefix(120))
            }
            append(content, isAssistant: false)
            messageCount += 1
        case "assistant":
            assistantChars += content.count
            assistantWords += content.split { $0.isWhitespace || $0.isNewline }.count
            lastAssistant = content
            append(content, isAssistant: true)
            messageCount += 1
        default:
            break
        }
    }

    private mutating func append(_ content: String, isAssistant: Bool) {
        if !fullText.isEmpty { fullText += "\n\n" }
        fullText += SessionLogMarkdownFormatter.transcriptTurnMarkdown(isAssistant: isAssistant, body: content)
    }
}
