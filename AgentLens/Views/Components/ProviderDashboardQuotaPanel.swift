import SwiftUI
import OpenBurnBarCore

#if canImport(AppKit)
import AppKit
#endif

struct ProviderDashboardQuotaPanel: View {
    let provider: AgentProvider
    @Bindable var quotaService: ProviderQuotaService
    let dataStore: DataStore
    @Environment(SettingsManager.self) private var settingsManager

    @State private var selectedSourceID: String?
    @State private var profileIndex = QuotaWorkspaceProfileIndex()

    private var snapshot: ProviderQuotaSnapshot? {
        quotaService.snapshot(for: provider)
    }

    /// The exact account set the Quota workspace renders, so a provider's
    /// detail page and the Quota tab never disagree about which accounts
    /// exist. Going through `displaySnapshots(for:cumulative:)` +
    /// `filteredDisplaySnapshots` buys three things this panel used to miss:
    /// the `cumulativeAcrossAccounts` toggle, the synthetic "Current <CLI>
    /// login" account, and the default-config / current-CLI coalescing.
    private var accountSnapshots: [ProviderQuotaSnapshot] {
        QuotaWorkspaceViewModel.filteredDisplaySnapshots(
            quotaService.displaySnapshots(
                for: provider,
                cumulative: settingsManager.cumulativeAcrossAccounts
            ),
            profileIndex: profileIndex
        )
    }

    private var hasMultipleAccounts: Bool {
        accountSnapshots.count > 1
    }

    private var activeSnapshot: ProviderQuotaSnapshot? {
        if let selectedSourceID,
           let match = accountSnapshots.first(where: { $0.sourceID == selectedSourceID }) {
            return match
        }
        return accountSnapshots.first ?? snapshot
    }

    private var routingState: ProviderRoutingStateSnapshot? {
        quotaService.routingStatesByProviderID[provider.providerID]
    }

    private var isRefreshing: Bool {
        quotaService.isRefreshing(provider)
    }

