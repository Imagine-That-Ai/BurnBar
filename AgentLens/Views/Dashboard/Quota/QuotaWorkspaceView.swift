import SwiftUI
import OpenBurnBarCore

#if canImport(AppKit)
import AppKit
#endif

// MARK: - QuotaWorkspaceView
//
// Top-level page for the "Subscription Vault". Composes the constellation
// hero, the filter rail, the per-plan cards (or list rows), the reset atlas,
// and the setup suggestions strip.
//
// A click on any hero orb pivots the workspace to focus that provider: the
// entries grid, reset atlas, and aggregate summaries all collapse to only
// that provider's accounts. Clicking the same orb again — or the inline
// "Show all providers" affordance — restores the full view.

struct QuotaWorkspaceView: View {
    @Bindable var dataStore: DataStore
    @Bindable var quotaService: ProviderQuotaService
    @Bindable var settingsManager: SettingsManager
    var onOpenConnections: () -> Void = {}

    @State private var viewModel = QuotaWorkspaceViewModel()
    @State private var selectedProvider: AgentProvider?
    @AppStorage("quotaTab.sort") private var sortStorage: QuotaSortMode = .urgency
    @AppStorage("quotaTab.viewMode") private var viewModeStorage: QuotaViewMode = .cards
    @AppStorage("quotaTab.showInactive") private var showInactiveStorage: Bool = false

    private var providerSpendByID: [ProviderID: Double] {
        let summaries = dataStore.usageWindowSummary(for: .last30Days).providerSummaries
        var dict: [ProviderID: Double] = [:]
        for summary in summaries {
            dict[summary.provider.providerID] = summary.totalCost
        }
        return dict
    }

    /// Entries shown in the grid + atlas + summary. Honors the orb-driven
    /// provider focus when one is set.
    private var displayedEntries: [SubscriptionEntry] {
        guard let selected = selectedProvider else { return viewModel.entries }
        return viewModel.entries.filter { $0.provider == selected }
    }

    /// Total distinct providers represented in the unfiltered set — used by
    /// the hero so its summary readouts stay accurate while focused.
    private var totalProviderCount: Int {
        Set(viewModel.entries.map(\.provider)).count
    }

