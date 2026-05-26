import Foundation
import GRDB
import OpenBurnBarCore

/// Computes running spend for a budget rule against the canonical `token_usage` table.
///
/// `BudgetGate` calls into this actor on every request to ask: "if I let this request through
/// at an estimated cost of $X, will rule R's running total cross its limit?" The actor runs
/// a tight indexed SQL query per evaluation — cheap because `token_usage` already carries
/// `startTime`, `provider`, `providerAccountID`, and `projectName` columns with appropriate
/// indexes (see `OpenBurnBarDatabase.swift` migrations v37 + v42).
actor BudgetLedger {
    private let dbQueue: any DatabaseWriter

    init(dbQueue: any DatabaseWriter) {
        self.dbQueue = dbQueue
    }

    /// Current accumulated spend (USD) attributed to the rule's scope within the rule's
    /// current period. Used by `BudgetGate.evaluate`.
    func currentSpend(forRule rule: BudgetRule, reference: Date = Date()) async throws -> Double {
        let windowStart = rule.period.windowStart(reference: reference)
        return try await query(rule: rule, windowStart: windowStart, reference: reference)
    }

    /// Cheaper "fast path" check for batch gate evaluation — runs the SQL once and returns
    /// the total. The caller picks how to combine with `estimatedCost`.
    func snapshot(forRules rules: [BudgetRule], reference: Date = Date()) async -> [String: Double] {
        var result: [String: Double] = [:]
        for rule in rules {
            let value = (try? await currentSpend(forRule: rule, reference: reference)) ?? 0
            result[rule.id] = value
        }
        return result
    }

    // MARK: - SQL

    private func query(rule: BudgetRule, windowStart: Date?, reference: Date) async throws -> Double {
        try await dbQueue.read { db in
            var clauses: [String] = []
            var args: [DatabaseValueConvertible] = []

            if let windowStart {
                clauses.append("startTime >= ?")
                args.append(windowStart)
            }
            clauses.append("startTime <= ?")
            args.append(reference)

            switch rule.scope {
            case .credential:
                if let providerID = rule.providerID, !providerID.isEmpty {
                    clauses.append("providerID = ?")
                    args.append(providerID)
                }
                if let accountID = rule.accountID, !accountID.isEmpty {
                    clauses.append("providerAccountID = ?")
                    args.append(accountID)
                }
            case .project:
                if let projectName = rule.projectName, !projectName.isEmpty {
                    clauses.append("projectName = ?")
                    args.append(projectName)
                }
            case .global:
                // No additional scope filter — global rules sum every per-usage row.
                // We can't easily distinguish subscription rows here without joining the
                // credential type table, so global rules include subscription spend as a
                // best-effort signal. Phase 6's billing-API reconciliation refines this.
                break
            case .organization:
                if let identifier = rule.identifier, !identifier.isEmpty {
                    clauses.append("(providerAccountLabel = ? OR providerAccountID = ?)")
                    args.append(identifier)
                    args.append(identifier)
                }
            }

            let whereSQL = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
            let sql = "SELECT COALESCE(SUM(cost), 0) AS total FROM token_usage \(whereSQL)"
            let row = try Row.fetchOne(db, sql: sql, arguments: StatementArguments(args))
            let total = row?["total"] as? Double ?? 0
            return total
        }
    }
}
