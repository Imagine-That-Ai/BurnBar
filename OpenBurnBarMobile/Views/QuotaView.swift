import SwiftUI
import OpenBurnBarCore

struct QuotaView: View {
    @State private var store = QuotaStore()
    @State private var selectedProvider: String?

    var body: some View {
        ScrollView {
            if store.isLoading && store.snapshotsByProvider.isEmpty {
                loadingPlaceholder
            } else if store.snapshotsByProvider.isEmpty {
                EmptyStateView(
                    icon: "gauge.with.dots.needle.67percent",
                    title: "No Quota Data",
                    message: "Connect a provider to see quota snapshots."
                )
            } else {
                VStack(spacing: MobileTheme.Spacing.xl) {
                    if !store.urgentProviders.isEmpty {
                        urgentSection
                    }
                    healthySection
                }
                .padding(.vertical, MobileTheme.Spacing.lg)
            }
        }
        .background(MobileTheme.Colors.background.ignoresSafeArea())
        .navigationTitle("Quota")
        .refreshable { await store.refresh() }
        .task {
            await store.load()
            store.startListening()
        }
        .onDisappear { store.stopListening() }
        .sheet(isPresented: .init(
            get: { selectedProvider != nil },
            set: { if !$0 { selectedProvider = nil } }
        )) {
            if let provider = selectedProvider {
                QuotaDetailSheet(
                    provider: provider,
                    snapshots: store.sortedSnapshots(for: provider),
                    routingState: store.routingState(for: ProviderID(rawValue: provider))
                )
            }
        }
    }

    // MARK: - Urgent Section

    private var urgentSection: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
            Label("Urgent", systemImage: "exclamationmark.triangle.fill")
                .font(MobileTheme.Typography.headline)
                .foregroundStyle(MobileTheme.Colors.error)
                .padding(.horizontal, MobileTheme.Spacing.lg)
            LazyVStack(spacing: MobileTheme.Spacing.md) {
                ForEach(store.urgentProviders, id: \.self) { provider in
                    QuotaProviderCard(
                        provider: provider,
                        snapshots: store.snapshotsByProvider[provider] ?? [],
                        accountCount: store.accountCount(for: provider),
                        routingState: store.routingState(for: ProviderID(rawValue: provider)),
                        onTap: { selectedProvider = provider }
                    )
                }
            }
            .padding(.horizontal, MobileTheme.Spacing.lg)
        }
    }

    // MARK: - Healthy Section

    private var healthySection: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
            Text("Healthy")
                .font(MobileTheme.Typography.headline)
                .foregroundStyle(MobileTheme.Colors.textPrimary)
                .padding(.horizontal, MobileTheme.Spacing.lg)
            LazyVStack(spacing: MobileTheme.Spacing.md) {
                ForEach(store.healthyProviders, id: \.self) { provider in
                    QuotaProviderCard(
                        provider: provider,
                        snapshots: store.snapshotsByProvider[provider] ?? [],
                        accountCount: store.accountCount(for: provider),
                        routingState: store.routingState(for: ProviderID(rawValue: provider)),
                        onTap: { selectedProvider = provider }
                    )
                }
            }
            .padding(.horizontal, MobileTheme.Spacing.lg)
        }
    }

    // MARK: - Loading Placeholder

    private var loadingPlaceholder: some View {
        VStack(spacing: MobileTheme.Spacing.lg) {
            SkeletonView(height: 120, cornerRadius: MobileTheme.Radius.lg)
            SkeletonView(height: 120, cornerRadius: MobileTheme.Radius.lg)
            SkeletonView(height: 120, cornerRadius: MobileTheme.Radius.lg)
        }
        .padding(.horizontal, MobileTheme.Spacing.lg)
        .padding(.top, MobileTheme.Spacing.xl)
    }
}

// MARK: - Quota Provider Card

private struct QuotaProviderCard: View {
    let provider: String
    let snapshots: [ProviderQuotaSnapshot]
    let accountCount: Int
    let routingState: ProviderRoutingStateSnapshot?
    let onTap: () -> Void

    var providerEnum: AgentProvider? {
        AgentProvider.fromProviderID(ProviderID(rawValue: provider))
    }

    private var attributedSnapshots: [ProviderQuotaSnapshot] {
        snapshots.filter { $0.accountID != nil }
    }

