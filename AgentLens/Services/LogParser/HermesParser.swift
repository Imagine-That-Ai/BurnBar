import Foundation
import GRDB

// MARK: - Hermes Parser

/// Parses Hermes sessions from SQLite first, then gateway/CLI fallback files.
final class HermesParser: LogParser, @unchecked Sendable {
    let provider: AgentProvider = .hermes
    private let fileManager: FileManager
    private let hermesRootURL: URL?

    init(fileManager: FileManager = .default, hermesRootURL: URL? = nil) {
        self.fileManager = fileManager
        self.hermesRootURL = hermesRootURL
    }

    nonisolated(unsafe) private static let iso8601Basic: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    nonisolated(unsafe) private static let iso8601Fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

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
        var usages: [TokenUsage] = []
        var conversations: [ConversationRecord] = []
        var seenSessionIds: Set<String> = []

        for scope in resolvedHermesScopes() {
            let hermesHome = scope.homeURL
            let sessionsDir = hermesHome.appendingPathComponent("sessions", isDirectory: true)

            let dbURL = hermesHome.appendingPathComponent("state.db")
            if fileManager.fileExists(atPath: dbURL.path), fileSize(at: dbURL) > 0 {
                let sqliteResult = try parseSQLiteDatabase(dbURL: dbURL, scope: scope)
                usages.append(contentsOf: sqliteResult.usages)
                conversations.append(contentsOf: sqliteResult.conversations)
                seenSessionIds.formUnion(sqliteResult.usages.map(\.sessionId))
                seenSessionIds.formUnion(sqliteResult.conversations.map(\.sessionId))
            }

            let indexURL = sessionsDir.appendingPathComponent("sessions.json")
            if fileManager.fileExists(atPath: indexURL.path) {
                let gatewayResult = parseGatewayIndex(
                    indexURL: indexURL,
                    sessionsDir: sessionsDir,
                    excluding: seenSessionIds,
                    scope: scope
                )
                usages.append(contentsOf: gatewayResult.usages)
                conversations.append(contentsOf: gatewayResult.conversations)
                seenSessionIds.formUnion(gatewayResult.usages.map(\.sessionId))
                seenSessionIds.formUnion(gatewayResult.conversations.map(\.sessionId))
            }

            if fileManager.fileExists(atPath: sessionsDir.path) {
                let contents = (try? fileManager.contentsOfDirectory(
                    at: sessionsDir,
                    includingPropertiesForKeys: [.isRegularFileKey]
                )) ?? []

                for file in contents where file.lastPathComponent.hasPrefix("session_") && file.pathExtension == "json" {
                    let result = parseCLISnapshot(file: file, excluding: seenSessionIds, scope: scope)
                    usages.append(contentsOf: result.usages)
                    conversations.append(contentsOf: result.conversations)
                    seenSessionIds.formUnion(result.usages.map(\.sessionId))
                    seenSessionIds.formUnion(result.conversations.map(\.sessionId))
                }

                for file in contents where file.pathExtension == "jsonl" && file.lastPathComponent != "sessions.json" {
                    let rawSessionId = file.deletingPathExtension().lastPathComponent
                    let sessionId = scope.qualify(sessionId: rawSessionId)
                    guard !seenSessionIds.contains(sessionId) else { continue }
                    guard let summary = parseLegacyTranscript(file: file) else { continue }

                    let projectName = scope.projectName(
                        candidates: [],
                        fallbackSource: nil,
                        fallbackSessionId: rawSessionId
                    )
                    if let usage = usage(
                        sessionId: sessionId,
                        projectName: projectName,
                        model: summary.model ?? "hermes",
                        inputTokens: summary.inputTokens,
                        outputTokens: summary.outputTokens,
                        cacheCreationTokens: summary.cacheCreationTokens,
                        cacheReadTokens: summary.cacheReadTokens,
                        costOverride: nil,
                        startTime: summary.startTime ?? summary.fileModifiedAt ?? Date(),
                        endTime: summary.endTime ?? summary.fileModifiedAt ?? Date()
                    ) {
                        usages.append(usage)
                    }

                    if let conversation = conversation(
                        sessionId: sessionId,
                        projectName: projectName,
                        title: summary.firstUser ?? projectName,
                        summary: summary,
                        startTime: summary.startTime ?? summary.fileModifiedAt,
                        endTime: summary.endTime ?? summary.fileModifiedAt
                    ) {
                        conversations.append(conversation)
                    }

                    seenSessionIds.insert(sessionId)
                }
            }
        }