    var body: some View {
        if ProviderQuotaService.supportedProviders.contains(provider) {
            GlassCard {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                    headerRow

                    if let routingState, routingState.hasMeaningfulRoutingDetail {
                        ProviderRoutingCockpit(provider: provider, state: routingState)
                    }

                    if hasMultipleAccounts {
                        accountPicker
                    } else if let only = accountSnapshots.first {
                        accountIdentityStrip(snapshot: only)
                    }

                    if let active = activeSnapshot, active.hasDisplayableQuotaSignal {
                        VStack(spacing: DesignSystem.Spacing.md) {
                            ForEach(active.customizedBuckets(
                                hiddenBuckets: settingsManager.quotas.hiddenBuckets,
                                bucketOrders: settingsManager.quotas.bucketOrders
                            )) { bucket in
                                ProviderQuotaBucketRow(bucket: bucket, provider: provider)
                            }
                        }
                    } else {
                        QuotaStatusCallout(
                            provider: provider,
                            title: isRefreshing
                                ? "Gathering live quota"
                                : (quotaService.errors[provider] != nil ? "Could not refresh quota" : "Quota signal not ready"),
                            message: quotaService.errors[provider]
                                ?? activeSnapshot?.statusMessage
                                ?? snapshot?.statusMessage
                                ?? "No quota snapshot yet.",
                            isActive: isRefreshing,
                            isWarning: quotaService.errors[provider] != nil
                        )
                    }

                    HStack(spacing: DesignSystem.Spacing.md) {
                        Text(snapshotFreshness)
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(
                                (activeSnapshot?.isStale() ?? snapshot?.isStale() ?? false)
                                    ? DesignSystem.Colors.warning
                                    : DesignSystem.Colors.textMuted
                            )

                        Spacer()

                        if let url = providerQuotaManagementURL(for: provider, snapshot: activeSnapshot ?? snapshot) {
                            Button("Open official quota") {
                                open(url: url)
                            }
                            .buttonStyle(.link)
                        }
                    }
                }
                .padding(DesignSystem.Spacing.lg)
            }
            .task {
                await quotaService.refreshRoutingState(
                    dataStore: dataStore,
                    request: ProviderRoutingRequest(
                        preferredProviderIDs: [provider.providerID],
                        routerMode: OpenBurnBarDaemonManager.shared.routerMode,
                        selectedProviderID: provider.providerID,
                        taskCategory: .coding
                    )
                )
                await quotaService.refreshIfNeeded(dataStore: dataStore)
                profileIndex = QuotaWorkspaceProfileIndex(
                    profiles: (try? dataStore.switcherStore.fetchAllProfiles()) ?? [],
                    homeDirectoryURL: quotaService.quotaHomeDirectoryURL
                )
            }
            .onChange(of: accountSnapshots.map(\.sourceID)) { _, ids in
                if let selectedSourceID, !ids.contains(selectedSourceID) {
                    self.selectedSourceID = nil
                }
            }
        }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    Text("Quota")
                        .font(DesignSystem.Typography.headline)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)

                    if hasMultipleAccounts {
                        Text("\(accountSnapshots.count) accounts")
                            .font(DesignSystem.Typography.tiny)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(DesignSystem.Colors.surfaceElevated)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                            .clipShape(Capsule())
                    }
                }

                Text(headerSubtitle)
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: DesignSystem.Spacing.xs) {
                if isRefreshing {
                    ProviderQuotaActivityBadge(provider: provider)
                }

                if let active = activeSnapshot ?? snapshot {
                    QuotaSourceBadge(source: active.sourceKind, confidence: active.confidence)
                }
            }
        }
    }

    private var headerSubtitle: String {
        if hasMultipleAccounts {
            return "Per-account quota — select an account to see its bucket detail."
        }
        return activeSnapshot?.summaryText ?? snapshot?.summaryText ?? "Checking current quota…"
    }

    // MARK: - Account picker (multi-account)

    private var accountPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                ForEach(accountSnapshots, id: \.sourceID) { snap in
                    accountChip(snap: snap)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func accountChip(snap: ProviderQuotaSnapshot) -> some View {
        let isSelected = (selectedSourceID ?? accountSnapshots.first?.sourceID) == snap.sourceID
        let label = ProviderQuotaAccountDisplay.label(for: snap, provider: provider)
        return Button {
            selectedSourceID = snap.sourceID
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(snap.isStale() ? DesignSystem.Colors.warning : DesignSystem.Colors.success)
                    .frame(width: 6, height: 6)
                Text(label)
                    .font(DesignSystem.Typography.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let scope = snap.accountStorageScope {
                    Image(systemName: ProviderAccountStorage.iconName(scope))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(ProviderAccountStorage.tint(scope))
                }
            }
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.vertical, DesignSystem.Spacing.xs)
            .background(
                Capsule()
                    .fill(isSelected ? DesignSystem.Colors.surfaceElevated : DesignSystem.Colors.surface.opacity(0.45))
            )
            .overlay(
                Capsule()
                    .stroke(isSelected ? DesignSystem.Colors.whimsy.opacity(0.6) : DesignSystem.Colors.border.opacity(0.45), lineWidth: isSelected ? 1.0 : 0.5)
            )
            .foregroundStyle(isSelected ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textSecondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label), \(snap.accountStorageScope.map { ProviderAccountStorage.label($0) } ?? "")")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // MARK: - Single-account identity strip

    private func accountIdentityStrip(snapshot: ProviderQuotaSnapshot) -> some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: ProviderQuotaAccountDisplay.isMerged(snapshot) ? "square.stack.3d.up" : "person.crop.circle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.textMuted)
            Text(ProviderQuotaAccountDisplay.label(for: snapshot, provider: provider))
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            // The merged snapshot's `.cloudRefreshable` scope is an artifact of
            // the synthetic envelope, not where any real credential lives.
            if let scope = snapshot.accountStorageScope, !ProviderQuotaAccountDisplay.isMerged(snapshot) {
                ProviderAccountStorageChip(scope: scope, compact: true)
            }
            Spacer()
        }
    }

    private var snapshotFreshness: String {
        guard let active = activeSnapshot ?? snapshot else { return "No snapshot yet" }
        let prefix = active.isStale() ? "Stale" : "Updated"
        return "\(prefix) \(active.fetchedAt.formatted(date: .abbreviated, time: .shortened))"
    }

    private func open(url: URL) {
        #if canImport(AppKit)
        NSWorkspace.shared.open(url)
        #endif
    }
}

// `ProviderRoutingCockpit` lives in
// `Views/Components/ProviderAccount/ProviderRoutingCockpit.swift` so the
// Settings, Dashboard, and Popover surfaces all read the same routing lanes.
