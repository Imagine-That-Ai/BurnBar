import Foundation
import os
import OpenBurnBarCore

// MARK: - Cumulative across accounts
//
// When the user has multiple accounts on the same provider, collapse the
// per-account snapshots into one synthetic snapshot whose buckets are
// summed by `(key, windowKind)`. Pure derivation — the cumulative
// snapshot is never persisted, never synced to Firestore. It exists only
// to feed the UI when `SettingsManager.cumulativeAcrossAccounts` is on.

extension ProviderQuotaService {

    /// Returns the cumulative snapshot for `provider`, or nil when there
    /// is nothing meaningful to merge (zero or one account, no displayable
    /// signal, or every input bucket dropped during normalization).
    func cumulativeSnapshot(for provider: AgentProvider, now: Date = Date()) -> ProviderQuotaSnapshot? {
        Self.cumulativeSnapshot(
            provider: provider,
            from: snapshots(for: provider),
            now: now
        )
    }

    /// Pure-logic variant: given an explicit input list of per-account
    /// snapshots, produce the cumulative snapshot. Used by tests and by
    /// the convenience instance method above. Returns nil when there is
    /// nothing meaningful to merge.
    static func cumulativeSnapshot(
        provider: AgentProvider,
        from inputs: [ProviderQuotaSnapshot],
        now: Date = Date()
    ) -> ProviderQuotaSnapshot? {
        // Drop only records that restate a measurement already in the list.
        // The synthetic "Current <CLI> login" is the provider-level rollup
        // re-badged as an account, so summing it double-counts one machine.
        //
        // This used to drop every `.localOnly` snapshot, which also discarded
        // real switcher-profile logins: `fetchSwitcherProfileSnapshot` marks
        // all of them `.localOnly` even though each is an isolated
        // `CODEX_HOME` / `CLAUDE_CONFIG_DIR` account with its own numbers. Two
        // daemon accounts plus one switcher profile therefore merged as two,
        // and the panel reported an understated total — the worst possible
        // failure mode for a spend readout — under a confident "Combined 2
        // accounts" label.
        let candidateSnapshots = inputs.filter { !ProviderQuotaAccountDisplay.isCurrentCLIMirror($0) }
        guard candidateSnapshots.count > 1 else { return nil }

        // Prefer fresh snapshots. If every account is stale, fall back to
        // the freshest single snapshot and tag the result so the UI can
        // show "stale merged" instead of silently dropping data.
        let freshSnapshots = candidateSnapshots.filter { !$0.isStale(relativeTo: now) }
        let mergedInputs: [ProviderQuotaSnapshot]
        let staleFallback: Bool
        if freshSnapshots.isEmpty {
            staleFallback = true
            if let freshest = candidateSnapshots.max(by: { $0.fetchedAt < $1.fetchedAt }) {
                mergedInputs = [freshest]
            } else {
                return nil
            }
        } else {
            staleFallback = false
            mergedInputs = freshSnapshots
        }

        let mergedBuckets = mergeBuckets(across: mergedInputs, now: now)
        guard !mergedBuckets.isEmpty else { return nil }

        let fetchedAt = mergedInputs.map(\.fetchedAt).min() ?? now
        let confidence: ProviderQuotaConfidence = staleFallback
            ? .unavailable
            : worstConfidence(among: mergedInputs)
        let managementURL = mergedInputs.compactMap(\.managementURL).first
        let accountCount = candidateSnapshots.count
        let statusMessage: String = {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            let relative = formatter.localizedString(for: fetchedAt, relativeTo: now)
            if staleFallback {
                return "Stale data merged across \(accountCount) accounts — last fetch \(relative)"
            }
            return "Combined \(accountCount) accounts — oldest fetch \(relative)"
        }()

        return ProviderQuotaSnapshot(
            provider: provider,
            providerID: provider.providerID,
            accountID: nil,
            accountLabel: "All accounts (\(accountCount))",
            accountStorageScope: .cloudRefreshable,
            fetchedAt: fetchedAt,
            source: dominantSourceKind(among: mergedInputs),
            sourceId: "cumulative:\(provider.providerID.rawValue)",
            confidence: confidence,
            managementURL: managementURL,
            statusMessage: statusMessage,
            buckets: mergedBuckets,
            schemaVersion: mergedInputs.first?.schemaVersion ?? 2,
            // Structured, so surfaces downstream of the collapse read the
            // footprint instead of counting one record and reporting "1".
            mergedAccountCount: accountCount
        )
    }