        return ParseResult(
            usages: deduplicate(usages),
            conversations: deduplicate(conversations)
        )
    }

    // MARK: - SQLite

    private func parseSQLiteDatabase(
        dbURL: URL,
        scope: HermesHomeScope
    ) throws -> ParseResult {
        var usages: [TokenUsage] = []
        var conversations: [ConversationRecord] = []

        var config = Configuration()
        config.readonly = true
        let dbQueue = try DatabaseQueue(path: dbURL.path, configuration: config)

        try dbQueue.read { db in
            let tables = Set(try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table'"))
            guard tables.contains("sessions") else { return }

            let sessionColumns = try availableColumns(in: "sessions", db: db)
            let sessionFields = [
                "id",
                "source",
                "model",
                "system_prompt",
                "started_at",
                "ended_at",
                "title",
                "input_tokens",
                "output_tokens",
                "cache_read_tokens",
                "cache_write_tokens",
                "reasoning_tokens",
                "estimated_cost_usd",
                "actual_cost_usd",
                "cost_status"
            ].filter { sessionColumns.contains($0) }

            guard !sessionFields.isEmpty else { return }

            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT \(sessionFields.joined(separator: ", "))
                    FROM sessions
                    ORDER BY started_at DESC
                """
            )

            let messageColumns = tables.contains("messages") ? try availableColumns(in: "messages", db: db) : []

            for row in rows {
                guard let rawSessionId: String = row["id"] else { continue }
                let sessionId = scope.qualify(sessionId: rawSessionId)

                var summary = messageColumns.isEmpty
                    ? nil
                    : try parseSQLiteTranscript(db: db, sessionId: rawSessionId, availableColumns: messageColumns)

                let source = stringValue(row, column: "source") ?? "hermes"
                let title = stringValue(row, column: "title")
                let projectName = scope.projectName(
                    candidates: [title],
                    fallbackSource: source,
                    fallbackSessionId: rawSessionId
                )

                var inputTokens = integerValue(row, column: "input_tokens")
                var outputTokens = integerValue(row, column: "output_tokens") + integerValue(row, column: "reasoning_tokens")
                let cacheReadTokens = integerValue(row, column: "cache_read_tokens")
                let cacheWriteTokens = integerValue(row, column: "cache_write_tokens")
                let model = TokenExtractionUtility.normalizeModelName(
                    stringValue(row, column: "model") ?? summary?.model ?? "hermes"
                )
                if let systemPrompt = stringValue(row, column: "system_prompt"),
                   var summaryValue = summary {
                    summaryValue.systemPromptChars = max(
                        summaryValue.systemPromptChars,
                        TokenExtractionUtility.contentMetrics(from: systemPrompt).visibleChars
                    )
                    summary = summaryValue
                }

                // VAL-TOKEN-004: Fallback/estimation runs only when explicit usage buckets are unavailable.
                // When all session row buckets are zero, try summary, then estimation as last resort.
                if inputTokens == 0 && outputTokens == 0 && cacheReadTokens == 0 && cacheWriteTokens == 0 {
                    if let summary {
                        // Summary available - use its parsed message data
                        inputTokens = summary.inputTokens
                        outputTokens = summary.outputTokens
                    } else {
                        // No summary either - fall back to estimation
                        let estimated = TokenExtractionUtility.estimateFallbackTokens(
                            userVisibleChars: 0,
                            assistantVisibleChars: 0,
                            assistantReasoningChars: 0,
                            userMessageCount: 0,
                            assistantMessageCount: 0
                        )
                        inputTokens = estimated.input
                        outputTokens = estimated.output
                    }
                }

                let startTime = dateValue(row["started_at"]) ?? summary?.startTime ?? modificationDate(of: dbURL) ?? Date()
                let endTime = dateValue(row["ended_at"]) ?? summary?.endTime ?? startTime

                let explicitCost: Double? = {
                    if let actual = doubleValue(row, column: "actual_cost_usd"), actual > 0 { return actual }
                    if let estimated = doubleValue(row, column: "estimated_cost_usd"), estimated > 0 { return estimated }
                    return nil
                }()

                if let usage = usage(
                    sessionId: sessionId,
                    projectName: projectName,
                    model: model,
                    inputTokens: inputTokens,
                    outputTokens: outputTokens,
                    cacheCreationTokens: cacheWriteTokens,
                    cacheReadTokens: cacheReadTokens,
                    costOverride: explicitCost,
                    startTime: startTime,
                    endTime: endTime
                ) {
                    usages.append(usage)
                }

                if let summary {
                    let conversation = conversation(
                        sessionId: sessionId,
                        projectName: projectName,
                        title: title ?? summary.firstUser ?? source,
                        summary: summary,
                        startTime: startTime,
                        endTime: endTime
                    )
                    if let conversation {
                        conversations.append(conversation)
                    }
                }
            }
        }

        return ParseResult(usages: usages, conversations: conversations)
    }

    private func parseSQLiteTranscript(
        db: Database,
        sessionId: String,
        availableColumns: Set<String>
    ) throws -> TranscriptSummary? {
        let fields = [
            "id",
            "role",
            "content",
            "tool_name",
            "tool_calls",
            "timestamp"
        ].filter { availableColumns.contains($0) }

        guard availableColumns.contains("session_id"), !fields.isEmpty else { return nil }

        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT \(fields.joined(separator: ", "))
                FROM messages
                WHERE session_id = ?
                ORDER BY timestamp ASC, id ASC
            """,
            arguments: [sessionId]
        )

        guard !rows.isEmpty else { return nil }

        var summary = TranscriptSummary()
        for row in rows {
            let role = (stringValue(row, column: "role") ?? "").lowercased()
            let content = stringValue(row, column: "content") ?? ""
            let toolName = stringValue(row, column: "tool_name")
            let timestamp = dateValue(row["timestamp"])

            if let timestamp {
                if summary.startTime == nil { summary.startTime = timestamp }
                summary.endTime = timestamp
            }

            if let toolName, !toolName.isEmpty {
                summary.keyTools.insert(toolName)
            }

            summary.consume(role: role, content: content)
        }

        return summary
    }

    // MARK: - Gateway / CLI Fallbacks

    private func parseGatewayIndex(
        indexURL: URL,
        sessionsDir: URL,
        excluding seenSessionIds: Set<String>,
        scope: HermesHomeScope
    ) -> ParseResult {
        guard let data = try? Data(contentsOf: indexURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ParseResult(usages: [], conversations: [])
        }

        var usages: [TokenUsage] = []
        var conversations: [ConversationRecord] = []

        for value in root.values {
            guard let entry = value as? [String: Any],
                  let rawSessionId = stringValue(entry, key: "session_id") else {
                continue
            }
            let sessionId = scope.qualify(sessionId: rawSessionId)
            guard !seenSessionIds.contains(sessionId) else { continue }

            let transcriptURL = sessionsDir.appendingPathComponent("\(rawSessionId).jsonl")
            let summary = fileManager.fileExists(atPath: transcriptURL.path)
                ? parseLegacyTranscript(file: transcriptURL)
                : nil

            let inputTokens = integerValue(entry, key: "input_tokens")
            let outputTokens = integerValue(entry, key: "output_tokens")
            let cacheReadTokens = integerValue(entry, key: "cache_read_tokens")
            let cacheWriteTokens = integerValue(entry, key: "cache_write_tokens")
            let model = TokenExtractionUtility.normalizeModelName(
                stringValue(entry, key: "model") ?? summary?.model ?? "hermes"
            )
            let projectName = scope.projectName(
                candidates: [
                    stringValue(entry, key: "display_name"),
                    stringValue(entry, key: "session_key"),
                ],
                fallbackSource: stringValue(entry, key: "platform"),
                fallbackSessionId: rawSessionId
            )

            let startTime = dateValue(entry["created_at"]) ?? summary?.startTime ?? modificationDate(of: transcriptURL) ?? Date()
            let endTime = dateValue(entry["updated_at"]) ?? summary?.endTime ?? startTime
            let explicitCost: Double? = {
                if let actual = doubleValue(entry, key: "actual_cost_usd"), actual > 0 { return actual }
                if let estimated = doubleValue(entry, key: "estimated_cost_usd"), estimated > 0 { return estimated }
                return nil
            }()

            // Determine if any explicit bucket is present in the gateway index
            let hasExplicit = inputTokens > 0 || outputTokens > 0 || cacheReadTokens > 0 || cacheWriteTokens > 0
            // Determine if summary has any usage data from message parsing
            let summaryHasUsage = (summary?.inputTokens ?? 0) > 0 || (summary?.outputTokens ?? 0) > 0
                || (summary?.cacheCreationTokens ?? 0) > 0 || (summary?.cacheReadTokens ?? 0) > 0

            // VAL-TOKEN-004: Fallback/estimation runs only when BOTH explicit and summary are unavailable
            // When explicit buckets exist, use them directly (no max with summary)
            // When explicit is absent but summary has data, use summary
            // Only estimate when both explicit AND summary are absent
            let usageInput: Int
            let usageOutput: Int
            let usageCacheWrite: Int
            let usageCacheRead: Int

            if hasExplicit {
                // Explicit buckets present - use them directly (VAL-TOKEN-001: preserve exact counts)
                usageInput = inputTokens
                usageOutput = outputTokens
                usageCacheWrite = cacheWriteTokens
                usageCacheRead = cacheReadTokens
            } else if summaryHasUsage {
                // No explicit buckets, but summary has usage data from message parsing
                usageInput = summary?.inputTokens ?? 0
                usageOutput = summary?.outputTokens ?? 0
                usageCacheWrite = summary?.cacheCreationTokens ?? 0
                usageCacheRead = summary?.cacheReadTokens ?? 0
            } else {
                // Neither explicit nor summary has data - fall back to estimation
                // Note: EstimatedTokens only provides input/output; cache tokens are estimated as 0
                // when no explicit cache data is available (VAL-TOKEN-006)
                let estimated: EstimatedTokens
                if let summary {
                    estimated = summary.estimatedUsage()
                } else {
                    estimated = TokenExtractionUtility.estimateFallbackTokens(
                        userVisibleChars: 0,
                        assistantVisibleChars: 0,
                        assistantReasoningChars: 0,
                        userMessageCount: 0,
                        assistantMessageCount: 0
                    )
                }
                usageInput = estimated.input
                usageOutput = estimated.output
                usageCacheWrite = 0
                usageCacheRead = 0
            }

            if let usage = usage(
                sessionId: sessionId,
                projectName: projectName,
                model: model,
                inputTokens: usageInput,
                outputTokens: usageOutput,
                cacheCreationTokens: usageCacheWrite,
                cacheReadTokens: usageCacheRead,
                costOverride: explicitCost,
                startTime: startTime,
                endTime: endTime
            ) {
                usages.append(usage)
            }

            if let summary,
               let conversation = conversation(
                    sessionId: sessionId,
                    projectName: projectName,
                    title: stringValue(entry, key: "display_name") ?? summary.firstUser ?? projectName,
                    summary: summary,
                    startTime: startTime,
                    endTime: endTime
               ) {
                conversations.append(conversation)
            }
        }

        return ParseResult(usages: usages, conversations: conversations)
    }

    private func parseCLISnapshot(
        file: URL,
        excluding seenSessionIds: Set<String>,
        scope: HermesHomeScope
    ) -> ParseResult {
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ParseResult(usages: [], conversations: [])
        }

        let rawSessionId = stringValue(json, key: "session_id")
            ?? file.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "session_", with: "")
        let sessionId = scope.qualify(sessionId: rawSessionId)
        guard !seenSessionIds.contains(sessionId) else {
            return ParseResult(usages: [], conversations: [])
        }

        var summary = transcriptSummary(from: json["messages"] as? [Any] ?? [])
        if let systemPrompt = stringValue(json, key: "system_prompt") {
            summary.systemPromptChars = max(
                summary.systemPromptChars,
                TokenExtractionUtility.contentMetrics(from: systemPrompt).visibleChars
            )
        }
        let model = TokenExtractionUtility.normalizeModelName(
            stringValue(json, key: "model") ?? summary.model ?? "hermes"
        )
        let projectName = scope.projectName(
            candidates: [stringValue(json, key: "title")],
            fallbackSource: stringValue(json, key: "platform"),
            fallbackSessionId: rawSessionId
        )
        let startTime = dateValue(json["session_start"]) ?? summary.startTime ?? modificationDate(of: file) ?? Date()
        let endTime = dateValue(json["last_updated"]) ?? summary.endTime ?? startTime

        // VAL-TOKEN-004: Fallback/estimation runs only when explicit usage buckets are unavailable.
        // For CLI snapshots, "explicit" means summary-derived from message events.
        // Estimation runs only when summary has no usage data at all.
        let summaryHasUsage = summary.inputTokens > 0 || summary.outputTokens > 0
            || summary.cacheCreationTokens > 0 || summary.cacheReadTokens > 0

        let (usageInput, usageOutput, usageCacheWrite, usageCacheRead): (Int, Int, Int, Int)
        if summaryHasUsage {
            // Summary has valid usage data from message events - use it directly
            usageInput = summary.inputTokens
            usageOutput = summary.outputTokens
            usageCacheWrite = summary.cacheCreationTokens
            usageCacheRead = summary.cacheReadTokens
        } else {
            // No summary data - fall back to estimation
            // Note: EstimatedTokens only provides input/output; cache tokens are 0 when
            // no explicit cache data is available (VAL-TOKEN-006)
            let estimated = summary.estimatedUsage()
            usageInput = estimated.input
            usageOutput = estimated.output
            usageCacheWrite = 0
            usageCacheRead = 0
        }

        let usage = usage(
            sessionId: sessionId,
            projectName: projectName,
            model: model,
            inputTokens: usageInput,
            outputTokens: usageOutput,
            cacheCreationTokens: usageCacheWrite,
            cacheReadTokens: usageCacheRead,
            costOverride: nil,
            startTime: startTime,
            endTime: endTime
        )

        let conversation = conversation(
            sessionId: sessionId,
            projectName: projectName,
            title: stringValue(json, key: "title") ?? summary.firstUser ?? projectName,
            summary: summary,
            startTime: startTime,
            endTime: endTime
        )

        return ParseResult(usages: usage.map { [$0] } ?? [], conversations: conversation.map { [$0] } ?? [])
    }

    private func parseLegacyTranscript(file: URL) -> TranscriptSummary? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }

        var events: [Any] = []
        for line in handle.readAllUTF8Lines() {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) else {
                continue
            }
            events.append(json)
        }

        guard !events.isEmpty else { return nil }
        var summary = transcriptSummary(from: events)
        summary.fileModifiedAt = modificationDate(of: file)
        return summary
    }

    private func transcriptSummary(from events: [Any]) -> TranscriptSummary {
        var summary = TranscriptSummary()

        for event in events {
            guard let json = event as? [String: Any] else { continue }
            let message = json["message"] as? [String: Any]
            let role = ((message?["role"] as? String) ?? (json["role"] as? String) ?? "").lowercased()
            let rawContent = message?["content"] ?? json["content"]
            let toolName = (json["tool_name"] as? String) ?? (message?["tool_name"] as? String)

            if let model = (message?["model"] as? String) ?? (json["model"] as? String), !model.isEmpty {
                summary.model = TokenExtractionUtility.normalizeModelName(model)
            }

            let timestamp = dateValue(json["timestamp"]) ?? dateValue(message?["timestamp"])
            if let timestamp {
                if summary.startTime == nil { summary.startTime = timestamp }
                summary.endTime = timestamp
            }

            if let usage = (message?["usage"] as? [String: Any]) ?? (json["usage"] as? [String: Any]) {
                let extracted = TokenExtractionUtility.extractUsageTokens(usage)
                summary.inputTokens += extracted.input
                summary.outputTokens += extracted.output
                summary.cacheCreationTokens += extracted.cacheCreation
                summary.cacheReadTokens += extracted.cacheRead
            }

            if let toolName, !toolName.isEmpty {
                summary.keyTools.insert(toolName)
            }

            summary.consume(role: role, content: stringContent(from: rawContent), rawContent: rawContent)
        }

        return summary
    }

    // MARK: - Builders

    private func usage(
        sessionId: String,
        projectName: String,
        model: String,
        inputTokens: Int,
        outputTokens: Int,
        cacheCreationTokens: Int,
        cacheReadTokens: Int,
        costOverride: Double?,
        startTime: Date,
        endTime: Date
    ) -> TokenUsage? {
        guard inputTokens > 0 || outputTokens > 0 || cacheCreationTokens > 0 || cacheReadTokens > 0 else {
            return nil
        }

        let pricing = ModelPricing.lookup(model: model)
        let cost = costOverride ?? pricing.cost(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheCreationTokens: cacheCreationTokens,
            cacheReadTokens: cacheReadTokens
        )

        return TokenUsage(
            provider: .hermes,
            sessionId: sessionId,
            projectName: projectName,
            model: model,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheCreationTokens: cacheCreationTokens,
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
        summary: TranscriptSummary,
        startTime: Date?,
        endTime: Date?
    ) -> ConversationRecord? {
        guard !summary.fullText.isEmpty || summary.messageCount > 0 else { return nil }

        return ConversationRecord(
            id: ConversationRecord.stableId(provider: .hermes, sessionId: sessionId),
            provider: .hermes,
            sessionId: sessionId,
            projectName: projectName,
            startTime: startTime,
            endTime: endTime,
            messageCount: summary.messageCount,
            userWordCount: summary.userWords,
            assistantWordCount: summary.assistantWords,
            keyFiles: [],
            keyCommands: [],
            keyTools: Array(summary.keyTools).sorted(),
            inferredTaskTitle: title,
            lastAssistantMessage: summary.lastAssistant,
            fullText: summary.fullText,
            indexedAt: Date(),
            fileModifiedAt: summary.fileModifiedAt,
            summary: nil
        )
    }

    private func deduplicate(_ usages: [TokenUsage]) -> [TokenUsage] {
        var bySessionId: [String: TokenUsage] = [:]
        for usage in usages {
            bySessionId[usage.sessionId] = usage
        }
        return Array(bySessionId.values)
    }

    private func deduplicate(_ conversations: [ConversationRecord]) -> [ConversationRecord] {
        var bySessionId: [String: ConversationRecord] = [:]
        for conversation in conversations {
            bySessionId[conversation.sessionId] = conversation
        }
        return Array(bySessionId.values)
    }

    // MARK: - Utilities

    private func resolvedHermesHome() -> URL {
        let configuredPath = URL(fileURLWithPath: (provider.logDirectory as NSString).expandingTildeInPath)
        if configuredPath.lastPathComponent == "sessions" {
            return configuredPath.deletingLastPathComponent()
        }
        return configuredPath
    }

    private func resolvedHermesScopes() -> [HermesHomeScope] {
        let configuredHome = canonicalHermesRoot(from: hermesRootURL ?? resolvedHermesHome())
        var scopes: [HermesHomeScope] = [.init(homeURL: configuredHome, profileName: nil)]

        let profilesRoot = configuredHome.appendingPathComponent("profiles", isDirectory: true)
        guard fileManager.fileExists(atPath: profilesRoot.path),
              let profileURLs = try? fileManager.contentsOfDirectory(
                at: profilesRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
              ) else {
            return scopes
        }

        let profileScopes = profileURLs
            .filter { url in
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
                return values?.isDirectory ?? false
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { url in
                HermesHomeScope(homeURL: url, profileName: url.lastPathComponent)
            }
        scopes.append(contentsOf: profileScopes)
        return scopes
    }

    private func canonicalHermesRoot(from homeURL: URL) -> URL {
        let parent = homeURL.deletingLastPathComponent()
        if parent.lastPathComponent == "profiles" {
            return parent.deletingLastPathComponent()
        }
        return homeURL
    }

    private func availableColumns(in table: String, db: Database) throws -> Set<String> {
        let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))")
        return Set(rows.compactMap { row in
            if let column: String = row["name"] {
                return column
            }
            return nil
        })
    }

    private func fileSize(at url: URL) -> UInt64 {
        ((try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value) ?? 0
    }

    private func modificationDate(of url: URL) -> Date? {
        (try? fileManager.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }

    private func stringValue(_ row: Row, column: String) -> String? {
        if let value: String = row[column], !value.isEmpty {
            return value
        }
        return nil
    }

    private func integerValue(_ row: Row, column: String) -> Int {
        if let value: Int = row[column] { return value }
        if let value: Int64 = row[column] { return Int(value) }
        if let value: Double = row[column] { return Int(value.rounded()) }
        if let value: String = row[column] { return Int(value) ?? 0 }
        return 0
    }

    private func doubleValue(_ row: Row, column: String) -> Double? {
        if let value: Double = row[column] { return value }
        if let value: Int = row[column] { return Double(value) }
        if let value: Int64 = row[column] { return Double(value) }
        if let value: String = row[column] { return Double(value) }
        return nil
    }

    private func stringValue(_ dictionary: [String: Any], key: String) -> String? {
        guard let value = dictionary[key] as? String, !value.isEmpty else { return nil }
        return value
    }

    private func integerValue(_ dictionary: [String: Any], key: String) -> Int {
        if let value = dictionary[key] as? Int { return value }
        if let value = dictionary[key] as? Int64 { return Int(value) }
        if let value = dictionary[key] as? Double { return Int(value.rounded()) }
        if let value = dictionary[key] as? String { return Int(value) ?? 0 }
        return 0
    }

    private func doubleValue(_ dictionary: [String: Any], key: String) -> Double? {
        if let value = dictionary[key] as? Double { return value }
        if let value = dictionary[key] as? Int { return Double(value) }
        if let value = dictionary[key] as? Int64 { return Double(value) }
        if let value = dictionary[key] as? String { return Double(value) }
        return nil
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
            if let date = Self.iso8601Fractional.date(from: value) ?? Self.iso8601Basic.date(from: value) {
                return date
            }
            for formatter in Self.sqliteDateFormats {
                if let date = formatter.date(from: value) {
                    return date
                }
            }
            if let epoch = Double(value) {
                return TimestampNormalizationUtility.date(fromEpoch: epoch)
            }
            return nil
        default:
            return nil
        }
    }

    private func stringContent(from raw: Any?) -> String {
        switch raw {
        case let value as String:
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        case let array as [Any]:
            return array.map { stringContent(from: $0) }.filter { !$0.isEmpty }.joined(separator: "\n")
        case let dictionary as [String: Any]:
            let orderedKeys = ["text", "content", "message", "input", "output"]
            var pieces: [String] = []
            for key in orderedKeys {
                if let nested = dictionary[key] {
                    let text = stringContent(from: nested)
                    if !text.isEmpty { pieces.append(text) }
                }
            }
            if pieces.isEmpty {
                for (key, value) in dictionary where key != "type" && key != "role" && key != "tool_calls" {
                    let text = stringContent(from: value)
                    if !text.isEmpty { pieces.append(text) }
                }
            }
            return pieces.joined(separator: "\n")
        default:
            return ""
        }
    }
}

