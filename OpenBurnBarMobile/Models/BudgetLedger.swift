import Foundation
import OpenBurnBarCore

// MARK: - BudgetSpendDataSource

/// Protocol for objects that provide pre-computed rollup data. `DashboardStore` already
/// exposes `rollupsByWindow` and naturally conforms.
@MainActor
protocol BudgetSpendDataSource: AnyObject, Sendable {
    /// The current set of usage rollup documents keyed by window (today, 7d, 30d, etc.).
    var rollupsByWindow: [RollupWindowKey: UsageRollupDoc] { get }

    /// Whether `rollupsByWindow` is a readable snapshot. A live but empty snapshot means
    /// "definitely zero"; an unreadable snapshot means spend is unknown and gates must fail closed.
    var budgetSpendSnapshotIsReadable: Bool { get }
}

extension BudgetSpendDataSource {
    var budgetSpendSnapshotIsReadable: Bool { true }
}

enum BudgetLedgerReadError: Error, LocalizedError, Equatable, Sendable {
    case spendSnapshotUnavailable
    case projectScopeUnsupported

    var errorDescription: String? {
        switch self {
        case .spendSnapshotUnavailable:
            "Budget spend snapshot is not readable."
        case .projectScopeUnsupported:
            "Project-scope spend cannot be computed on iOS (rollups carry no per-project breakdown)."
        }
    }
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
    private struct SessionSpendKey: Hashable, Sendable {
        let providerID: String
        let accountID: String?

        init(providerID: String, accountID: String?) {
            self.providerID = providerID
            self.accountID = accountID.flatMap(Self.nonEmpty)
        }

