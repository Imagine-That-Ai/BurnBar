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
    ///
    /// A failed read of the `token_usage` spend history is NOT collapsed to `$0` spent:
    /// doing so would be indistinguishable from genuinely-zero recent spend and would
    /// paint a rule as fully under budget (0% used, full headroom, will-not-exceed) when we
    /// actually have no idea what the spend is. Instead the read fault is logged and the
    /// projection is marked `dataUnavailable`, whose derived safety properties fail closed
    /// (`willExceed == true`, `headroom == 0`, `usedPercent == nil`) so no consumer can
    /// mistake "we couldn't read the ledger" for "this rule is safe."
    func forecast(forRule rule: BudgetRule, reference: Date = Date()) async -> Projection {
        let limit = rule.amountUSD

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
            return Projection.unavailable(forRule: rule, generatedAt: reference)
        }

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
            let total: Double = row?["total"] ?? 0
            return total
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
        /// `true` when the spend history could not be read (missing/corrupt `token_usage`,
        /// keychain-locked SQLCipher key, etc.). The numeric fields are meaningless in this
        /// state — consumers must surface a "forecast unavailable" affordance rather than
        /// trusting `currentSpend`/`usedPercent`, and the derived safety properties below
        /// fail closed so the rule is never painted as under budget on a read fault.
        let dataUnavailable: Bool

        init(
            ruleID: String,
            currentSpend: Double,
            limit: Double,
            trailingDailyAverage: Double,
            daysUntilLimit: Double?,
            projectedAtPeriodEnd: Double,
            generatedAt: Date,
            dataUnavailable: Bool = false
        ) {
            self.ruleID = ruleID
            self.currentSpend = currentSpend
            self.limit = limit
            self.trailingDailyAverage = trailingDailyAverage
            self.daysUntilLimit = daysUntilLimit
            self.projectedAtPeriodEnd = projectedAtPeriodEnd
            self.generatedAt = generatedAt
            self.dataUnavailable = dataUnavailable
        }

        /// A fail-closed projection for when the spend ledger could not be read. We do NOT
        /// know the spend, so we refuse to claim the rule is safe: `willExceed` is `true`,
        /// `headroom` is `0`, and `usedPercent` is `nil` (unknown, not 0%).
        static func unavailable(forRule rule: BudgetRule, generatedAt: Date) -> Projection {
            Projection(
                ruleID: rule.id,
                currentSpend: 0,
                limit: rule.amountUSD,
                trailingDailyAverage: 0,
                daysUntilLimit: nil,
                projectedAtPeriodEnd: 0,
                generatedAt: generatedAt,
                dataUnavailable: true
            )
        }

        /// Fails closed on a read fault: an unknown spend is treated as potentially over the
        /// limit so callers never render a green/under-budget state for a rule we couldn't read.
        var willExceed: Bool { dataUnavailable ? true : projectedAtPeriodEnd >= limit }

        /// Fails closed on a read fault: no headroom is promised when the spend is unknown.
        var headroom: Double { dataUnavailable ? 0 : max(0, limit - currentSpend) }

        /// `nil` when the spend is unknown (read fault) — distinct from a genuine `0` used.
        var usedPercent: Double? {
            if dataUnavailable { return nil }
            return limit > 0 ? currentSpend / limit : 0
        }

        /// ISO8601-ish ETA string for the daily-rate projection. Returns nil when the
        /// trailing rate is zero (no recent activity) or when the spend could not be read.
        func projectedHitDate(calendar: Calendar = .current) -> Date? {
            guard !dataUnavailable else { return nil }
            guard let daysUntilLimit, daysUntilLimit.isFinite else { return nil }
            return calendar.date(byAdding: .second, value: Int(daysUntilLimit * 86_400), to: generatedAt)
        }
    }
}
