import SwiftUI
import OpenBurnBarKernel

// MARK: - Home quota panel
//
// The lower half of the Home rail: how much is left, per provider, in whichever
// of four presentations the user picked.
//
// Every mode is pure assembly of components that already exist and are already
// proven at this width — `QuotaPrimaryBar` and friends ship in the 340pt menu
// bar popover. There is no new quota rendering code here, and there should not
// be: a second implementation of "draw a quota bar" is how two surfaces start
// disagreeing about what 18% looks like.
//
// Refresh follows `ProviderQuotaChip`, not `QuotaWorkspaceViewModel`: hold the
// `@Observable` service and let it drive redraw. The workspace view model needs
// six `.onChange` triggers to stay alive and recomputes a 30-day spend map per
// rebuild — far too much machinery for a rail.

struct DashboardHomeQuotaPanel: View {
    let dataStore: DataStore
    let settingsManager: SettingsManager
    let mode: DashboardHomeQuotaMode
    let ink: BackdropInk
    /// Tapping a row opens the full quota workspace.
    let onOpenQuota: () -> Void

    @State private var quotaService = ProviderQuotaService.shared
    @State private var providers: [AgentProvider] = []

    private var cumulative: Bool { settingsManager.cumulativeAcrossAccounts }

    var body: some View {
        Group {
            if providers.isEmpty {
                emptyState
            } else {
                ScrollView {
                    content
                        .padding(.horizontal, DesignSystem.Spacing.md)
                        .padding(.vertical, DesignSystem.Spacing.sm)
                }
            }
        }
        .task {
            await quotaService.refreshIfNeeded(dataStore: dataStore)
            providers = await quotaService.visiblePopoverProviders(dataStore: dataStore)
        }
        // The service is `@Observable`, so a refreshed snapshot redraws the
        // bars on its own. Only the *set* of visible providers needs recomputing
        // when the underlying data changes.
        .onChange(of: quotaService.lastFetch) { _, _ in
            Task { providers = await quotaService.visiblePopoverProviders(dataStore: dataStore) }
        }
        .accessibilityIdentifier(OBBAccessibilityID.dashboardHomeRailPanel("quota"))
    }

    // MARK: - Modes

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .bars:    barsMode
        case .windows: windowsMode
        case .dials:   dialsMode
        case .chips:   chipsMode
        }
    }

    private var barsMode: some View {
        VStack(spacing: DesignSystem.Spacing.xs) {
            ForEach(providers) { provider in
                row(provider) {
                    QuotaPrimaryBar(
                        bucket: snapshot(provider)?.primaryDisplayableBucket,
                        provider: provider,
                        isActive: quotaService.isRefreshing(provider)
                    )
                }
            }
        }
    }

    private var windowsMode: some View {
        VStack(spacing: DesignSystem.Spacing.sm) {
            ForEach(providers) { provider in
                let snap = snapshot(provider)
                row(provider) {
                    QuotaDualWindowStrip(
                        hourlyBucket: snap?.hourlyBucket,
                        weeklyBucket: snap?.weeklyBucket,
                        fallbackBucket: snap?.primaryDisplayableBucket,
                        provider: provider,
                        isActive: quotaService.isRefreshing(provider)
                    )
                }
            }
        }
    }

    private var dialsMode: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 108, maximum: 150), spacing: DesignSystem.Spacing.sm)],
            spacing: DesignSystem.Spacing.sm
        ) {
            ForEach(providers) { provider in
                let snap = snapshot(provider)
                Button(action: onOpenQuota) {
                    QuotaArcDial(
                        outer: snap?.weeklyBucket ?? snap?.primaryDisplayableBucket,
                        inner: snap?.hourlyBucket,
                        provider: provider,
                        diameter: 96
                    )
                }
                .buttonStyle(.plain)
                .help(provider.displayName)
            }
        }
    }

    private var chipsMode: some View {
        FlowLayout(horizontalSpacing: DesignSystem.Spacing.xs, verticalSpacing: DesignSystem.Spacing.xs) {
            ForEach(providers) { provider in
                Button(action: onOpenQuota) {
                    ProviderQuotaChip(provider: provider, style: .full)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Row chrome

    /// The popover's row anatomy: a tinted logo disc, then the bar.
    ///
    /// Copied in shape from `ProviderQuotaPopoverViews.quotaProviderRow` so the
    /// rail and the menu bar read as the same product.
    @ViewBuilder
    private func row<Content: View>(
        _ provider: AgentProvider,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Button(action: onOpenQuota) {
            HStack(alignment: .center, spacing: DesignSystem.Spacing.sm) {
                ZStack {
                    Circle()
                        .fill(ProviderTheme.theme(for: provider).primaryColor.opacity(0.16))
                        .frame(width: 26, height: 26)
                    ProviderLogoView(provider: provider, size: 15, useFallbackColor: false)
                }
                content()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(provider.displayName) — open the quota workspace")
    }

    private func snapshot(_ provider: AgentProvider) -> ProviderQuotaSnapshot? {
        quotaService.primaryDisplaySnapshot(for: provider, cumulative: cumulative)
    }

    // MARK: - Empty

    private var emptyState: some View {
        VStack(spacing: DesignSystem.Spacing.xs) {
            Image(systemName: "gauge.with.dots.needle.bottom.0percent")
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(ink.icon)
            Text("No quota signal yet")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(ink.secondary)
            Text("Connect an agent and its limits show up here.")
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(ink.subtle)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DesignSystem.Spacing.md)
    }
}
