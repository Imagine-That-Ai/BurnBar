import Foundation
import GRDB
import OpenBurnBarCore

public final class TextExpansionSnippetStore: Sendable {
    private let dbQueue: any DatabaseWriter

    public init(dbQueue: any DatabaseWriter) {
        self.dbQueue = dbQueue
    }

    public func upsert(_ snippet: TextExpansionSnippet, markUnsynced: Bool = true) throws {
        var normalized = snippet
        normalized.trigger = TextExpansionTrigger.canonicalName(snippet.trigger)
        guard TextExpansionTrigger.isValid(normalized.trigger) else {
            throw TextExpansionSnippetStoreError.invalidTrigger(TextExpansionTrigger.validationError(for: normalized.trigger) ?? "Invalid trigger.")
        }
        let scopeJSON = try OpenBurnBarDatabase.encodeJSON(normalized.scope)
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO text_expansion_snippets (
                    id, title, trigger, body, mode, isEnabled, scopeJSON, revision,
                    createdAt, updatedAt, deletedAt, syncedAt, sourceDeviceID
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    title = excluded.title,
                    trigger = excluded.trigger,
                    body = excluded.body,
                    mode = excluded.mode,
                    isEnabled = excluded.isEnabled,
                    scopeJSON = excluded.scopeJSON,
                    revision = excluded.revision,
                    createdAt = excluded.createdAt,
                    updatedAt = excluded.updatedAt,
                    deletedAt = excluded.deletedAt,
                    syncedAt = excluded.syncedAt,
                    sourceDeviceID = excluded.sourceDeviceID
                """,
                arguments: [
                    normalized.id,
                    normalized.title,
                    normalized.trigger,
                    normalized.body,
                    normalized.mode.rawValue,
                    normalized.isEnabled ? 1 : 0,
                    scopeJSON,
                    normalized.revision,
                    normalized.createdAt,
                    normalized.updatedAt,
                    normalized.deletedAt,
                    markUnsynced ? nil : normalized.syncedAt,
                    normalized.sourceDeviceID
                ]
            )
        }
    }

    public func saveFromRemote(_ snippet: TextExpansionSnippet, syncedAt: Date = Date()) throws {
        var remote = snippet
        remote.syncedAt = syncedAt
        try upsert(remote, markUnsynced: false)
    }

    public func fetchAll(includeDeleted: Bool = false) throws -> [TextExpansionSnippet] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM text_expansion_snippets
                \(includeDeleted ? "" : "WHERE deletedAt IS NULL")
                ORDER BY updatedAt DESC, title ASC
                """
            )
            return rows.compactMap(Self.snippet(from:))
        }
    }

    public func fetchEnabled(
        surface: TextExpansionSurface? = nil,
        bundleIdentifier: String? = nil,
        threadID: String? = nil
    ) throws -> [TextExpansionSnippet] {
        let snippets = try fetchAll(includeDeleted: false).filter(\.isEnabled)
        guard let surface else { return snippets }
        return snippets.filter { $0.scope.allows(surface: surface, bundleIdentifier: bundleIdentifier, threadID: threadID) }
    }

    public func fetchUnsynced(limit: Int = 200) throws -> [TextExpansionSnippet] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM text_expansion_snippets
                WHERE syncedAt IS NULL OR syncedAt < updatedAt
                ORDER BY updatedAt ASC
                LIMIT ?
                """,
                arguments: [limit]
            )
            return rows.compactMap(Self.snippet(from:))
        }
    }

    public func markSynced(ids: [String], at date: Date = Date()) throws {
        guard !ids.isEmpty else { return }
        try dbQueue.write { db in
            var arguments: [any DatabaseValueConvertible] = [date]
            arguments.append(contentsOf: ids)
            try db.execute(
                sql: """
                UPDATE text_expansion_snippets
                SET syncedAt = ?
                WHERE id IN (\(OpenBurnBarDatabase.sqlPlaceholders(count: ids.count)))
                """,
                arguments: StatementArguments(arguments)
            )
        }
    }

    public func delete(id: String, at date: Date = Date()) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE text_expansion_snippets
                SET deletedAt = ?, updatedAt = ?, syncedAt = NULL, isEnabled = 0, revision = revision + 1
                WHERE id = ?
                """,
                arguments: [date, date, id]
            )
        }
    }

    public func count() throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(1) FROM text_expansion_snippets WHERE deletedAt IS NULL") ?? 0
        }
    }

    private static func snippet(from row: Row) -> TextExpansionSnippet? {
        let scopeJSON = row["scopeJSON"] as? String
        let scope = decodeScope(scopeJSON) ?? .global
        let modeRaw = (row["mode"] as? String) ?? TextExpansionMode.staticText.rawValue
        guard let id = row["id"] as? String,
              let title = row["title"] as? String,
              let trigger = row["trigger"] as? String,
              let body = row["body"] as? String,
              let mode = TextExpansionMode(rawValue: modeRaw),
              let createdAt = OpenBurnBarDatabase.parseDateValue(row["createdAt"]),
              let updatedAt = OpenBurnBarDatabase.parseDateValue(row["updatedAt"]) else {
            return nil
        }
        return TextExpansionSnippet(
            id: id,
            title: title,
            trigger: trigger,
            body: body,
            mode: mode,
            isEnabled: OpenBurnBarDatabase.parseBoolValue(row["isEnabled"]) ?? true,
            scope: scope,
            revision: revisionValue(row["revision"]) ?? 1,
            createdAt: createdAt,
            updatedAt: updatedAt,
            deletedAt: OpenBurnBarDatabase.parseDateValue(row["deletedAt"]),
            syncedAt: OpenBurnBarDatabase.parseDateValue(row["syncedAt"]),
            sourceDeviceID: row["sourceDeviceID"] as? String
        )
    }

    private static func decodeScope(_ string: String?) -> TextExpansionScope? {
        guard let string, let data = string.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(TextExpansionScope.self, from: data)
    }

    private static func revisionValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? Int64 { return Int(value) }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }
}

enum TextExpansionSnippetStoreError: LocalizedError {
    case invalidTrigger(String)

    var errorDescription: String? {
        switch self {
        case .invalidTrigger(let message): return message
        }
    }
}