        private static func nonEmpty(_ value: String) -> String? {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    private struct SessionSpendRecord: Sendable {
        let key: SessionSpendKey
        var accountLabel: String?
        var cost: Double
    }

    private struct RollupSpend: Sendable {
        var total: Double
        var matchedAccountKeys: Set<SessionSpendKey> = []
    }

    /// The data source providing rollup snapshots. Accessed on `@MainActor` when reading.
    private let dataSource: any BudgetSpendDataSource

    /// Per-session cost accumulator keyed by `(providerID, accountID)`. Captures spend
    /// that hasn't yet been reflected in the server-computed rollup (which only updates
    /// periodically via Cloud Functions). Added on top of rollup totals for real-time gate
    /// accuracy.
    private var sessionSpend: [SessionSpendKey: SessionSpendRecord] = [:]

    /// Creates a ledger backed by the given rollup data source.
    init(dataSource: any BudgetSpendDataSource) {
        self.dataSource = dataSource
    }

    // MARK: - Spend queries

    /// Current accumulated spend (USD) attributed to the rule's scope within the rule's
    /// current period. Used by `BudgetGate.evaluate`.
    func currentSpend(forRule rule: BudgetRule, reference: Date = Date()) async throws -> Double {
        let rollupSpend = try await rollupSpend(forRule: rule)
        let session = sessionSpendForRule(rule, matchedAccountKeys: rollupSpend.matchedAccountKeys)
        return rollupSpend.total + session
    }

    /// Batch version — runs `currentSpend` for each rule and returns a dictionary keyed by
    /// rule ID. A successful read is present even when the value is `0`; a failed read is
    /// omitted so callers can distinguish "definitely zero" from "unknown, fail closed".
    func snapshot(forRules rules: [BudgetRule], reference: Date = Date()) async -> [String: Double] {
        var result: [String: Double] = [:]
        for rule in rules {
            result[rule.id] = try? await currentSpend(forRule: rule, reference: reference)
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
    ///   - accountLabel: Human-facing account label when the caller has it. Organization
    ///     rules use this to include first-session spend before the next rollup lands.
    ///   - cost: The cost of this single request in USD.
    func recordSessionCost(providerID: String, accountID: String?, accountLabel: String? = nil, cost: Double) {
        let key = sessionKey(providerID: providerID, accountID: accountID)
        let label = Self.nonEmpty(accountLabel)
        if var record = sessionSpend[key] {
            record.cost += cost
            record.accountLabel = record.accountLabel ?? label
            sessionSpend[key] = record
        } else {
            sessionSpend[key] = SessionSpendRecord(key: key, accountLabel: label, cost: cost)
        }
    }

    /// Resets the session accumulator. Call on period boundaries (e.g. midnight for daily
    /// rules) or after a rollup refresh confirms the server has caught up.
    func resetSessionAccumulator() {
        sessionSpend.removeAll()
    }

    // MARK: - Private helpers

    /// Maps `BudgetPeriod` to the appropriate `RollupWindowKey` and extracts cost from the
    /// matching rollup document, filtered by the rule's scope.
    private func rollupSpend(forRule rule: BudgetRule) async throws -> RollupSpend {
        let windowKey = rollupWindowKey(for: rule.period)
        let snapshot = await MainActor.run {
            (
                isReadable: dataSource.budgetSpendSnapshotIsReadable,
                rollupsByWindow: dataSource.rollupsByWindow
            )
        }
        guard snapshot.isReadable else {
            throw BudgetLedgerReadError.spendSnapshotUnavailable
        }
        let rollupsByWindow = snapshot.rollupsByWindow
        guard let rollup = rollupsByWindow[windowKey] else {
            return RollupSpend(total: 0)
        }

        switch rule.scope {
        case .global:
            return RollupSpend(total: rollup.totals.costUsd)

        case .credential:
            // Filter account summaries by providerID and optionally accountID
            let total = rollup.accountSummaries
                .filter { summary in
                    guard summary.providerID.rawValue == rule.providerID else { return false }
                    if let ruleAccountID = rule.accountID, !ruleAccountID.isEmpty {
                        return summary.accountID == ruleAccountID
                    }
                    return true
                }
                .compactMap(\.totalCost)
                .reduce(0, +)
            return RollupSpend(total: total)

        case .project:
            // Rollups carry no per-project breakdown, so project spend is UNKNOWABLE here —
            // not zero. Returning 0 made project rules silently enforce nothing; throwing
            // routes the gate through its fail-closed path instead (audit wave 4, item 3).
            throw BudgetLedgerReadError.projectScopeUnsupported

        case .organization:
            guard let identifier = Self.nonEmpty(rule.identifier) else { return RollupSpend(total: 0) }
            let memberAccountIDs = Self.organizationMemberAccountIDs(
                identifier: identifier,
                rollupsByWindow: rollupsByWindow
            )
            let matches = rollup.accountSummaries.filter {
                Self.matchesOrganization($0, identifier: identifier, memberAccountIDs: memberAccountIDs)
            }
            let total = matches.compactMap(\.totalCost).reduce(0, +)
            let keys = Set(matches.map { sessionKey(providerID: $0.providerID.rawValue, accountID: $0.accountID) })
            return RollupSpend(total: total, matchedAccountKeys: keys)
        }
    }

    /// Returns accumulated session spend relevant to the rule's scope.
    private func sessionSpendForRule(_ rule: BudgetRule, matchedAccountKeys: Set<SessionSpendKey>) -> Double {
        switch rule.scope {
        case .global:
            return sessionSpend.values.map(\.cost).reduce(0, +)

        case .credential:
            guard let providerID = rule.providerID else { return 0 }
            if let accountID = Self.nonEmpty(rule.accountID) {
                let key = sessionKey(providerID: providerID, accountID: accountID)
                return sessionSpend[key]?.cost ?? 0
            }
            return sessionSpend.values
                .filter { $0.key.providerID == providerID }
                .map(\.cost)
                .reduce(0, +)

        case .project:
            // Session accumulator doesn't track per-project (no project ID in relay responses).
            return 0

        case .organization:
            guard let identifier = Self.nonEmpty(rule.identifier) else { return 0 }
            return sessionSpend.values
                .filter { record in
                    matchedAccountKeys.contains(record.key)
                        || record.key.accountID == identifier
                        || record.accountLabel == identifier
                }
                .map(\.cost)
                .reduce(0, +)
        }
    }

    /// Builds a stable dictionary key for session spend tracking.
    private nonisolated func sessionKey(providerID: String, accountID: String?) -> SessionSpendKey {
        SessionSpendKey(providerID: providerID, accountID: accountID)
    }

    /// Rollup equivalent of the macOS ledger's recursive `providerAccountID` subquery: an
    /// account whose label matched the organization in ANY rollup window is an org member,
    /// so its spend still counts in windows where the summary carries a renamed label.
    private nonisolated static func organizationMemberAccountIDs(
        identifier: String,
        rollupsByWindow: [RollupWindowKey: UsageRollupDoc]
    ) -> Set<String> {
        var members: Set<String> = []
        for rollup in rollupsByWindow.values {
            for summary in rollup.accountSummaries where summary.accountLabel == identifier {
                if let accountID = nonEmpty(summary.accountID) {
                    members.insert(accountID)
                }
            }
        }
        return members
    }

    private nonisolated static func matchesOrganization(
        _ summary: RollupProviderAccountSummary,
        identifier: String,
        memberAccountIDs: Set<String>
    ) -> Bool {
        if summary.accountLabel == identifier || summary.accountID == identifier {
            return true
        }
        guard let accountID = nonEmpty(summary.accountID) else { return false }
        return memberAccountIDs.contains(accountID)
    }

    private nonisolated static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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