    /// Single switchboard every UI surface reads from. When the
    /// `cumulativeAcrossAccounts` toggle is on and the provider has more
    /// than one account, returns the cumulative snapshot wrapped in a
    /// one-element array. Otherwise returns the per-account list from
    /// `snapshots(for:)`.
    func displaySnapshots(
        for provider: AgentProvider,
        cumulative: Bool,
        now: Date = Date()
    ) -> [ProviderQuotaSnapshot] {
        let perAccountSnapshots = displaySnapshotsIncludingCurrentCLI(for: provider)
        guard cumulative else { return perAccountSnapshots }
        if let combined = Self.cumulativeSnapshot(
            provider: provider,
            from: perAccountSnapshots,
            now: now
        ) {
            return [combined]
        }
        return perAccountSnapshots
    }

    /// Single-snapshot variant for surfaces that show one summary per
    /// provider (popover strip, menu bar). When `cumulative` is on AND
    /// the provider has multiple accounts, returns the merged snapshot.
    /// Otherwise falls back to `snapshot(for:)` (the existing
    /// provider-level snapshot).
    func primaryDisplaySnapshot(
        for provider: AgentProvider,
        cumulative: Bool,
        now: Date = Date()
    ) -> ProviderQuotaSnapshot? {
        if cumulative, let combined = cumulativeSnapshot(for: provider, now: now) {
            return combined
        }
        return snapshot(for: provider)
    }

    // MARK: - Helpers

    private func displaySnapshotsIncludingCurrentCLI(for provider: AgentProvider) -> [ProviderQuotaSnapshot] {
        let accountSnapshots = snapshots(for: provider)
        guard let currentCLIType = Self.currentCLIType(for: provider),
              accountSnapshots.contains(where: \.hasDisplayableQuotaSignal),
              let providerSnapshot = snapshot(for: provider),
              providerSnapshot.hasDisplayableQuotaSignal else {
            return accountSnapshots
        }

        let currentAccountID = "current-\(currentCLIType.rawValue)"
        let currentSourceID = ProviderQuotaAccountDisplay.currentCLISourceIDPrefix + currentCLIType.rawValue
        let alreadyIncluded = accountSnapshots.contains { snapshot in
            snapshot.accountID == currentAccountID || snapshot.sourceId == currentSourceID
        }
        guard !alreadyIncluded else { return accountSnapshots }

        let currentLabel = Self.currentCLIDisplayLabel(for: currentCLIType)
        let currentSnapshot = providerSnapshot.withAccountMetadata(
            providerID: provider.providerID,
            accountID: currentAccountID,
            accountLabel: currentLabel,
            accountStorageScope: .localOnly,
            sourceId: currentSourceID
        )

        return [currentSnapshot] + accountSnapshots
    }

    private static func currentCLIDisplayLabel(for cliType: SwitcherCLIProfileType) -> String {
        switch cliType {
        case .codex:
            return CLIAuthDiscovery.discoverAuthState(for: cliType).accountDescription
                ?? "Current \(cliType.displayName) login"
        case .claude, .opencode, .droid, .forge, .antigravity, .grok, .cursorAgent, .gemini, .kimi, .pi, .omp, .junie, .primeAgent, .fx, .muse, .hermes, .goose, .windsurf, .openClaude, .openClaw:
            return "Current \(cliType.displayName) login"
        }
    }

    private static func currentCLIType(for provider: AgentProvider) -> SwitcherCLIProfileType? {
        switch provider {
        case .codex:
            return .codex
        case .claudeCode:
            return .claude
        case .factory:
            return .droid
        case .forgeDev:
            return .forge
        case .antigravity:
            return .antigravity
        case .xAI:
            return .grok
        case .junie:
            return .junie
        case .fx:
            return .fx
        case .primeAgent:
            return .primeAgent
        case .hermes:
            return .hermes
        case .goose:
            return .goose
        case .windsurf:
            return .windsurf
        case .openClaude:
            return .openClaude
        case .openClaw:
            return .openClaw
        case .muse:
            return .muse
        default:
            return nil
        }
    }

