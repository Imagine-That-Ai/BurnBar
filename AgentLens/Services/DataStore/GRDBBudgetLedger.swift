import Foundation
import GRDB
import OpenBurnBarInsights
import OpenBurnBarKernel

/// Computes running spend for a budget rule against the canonical `token_usage` table.
///
/// `BudgetGate` calls into this actor on every request to ask: "if I let this request through
/// at an estimated cost of $X, will rule R's running total cross its limit?" The actor runs
/// a tight indexed SQL query per evaluation — cheap because `token_usage` already carries
/// `startTime`, `provider`, `providerAccountID`, and `projectName` columns with appropriate
/// indexes (see `OpenBurnBarDatabase.swift` migrations v37 + v42).
///
/// The GRDB-backed macOS ledger backend. SQL spend reads stay here; the fail-closed batch
/// `snapshot` loop lives on `BudgetLedgerReading` in OpenBurnBarKernel, shared with the
/// iOS rollup backend.
actor GRDBBudgetLedger {
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
    /// `estimatedCost`. Fail-closed: a failed read omits the key (never `0`) and is logged;
    /// callers MUST treat a missing key as at-limit / blocked.
    func snapshot(forRules rules: [BudgetRule], reference: Date = Date()) async -> [String: Double] {
        await (self as any BudgetLedgerReading).snapshot(forRules: rules, reference: reference) { rule, error in
            AppLogger.dataStore.error(
                "budget_ledger_snapshot_read_failed",
                metadata: [
                    "ruleScope": rule.scope.rawValue,
                    "errorClass": "\(String(describing: type(of: error)))"
                ]
            )
        }
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
