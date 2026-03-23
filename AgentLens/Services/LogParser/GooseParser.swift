import Foundation
import GRDB

// MARK: - Goose Parser

/// Parses Goose (Block) sessions from ~/.local/share/goose/sessions/sessions.db (SQLite).
/// Falls back to legacy JSONL files for pre-v1.10 installations.
final class GooseParser: LogParser {
    let provider: AgentProvider = .goose

    func parse() async throws -> ParseResult {
        let fm = FileManager.default
        let sessionsPath = (provider.logDirectory as NSString).expandingTildeInPath

        guard fm.fileExists(atPath: sessionsPath) else {
            return ParseResult(usages: [], conversations: [])
        }

        // Prefer SQLite database
        let dbPath = (sessionsPath as NSString).appendingPathComponent("sessions.db")
        if fm.fileExists(atPath: dbPath) {
            let usages = try parseSQLiteDatabase(dbPath: dbPath)
            if !usages.isEmpty {
                return ParseResult(usages: usages, conversations: [])
            }
        }

        // Fallback: legacy JSONL files
        let sessionsURL = URL(fileURLWithPath: sessionsPath)
        let jsonlFiles = (try? fm.contentsOfDirectory(at: sessionsURL, includingPropertiesForKeys: nil))?.filter {
            $0.pathExtension == "jsonl"
        } ?? []

        var usages: [TokenUsage] = []
        var conversations: [ConversationRecord] = []

        for file in jsonlFiles {
            let sessionId = file.deletingPathExtension().lastPathComponent
            if let pair = parseJsonlSession(file: file, sessionId: sessionId),
               let usage = pair.usage {
                usages.append(usage)
                if let conv = pair.conversation { conversations.append(conv) }
            }
        }

        return ParseResult(usages: usages, conversations: conversations)
    }

    // MARK: - SQLite Parsing

