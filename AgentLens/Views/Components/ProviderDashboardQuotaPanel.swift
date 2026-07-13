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

    @State private var selectedAccountID: String?

    private var theme: ProviderTheme { ProviderTheme.theme(for: provider) }

    private var snapshot: ProviderQuotaSnapshot? {
        quotaService.snapshot(for: provider)
    }

    private var accountSnapshots: [ProviderQuotaSnapshot] {
        // The per-account list intentionally drops the provider-level rollup
        // so the picker doesn't double-count accounts that already have a
        // dedicated snapshot.
        quotaService.snapshots(for: provider).filter { $0.accountID != nil }
    }

    private var hasMultipleAccounts: Bool {
        accountSnapshots.count > 1
    }

    private var activeSnapshot: ProviderQuotaSnapshot? {
        if let selectedAccountID,
           let match = accountSnapshots.first(where: { $0.accountID == selectedAccountID }) {
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
            DetailLiquidGlassSurface(accent: theme.primaryColor) {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xl) {
                    headerRow

                    if let routingState, routingState.hasMeaningfulRoutingDetail {
                        ProviderRoutingCockpit(
                            provider: provider,
                            state: routingState,
                            compact: true
                        )
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
                        quotaEmptyState
                    }

                    Divider()
                        .overlay(Color.white.opacity(0.08))

                    HStack(spacing: DesignSystem.Spacing.md) {
                        HStack(spacing: 7) {
                            Circle()
                                .fill(freshnessColor)
                                .frame(width: 6, height: 6)

                            Text(snapshotFreshness)
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .tracking(0.8)
                                .foregroundStyle(freshnessColor)
                        }
                        .accessibilityElement(children: .combine)

                        Spacer()

                        if let url = providerQuotaManagementURL(for: provider, snapshot: activeSnapshot ?? snapshot) {
                            Button {
                                open(url: url)
                            } label: {
                                Label("Official quota", systemImage: "arrow.up.right")
                            }
                            .buttonStyle(DetailGlassActionButtonStyle(accent: theme.primaryColor))
                            .accessibilityHint("Opens the provider quota page")
                        }
                    }
                }
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
            }
            .onChange(of: accountSnapshots.map(\.accountID)) { _, ids in
                if let selectedAccountID, !ids.contains(selectedAccountID) {
                    self.selectedAccountID = nil
                }
            }
        }
    }

    // MARK: - Header

    private var quotaEmptyState: some View {
        HStack(spacing: DesignSystem.Spacing.lg) {
            ZStack {
                Circle()
                    .fill((quotaService.errors[provider] == nil
                        ? theme.primaryColor
                        : DesignSystem.Colors.warning).opacity(0.12))
                    .frame(width: 44, height: 44)

                if isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .tint(theme.primaryColor)
                } else {
                    Image(systemName: quotaService.errors[provider] == nil
                        ? "waveform.path.ecg"
                        : "exclamationmark.triangle.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(quotaService.errors[provider] == nil
                            ? theme.primaryColor
                            : DesignSystem.Colors.warning)
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(isRefreshing
                    ? "Gathering live quota"
                    : (quotaService.errors[provider] != nil
                        ? "Could not refresh quota"
                        : "Waiting for quota signal"))
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)

                Text(
                    quotaService.errors[provider]
                        ?? activeSnapshot?.statusMessage
                        ?? snapshot?.statusMessage
                        ?? "Connect a supported plan or provider key to monitor remaining capacity."
                )
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(3)
            }

            Spacer(minLength: DesignSystem.Spacing.lg)

            Text(isRefreshing ? "SYNCING" : "NO SIGNAL")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(1.2)
                .foregroundStyle(isRefreshing ? theme.primaryColor : DesignSystem.Colors.textMuted)
        }
        .padding(.vertical, DesignSystem.Spacing.sm)
        .accessibilityElement(children: .combine)
    }

    private var freshnessColor: Color {
        (activeSnapshot?.isStale() ?? snapshot?.isStale() ?? false)
            ? DesignSystem.Colors.warning
            : DesignSystem.Colors.textMuted
    }

    private var headerRow: some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.lg) {
            DetailSectionHeader(
                eyebrow: "Capacity",
                title: "Quota & routing",
                subtitle: headerSubtitle,
                accent: theme.primaryColor
            )

            Spacer(minLength: DesignSystem.Spacing.md)

            VStack(alignment: .trailing, spacing: DesignSystem.Spacing.xs) {
                if isRefreshing {
                    ProviderQuotaActivityBadge(provider: provider)
                }

                if let active = activeSnapshot ?? snapshot {
                    QuotaSourceBadge(source: active.sourceKind, confidence: active.confidence)
                } else if hasMultipleAccounts {
                    Text("\(accountSnapshots.count) accounts")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
            }
            .padding(.top, 2)
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
        let isSelected = (selectedAccountID ?? accountSnapshots.first?.accountID) == snap.accountID
        let label = snap.accountLabel ?? snap.accountID ?? "Account"
        return Button {
            selectedAccountID = snap.accountID
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
            Image(systemName: "person.crop.circle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.textMuted)
            Text(snapshot.accountLabel ?? snapshot.accountID ?? "Account")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let scope = snapshot.accountStorageScope {
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
