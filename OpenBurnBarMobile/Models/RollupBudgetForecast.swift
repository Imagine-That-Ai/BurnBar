import Foundation
import OpenBurnBarKernel

/// Forward projections built from Firestore usage rollup history.
///
/// iOS equivalent of the macOS `GRDBBudgetForecast` which queries raw `token_usage` rows
/// via SQL. On mobile we derive spend and trailing averages from pre-computed
/// `UsageRollupDoc` data (daily points + totals) provided by a `BudgetSpendDataSource`.
///
/// `RollupBudgetForecast` answers "at the current burn rate, when will this rule's
/// running spend cross the limit?" Used by the budget settings UI to render the
/// "Projected hit: May 28" chip beside each rule and by the burn rail budget chip.
///
/// The rollup-backed iOS forecast backend. Spend reads stay here; the projection math
/// and `BudgetForecastProjection` shape live in OpenBurnBarKernel (`BudgetForecasting`),
/// shared with the macOS GRDB backend.
actor RollupBudgetForecast: BudgetForecasting {
    /// The data source providing rollup snapshots.
    private weak var dataSource: (any BudgetSpendDataSource)?
    private let calendar: Calendar

    /// Creates a forecast engine backed by the given rollup data source.
    init(dataSource: any BudgetSpendDataSource, calendar: Calendar = .current) {
        self.dataSource = dataSource
        self.calendar = calendar
    }

    /// Returns the projection for a rule given its current spend window.
    func forecast(forRule rule: BudgetRule, reference: Date = Date()) async -> BudgetForecastProjection {
        let currentSpend = await currentSpend(forRule: rule)
        let trailingDailyAverage = await trailingDailyAverage(forRule: rule)
        return BudgetProjectionMath.project(
            rule: rule,
            currentSpend: currentSpend,
            trailingDailyAverage: trailingDailyAverage,
            reference: reference,
            calendar: calendar
        )
    }

    // MARK: - Rollup helpers

    /// Current spend for the rule's period, extracted from the matching rollup's totals.
    private func currentSpend(forRule rule: BudgetRule) async -> Double {
        guard let dataSource else { return 0 }
        let windowKey = rollupWindowKey(for: rule.period)
        let rollupsByWindow = await MainActor.run {
            dataSource.rollupsByWindow
        }
        guard let rollup = rollupsByWindow[windowKey] else { return 0 }

        switch rule.scope {
        case .global:
            return rollup.totals.costUsd
        case .credential:
            return rollup.accountSummaries
                .filter { summary in
                    guard summary.providerID.rawValue == rule.providerID else { return false }
                    if let ruleAccountID = rule.accountID, !ruleAccountID.isEmpty {
                        return summary.accountID == ruleAccountID
                    }
                    return true
                }
                .compactMap(\.totalCost)
                .reduce(0, +)
        case .project:
            return 0
        case .organization:
            guard let identifier = rule.identifier, !identifier.isEmpty else { return 0 }
            return rollup.accountSummaries
                .filter { $0.accountLabel == identifier || $0.accountID == identifier }
                .compactMap(\.totalCost)
                .reduce(0, +)
        }
    }

    /// Trailing daily average derived from the rollup's `dailyPoints`. Uses the last 7
    /// entries (or fewer if the rollup has less history) to compute the average daily spend.
    ///
    /// On macOS this is a SQL `SUM(cost)` over the trailing 7 days divided by 7. Here we
    /// approximate from the pre-aggregated daily points, which is equivalent when the
    /// rollup covers the right window.
    private func trailingDailyAverage(forRule rule: BudgetRule) async -> Double {
        guard let dataSource else { return 0 }

        // Use the 7-day rollup for trailing average regardless of the rule's period —
        // it has the best daily-granularity data for recent history.
        let rollupsByWindow = await MainActor.run {
            dataSource.rollupsByWindow
        }
        guard let rollup = rollupsByWindow[.sevenDays] else { return 0 }

        let points = rollup.dailyPoints.suffix(7)
        guard !points.isEmpty else { return 0 }

        let total = points.map(\.value).reduce(0, +)
        return total / Double(max(1, points.count))
    }

    /// Maps a `BudgetPeriod` to the closest `RollupWindowKey`.
    private nonisolated func rollupWindowKey(for period: BudgetPeriod) -> RollupWindowKey {
        switch period {
        case .day:     return .today
        case .week:    return .sevenDays
        case .month:   return .thirtyDays
        case .allTime: return .allTime
        }
    }
}
