import Foundation
import OpenBurnBarCore

// MARK: - BudgetSpendDataSource

/// Protocol for objects that provide pre-computed rollup data. `DashboardStore` already
/// exposes `rollupsByWindow` and naturally conforms.
@MainActor
protocol BudgetSpendDataSource: AnyObject, Sendable {
    /// The current set of usage rollup documents keyed by window (today, 7d, 30d, etc.).
    var rollupsByWindow: [RollupWindowKey: UsageRollupDoc] { get }
}

// MARK: - BudgetLedger

/// Computes running spend for a budget rule against Firestore usage rollups.
///
/// iOS equivalent of the macOS `BudgetLedger` which queries raw `token_usage` rows via
/// SQL. On mobile we use pre-computed `UsageRollupDoc` data from `DashboardStore` (or any
/// `BudgetSpendDataSource`) and supplement with a local session accumulator for sub-cycle
/// accuracy.
///
/// `BudgetGate` calls into this actor on every request to ask: "if I let this request
/// through at an estimated cost of $X, will rule R's running total cross its limit?"
actor BudgetLedger {
    /// The data source providing rollup snapshots. Accessed on `@MainActor` when reading.
    private weak var dataSource: (any BudgetSpendDataSource)?

    /// Per-session cost accumulator keyed by `"{providerID}_{accountID}"`. Captures spend
    /// that hasn't yet been reflected in the server-computed rollup (which only updates
    /// periodically via Cloud Functions). Added on top of rollup totals for real-time gate
    /// accuracy.
    private var sessionSpend: [String: Double] = [:]

    /// Creates a ledger backed by the given rollup data source.
    init(dataSource: any BudgetSpendDataSource) {
        self.dataSource = dataSource
    }

    // MARK: - Spend queries

    /// Current accumulated spend (USD) attributed to the rule's scope within the rule's
    /// current period. Used by `BudgetGate.evaluate`.
    func currentSpend(forRule rule: BudgetRule, reference: Date = Date()) async -> Double {
        let rollupSpend = await rollupSpend(forRule: rule)
        let session = sessionSpendForRule(rule)
        return rollupSpend + session
    }

    /// Batch version — runs `currentSpend` for each rule and returns a dictionary keyed by
    /// rule ID. The caller picks how to combine with `estimatedCost`.
    func snapshot(forRules rules: [BudgetRule], reference: Date = Date()) async -> [String: Double] {
        var result: [String: Double] = [:]
        for rule in rules {
            result[rule.id] = await currentSpend(forRule: rule, reference: reference)
        }
        return result
    }

    // MARK: - Session accumulator

    /// Records marginal spend from a single relay response. Called after each completed
    /// API request so the ledger stays ahead of the next rollup refresh cycle.
    ///
    /// - Parameters:
    ///   - providerID: The provider that served the request (e.g. "anthropic").
    ///   - accountID: The hashed account/slot ID, or nil for default accounts.
    ///   - cost: The cost of this single request in USD.
    func recordSessionCost(providerID: String, accountID: String?, cost: Double) {
        let key = sessionKey(providerID: providerID, accountID: accountID)
        sessionSpend[key, default: 0] += cost
    }

    /// Resets the session accumulator. Call on period boundaries (e.g. midnight for daily
    /// rules) or after a rollup refresh confirms the server has caught up.
    func resetSessionAccumulator() {
        sessionSpend.removeAll()
    }

    // MARK: - Private helpers

    /// Maps `BudgetPeriod` to the appropriate `RollupWindowKey` and extracts cost from the
    /// matching rollup document, filtered by the rule's scope.
    private func rollupSpend(forRule rule: BudgetRule) async -> Double {
        guard let source = self.dataSource else { return 0 }

        let windowKey = rollupWindowKey(for: rule.period)
        let rollupsByWindow = await MainActor.run {
            source.rollupsByWindow
        }
        guard let rollup = rollupsByWindow[windowKey] else { return 0 }

        switch rule.scope {
        case .global:
            return rollup.totals.costUsd

        case .credential:
            // Filter account summaries by providerID and optionally accountID
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
            // Rollups don't currently have per-project breakdowns — future enhancement.
            return 0

        case .organization:
            // Filter account summaries by the organization identifier (matched against
            // accountLabel or accountID, mirroring the macOS SQL join pattern).
            guard let identifier = rule.identifier, !identifier.isEmpty else { return 0 }
            return rollup.accountSummaries
                .filter { $0.accountLabel == identifier || $0.accountID == identifier }
                .compactMap(\.totalCost)
                .reduce(0, +)
        }
    }

    /// Returns accumulated session spend relevant to the rule's scope.
    private func sessionSpendForRule(_ rule: BudgetRule) -> Double {
        switch rule.scope {
        case .global:
            return sessionSpend.values.reduce(0, +)

        case .credential:
            guard let providerID = rule.providerID else { return 0 }
            let key = sessionKey(providerID: providerID, accountID: rule.accountID)
            return sessionSpend[key] ?? 0

        case .project:
            // Session accumulator doesn't track per-project (no project ID in relay responses).
            return 0

        case .organization:
            // Organization scope would need to aggregate across all matching accounts;
            // for now return the full session total as a conservative upper bound.
            return sessionSpend.values.reduce(0, +)
        }
    }

    /// Builds a stable dictionary key for session spend tracking.
    private func sessionKey(providerID: String, accountID: String?) -> String {
        let account = accountID ?? "_default"
        return "\(providerID)_\(account)"
    }

    /// Maps a `BudgetPeriod` to the closest `RollupWindowKey`. The rollup windows don't
    /// perfectly align with calendar periods (7d ≠ week, 30d ≠ month) but are the best
    /// available data on iOS without raw SQL access.
    private nonisolated func rollupWindowKey(for period: BudgetPeriod) -> RollupWindowKey {
        switch period {
        case .day:     return .today
        case .week:    return .sevenDays
        case .month:   return .thirtyDays
        case .allTime: return .allTime
        }
    }
}
