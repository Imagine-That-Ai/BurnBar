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

struct QuotaWorkspaceView: View {
    @Bindable var dataStore: DataStore
    @Bindable var quotaService: ProviderQuotaService
    @Bindable var settingsManager: SettingsManager
    var onOpenConnections: () -> Void = {}

    @State private var viewModel = QuotaWorkspaceViewModel()
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

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DesignSystem.Spacing.lg, pinnedViews: []) {
                if viewModel.entries.isEmpty && !showInactiveStorage {
                    QuotaEmptyState(onOpenConnections: onOpenConnections)
                        .frame(minHeight: 460)
                } else {
                    SubscriptionConstellationHero(
                        entries: viewModel.entries,
                        summary: viewModel.aggregateSummary(),
                        onOrbTap: { _ in }
                    )

                    QuotaFilterRail(
                        viewMode: $viewModeStorage,
                        sort: $sortStorage,
                        showInactive: $showInactiveStorage,
                        isRefreshing: quotaService.isFetching,
                        onRefreshAll: { Task { await quotaService.refreshAll(dataStore: dataStore) } }
                    )

                    activeEntriesSection

                    if !viewModel.entries.isEmpty {
                        QuotaResetAtlas(entries: viewModel.entries)
                    }

                    if showInactiveStorage, !viewModel.setupSlots.isEmpty {
                        QuotaSetupSuggestionsStrip(
                            slots: viewModel.setupSlots,
                            onOpenConnections: onOpenConnections
                        )
                    } else if viewModel.entries.isEmpty == false, !viewModel.setupSlots.isEmpty {
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
    }

    @ViewBuilder
    private var activeEntriesSection: some View {
        if viewModel.entries.isEmpty {
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
                    ForEach(viewModel.entries) { entry in
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
                    ForEach(viewModel.entries) { entry in
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
