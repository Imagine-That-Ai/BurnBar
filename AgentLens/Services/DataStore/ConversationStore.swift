import Foundation
import GRDB
import OpenBurnBarCore

// MARK: - ConversationStore

/// Conversations, chat messages, FTS search, session logs, and CLI conversation helpers.
final class ConversationStore: Sendable {
    let dbQueue: any DatabaseWriter

    init(dbQueue: any DatabaseWriter) {
        self.dbQueue = dbQueue
    }

    // MARK: - Row Decoding

    static func fetchConversationRow(_ db: Database, id: String) throws -> ConversationRecord? {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM conversations WHERE id = ?", arguments: [id]) else {
            return nil
        }
        return conversation(from: row)
    }

    static func conversation(from row: Row) -> ConversationRecord? {
        guard let id = row["id"] as? String,
              let providerRaw = row["provider"] as? String,
              let provider = AgentProvider(rawValue: providerRaw),
              let sessionId = row["sessionId"] as? String,
              let projectName = row["projectName"] as? String else {
            return nil
        }
        let messageCount = (row["messageCount"] as? Int) ?? Int(row["messageCount"] as? Int64 ?? 0)
        let userWordCount = (row["userWordCount"] as? Int) ?? Int(row["userWordCount"] as? Int64 ?? 0)
        let assistantWordCount = (row["assistantWordCount"] as? Int) ?? Int(row["assistantWordCount"] as? Int64 ?? 0)
        let inferredTaskTitle = (row["inferredTaskTitle"] as? String) ?? ""
        let lastAssistantMessage = (row["lastAssistantMessage"] as? String) ?? ""
        let fullText = (row["fullText"] as? String) ?? ""

        let keyFiles = OpenBurnBarDatabase.decodeJSONStringArray(row["keyFiles"] as? String)
        let keyCommands = OpenBurnBarDatabase.decodeJSONStringArray(row["keyCommands"] as? String)
        let keyTools = OpenBurnBarDatabase.decodeJSONStringArray(row["keyTools"] as? String)

        let startTime = OpenBurnBarDatabase.parseDateValue(row["startTime"])
        let endTime = OpenBurnBarDatabase.parseDateValue(row["endTime"])
        let indexedAt = OpenBurnBarDatabase.parseDateValue(row["indexedAt"]) ?? Date()
        let fileModifiedAt = OpenBurnBarDatabase.parseDateValue(row["fileModifiedAt"])

        let sourceTypeRaw = (row["sourceType"] as? String) ?? "provider_log"
        let sourceType = ConversationSourceType(rawValue: sourceTypeRaw) ?? .providerLog

        return ConversationRecord(
            id: id,
            provider: provider,
            sessionId: sessionId,
            projectName: projectName,
            startTime: startTime,
            endTime: endTime,
            messageCount: messageCount,
            userWordCount: userWordCount,
            assistantWordCount: assistantWordCount,
            keyFiles: keyFiles,
            keyCommands: keyCommands,
            keyTools: keyTools,
            inferredTaskTitle: inferredTaskTitle,
            lastAssistantMessage: lastAssistantMessage,
            fullText: fullText,
            indexedAt: indexedAt,
            workingDirectory: row["workingDirectory"] as? String,
            fileModifiedAt: fileModifiedAt,
            summary: row["summary"] as? String,
            summaryTitle: row["summaryTitle"] as? String,
            summaryUpdatedAt: OpenBurnBarDatabase.parseDateValue(row["summaryUpdatedAt"]),
            summaryProvider: row["summaryProvider"] as? String,
            summaryModel: row["summaryModel"] as? String,
            sourceType: sourceType,
            sourceDeviceId: row["sourceDeviceId"] as? String,
            sourceDeviceName: row["sourceDeviceName"] as? String,
            isRemote: ((row["isRemote"] as? Int) ?? Int(row["isRemote"] as? Int64 ?? 0)) != 0,
            deletedAt: OpenBurnBarDatabase.parseDateValue(row["deletedAt"]),
            version: (row["version"] as? Int) ?? Int(row["version"] as? Int64 ?? 1)
        )
    }

    static func chatMessage(from row: Row) -> ChatMessageRecord? {
        guard let id = row["id"] as? String,
              let roleRaw = row["role"] as? String,
              let role = ChatMessageRole(rawValue: roleRaw),
              let content = row["content"] as? String,
              let ts = OpenBurnBarDatabase.parseDateValue(row["timestamp"]) else {
            return nil
        }

        let pieces = OpenBurnBarDatabase.decodeTranscriptPieces(row["transcriptPiecesJSON"] as? String) ?? []
        let attachments = OpenBurnBarDatabase.decodeChatAttachments(row["attachmentsJSON"] as? String) ?? []
        return ChatMessageRecord(
            id: id,
            role: role,
            content: content,
            timestamp: ts,
            cliUsed: row["cliUsed"] as? String,
            transcriptPieces: pieces,
            attachments: attachments
        )
    }

    // MARK: - Private Helpers

    static func upsertChatThread(_ threadID: String, at timestamp: Date, db: Database) throws {
        try db.execute(
            sql: """
            INSERT OR IGNORE INTO chat_threads (id, createdAt, updatedAt)
            VALUES (?, ?, ?)
            """,
            arguments: [threadID, timestamp, timestamp]
        )
        try db.execute(
            sql: """
            UPDATE chat_threads
            SET updatedAt = CASE WHEN updatedAt > ? THEN updatedAt ELSE ? END
            WHERE id = ?
            """,
            arguments: [timestamp, timestamp, threadID]
        )
    }

    static func compactChatSnippet(_ source: String, limit: Int) -> String {
        let compact = source
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard compact.count > limit else { return compact }
        return String(compact.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    static func aggregateMatchSnippet(text: NSString, matchRange: NSRange, radius: Int = 120) -> String {
        let start = max(0, matchRange.location - radius)
        let end = min(text.length, matchRange.location + matchRange.length + radius)
        let snippetRange = NSRange(location: start, length: max(0, end - start))
        let raw = text.substring(with: snippetRange)
        let compact = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var prefix = ""
        var suffix = ""
        if start > 0 { prefix = "..." }
        if end < text.length { suffix = "..." }
        return prefix + compact + suffix
    }

    static func shouldPreserveConversationSyncedAt(
        existing: ConversationRecord,
        incoming: ConversationRecord,
        resolvedSummary: String?,
        resolvedSummaryTitle: String?,
        resolvedSummaryUpdatedAt: Date?,
        resolvedSummaryProvider: String?,
        resolvedSummaryModel: String?
    ) -> Bool {
        let identityMatch =
            existing.provider == incoming.provider
            && existing.sessionId == incoming.sessionId
            && existing.projectName == incoming.projectName
        let timingMatch =
            existing.startTime == incoming.startTime
            && existing.endTime == incoming.endTime
        let countsMatch =
            existing.messageCount == incoming.messageCount
            && existing.userWordCount == incoming.userWordCount
            && existing.assistantWordCount == incoming.assistantWordCount
        let keysMatch =
            existing.keyFiles == incoming.keyFiles
            && existing.keyCommands == incoming.keyCommands
            && existing.keyTools == incoming.keyTools
        let textMatch =
            existing.inferredTaskTitle == incoming.inferredTaskTitle
            && existing.lastAssistantMessage == incoming.lastAssistantMessage
            && existing.fullText == incoming.fullText
        let coreUnchanged =
            identityMatch && timingMatch && countsMatch && keysMatch && textMatch

        let summaryUnchanged =
            existing.summary == resolvedSummary
            && existing.summaryTitle == resolvedSummaryTitle
            && existing.summaryUpdatedAt == resolvedSummaryUpdatedAt
            && existing.summaryProvider == resolvedSummaryProvider
            && existing.summaryModel == resolvedSummaryModel

        return coreUnchanged && summaryUnchanged
    }

    static let credentialExposureRegexes: [NSRegularExpression] = {
        let patterns = [
            #"(?i)\b[A-Z0-9_]*(?:API[_-]?KEY|ACCESS[_-]?TOKEN|TOKEN|SECRET|PASSWORD)\b\s*[:=]\s*["']?[A-Za-z0-9_\-./+=]{8,}"#,
            #"\bsk-[A-Za-z0-9]{16,}\b"#,
            #"\bAIza[0-9A-Za-z\-_]{16,}\b"#,
            #"\bgh[pousr]_[A-Za-z0-9]{20,}\b"#
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0) }
    }()

    static func looksLikePlaceholderCredential(_ text: String) -> Bool {
        let lower = text.lowercased()
        let placeholders = [
            "your-key", "your_key", "your key", "key-here", "placeholder",
            "example", "dummy", "changeme", "replace-me", "***", "<", "test"
        ]
        return placeholders.contains { lower.contains($0) }
    }

    static func nonOverlappingOccurrenceCount(of pattern: String, in lowercasedText: String) -> Int {
        guard pattern.isEmpty == false, lowercasedText.isEmpty == false else { return 0 }
        var count = 0
        var searchStart = lowercasedText.startIndex
        while searchStart < lowercasedText.endIndex,
              let range = lowercasedText.range(of: pattern, range: searchStart..<lowercasedText.endIndex) {
            count += 1
            searchStart = range.upperBound
        }
        return count
    }
}
