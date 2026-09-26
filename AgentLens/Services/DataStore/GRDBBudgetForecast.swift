import Foundation
import GRDB
import OpenBurnBarInsights
import OpenBurnBarKernel

/// Forward projections built from `token_usage` spend history.
///
/// `GRDBBudgetForecast` answers "at the current burn rate, when will this rule's running spend
/// cross the limit?" Used by `BudgetSettingsView` to render the "Projected hit: May 28"
/// chip beside each rule and (Phase 5+) by the `BurnRailBudgetChip` on the top rail.
///
/// The GRDB-backed macOS forecast backend. Spend reads stay here; the projection math
/// and `BudgetForecastProjection` shape live in OpenBurnBarKernel (`BudgetForecasting`),
/// shared with the iOS rollup backend.
actor GRDBBudgetForecast: BudgetForecasting {
    private let dbQueue: any DatabaseWriter
    private let calendar: Calendar

    init(dbQueue: any DatabaseWriter, calendar: Calendar = .current) {
        self.dbQueue = dbQueue
        self.calendar = calendar
    }

    /// Returns the projection for a rule given its current spend window.
    ///
    /// A failed read of the `token_usage` spend history is NOT collapsed to `$0` spent:
    /// doing so would be indistinguishable from genuinely-zero recent spend and would
    /// paint a rule as fully under budget (0% used, full headroom, will-not-exceed) when we
    /// actually have no idea what the spend is. Instead the read fault is logged and the
    /// projection is marked `dataUnavailable`, whose derived safety properties fail closed
    /// (`willExceed == true`, `headroom == 0`, `usedPercent == nil`) so no consumer can
    /// mistake "we couldn't read the ledger" for "this rule is safe."
    func forecast(forRule rule: BudgetRule, reference: Date = Date()) async -> BudgetForecastProjection {
        let trailingDailyAverage: Double
        let currentSpend: Double
        do {
            // Read both windows from the same try so a single DB fault fails the whole
            // projection closed rather than half-trusting a partial read.
            trailingDailyAverage = try await self.trailingDailyAverage(rule: rule, reference: reference)
            currentSpend = try await self.currentSpend(rule: rule, reference: reference)
        } catch {
            AppLogger.dataStore.error(
                "budget_forecast_spend_read_failed",
                metadata: [
                    "errorClass": "\(String(describing: type(of: error)))",
                    "rulePeriod": rule.period.rawValue
                ]
            )
            return BudgetForecastProjection.unavailable(forRule: rule, generatedAt: reference)
        }

        return BudgetProjectionMath.project(
            rule: rule,
            currentSpend: currentSpend,
            trailingDailyAverage: trailingDailyAverage,
            reference: reference,
            calendar: calendar
        )
    }

    // MARK: - SQL helpers

    private func currentSpend(rule: BudgetRule, reference: Date) async throws -> Double {
        let windowStart = rule.period.windowStart(reference: reference, calendar: calendar)
        return try await sumCost(rule: rule, windowStart: windowStart, windowEnd: reference)
    }

    private func trailingDailyAverage(rule: BudgetRule, reference: Date, lookbackDays: Int = 7) async throws -> Double {
        let lookbackStart = calendar.date(byAdding: .day, value: -lookbackDays, to: reference) ?? reference
        let total = try await sumCost(rule: rule, windowStart: lookbackStart, windowEnd: reference)
        return total / Double(max(1, lookbackDays))
    }

    private func sumCost(rule: BudgetRule, windowStart: Date?, windowEnd: Date) async throws -> Double {
        try await dbQueue.read { db in
            var clauses: [String] = []
            var args: [DatabaseValueConvertible] = []

            if let windowStart {
                clauses.append("startTime >= ?")
                args.append(windowStart)
            }
            clauses.append("startTime <= ?")
            args.append(windowEnd)

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
            case .global, .organization:
                break
            }

            let whereSQL = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
            let sql = "SELECT COALESCE(SUM(cost), 0) AS total FROM token_usage \(whereSQL)"
            let row = try Row.fetchOne(db, sql: sql, arguments: StatementArguments(args))
            let total: Double = row?["total"] ?? 0
            return total
        }
    }
}
