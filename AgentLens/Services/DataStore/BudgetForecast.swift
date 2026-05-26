import Foundation
import GRDB
import OpenBurnBarCore

/// Forward projections built from `token_usage` spend history.
///
/// `BudgetForecast` answers "at the current burn rate, when will this rule's running spend
/// cross the limit?" Used by `BudgetSettingsView` to render the "Projected hit: May 28"
/// chip beside each rule and (Phase 5+) by the `BurnRailBudgetChip` on the top rail.
actor BudgetForecast {
    private let dbQueue: any DatabaseWriter
    private let calendar: Calendar

    init(dbQueue: any DatabaseWriter, calendar: Calendar = .current) {
        self.dbQueue = dbQueue
        self.calendar = calendar
    }

    /// Returns the projection for a rule given its current spend window.
    func forecast(forRule rule: BudgetRule, reference: Date = Date()) async -> Projection {
        let trailingDailyAverage = (try? await trailingDailyAverage(rule: rule, reference: reference)) ?? 0
        let currentSpend = (try? await currentSpend(rule: rule, reference: reference)) ?? 0
        let limit = rule.amountUSD
        let remaining = max(0, limit - currentSpend)

        // Linear projection — accurate for steady-state work and conservative for spiky days.
        let daysUntilLimit: Double?
        if trailingDailyAverage > 0 {
            daysUntilLimit = remaining / trailingDailyAverage
        } else {
            daysUntilLimit = nil
        }

        let projectedAtPeriodEnd: Double
        switch rule.period {
        case .day:
            // Single-day rule — project today's burn forward to midnight.
            let elapsedHours = elapsedHoursIntoToday(reference: reference)
            if elapsedHours > 0 {
                projectedAtPeriodEnd = currentSpend / max(elapsedHours, 0.1) * 24
            } else {
                projectedAtPeriodEnd = currentSpend
            }
        case .week, .month:
            guard let windowStart = rule.period.windowStart(reference: reference, calendar: calendar),
                  let windowEnd = rule.period.nextReset(reference: reference, calendar: calendar) else {
                projectedAtPeriodEnd = currentSpend
                break
            }
            let totalDays = max(1.0, windowEnd.timeIntervalSince(windowStart) / 86_400)
            let elapsedDays = max(0.01, reference.timeIntervalSince(windowStart) / 86_400)
            let dailyRateSoFar = currentSpend / elapsedDays
            projectedAtPeriodEnd = dailyRateSoFar * totalDays
        case .allTime:
            projectedAtPeriodEnd = currentSpend
        }

        return Projection(
            ruleID: rule.id,
            currentSpend: currentSpend,
            limit: limit,
            trailingDailyAverage: trailingDailyAverage,
            daysUntilLimit: daysUntilLimit,
            projectedAtPeriodEnd: projectedAtPeriodEnd,
            generatedAt: reference
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
            return row?["total"] as? Double ?? 0
        }
    }

    private func elapsedHoursIntoToday(reference: Date) -> Double {
        let start = calendar.startOfDay(for: reference)
        return reference.timeIntervalSince(start) / 3_600
    }

    // MARK: - Projection

    struct Projection: Hashable, Sendable {
        let ruleID: String
        let currentSpend: Double
        let limit: Double
        let trailingDailyAverage: Double
        let daysUntilLimit: Double?
        let projectedAtPeriodEnd: Double
        let generatedAt: Date

        var willExceed: Bool { projectedAtPeriodEnd >= limit }
        var headroom: Double { max(0, limit - currentSpend) }
        var usedPercent: Double { limit > 0 ? currentSpend / limit : 0 }

        /// ISO8601-ish ETA string for the daily-rate projection. Returns nil when the
        /// trailing rate is zero (no recent activity).
        func projectedHitDate(calendar: Calendar = .current) -> Date? {
            guard let daysUntilLimit, daysUntilLimit.isFinite else { return nil }
            return calendar.date(byAdding: .second, value: Int(daysUntilLimit * 86_400), to: generatedAt)
        }
    }
}
