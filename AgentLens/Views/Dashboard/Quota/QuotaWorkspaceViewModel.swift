import Foundation
import OpenBurnBarCore
import SwiftUI

// MARK: - Subscription Entry

struct SubscriptionEntry: Identifiable, Hashable {
    let id: String
    let provider: AgentProvider
    let providerID: ProviderID
    let snapshot: ProviderQuotaSnapshot
    let accountLabel: String
    let planTierBadge: String?
    let storageScope: ProviderAccountStorageScope?
    let hourlyBucket: ProviderQuotaBucket?
    let weeklyOrMonthlyBucket: ProviderQuotaBucket?
    let primaryBucket: ProviderQuotaBucket
    let allDisplayableBuckets: [ProviderQuotaBucket]
    let pressure: Double
    let nextResetDate: Date?
    let managementURL: URL?
    let isStale: Bool
    let isRefreshing: Bool
    let lastValidatedAt: Date?

    var remainingPercentRounded: Int {
        let frac = max(0.0, min(1.0, 1.0 - pressure))
        return Int((frac * 100).rounded())
    }
}

// MARK: - Subscription Setup Slot
//
// A provider that *could* be tracked but has no displayable snapshot yet.

struct SubscriptionSetupSlot: Identifiable, Hashable {
    let id: String
    let provider: AgentProvider
    let providerID: ProviderID
    let hasConnectedAccount: Bool
    let statusMessage: String
}

// MARK: - Sort + view modes

enum QuotaSortMode: String, CaseIterable, Identifiable {
    case urgency
    case spend
    case alphabetical
    case recentlyRefreshed

    var id: String { rawValue }

    var label: String {
        switch self {
        case .urgency: return "Urgency"
        case .spend: return "Spend"
        case .alphabetical: return "A → Z"
        case .recentlyRefreshed: return "Recently refreshed"
        }
    }

    var systemImage: String {
        switch self {
        case .urgency: return "exclamationmark.gauge"
        case .spend: return "dollarsign.circle"
        case .alphabetical: return "textformat"
        case .recentlyRefreshed: return "clock.arrow.circlepath"
        }
    }
}

enum QuotaViewMode: String, CaseIterable, Identifiable {
    case cards
    case list

    var id: String { rawValue }

    var label: String {
        switch self {
        case .cards: return "Cards"
        case .list: return "List"
        }
    }

    var systemImage: String {
        switch self {
        case .cards: return "square.grid.2x2"
        case .list: return "list.bullet"
        }
    }
}

// MARK: - View Model

@Observable
@MainActor
final class QuotaWorkspaceViewModel {
    private(set) var entries: [SubscriptionEntry] = []
    private(set) var setupSlots: [SubscriptionSetupSlot] = []
    private(set) var lastBuiltAt: Date?

    var sort: QuotaSortMode = .urgency
    var viewMode: QuotaViewMode = .cards
    var showInactive: Bool = false

