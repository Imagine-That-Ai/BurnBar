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

    /// Cheaper "fast path" check for batch gate evaluation — runs the SQL once per rule and
    /// returns the totals keyed by `rule.id`. The caller picks how to combine with
    /// `estimatedCost`.
    ///
    /// Fail-closed contract: a rule whose spend read **succeeds** is always present in the
    /// result — including the legitimate `0.0` for "no matching rows". A rule whose spend
    /// read **fails** (DB I/O error, corrupt page, locked file) is deliberately *omitted*
    /// from the result and the failure is logged. This distinguishes "definitely spent $0"
    /// (key present, value `0`) from "spend is unknown because the read failed" (key absent),
    /// so the gate never silently treats an unreadable ledger as zero accumulated spend and
    /// lets an over-limit request through. Callers MUST treat a missing key as
    /// at-limit / blocked, e.g. `result[rule.id] ?? rule.amountUSD`, rather than `?? 0`.
    func snapshot(forRules rules: [BudgetRule], reference: Date = Date()) async -> [String: Double] {
        var result: [String: Double] = [:]
        for rule in rules {
            do {
                result[rule.id] = try await currentSpend(forRule: rule, reference: reference)
            } catch {
                // Do NOT default to 0: a swallowed read failure would report zero accumulated
                // spend and let an over-limit request through (fail-open). Omit the key so the
                // gate fails closed on unknown spend, and surface the failure for observability.
                AppLogger.dataStore.error(
                    "budget_ledger_snapshot_read_failed",
                    metadata: [
                        "ruleScope": rule.scope.rawValue,
                        "errorClass": "\(String(describing: type(of: error)))"
                    ]
                )
            }
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
                    var matchingAccountSubqueryClauses = [
                        "providerAccountLabel = ?",
                        "providerAccountID IS NOT NULL",
                        "providerAccountID != ''"
                    ]
                    if windowStart != nil {
                        matchingAccountSubqueryClauses.append("startTime >= ?")
                    }
                    matchingAccountSubqueryClauses.append("startTime <= ?")

                    clauses.append("""
                        (
                            providerAccountLabel = ?
                            OR providerAccountID = ?
                            OR (
                                providerAccountID IS NOT NULL
                                AND providerAccountID != ''
                                AND providerAccountID IN (
                                    SELECT DISTINCT providerAccountID
                                    FROM token_usage
                                    WHERE \(matchingAccountSubqueryClauses.joined(separator: " AND "))
                                )
                            )
                        )
                        """)
                    args.append(identifier)
                    args.append(identifier)
                    args.append(identifier)
                    if let windowStart {
                        args.append(windowStart)
                    }
                    args.append(reference)
                }
            }

            let whereSQL = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
            let sql = "SELECT COALESCE(SUM(cost), 0) AS total FROM token_usage \(whereSQL)"
            let row = try Row.fetchOne(db, sql: sql, arguments: StatementArguments(args))
            let total: Double = row?["total"] ?? 0
            return total
        }
    }
}