    private func parseSQLiteDatabase(dbPath: String) throws -> [TokenUsage] {
        var usages: [TokenUsage] = []

        var config = Configuration()
        config.readonly = true
        let db = try DatabaseQueue(path: dbPath, configuration: config)

        try db.read { db in
            // Discover available tables and columns
            let tables = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table'")

            // Try "sessions" table first (Goose v1.10+)
            if tables.contains("sessions") {
                let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(sessions)")
                let columnNames = Set(columns.compactMap { $0["name"] as? String })

                // Build query based on available columns
                var selectFields = ["id"]
                if columnNames.contains("model") { selectFields.append("model") }
                if columnNames.contains("provider") { selectFields.append("provider") }
                if columnNames.contains("working_directory") || columnNames.contains("cwd") {
                    selectFields.append(columnNames.contains("working_directory") ? "working_directory" : "cwd")
                }
                if columnNames.contains("input_tokens") { selectFields.append("input_tokens") }
                if columnNames.contains("output_tokens") { selectFields.append("output_tokens") }
                if columnNames.contains("total_tokens") { selectFields.append("total_tokens") }
                if columnNames.contains("tokens_used") { selectFields.append("tokens_used") }
                if columnNames.contains("created_at") { selectFields.append("created_at") }
                if columnNames.contains("updated_at") { selectFields.append("updated_at") }

                let sql = "SELECT \(selectFields.joined(separator: ", ")) FROM sessions ORDER BY created_at DESC LIMIT 500"
                let rows = try Row.fetchAll(db, sql: sql)

                for row in rows {
                    guard let sessionId: String = row["id"] else { continue }

                    let model: String = row["model"] ?? "goose"
                    let cwd: String = row["working_directory"] ?? row["cwd"] ?? "~"
                    let projectName = (cwd as NSString).lastPathComponent

                    // Token counts — try exact fields first, then aggregate
                    var inputTokens: Int = row["input_tokens"] ?? 0
                    var outputTokens: Int = row["output_tokens"] ?? 0

                    if inputTokens == 0 && outputTokens == 0 {
                        let total: Int = row["total_tokens"] ?? row["tokens_used"] ?? 0
                        if total > 0 {
                            inputTokens = Int(Double(total) * 0.85)
                            outputTokens = max(total - inputTokens, 0)
                        }
                    }

                    guard inputTokens > 0 || outputTokens > 0 else { continue }

                    // Timestamps
                    let startTime: Date
                    let endTime: Date
                    if let created: Int64 = row["created_at"] {
                        startTime = Date(timeIntervalSince1970: Double(created))
                    } else if let created: Double = row["created_at"] {
                        startTime = Date(timeIntervalSince1970: created)
                    } else if let created: String = row["created_at"],
                              let date = ISO8601DateFormatter().date(from: created) {
                        startTime = date
                    } else {
                        startTime = Date()
                    }

                    if let updated: Int64 = row["updated_at"] {
                        endTime = Date(timeIntervalSince1970: Double(updated))
                    } else if let updated: Double = row["updated_at"] {
                        endTime = Date(timeIntervalSince1970: updated)
                    } else if let updated: String = row["updated_at"],
                              let date = ISO8601DateFormatter().date(from: updated) {
                        endTime = date
                    } else {
                        endTime = startTime
                    }

                    let pricing = ModelPricing.lookup(model: model)
                    let cost = pricing.cost(inputTokens: inputTokens, outputTokens: outputTokens)

                    let usage = TokenUsage(
                        provider: .goose,
                        sessionId: sessionId,
                        projectName: projectName,
                        model: model,
                        inputTokens: inputTokens,
                        outputTokens: outputTokens,
                        costUSD: cost,
                        startTime: startTime,
                        endTime: endTime
                    )
                    usages.append(usage)
                }
            }
        }

        return usages
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
        var model = "goose"
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

            // Timestamps
            if let ts = json["timestamp"] as? String,
               let date = ISO8601DateFormatter().date(from: ts) {
                if startTime == nil { startTime = date }
                endTime = date
            }

            // Model
            if let m = json["model"] as? String, !m.isEmpty {
                model = TokenExtractionUtility.normalizeModelName(m)
            }

            // Usage
            if let usage = json["usage"] as? [String: Any] {
                let extracted = TokenExtractionUtility.extractUsageTokens(usage)
                inputTokens += extracted.input
                outputTokens += extracted.output
            }
            if let message = json["message"] as? [String: Any],
               let usage = message["usage"] as? [String: Any] {
                let extracted = TokenExtractionUtility.extractUsageTokens(usage)
                inputTokens += extracted.input
                outputTokens += extracted.output
            }

            // Content
            let role = (json["role"] as? String ?? (json["message"] as? [String: Any])?["role"] as? String ?? "").lowercased()
            let content = json["content"] as? String ?? (json["message"] as? [String: Any])?["content"] as? String ?? ""

            if role == "user" && !content.isEmpty {
                userChars += content.count
                userWords += content.split { $0.isWhitespace || $0.isNewline }.count
                if firstUser == nil {
                    firstUser = String(content.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
                }
                if !fullText.isEmpty { fullText += "\n\n" }
                fullText += content
                messageCount += 1
            } else if role == "assistant" && !content.isEmpty {
                assistantChars += content.count
                assistantWords += content.split { $0.isWhitespace || $0.isNewline }.count
                lastAssistant = content
                if !fullText.isEmpty { fullText += "\n\n" }
                fullText += content
                messageCount += 1
            }
        }

        // Fallback estimation
        if inputTokens == 0 && outputTokens == 0 {
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
        }

        guard inputTokens > 0 || outputTokens > 0 else { return nil }

        let pricing = ModelPricing.lookup(model: model)
        let cost = pricing.cost(inputTokens: inputTokens, outputTokens: outputTokens)

        let usage = TokenUsage(
            provider: .goose,
            sessionId: sessionId,
            projectName: sessionId,
            model: model,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            costUSD: cost,
            startTime: startTime ?? Date(),
            endTime: endTime ?? Date()
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