    func rebuild(
        quotaService: ProviderQuotaService,
        dataStore: DataStore,
        providerSpendByID: [ProviderID: Double]
    ) {
        var byID: [String: SubscriptionEntry] = [:]

        for provider in AgentProvider.quotaSignalProviders {
            let allAccountSnapshots = quotaService.snapshots(for: provider)
            let candidateSnapshots = allAccountSnapshots
                .filter { $0.hasDisplayableQuotaSignal }

            if !candidateSnapshots.isEmpty {
                for snapshot in candidateSnapshots {
                    let entry = Self.makeEntry(
                        provider: provider,
                        snapshot: snapshot,
                        isRefreshing: quotaService.isRefreshing(provider)
                    )
                    byID[entry.id] = entry
                }
                continue
            }

            let isConnected = quotaService.hasConnectedQuotaAccount(for: provider, dataStore: dataStore)
            if let rollup = quotaService.snapshot(for: provider),
               rollup.hasDisplayableQuotaSignal {
                let entry = Self.makeEntry(
                    provider: provider,
                    snapshot: rollup,
                    isRefreshing: quotaService.isRefreshing(provider)
                )
                byID[entry.id] = entry
                continue
            }

            let fallbackAccountSnapshots = allAccountSnapshots.filter { snapshot in
                guard !snapshot.hasDisplayableQuotaSignal else { return false }
                return isConnected || snapshot.accountID != nil || snapshot.source != .unavailable
            }
            if !fallbackAccountSnapshots.isEmpty {
                for snapshot in fallbackAccountSnapshots {
                    let entry = Self.makeEntry(
                        provider: provider,
                        snapshot: snapshot,
                        isRefreshing: quotaService.isRefreshing(provider)
                    )
                    byID[entry.id] = entry
                }
                continue
            }

            if let rollup = quotaService.snapshot(for: provider),
               rollup.hasDisplayableQuotaSignal || isConnected || rollup.source != .unavailable {
                let entry = Self.makeEntry(
                    provider: provider,
                    snapshot: rollup,
                    isRefreshing: quotaService.isRefreshing(provider)
                )
                byID[entry.id] = entry
            }
        }

        let unsortedEntries = Array(byID.values)
        self.entries = Self.sort(unsortedEntries, by: sort, spendByID: providerSpendByID)
        self.setupSlots = Self.makeSetupSlots(
            quotaService: quotaService,
            dataStore: dataStore,
            takenProviderIDs: Set(entries.map(\.providerID))
        )
        self.lastBuiltAt = Date()
    }

    // MARK: Aggregate readouts

    struct AggregateSummary {
        let activeCount: Int
        let wideOpenCount: Int
        let narrowingCount: Int
        let nearEdgeCount: Int
        let nextResetEntry: SubscriptionEntry?
        let lastSync: Date?
        let committedMonthlyUSD: Double?
    }

    func aggregateSummary() -> AggregateSummary {
        Self.aggregate(entries)
    }

    /// Computes the same summary off an arbitrary subset of entries — used by
    /// the workspace when the user has pivoted to a single provider via the
    /// constellation hero.
    static func aggregate(_ entries: [SubscriptionEntry]) -> AggregateSummary {
        let active = entries.count
        var wide = 0
        var narrow = 0
        var edge = 0
        for entry in entries {
            switch entry.pressure {
            case ..<0.20: wide += 1
            case ..<0.46: wide += 1
            case ..<0.74: narrow += 1
            default: edge += 1
            }
        }
        let nextEntry = entries
            .compactMap { entry -> (SubscriptionEntry, Date)? in
                entry.nextResetDate.map { (entry, $0) }
            }
            .min(by: { $0.1 < $1.1 })?
            .0
        let lastSync = entries.map(\.snapshot.fetchedAt).max()
        return AggregateSummary(
            activeCount: active,
            wideOpenCount: wide,
            narrowingCount: narrow,
            nearEdgeCount: edge,
            nextResetEntry: nextEntry,
            lastSync: lastSync,
            committedMonthlyUSD: nil
        )
    }

    // MARK: Helpers