    private var displayedSummary: QuotaWorkspaceViewModel.AggregateSummary {
        QuotaWorkspaceViewModel.aggregate(displayedEntries)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DesignSystem.Spacing.lg, pinnedViews: []) {
                if viewModel.entries.isEmpty && !showInactiveStorage {
                    QuotaEmptyState(onOpenConnections: onOpenConnections)
                        .frame(minHeight: 460)
                } else {
                    SubscriptionConstellationHero(
                        entries: viewModel.entries,
                        summary: displayedSummary,
                        selectedProvider: selectedProvider,
                        totalProviderCount: totalProviderCount,
                        onOrbTap: { provider in
                            withAnimation(DesignSystem.Animation.gentle) {
                                if selectedProvider == provider {
                                    selectedProvider = nil
                                } else {
                                    selectedProvider = provider
                                }
                            }
                        },
                        onClearSelection: {
                            withAnimation(DesignSystem.Animation.gentle) {
                                selectedProvider = nil
                            }
                        }
                    )

                    QuotaFilterRail(
                        viewMode: $viewModeStorage,
                        sort: $sortStorage,
                        showInactive: $showInactiveStorage,
                        isRefreshing: quotaService.isFetching,
                        onRefreshAll: { Task { await quotaService.refreshAll(dataStore: dataStore) } }
                    )

                    if let selected = selectedProvider {
                        providerFocusBanner(selected)
                            .transition(.asymmetric(
                                insertion: .move(edge: .top).combined(with: .opacity),
                                removal: .opacity
                            ))
                    }

                    activeEntriesSection

                    if !displayedEntries.isEmpty {
                        QuotaResetAtlas(entries: displayedEntries)
                    }

                    if showInactiveStorage, !viewModel.setupSlots.isEmpty, selectedProvider == nil {
                        QuotaSetupSuggestionsStrip(
                            slots: viewModel.setupSlots,
                            onOpenConnections: onOpenConnections
                        )
                    } else if !viewModel.entries.isEmpty, !viewModel.setupSlots.isEmpty, selectedProvider == nil {
                        compactSetupHint
                    }
                }
            }
            .padding(.bottom, DesignSystem.Spacing.xxl)
        }
        .scrollContentBackground(.hidden)
        .background {
            ZStack {
                DesignSystem.Colors.background
                LinearGradient(
                    colors: [
                        DesignSystem.Colors.ember.opacity(0.03),
                        Color.clear,
                        DesignSystem.Colors.amber.opacity(0.02)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
            .ignoresSafeArea()
        }
        .onAppear {
            viewModel.sort = sortStorage
            viewModel.viewMode = viewModeStorage
            viewModel.showInactive = showInactiveStorage
            rebuild()
            Task { await quotaService.refreshIfNeeded(dataStore: dataStore) }
        }
        .onChange(of: sortStorage) { _, newSort in
            viewModel.sort = newSort
            rebuild()
        }
        .onChange(of: viewModeStorage) { _, newMode in
            viewModel.viewMode = newMode
        }
        .onChange(of: showInactiveStorage) { _, newValue in
            viewModel.showInactive = newValue
            rebuild()
        }
        .onChange(of: quotaService.lastFetch) { _, _ in rebuild() }
        .onChange(of: quotaService.snapshotsByProvider) { _, _ in rebuild() }
        .onChange(of: quotaService.snapshotsByAccountID) { _, _ in rebuild() }
        .onChange(of: viewModel.entries) { _, newEntries in
            // If the selected provider's snapshots vanish (e.g. service is
            // disconnected), drop the focus so the user isn't stranded on an
            // empty page.
            if let selected = selectedProvider,
               !newEntries.contains(where: { $0.provider == selected }) {
                selectedProvider = nil
            }
        }
    }

    @ViewBuilder
    private var activeEntriesSection: some View {
        if displayedEntries.isEmpty && selectedProvider != nil {
            providerEmptyFocusState
        } else if viewModel.entries.isEmpty {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                Text("NO ACTIVE PLANS · SHOWING UNCONFIGURED PROVIDERS")
                    .font(DesignSystem.Typography.monoTiny)
                    .tracking(1.0)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                Text("Connect any of the providers below to start tracking quota.")
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
            .padding(.horizontal, DesignSystem.Spacing.lg)
        } else {
            switch viewModeStorage {
            case .cards:
                LazyVGrid(
                    columns: [
                        GridItem(
                            .adaptive(minimum: 360, maximum: 460),
                            spacing: DesignSystem.Spacing.lg,
                            alignment: .top
                        )
                    ],
                    alignment: .leading,
                    spacing: DesignSystem.Spacing.lg
                ) {
                    ForEach(displayedEntries) { entry in
                        SubscriptionCard(
                            entry: entry,
                            onRefresh: {
                                Task { await quotaService.refresh(provider: entry.provider, dataStore: dataStore) }
                            }
                        )
                    }
                }
                .padding(.horizontal, DesignSystem.Spacing.lg)
            case .list:
                VStack(spacing: DesignSystem.Spacing.sm) {
                    ForEach(displayedEntries) { entry in
                        SubscriptionListRow(
                            entry: entry,
                            onRefresh: {
                                Task { await quotaService.refresh(provider: entry.provider, dataStore: dataStore) }
                            }
                        )
                    }
                }
                .padding(.horizontal, DesignSystem.Spacing.lg)
            }
        }
    }

    private func providerFocusBanner(_ provider: AgentProvider) -> some View {
        let theme = ProviderTheme.theme(for: provider)
        let accountCount = displayedEntries.count
        let accountWord = accountCount == 1 ? "account" : "accounts"
        return HStack(spacing: DesignSystem.Spacing.sm) {
            ProviderLogoView(provider: provider, size: 14, useFallbackColor: false)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text("FOCUSED")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .tracking(0.9)
                        .foregroundStyle(theme.primaryColor)
                    Text("·")
                        .font(DesignSystem.Typography.monoTiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                    Text(provider.displayName)
                        .font(DesignSystem.Typography.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                }
                Text("\(accountCount) \(accountWord) · \(totalProviderCount - 1) other provider\(totalProviderCount - 1 == 1 ? "" : "s") hidden")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }

            Spacer()

            Button {
                withAnimation(DesignSystem.Animation.gentle) {
                    selectedProvider = nil
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                    Text("Show all")
                        .font(DesignSystem.Typography.caption)
                }
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule(style: .continuous)
                        .fill(DesignSystem.Colors.surface.opacity(0.55))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(DesignSystem.Colors.border.opacity(0.55), lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
            .help("Show every provider")
        }
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, DesignSystem.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .fill(theme.primaryColor.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .stroke(theme.primaryColor.opacity(0.30), lineWidth: 0.75)
        )
        .padding(.horizontal, DesignSystem.Spacing.lg)
    }

    private var providerEmptyFocusState: some View {
        VStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(DesignSystem.Colors.textMuted)
            Text("No accounts found for the focused provider.")
                .font(DesignSystem.Typography.body)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            Button("Show all providers") {
                withAnimation(DesignSystem.Animation.gentle) {
                    selectedProvider = nil
                }
            }
            .buttonStyle(.borderless)
            .foregroundStyle(DesignSystem.Colors.ember)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DesignSystem.Spacing.xl)
    }

    private var compactSetupHint: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "plus.circle.dashed")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.textMuted)
            Text("\(viewModel.setupSlots.count) more provider\(viewModel.setupSlots.count == 1 ? "" : "s") available — toggle \"Inactive plans\" to see setup hints.")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textMuted)
            Spacer()
            Button("Show") {
                showInactiveStorage = true
            }
            .font(DesignSystem.Typography.caption)
            .buttonStyle(.plain)
            .foregroundStyle(DesignSystem.Colors.ember)
        }
        .padding(.horizontal, DesignSystem.Spacing.lg)
        .padding(.vertical, DesignSystem.Spacing.sm)
    }

    private func rebuild() {
        viewModel.rebuild(
            quotaService: quotaService,
            dataStore: dataStore,
            providerSpendByID: providerSpendByID
        )
    }
}
