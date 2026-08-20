import Foundation
import GRDB
import OpenBurnBarInsights

// MARK: - Recap projection
//
// The monthly recap needs conversation-level facts the usage rows do not carry:
// how many messages a session had, what it was called, and which tools the agent
// reached for. `InsightSessionRow` is the shared shape for exactly that, and the
// existing `MacInsightDataSource` hardcodes those fields empty (its own comment
// says so), which is why every tool-based insight would otherwise be blank.
//
// Deliberately narrow: `keyFiles` is never selected. File paths are the most
// sensitive thing in this table and the recap has no use for them.

extension ConversationStore {

    /// Conversations whose start falls inside `range`.
    ///
    /// `conversations` carries no index on `startTime`, so callers wanting
    /// several months should ask for the whole span **once** and bucket in
    /// memory rather than looping month by month — twelve calls here is twelve
    /// full table scans.
    func fetchRecapSessionRows(
        startingIn range: Range<Date>
    ) async throws -> [InsightSessionRow] {
        try await dbQueue.read { db in
            try Self.fetchRecapSessionRows(db: db, startingIn: range)
        }
    }

    static func fetchRecapSessionRows(
        db: Database,
        startingIn range: Range<Date>
    ) throws -> [InsightSessionRow] {
        try UsageStore.compactMapCachedRows(
            db: db,
            sql: """
                SELECT sessionId, provider, projectName, startTime, endTime,
                       messageCount, keyTools, inferredTaskTitle
                FROM conversations
                WHERE deletedAt IS NULL
                  AND startTime >= ? AND startTime < ?
                """,
            arguments: [range.lowerBound, range.upperBound],
            transform: decodeRecapSessionRow
        )
    }

    static func decodeRecapSessionRow(_ row: Row) -> InsightSessionRow? {
        guard let sessionId: String = row["sessionId"],
              let startTime: Date = row["startTime"] else { return nil }
        let projectName: String? = row["projectName"]
        let title: String? = row["inferredTaskTitle"]
        return InsightSessionRow(
            sessionID: sessionId,
            provider: row["provider"] ?? "",
            projectName: (projectName?.isEmpty ?? true) ? nil : projectName,
            startTime: startTime,
            endTime: row["endTime"] ?? startTime,
            messageCount: row["messageCount"] ?? 0,
            inferredTaskTitle: (title?.isEmpty ?? true) ? nil : title,
            keyTools: OpenBurnBarDatabase.decodeJSONStringArray(row["keyTools"] as? String),
            keyCommands: [],
            keyFiles: []
        )
    }
}

// MARK: - DataStore facade

extension DataStore {
    /// Conversation rows for the recap, over one contiguous span.
    func fetchRecapSessionRows(startingIn range: Range<Date>) async throws -> [InsightSessionRow] {
        try await actor.conversationStore.fetchRecapSessionRows(startingIn: range)
    }
}
