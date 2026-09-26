// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import OpenBurnBarUsageModels

// MARK: - BudgetForecastProjection

/// Forward projection for a single budget rule at a point in time.
///
/// Unified from the Mac (`BudgetForecast`, GRDB-backed) and iOS (`BudgetForecast`,
/// rollup-backed) twins. The fail-closed shape is the Mac contract: a failed spend
/// read must never render as "under budget", so an unreadable ledger yields
/// `unavailable(forRule:)` whose derived properties refuse to claim safety
/// (`willExceed == true`, `headroom == 0`, `usedPercent == nil`).
public struct BudgetForecastProjection: Hashable, Sendable {
    public let ruleID: String
    public let currentSpend: Double
    public let limit: Double
    public let trailingDailyAverage: Double
    public let daysUntilLimit: Double?
    public let projectedAtPeriodEnd: Double
    public let generatedAt: Date
    /// `true` when the spend history could not be read. The numeric fields are
    /// meaningless in this state — consumers must surface a "forecast unavailable"
    /// affordance rather than trusting `currentSpend`/`usedPercent`.
    public let dataUnavailable: Bool

    public init(
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
    public static func unavailable(forRule rule: BudgetRule, generatedAt: Date) -> BudgetForecastProjection {
        BudgetForecastProjection(
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
    public var willExceed: Bool { dataUnavailable ? true : projectedAtPeriodEnd >= limit }

    /// Fails closed on a read fault: no headroom is promised when the spend is unknown.
    public var headroom: Double { dataUnavailable ? 0 : max(0, limit - currentSpend) }

    /// `nil` when the spend is unknown (read fault) — distinct from a genuine `0` used.
    public var usedPercent: Double? {
        if dataUnavailable { return nil }
        return limit > 0 ? currentSpend / limit : 0
    }

    /// ISO8601-ish ETA string for the daily-rate projection. Returns nil when the
    /// trailing rate is zero (no recent activity) or when the spend could not be read.
    public func projectedHitDate(calendar: Calendar = .current) -> Date? {
        guard !dataUnavailable else { return nil }
        guard let daysUntilLimit, daysUntilLimit.isFinite else { return nil }
        return calendar.date(byAdding: .second, value: Int(daysUntilLimit * 86_400), to: generatedAt)
    }
}

// MARK: - BudgetProjectionMath

/// Pure projection math shared by the GRDB (macOS) and rollup (iOS) forecast backends.
/// Both twins computed this identically from `(currentSpend, trailingDailyAverage)` —
/// only the spend reads diverge, and those stay platform-side.
public enum BudgetProjectionMath {
    public static func project(
        rule: BudgetRule,
        currentSpend: Double,
        trailingDailyAverage: Double,
        reference: Date,
        calendar: Calendar = .current
    ) -> BudgetForecastProjection {
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
            let elapsedHours = elapsedHoursIntoToday(reference: reference, calendar: calendar)
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

        return BudgetForecastProjection(
            ruleID: rule.id,
            currentSpend: currentSpend,
            limit: limit,
            trailingDailyAverage: trailingDailyAverage,
            daysUntilLimit: daysUntilLimit,
            projectedAtPeriodEnd: projectedAtPeriodEnd,
            generatedAt: reference
        )
    }

    private static func elapsedHoursIntoToday(reference: Date, calendar: Calendar) -> Double {
        let start = calendar.startOfDay(for: reference)
        return reference.timeIntervalSince(start) / 3_600
    }
}

// MARK: - BudgetForecasting

/// The single forecast read `BudgetEnforcement` exposes to views. The GRDB (macOS) and
/// rollup (iOS) forecast actors both conform; the enforcement singleton holds the
/// backend as an existential so neither app module leaks into the other.
public protocol BudgetForecasting: Sendable {
    func forecast(forRule rule: BudgetRule, reference: Date) async -> BudgetForecastProjection
}
