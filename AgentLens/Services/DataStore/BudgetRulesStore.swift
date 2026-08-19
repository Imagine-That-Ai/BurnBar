import Foundation
@preconcurrency import GRDB
import OpenBurnBarCore

/// SQLite CRUD against `budget_rules` and `budget_events`. The `BudgetSettings` observable
/// store wraps this; `BudgetLedger` reads via this; Hermes / MCP write through this.
///
/// All operations route through the canonical `OpenBurnBarDatabase` queue so concurrency
/// matches every other table in the project. The store keeps no in-memory state — that's
/// `BudgetSettings`'s job.
final class BudgetRulesStore: Sendable {
    private let dbQueue: any DatabaseWriter

    init(dbQueue: any DatabaseWriter) {
        self.dbQueue = dbQueue
    }

    // MARK: - Rules

    func upsertRule(_ rule: BudgetRule) async throws {
        try await dbQueue.write { db in
            try Self.upsert(rule: rule, in: db)
        }
    }

    func deleteRule(id: String) async throws {
        _ = try await dbQueue.write { db in
            try BudgetRulesStore.deleteRule(id: id, in: db)
        }
    }

    func fetchAllRules(includeDisabled: Bool = false) async throws -> [BudgetRule] {
        try await dbQueue.read { db in
            let predicate = includeDisabled ? "" : "WHERE isEnabled = 1"
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM budget_rules \(predicate) ORDER BY createdAt DESC"
            )
            return rows.compactMap(Self.decodeRule(row:))
        }
    }

    func fetchRule(id: String) async throws -> BudgetRule? {
        try await dbQueue.read { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM budget_rules WHERE id = ? LIMIT 1",
                arguments: [id]
            )
            return row.flatMap(Self.decodeRule(row:))
        }
    }

    func fetchRules(forCredential providerID: String, accountID: String?) async throws -> [BudgetRule] {
        try await dbQueue.read { db in
            let sql: String
            let args: StatementArguments
            if let accountID {
                sql = """
                    SELECT * FROM budget_rules
                    WHERE scope = 'credential'
                      AND providerID = ?
                      AND accountID = ?
                      AND isEnabled = 1
                    """
                args = [providerID, accountID]
            } else {
                sql = """
                    SELECT * FROM budget_rules
                    WHERE scope = 'credential'
                      AND providerID = ?
                      AND (accountID IS NULL OR accountID = '')
                      AND isEnabled = 1
                    """
                args = [providerID]
            }
            return try Row.fetchAll(db, sql: sql, arguments: args).compactMap(Self.decodeRule(row:))
        }
    }

    func fetchRules(forProject projectName: String) async throws -> [BudgetRule] {
        try await dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM budget_rules
                    WHERE scope = 'project'
                      AND projectName = ?
                      AND isEnabled = 1
                    """,
                arguments: [projectName]
            )
            return rows.compactMap(Self.decodeRule(row:))
        }
    }

    func fetchGlobalRules() async throws -> [BudgetRule] {
        try await dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM budget_rules WHERE scope = 'global' AND isEnabled = 1"
            )
            return rows.compactMap(Self.decodeRule(row:))
        }
    }

    // MARK: - Events

    func recordEvent(_ event: BudgetEvent) async throws {
        try await dbQueue.write { db in
            try Self.insert(event: event, in: db)
        }
    }

    func recentEvents(forRule ruleID: String? = nil, limit: Int = 100) async throws -> [BudgetEvent] {
        try await dbQueue.read { db in
            let sql: String
            let args: StatementArguments
            if let ruleID {
                sql = "SELECT * FROM budget_events WHERE ruleID = ? ORDER BY occurredAt DESC LIMIT ?"
                args = [ruleID, limit]
            } else {
                sql = "SELECT * FROM budget_events ORDER BY occurredAt DESC LIMIT ?"
                args = [limit]
            }
            return try Row.fetchAll(db, sql: sql, arguments: args).compactMap(Self.decodeEvent(row:))
        }
    }

    // MARK: - Private helpers

    private static func upsert(rule: BudgetRule, in db: Database) throws {
        let fallbackJSON: String?
        if rule.fallbackCredentialIDs.isEmpty {
            fallbackJSON = nil
        } else {
            let data = try JSONEncoder().encode(rule.fallbackCredentialIDs)
            fallbackJSON = String(data: data, encoding: .utf8)
        }
        try db.execute(
            sql: """
                INSERT INTO budget_rules (
                    id, scope, identifier, providerID, accountID, projectName, label,
                    amountUSD, period, behavior, fallbackCredentialIDsJSON, pausedUntil,
                    createdAt, updatedAt, syncedAt, sourceDeviceID, isEnabled
                ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET
                    scope = excluded.scope,
                    identifier = excluded.identifier,
                    providerID = excluded.providerID,
                    accountID = excluded.accountID,
                    projectName = excluded.projectName,
                    label = excluded.label,
                    amountUSD = excluded.amountUSD,
                    period = excluded.period,
                    behavior = excluded.behavior,
                    fallbackCredentialIDsJSON = excluded.fallbackCredentialIDsJSON,
                    pausedUntil = excluded.pausedUntil,
                    updatedAt = excluded.updatedAt,
                    syncedAt = NULL,
                    isEnabled = excluded.isEnabled
                """,
            arguments: [
                rule.id,
                rule.scope.rawValue,
                rule.identifier,
                rule.providerID,
                rule.accountID,
                rule.projectName,
                rule.label,
                rule.amountUSD,
                rule.period.rawValue,
                rule.behavior.rawValue,
                fallbackJSON,
                rule.pausedUntil,
                rule.createdAt,
                rule.updatedAt,
                rule.syncedAt,
                rule.sourceDeviceID,
                rule.isEnabled ? 1 : 0
            ]
        )
    }

    private static func deleteRule(id: String, in db: Database) throws -> Bool {
        try db.execute(sql: "DELETE FROM budget_rules WHERE id = ?", arguments: [id])
        return db.changesCount > 0
    }

    private static func insert(event: BudgetEvent, in db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO budget_events (
                    id, ruleID, kind, source, amountAtEvent, limitAtEvent,
                    detailJSON, occurredAt, syncedAt, sourceDeviceID
                ) VALUES (?,?,?,?,?,?,?,?,?,?)
                """,
            arguments: [
                event.id,
                event.ruleID,
                event.kind.rawValue,
                event.source,
                event.amountAtEvent,
                event.limitAtEvent,
                event.detailJSON,
                event.occurredAt,
                event.syncedAt,
                event.sourceDeviceID
            ]
        )
    }

    private static func decodeRule(row: Row) -> BudgetRule? {
        guard let id = row["id"] as? String,
              let scopeRaw = row["scope"] as? String,
              let scope = BudgetRuleScope(rawValue: scopeRaw),
              let periodRaw = row["period"] as? String,
              let period = BudgetPeriod(rawValue: periodRaw),
              let behaviorRaw = row["behavior"] as? String,
              let behavior = BudgetBehavior(rawValue: behaviorRaw) else {
            return nil
        }
        let amount: Double = row["amountUSD"] ?? 0
        let createdAt = OpenBurnBarDatabase.parseDateValue(row["createdAt"]) ?? Date()
        let updatedAt = OpenBurnBarDatabase.parseDateValue(row["updatedAt"]) ?? createdAt
        let isEnabled: Bool = row["isEnabled"] ?? true

        var fallbacks: [String] = []
        if let json = row["fallbackCredentialIDsJSON"] as? String,
           let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String].self, from: data) { // try?-ok(decode fallback empty)
            fallbacks = decoded
        }

        return BudgetRule(
            id: id,
            scope: scope,
            identifier: row["identifier"] as? String,
            providerID: row["providerID"] as? String,
            accountID: row["accountID"] as? String,
            projectName: row["projectName"] as? String,
            label: row["label"] as? String,
            amountUSD: amount,
            period: period,
            behavior: behavior,
            fallbackCredentialIDs: fallbacks,
            pausedUntil: OpenBurnBarDatabase.parseDateValue(row["pausedUntil"]),
            createdAt: createdAt,
            updatedAt: updatedAt,
            syncedAt: OpenBurnBarDatabase.parseDateValue(row["syncedAt"]),
            sourceDeviceID: row["sourceDeviceID"] as? String,
            isEnabled: isEnabled
        )
    }

    private static func decodeEvent(row: Row) -> BudgetEvent? {
        guard let id = row["id"] as? String,
              let ruleID = row["ruleID"] as? String,
              let kindRaw = row["kind"] as? String,
              let kind = BudgetEventKind(rawValue: kindRaw) else {
            return nil
        }
        let amountAtEvent: Double = row["amountAtEvent"] ?? 0
        let limitAtEvent: Double = row["limitAtEvent"] ?? 0
        return BudgetEvent(
            id: id,
            ruleID: ruleID,
            kind: kind,
            source: row["source"] as? String,
            amountAtEvent: amountAtEvent,
            limitAtEvent: limitAtEvent,
            detailJSON: row["detailJSON"] as? String,
            occurredAt: OpenBurnBarDatabase.parseDateValue(row["occurredAt"]) ?? Date(),
            syncedAt: OpenBurnBarDatabase.parseDateValue(row["syncedAt"]),
            sourceDeviceID: row["sourceDeviceID"] as? String
        )
    }

    // MARK: - Sync helpers

    /// Marks a budget event as synced by setting `syncedAt` to now. Used by
    /// `CloudBudgetService` after a successful Firestore write.
    func markEventSynced(_ eventID: String) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: "UPDATE budget_events SET syncedAt = ? WHERE id = ?",
                arguments: [Date(), eventID]
            )
        }
    }
}
