import SwiftUI

struct DashboardDetailView: View {
    /// The inbox shelf (pins, tags, categories, manual order).
    ///
    /// Held here rather than as a global because the models below are rebuilt
    /// on every body evaluation, and the shelf coalesces its writes on a timer:
    /// a store discarded mid-debounce loses the write. `@State` gives it a
    /// lifetime tied to this view instead of to the process.
    @State private var inboxShelf = InboxShelfStore()
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
                case .recap:
                    RecapPageView(
                        dataStore: dataStore,
                        settingsManager: settingsManager,
                        chatController: chatController
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .charts:
                    ChartsPageDetailHost(
                        context: context,
                        selectedTimeRange: selectedTimeRange
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
                case .receipts:
                    ReceiptDrawerView(dataStore: dataStore)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .memoryReview:
                    // Parallel/legacy detail surface (not on the live `DashboardView`
                    // path, which wires the inbox to the shared `ControlPlaneStore`).
                    // This context carries no memory store, so render the graceful
                    // unavailable state to keep the route exhaustive.
                    ContentUnavailableView(
                        "Memory is unavailable",
                        systemImage: "brain.head.profile",
                        description: Text("Open Memory from the main dashboard to review extracted memories.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .home:
                    // Parallel/legacy detail surface. Home needs the fleet model,
                    // the quota service and the chat controller for presence —
                    // none of which this context carries — so render the graceful
                    // unavailable state rather than a half-wired rail, the same
                    // choice `.memoryReview` and `.controlDeck` make.
                    ContentUnavailableView(
                        "Home is unavailable",
                        systemImage: "house",
                        description: Text("Open the main dashboard to see your inbox, fleet, and quota.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .fleet:
                    ContentUnavailableView(
                        "Fleet is unavailable",
                        systemImage: "rectangle.3.group",
                        description: Text("Open Fleet from the main dashboard.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .controlDeck:
                    // Parallel/legacy detail surface. The Control Deck needs the
                    // daemon manager and the deck model, which this context does
                    // not carry, so render the graceful unavailable state rather
                    // than a half-wired deck — the same choice `.memoryReview`
                    // makes above.
                    ContentUnavailableView(
                        "The Control Deck is unavailable",
                        systemImage: "slider.horizontal.below.square.filled.and.square",
                        description: Text("Open the Control Deck from the main dashboard.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .inbox:
                    // Unlike memory review, the inbox needs only `DataStore`,
                    // which this context has — so it renders fully here.
                    // Memory approval is omitted (no memory store in scope), and
                    // the detail view degrades to read-only proposals.
                    InboxView(
                        model: InboxModel(
                            loadRows: { [dataStore] states in
                                try await dataStore.fetchAIInboxRows(states: states)
                            },
                            loadMarker: { [dataStore] in try await dataStore.aiInboxChangeMarker() },
                            markRead: { [dataStore] id in try await dataStore.markAIInboxItemRead(id: id) },
                            markUnread: { [dataStore] id in try await dataStore.markAIInboxItemUnread(id: id) },
                            setArchived: { [dataStore] id, archived in
                                try await dataStore.setAIInboxItemArchived(id: id, archived: archived)
                            },
                            snooze: { [dataStore] id, until in
                                try await dataStore.snoozeAIInboxItem(id: id, until: until)
                            },
                            setFeedback: { [dataStore] id, feedback in
                                try await dataStore.setAIInboxItemFeedback(id: id, feedback: feedback)
                            },
                            markAllRead: { [dataStore] in try await dataStore.markAllAIInboxItemsRead() },
                            loadRuns: { [dataStore] in try await dataStore.fetchAIInboxRuns() },
                            shelf: inboxShelf
                        ),
                        onOpenSessionLog: { conversationID in
                            Task { @MainActor in
                                let resolver = InboxConversationJumpResolver(dataStore: dataStore)
                                if let target = await resolver.jumpTarget(conversationID: conversationID) {
                                    onOpenSessionLogs(target)
                                } else {
                                    onNavigate(.sessionLogs)
                                }
                            }
                        },
                        onOpenSettings: onOpenSettings
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
                case .quota:
                    QuotaWorkspaceView(
                        dataStore: dataStore,
                        quotaService: ProviderQuotaService.shared,
                        settingsManager: settingsManager,
                        onOpenConnections: onOpenSettings
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
