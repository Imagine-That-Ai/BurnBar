import SwiftUI

struct DashboardDetailView: View {
    let mainRoute: DashboardMainRoute
    let context: DashboardContext
    let selectedTimeRange: TimeRange
    let sessionLogJumpTarget: ConversationJumpTarget?
    let providerSummaries: [ProviderSummary]
    let modelSummaries: [ModelSummary]
    let topModels: [(model: String, provider: AgentProvider, cost: Double, tokens: Int)]
    let usageWindow: DashboardUsageWindowSummary
    let overviewAppeared: Bool
    @Binding var showProgressPanel: Bool
    @Binding var showContextPackSheet: Bool
    let onNavigate: (DashboardMainRoute) -> Void
    let onOpenSessionLogs: (ConversationJumpTarget) -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        let dataStore = context.dataStore
        let settingsManager = context.settingsManager
        let accountManager = context.accountManager
        let cloudSyncService = context.cloudSyncService
        let chatController = context.chatController
        let operatingLayer = context.operatingLayer
        let aggregator = context.aggregator
        let iCloudSessionMirrorService = context.iCloudSessionMirrorService

        VStack(spacing: 0) {
            EmptyView()

            Group {
                switch mainRoute {
                case .overview:
                    DashboardOverviewView(
                        providerSummaries: providerSummaries,
                        modelSummaries: modelSummaries,
                        topModels: topModels,
                        usageWindow: usageWindow,
                        context: context,
                        selectedTimeRange: selectedTimeRange,
                        overviewAppeared: overviewAppeared,
                        onNavigate: onNavigate,
                        onOpenSettings: onOpenSettings
                    )
                case .insights:
                    InsightsWorkspaceView(
                        dataStore: dataStore,
                        settingsManager: settingsManager,
                        chatController: chatController
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .database:
                    DatabaseWorkspaceView(
                        dataStore: dataStore,
                        settingsManager: settingsManager,
                        accountManager: accountManager,
                        cloudSyncService: cloudSyncService
                    )
                case .projects:
                    ProjectsView(
                        dataStore: dataStore,
                        settingsManager: settingsManager,
                        operatingLayer: operatingLayer,
                        chatController: chatController
                    )
                case .missions:
                    MissionsLaneView(
                        operatingLayer: operatingLayer,
                        onOpenSessionLogs: {
                            withAnimation(DesignSystem.Animation.standard) {
                                onNavigate(.sessionLogs)
                            }
                        }
                    )
                case .sessionLogs:
                    SessionLogsView(
                        dataStore: dataStore,
                        accountManager: accountManager,
                        settingsManager: settingsManager,
                        operatingLayer: operatingLayer,
                        cloudSyncService: cloudSyncService,
                        iCloudMirrorService: iCloudSessionMirrorService,
                        jumpTarget: sessionLogJumpTarget,
                        preferredChatModelKey: chatController.hermesModelName
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .chat:
                    DashboardChatWorkspaceView(
                        controller: chatController,
                        dataStore: dataStore,
                        settingsManager: settingsManager,
                        sharedFeaturesAvailable: accountManager.isSignedIn,
                        mode: .embedded,
                        onOpenConversationJump: onOpenSessionLogs,
                        onPopOut: {
                            WindowManager.shared.openChatPopOutWindow(
                                controller: chatController,
                                dataStore: dataStore,
                                settingsManager: settingsManager,
                                accountManager: accountManager
                            )
                        },
                        onRestoreFloating: {
                            UserDefaults.standard.set(false, forKey: "dashboardChatPreferMaximized")
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                                onNavigate(.overview)
                            }
                        }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .provider(let provider):
                    ProviderDashboardView(
                        provider: provider,
                        dataStore: dataStore,
                        timeRange: selectedTimeRange,
                        onOpenSessionLog: onOpenSessionLogs
                    )
                case .model(let modelName):
                    ModelDashboardView(
                        modelName: modelName,
                        dataStore: dataStore,
                        timeRange: selectedTimeRange,
                        onOpenSessionLog: onOpenSessionLogs
                    )
                }
            }
            .id(mainRoute)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let agg = aggregator, agg.isSummarizing {
                SummarizingStatusStrip(
                    done: agg.summaryProgressDone,
                    total: agg.summaryProgressTotal,
                    currentTitle: agg.summaryCurrentTitle,
                    completedProviders: Array(Set(agg.summaryQueue.compactMap(\.provider))).sorted(),
                    onTap: { showProgressPanel = true }
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(DesignSystem.Animation.standard, value: aggregator?.isSummarizing)
        .sheet(isPresented: $showProgressPanel) {
            if let agg = aggregator {
                SummaryProgressPanel(aggregator: agg)
            }
        }
        .sheet(isPresented: $showContextPackSheet) {
            ContextPackSheet(
                dataStore: dataStore,
                anchorSessionId: nil,
                anchorProject: nil,
                dateRange: selectedTimeRange.dateRange()
            )
        }
    }
}
