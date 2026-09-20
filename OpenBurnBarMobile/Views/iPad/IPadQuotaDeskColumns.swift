import SwiftUI
import OpenBurnBarCore

/// Quota decision rail: urgency-sorted provider cards, not the full-bleed
/// Burn collage stretched across the canvas.
struct IPadQuotaRail: View {
    let quotaStore: QuotaStore
    @Binding var selectedProvider: String?
    var searchQuery: String = ""

    private var providers: [String] {
        let ordered = quotaStore.urgentProviders + quotaStore.healthyProviders
        let unique = ordered.reduce(into: [String]()) { acc, key in
            if !acc.contains(key) { acc.append(key) }
        }
        let keys = unique.isEmpty ? quotaStore.visibleProviders : unique
        return IPadAwayDeskNavigation.filteredProviderKeys(keys, query: searchQuery)
    }

    var body: some View {
        Group {
            if quotaStore.snapshots.isEmpty && quotaStore.isLoading {
                ContentUnavailableView {
                    Label("Loading quota", systemImage: "gauge.with.dots.needle.bottom.50percent")
                }
            } else if providers.isEmpty {
                ContentUnavailableView(
                    "No providers",
                    systemImage: "gauge.with.dots.needle.bottom.50percent",
                    description: Text("Connect a provider on the Mac, then pull to refresh.")
                )
            } else {
                List {
                    ForEach(providers, id: \.self) { provider in
                        Button {
                            selectedProvider = provider
                            HapticBus.tabChange()
                        } label: {
                            IPadQuotaProviderRow(
                                provider: provider,
                                accountCount: quotaStore.accountCount(for: provider),
                                isUrgent: quotaStore.urgentProviders.contains(provider),
                                isSelected: selectedProvider == provider
                            )
                        }
                        .buttonStyle(.plain)
                        .hoverEffect(.highlight)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .accessibilityIdentifier("ipad.quota.provider.\(provider)")
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle("Quota")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("ipad.quota.rail")
        .refreshable {
            HapticBus.refreshStarted()
            await quotaStore.load()
            HapticBus.refreshFinished()
        }
        .task {
            await quotaStore.loadIfNeeded()
            if selectedProvider == nil {
                selectedProvider = providers.first
            }
        }
    }
}

struct IPadQuotaCanvas: View {
    let quotaStore: QuotaStore
    let selectedProvider: String?

    var body: some View {
        NavigationStack {
            Group {
                if let provider = selectedProvider {
                    QuotaDetailSheet(
                        provider: provider,
                        snapshots: quotaStore.sortedSnapshots(for: provider),
                        routingState: quotaStore.routingState(for: ProviderID(rawValue: provider)),
                        onRefresh: {
                            await quotaStore.refreshAllAccounts(for: ProviderID(rawValue: provider))
                        }
                    )
                    .id(provider)
                } else {
                    ContentUnavailableView(
                        "Select a provider",
                        systemImage: "gauge.with.dots.needle.bottom.50percent",
                        description: Text("Headroom and reset times for the selected account.")
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("ipad.quota.canvas")
        }
    }
}

private struct IPadQuotaProviderRow: View {
    let provider: String
    let accountCount: Int
    let isUrgent: Bool
    let isSelected: Bool

    @State private var isHovered = false

    private var displayName: String {
        AgentProvider.fromProviderID(ProviderID(rawValue: provider))?.displayName ?? provider
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(displayName)
                    .font(MobileTheme.Typography.body)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                Text(accountCount == 1 ? "1 account" : "\(accountCount) accounts")
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
            }
            Spacer()
            if isUrgent {
                Text("Tight")
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.ember)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(MobileTheme.ember.opacity(0.14)))
            }
            if isSelected {
                Circle()
                    .fill(MobileTheme.ember)
                    .frame(width: 7, height: 7)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .iPadDeskRowBackground(isSelected: isSelected, isHovered: isHovered)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }

}
