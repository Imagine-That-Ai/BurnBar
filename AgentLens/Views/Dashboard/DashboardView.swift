import AppKit
import SwiftUI
import WebKit

struct DashboardView: View {
    let context: DashboardContext
    @Environment(NavigationCoordinator.self) var navigationCoordinator
    @AppStorage("dashboardViewMode") var storedViewMode: DashboardViewMode = .agents
    @State var navigationModel = DashboardNavigationModel()
    @State var consentCoordinator: DashboardConsentCoordinator?
    @State var showingSettings = false
    @State var showProgressPanel = false
    @State var overviewAppeared = false
    @State var sidebarAppeared = false
    @State var chatPanelOpen = false
    @State var sessionLogJumpTarget: ConversationJumpTarget?
    @State var dashboardCanvasSize: CGSize = .zero
    @State var showContextPackSheet = false

    init(context: DashboardContext) {
        self.context = context
        self._consentCoordinator = State(wrappedValue: DashboardConsentCoordinator(
            settingsManager: context.settingsManager,
            accountManager: context.accountManager
        ))
    }

    var isScanning: Bool { context.aggregator?.isRefreshing ?? false }
    var canRunRecount: Bool { context.aggregator != nil }

    var body: some View {
        let dataStore = context.dataStore
        let dateRange = navigationModel.selectedTimeRange.dateRange()
        let providerSummaries = dataStore.providerSummaries(in: dateRange)
        let modelSummaries = dataStore.modelSummaries(in: dateRange)
        let filteredUsages = dataStore.usages(in: dateRange)
        let totalCost = filteredUsages.reduce(0) { $0 + $1.cost }
        let totalTokens = filteredUsages.reduce(0) { $0 + $1.totalTokens }
        let activeProviderCount = Set(filteredUsages.map(\.provider)).count
        let topModels = providerSummaries.flatMap { s in
            s.modelBreakdown.map { (model: $0.modelName, provider: s.provider, cost: $0.cost, tokens: $0.totalTokens) }
        }.sorted { $0.cost > $1.cost }

        chrome(content:
            NavigationSplitView {
                DashboardSidebar(
                    viewMode: navigationModel.viewMode,
                    mainRoute: navigationModel.mainRoute,
                    providerSummaries: providerSummaries,
                    modelSummaries: modelSummaries,
                    totalCost: totalCost,
                    totalTokens: totalTokens,
                    filteredUsagesCount: filteredUsages.count,
                    activeProviderCount: activeProviderCount,
                    selectedTimeRange: navigationModel.selectedTimeRange,
                    context: context,
                    sidebarAppeared: sidebarAppeared,
                    onNavigate: { navigationModel.navigate(to: $0) },
                    onBack: { navigationModel.goBack() },
                    onOpenCursorExtension: { openBurnBarCursorExtension() }
                )
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 280)
                .background(DesignSystem.Colors.background)
            } detail: {
                DashboardDetailView(
                    mainRoute: navigationModel.mainRoute,
                    context: context,
                    selectedTimeRange: navigationModel.selectedTimeRange,
                    sessionLogJumpTarget: sessionLogJumpTarget,
                    providerSummaries: providerSummaries,
                    modelSummaries: modelSummaries,
                    topModels: topModels,
                    filteredUsages: filteredUsages,
                    overviewAppeared: overviewAppeared,
                    showProgressPanel: $showProgressPanel,
                    showContextPackSheet: $showContextPackSheet,
                    onNavigate: { navigationModel.navigate(to: $0) },
                    onOpenSessionLogs: { target in
                        sessionLogJumpTarget = target
                        if navigationModel.mainRoute != .sessionLogs {
                            navigationModel.navigate(to: .sessionLogs)
                        }
                    },
                    onOpenSettings: { showingSettings = true }
                )
            }
            .navigationSplitViewStyle(.balanced)
        )
    }
}