    private var hasMultipleAccounts: Bool {
        accountCount > 1 || attributedSnapshots.count > 1
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
                HStack(alignment: .top) {
                    if let providerEnum {
                        ProviderBadge(provider: providerEnum, size: 40)
                            .accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(providerEnum?.displayName ?? provider)
                            .font(MobileTheme.Typography.headline)
                            .foregroundStyle(MobileTheme.Colors.textPrimary)
                        HStack(spacing: 6) {
                            Text(accountCountLabel)
                                .font(MobileTheme.Typography.footnote)
                                .foregroundStyle(MobileTheme.Colors.textSecondary)
                            if hasUrgentBucket {
                                Text("·")
                                    .font(MobileTheme.Typography.footnote)
                                    .foregroundStyle(MobileTheme.Colors.textMuted)
                                Text("Quota under pressure")
                                    .font(MobileTheme.Typography.tiny)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(MobileTheme.Colors.warning)
                            }
                        }
                        if !storageScopes.isEmpty {
                            HStack(spacing: 4) {
                                ForEach(storageScopes, id: \.self) { scope in
                                    ProviderAccountStorageChip(scope: scope, compact: true)
                                }
                            }
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                        .accessibilityHidden(true)
                }

                if hasMultipleAccounts, let primaryName = primaryAccountName {
                    Text("Showing \(primaryName)\(remainingAccountsLabel) — tap for full breakdown")
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let providerEnum,
                   let routingState,
                   routingState.hasMeaningfulRoutingDetail {
                    ProviderRoutingCockpit(provider: providerEnum, state: routingState, compact: true)
                }

                if let bucket = mostPressuredBucket {
                    QuotaBucketView(bucket: bucket)
                } else {
                    QuotaPlaceholderRow()
                }
            }
            .padding(MobileTheme.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                    .fill(MobileTheme.Colors.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                    .stroke(MobileTheme.Colors.border, lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(Text("Tap to see per-account quota detail."))
    }

    private var accountCountLabel: String {
        if accountCount == 0 { return "No accounts attributed" }
        return accountCount == 1 ? "1 account" : "\(accountCount) accounts"
    }

    private var storageScopes: [ProviderAccountStorageScope] {
        let scopes = snapshots.compactMap(\.accountStorageScope)
        // Preserve the natural priority order so chips read consistently.
        let order: [ProviderAccountStorageScope] = [
            .cloudRefreshable,
            .serverPrivate,
            .deviceKeychain,
            .localOnly
        ]
        var seen = Set<ProviderAccountStorageScope>()
        return order.filter { scope in
            if scopes.contains(scope) {
                seen.insert(scope).inserted
            } else {
                false
            }
        }
    }

    private var hasUrgentBucket: Bool {
        snapshots.flatMap(\.buckets).contains { bucket in
            guard bucket.limit > 0 else { return false }
            return max(0, bucket.remaining) / bucket.limit < 0.25
        }
    }

    private var primaryAccountName: String? {
        attributedSnapshots.first?.accountLabel ?? attributedSnapshots.first?.accountID
    }

    private var remainingAccountsLabel: String {
        let extra = max(attributedSnapshots.count - 1, 0)
        if extra == 0 { return "" }
        return ", +\(extra) more"
    }

    private var mostPressuredBucket: ProviderQuotaBucket? {
        snapshots
            .flatMap(\.buckets)
            .filter { $0.limit > 0 }
            .min {
                max(0, $0.remaining) / $0.limit < max(0, $1.remaining) / $1.limit
            } ?? snapshots.first?.buckets.first
    }

    private var accessibilityLabel: String {
        let name = providerEnum?.displayName ?? provider
        var parts: [String] = [name, accountCountLabel]
        if let routingState, let active = routingState.activeAccount {
            parts.append("active account \(active.accountLabel)")
        }
        if hasUrgentBucket { parts.append("quota under pressure") }
        if let bucket = mostPressuredBucket, bucket.limit > 0 {
            let pct = Int((max(0, bucket.remaining) / bucket.limit) * 100)
            parts.append("\(bucket.name) \(pct) percent remaining")
        }
        return parts.joined(separator: ", ")
    }

}

// MARK: - Quota Placeholder Row

private struct QuotaPlaceholderRow: View {
    var body: some View {
        HStack(spacing: MobileTheme.Spacing.sm) {
            Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(MobileTheme.Colors.textMuted)
            Text("No quota signal yet")
                .font(MobileTheme.Typography.footnote)
                .foregroundStyle(MobileTheme.Colors.textSecondary)
            Spacer()
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    NavigationStack {
        QuotaView()
    }
}