private struct HermesHomeScope {
    let homeURL: URL
    let profileName: String?

    func qualify(sessionId: String) -> String {
        guard let profileName, !profileName.isEmpty else { return sessionId }
        return "\(profileName)::\(sessionId)"
    }

    func projectName(
        candidates: [String?],
        fallbackSource: String?,
        fallbackSessionId: String
    ) -> String {
        for candidate in candidates {
            guard let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
                continue
            }
            if isGenericSourceLabel(trimmed), profileName != nil {
                continue
            }
            return trimmed
        }

        if let profileName, !profileName.isEmpty {
            return profileName
        }
        if let fallbackSource = fallbackSource?.trimmingCharacters(in: .whitespacesAndNewlines), !fallbackSource.isEmpty {
            return fallbackSource
        }
        return fallbackSessionId
    }

    private func isGenericSourceLabel(_ value: String) -> Bool {
        switch value.lowercased() {
        case "cron", "cli", "gateway", "hermes":
            return true
        default:
            return false
        }
    }
}

// MARK: - Transcript Summary

private struct TranscriptSummary {
    var model: String?
    var inputTokens = 0
    var outputTokens = 0
    var cacheCreationTokens = 0
    var cacheReadTokens = 0
    var startTime: Date?
    var endTime: Date?
    var systemPromptChars = 0
    var userChars = 0
    var toolChars = 0
    var assistantChars = 0
    var assistantReasoningChars = 0
    var messageCount = 0
    var toolMessageCount = 0
    var userWords = 0
    var assistantWords = 0
    var firstUser: String?
    var lastAssistant = ""
    var fullText = ""
    var keyTools: Set<String> = []
    var fileModifiedAt: Date?