    /// Group inputs' displayable buckets by `(key, windowKind)` and sum
    /// them into one bucket per group. Buckets without a unit match are
    /// dropped (mismatched units would produce nonsense sums).
    static func mergeBuckets(across snapshots: [ProviderQuotaSnapshot], now: Date = Date()) -> [ProviderQuotaBucket] {
        struct GroupKey: Hashable {
            let key: String
            let windowKind: ProviderQuotaWindowKind
        }
        var groups: [GroupKey: [ProviderQuotaBucket]] = [:]
        for snapshot in snapshots {
            for bucket in snapshot.displayableQuotaBuckets(relativeTo: now) {
                let groupKey = GroupKey(key: bucket.key, windowKind: bucket.windowKind)
                groups[groupKey, default: []].append(bucket)
            }
        }

        return groups.compactMap { groupKey, members -> ProviderQuotaBucket? in
            guard let first = members.first else { return nil }
            // Require unit consistency. If one input is requests and another
            // is tokens for the same key (shouldn't happen, but) we cannot
            // sum them.
            let units = Set(members.map(\.unit))
            guard units.count == 1, let unit = units.first else { return nil }

            let usedValues = members.compactMap(\.usedValue)
            let limitValues = members.compactMap(\.limitValue)
            let remainingValues = members.compactMap(\.remainingValue)

            let usedSum = usedValues.isEmpty ? nil : usedValues.reduce(0, +)
            let limitSum = limitValues.isEmpty ? nil : limitValues.reduce(0, +)
            let remainingSum: Double? = {
                if !remainingValues.isEmpty { return remainingValues.reduce(0, +) }
                if let usedSum, let limitSum {
                    return max(limitSum - usedSum, 0)
                }
                return nil
            }()

            // Always recompute usedPercent from the summed totals — never
            // average raw percents (a 90%-used small bucket and a 10%-used
            // large bucket are NOT 50% combined).
            let usedPercent: Double? = {
                if let usedSum, let limitSum, limitSum > 0 {
                    return min(max((usedSum / limitSum) * 100, 0), 100)
                }
                let rawPercents = members.compactMap(\.usedPercent)
                guard !rawPercents.isEmpty else { return nil }
                return rawPercents.reduce(0, +) / Double(rawPercents.count)
            }()

            // Earliest reset = soonest moment new capacity arrives.
            let resetsAt = members.compactMap(\.resetsAt).min()

            return ProviderQuotaBucket(
                key: groupKey.key,
                label: first.label,
                windowKind: groupKey.windowKind,
                usedValue: usedSum,
                limitValue: limitSum,
                remainingValue: remainingSum,
                usedPercent: usedPercent,
                resetsAt: resetsAt,
                unit: unit,
                isEstimated: members.contains(where: \.isEstimated)
            )
        }
        // Stable order: hourly window first, then daily, weekly, etc.
        .sorted { lhs, rhs in
            Self.windowKindOrder(lhs.windowKind) < Self.windowKindOrder(rhs.windowKind)
        }
    }

    private static func windowKindOrder(_ kind: ProviderQuotaWindowKind) -> Int {
        switch kind {
        case .rollingHours: return 0
        case .daily:        return 1
        case .weekly:       return 2
        case .rollingDays:  return 3
        case .monthly:      return 4
        case .lifetime:     return 5
        case .custom:       return 6
        }
    }

    private static func worstConfidence(among snapshots: [ProviderQuotaSnapshot]) -> ProviderQuotaConfidence {
        // `unavailable` worst, then `estimated`, then `exact`.
        if snapshots.contains(where: { $0.confidence == .unavailable }) { return .unavailable }
        if snapshots.contains(where: { $0.confidence == .estimated }) { return .estimated }
        return .exact
    }

    /// Pick a representative source kind for the merged envelope. Prefers
    /// `officialAPI` > `localCLI` > `localSession` > `manualEstimate` >
    /// `unavailable`.
    private static func dominantSourceKind(among snapshots: [ProviderQuotaSnapshot]) -> ProviderQuotaSourceKind {
        let order: [ProviderQuotaSourceKind] = [
            .officialAPI, .localCLI, .localSession, .manualEstimate, .unavailable
        ]
        for kind in order where snapshots.contains(where: { $0.sourceKind == kind }) {
            return kind
        }
        return .unavailable
    }
}
