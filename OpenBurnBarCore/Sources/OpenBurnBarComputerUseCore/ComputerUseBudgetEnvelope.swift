import Foundation

/// Live budget envelope governing the maximum action footprint per
/// session, per run, and per day. Driven by the hourly cloud function
/// `evaluateComputerUseBudget` (Phase 9). The Mac coordinator reads
/// `ops/computer_use_budget_status/state/current` at session start and
/// after every 5-minute heartbeat.
///
/// See `plans/2026-05-16-computer-use-master-plan.md` § E.3.
public struct ComputerUseBudgetEnvelope: Codable, Hashable, Sendable {
    public enum Level: String, Codable, Sendable, Hashable, CaseIterable {
        case normal
        case softCap = "soft_cap"
        case hardCap = "hard_cap"
    }

    public let level: Level
    public let projectedMonthEndUSD: Double
    public let monthToDateUSD: Double
    public let activeActionsPerRun: Int
    public let activeActionsPerDay: Int
    public let activeSessionsPerDay: Int
    public let perUserDailySpendCeilingUSD: Double
    public let updatedAt: Date

    public init(
        level: Level,
        projectedMonthEndUSD: Double,
        monthToDateUSD: Double,
        activeActionsPerRun: Int,
        activeActionsPerDay: Int,
        activeSessionsPerDay: Int,
        perUserDailySpendCeilingUSD: Double,
        updatedAt: Date
    ) {
        self.level = level
        self.projectedMonthEndUSD = projectedMonthEndUSD
        self.monthToDateUSD = monthToDateUSD
        self.activeActionsPerRun = activeActionsPerRun
        self.activeActionsPerDay = activeActionsPerDay
        self.activeSessionsPerDay = activeSessionsPerDay
        self.perUserDailySpendCeilingUSD = perUserDailySpendCeilingUSD
        self.updatedAt = updatedAt
    }

    /// Default envelope when no budget document exists yet (e.g.,
    /// first session after install). Conservative — matches the master
    /// plan's "normal mode" caps: 50 actions/run, 200/day, 4 sessions/day,
    /// $5 daily spend ceiling.
    public static let initialNormal = ComputerUseBudgetEnvelope(
        level: .normal,
        projectedMonthEndUSD: 0,
        monthToDateUSD: 0,
        activeActionsPerRun: 50,
        activeActionsPerDay: 200,
        activeSessionsPerDay: 4,
        perUserDailySpendCeilingUSD: 5.0,
        updatedAt: Date(timeIntervalSince1970: 0)
    )

    /// Envelope tightening applied at the soft cap boundary. The plan
    /// fixes these to 25/100/2/$2.50.
    public static func softCapEnvelope(
        projectedMonthEndUSD: Double,
        monthToDateUSD: Double,
        updatedAt: Date
    ) -> ComputerUseBudgetEnvelope {
        ComputerUseBudgetEnvelope(
            level: .softCap,
            projectedMonthEndUSD: projectedMonthEndUSD,
            monthToDateUSD: monthToDateUSD,
            activeActionsPerRun: 25,
            activeActionsPerDay: 100,
            activeSessionsPerDay: 2,
            perUserDailySpendCeilingUSD: 2.5,
            updatedAt: updatedAt
        )
    }

    /// Envelope after the hard-cap kill switch fires.
    public static func hardCapEnvelope(
        projectedMonthEndUSD: Double,
        monthToDateUSD: Double,
        updatedAt: Date
    ) -> ComputerUseBudgetEnvelope {
        ComputerUseBudgetEnvelope(
            level: .hardCap,
            projectedMonthEndUSD: projectedMonthEndUSD,
            monthToDateUSD: monthToDateUSD,
            activeActionsPerRun: 0,
            activeActionsPerDay: 0,
            activeSessionsPerDay: 0,
            perUserDailySpendCeilingUSD: 0,
            updatedAt: updatedAt
        )
    }
}

/// Convenience computation shared by the Mac coordinator and the
/// cloud function. Pure — given inputs, returns the deterministic
/// envelope. Tests use this directly.
public enum ComputerUseBudgetProjector {
    /// Soft cap engages at ≥ $1500/mo projected; hard at ≥ $2500/mo.
    public static let softCapThresholdUSD: Double = 1500
    public static let hardCapThresholdUSD: Double = 2500

    public static func envelope(
        forProjectedMonthEnd projection: Double,
        monthToDate: Double,
        at now: Date = Date()
    ) -> ComputerUseBudgetEnvelope {
        if projection >= hardCapThresholdUSD {
            return .hardCapEnvelope(
                projectedMonthEndUSD: projection,
                monthToDateUSD: monthToDate,
                updatedAt: now
            )
        }
        if projection >= softCapThresholdUSD {
            return .softCapEnvelope(
                projectedMonthEndUSD: projection,
                monthToDateUSD: monthToDate,
                updatedAt: now
            )
        }
        return ComputerUseBudgetEnvelope(
            level: .normal,
            projectedMonthEndUSD: projection,
            monthToDateUSD: monthToDate,
            activeActionsPerRun: 50,
            activeActionsPerDay: 200,
            activeSessionsPerDay: 4,
            perUserDailySpendCeilingUSD: 5.0,
            updatedAt: now
        )
    }

    /// Linear-extrapolation projection from month-to-date to month-end.
    /// `daysElapsed` and `daysInMonth` count whole days; clamp to ≥ 1
    /// for safety so a stale clock doesn't divide by zero.
    public static func projectMonthEnd(
        monthToDateUSD: Double,
        daysElapsed: Int,
        daysInMonth: Int
    ) -> Double {
        let elapsed = max(daysElapsed, 1)
        let total = max(daysInMonth, elapsed)
        return monthToDateUSD * Double(total) / Double(elapsed)
    }
}