    mutating func consume(role: String, content: String, rawContent: Any? = nil) {
        let metrics = TokenExtractionUtility.contentMetrics(from: rawContent ?? content)
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)

        switch role {
        case "system":
            systemPromptChars += max(metrics.visibleChars, text.count)
        case "tool":
            toolChars += max(metrics.visibleChars, text.count)
            if !text.isEmpty {
                toolMessageCount += 1
            }
        case "user":
            userChars += max(metrics.visibleChars, text.count)
            if !text.isEmpty {
                userWords += text.split { $0.isWhitespace || $0.isNewline }.count
                if firstUser == nil {
                    firstUser = String(text.prefix(120))
                }
                append(text, isAssistant: false)
                messageCount += 1
            }
        case "assistant":
            assistantChars += max(metrics.visibleChars, text.count)
            assistantReasoningChars += metrics.reasoningChars
            if !text.isEmpty {
                assistantWords += text.split { $0.isWhitespace || $0.isNewline }.count
                lastAssistant = text
                append(text, isAssistant: true)
                messageCount += 1
            }
        default:
            break
        }
    }

    func estimatedUsage() -> EstimatedTokens {
        TokenExtractionUtility.estimateFallbackTokens(
            userVisibleChars: userChars + toolChars + systemPromptChars,
            assistantVisibleChars: assistantChars,
            assistantReasoningChars: assistantReasoningChars,
            userMessageCount: max(userWords > 0 ? 1 : 0, messageCount / 2) + toolMessageCount + (systemPromptChars > 0 ? 1 : 0),
            assistantMessageCount: max(assistantWords > 0 ? 1 : 0, messageCount / 2)
        )
    }

    private mutating func append(_ text: String, isAssistant: Bool) {
        if !fullText.isEmpty { fullText += "\n\n" }
        fullText += SessionLogMarkdownFormatter.transcriptTurnMarkdown(isAssistant: isAssistant, body: text)
    }
}