    static func makeEntry(
        provider: AgentProvider,
        snapshot: ProviderQuotaSnapshot,
        isRefreshing: Bool
    ) -> SubscriptionEntry {
        let primary = snapshot.primaryDisplayableBucket ?? snapshot.buckets.first
        let displayable = snapshot.displayableQuotaBuckets
        let pressure = max(
            primary?.progressFraction ?? 0,
            displayable.map(\.progressFraction).max() ?? 0
        )
        let upcomingResets = displayable.compactMap(\.resetsAt).filter { $0 > Date() }
        let nextReset = upcomingResets.min()
        let accountLabel = snapshot.accountLabel
            ?? snapshot.accountID
            ?? snapshot.sourceId
        let planTierBadge: String? = {
            if provider == .factory {
                let tier = snapshot.statusMessage.lowercased()
                if tier.contains("max") { return "Max" }
                if tier.contains("plus") { return "Plus" }
                if tier.contains("pro") { return "Pro" }
            }
            return nil
        }()

        return SubscriptionEntry(
            id: snapshot.providerID.rawValue + ":" + (snapshot.accountID ?? snapshot.sourceId),
            provider: provider,
            providerID: snapshot.providerID,
            snapshot: snapshot,
            accountLabel: accountLabel,
            planTierBadge: planTierBadge,
            storageScope: snapshot.accountStorageScope,
            hourlyBucket: snapshot.hourlyBucket,
            weeklyOrMonthlyBucket: snapshot.weeklyBucket ?? displayable.first { $0.windowKind == .monthly },
            primaryBucket: primary ?? ProviderQuotaBucket(
                key: "unavailable",
                label: snapshot.statusMessage,
                windowKind: .custom,
                usedValue: nil,
                limitValue: nil,
                remainingValue: nil,
                usedPercent: nil,
                resetsAt: nil,
                unit: .percent,
                isEstimated: true
            ),
            allDisplayableBuckets: displayable,
            pressure: pressure,
            nextResetDate: nextReset,
            managementURL: snapshot.managementLink,
            isStale: snapshot.isStale(),
            isRefreshing: isRefreshing,
            lastValidatedAt: snapshot.fetchedAt
        )
    }

    static func makeSetupSlots(
        quotaService: ProviderQuotaService,
        dataStore: DataStore,
        takenProviderIDs: Set<ProviderID>
    ) -> [SubscriptionSetupSlot] {
        var slots: [SubscriptionSetupSlot] = []
        for provider in AgentProvider.quotaSignalProviders {
            if takenProviderIDs.contains(provider.providerID) { continue }
            let isConnected = quotaService.hasConnectedQuotaAccount(for: provider, dataStore: dataStore)
            let snapshot = quotaService.snapshot(for: provider)
            slots.append(SubscriptionSetupSlot(
                id: provider.providerID.rawValue,
                provider: provider,
                providerID: provider.providerID,
                hasConnectedAccount: isConnected,
                statusMessage: snapshot?.statusMessage ?? "Not connected yet."
            ))
        }
        return slots.sorted { lhs, rhs in
            if lhs.hasConnectedAccount != rhs.hasConnectedAccount {
                return lhs.hasConnectedAccount && !rhs.hasConnectedAccount
            }
            return lhs.provider.displayName
                .localizedCaseInsensitiveCompare(rhs.provider.displayName) == .orderedAscending
        }
    }

    static func sort(
        _ entries: [SubscriptionEntry],
        by mode: QuotaSortMode,
        spendByID: [ProviderID: Double]
    ) -> [SubscriptionEntry] {
        switch mode {
        case .urgency:
            return entries.sorted { lhs, rhs in
                if lhs.pressure != rhs.pressure { return lhs.pressure > rhs.pressure }
                let lDate = lhs.nextResetDate ?? .distantFuture
                let rDate = rhs.nextResetDate ?? .distantFuture
                if lDate != rDate { return lDate < rDate }
                return lhs.provider.displayName
                    .localizedCaseInsensitiveCompare(rhs.provider.displayName) == .orderedAscending
            }
        case .spend:
            return entries.sorted { lhs, rhs in
                let lSpend = spendByID[lhs.providerID] ?? 0
                let rSpend = spendByID[rhs.providerID] ?? 0
                if lSpend != rSpend { return lSpend > rSpend }
                return lhs.provider.displayName
                    .localizedCaseInsensitiveCompare(rhs.provider.displayName) == .orderedAscending
            }
        case .alphabetical:
            return entries.sorted { lhs, rhs in
                lhs.provider.displayName
                    .localizedCaseInsensitiveCompare(rhs.provider.displayName) == .orderedAscending
            }
        case .recentlyRefreshed:
            return entries.sorted { lhs, rhs in
                lhs.snapshot.fetchedAt > rhs.snapshot.fetchedAt
            }
        }
    }
}
