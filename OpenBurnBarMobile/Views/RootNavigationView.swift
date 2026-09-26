import SwiftUI
import OpenBurnBarInboxModels
import OpenBurnBarKernel
import OpenBurnBarQuota
import OpenBurnBarUI
import OpenBurnBarRecap
#if DEBUG
import OSLog
#endif

// MARK: - Root Navigation View (iPad command desk)
//
// Regular-width iPad is a desk, not a large phone. Inbox launches.
// `NavigationSplitView` columns: destinations | decision rail | canvas.
// Watch + Mercury Ask-to-Mirror live in `.inspector`, not a phone dock.

struct RootNavigationView: View {
    #if DEBUG
    private static let hermesE2ELogger = Logger(subsystem: "com.openburnbar.mobile", category: "HermesE2E")
    private static let computerUseE2ELogger = Logger(subsystem: "com.openburnbar.mobile", category: "ComputerUseE2E")
    #endif

    let authStore: AuthStore
    let syncHealthStore: CloudSyncHealthStore
    let providerSummaryStore: ProviderSummaryStore
    let devicesStore: DevicesStore
    let transferStore: CredentialTransferStore

    @State private var selection: AppDestination = IPadAwayDeskNavigation.launchDestination
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showWatchInspector = true
    @StateObject private var customization = AppCustomization.shared
    @State private var didApplyScreenshotRoute = false
    #if DEBUG
    @State private var didApplyHermesE2EPrompt = false
    @State private var didApplyComputerUseE2EProof = false
    #endif
    @State private var router = PulseRouter()
    @State private var settingsRouter = SettingsRouter()
    @State private var hermesService = HermesService(runtimeStore: .shared)
    @State private var motionStore = MotionStore()
    @State private var insightsDashboardStore = DashboardStore()
    // Pulse/Burn data stores hoisted to the split-view root (same fix as
    // `RootTabView`): the detail switch destroys the selected branch's view
    // tree on every sidebar change, and per-view stores used to re-run the
    // full network load each time.
    @State private var pulseDashboardStore = DashboardStore()
    @State private var pulseQuotaStore = QuotaStore()
    @State private var pulseSessionsStore = ActivityStore()
    @State private var pulseHermesService = HermesService(runtimeStore: .shared)
    @State private var burnQuotaStore = QuotaStore()
    @State private var burnDashboardStore = DashboardStore()
    @State private var burnActivityStore = ActivityStore()
    /// Hoisted for the same reason as the Pulse/Burn stores: the detail switch
    /// destroys the selected branch's view tree on every sidebar change, and a
    /// per-view inbox store would re-open two Firestore listeners each time.
    @State private var streamsInboxStore = AIInboxStore()
    @State private var missionActivityCenter = MobileMissionActivityCenter()
    @State private var missionConsoleHost = MobileMissionConsoleHost()
    @State private var showHermesSheet = false
    @State private var subscriptionStore = HostedQuotaSubscriptionStore()
    @State private var detailPath = NavigationPath()
    @State private var isCloudStoreChromeHidden = false
    @State private var showMissionConsole = false
    @State private var showMercuryCall = false
    @State private var pendingMercuryConnectionId: String?
    /// App-scope Agent Watch overlay singleton. The iPad split shell needs the
    /// same always-on control stream as iPhone so Mac-initiated screen sharing
    /// can surface without first navigating to You -> Agent Watch.
    @ObservedObject private var liveStageSingleton = AgentWatchOverlaySingleton.shared
    @StateObject private var liveStagePresenter = AgentLiveStagePresenter()
    @StateObject private var skillRunPiPController = SkillRunTextPiPController()
    @ObservedObject private var hostReachability = HostReachabilityClient.shared
    @Environment(\.openWindow) private var openWindow
    @StateObject private var agentsDesk = IPadAgentsDeskController()
    @State private var deskSearchText = ""
    @State private var quotaProvider: String?
    @State private var youGroup: IPadAwayDeskNavigation.YouGroup = .pairing

    // Sidebar destinations have been moved to AppDestination in AppCustomization.swift

    var body: some View {
        deskWithPresentation
    }

    private var deskChrome: some View {
        ZStack(alignment: .bottomTrailing) {
            deskSplit
            .inspector(isPresented: $showWatchInspector) {
                IPadWatchInspectorColumn(
                    authUID: authStore.currentIdentity?.uid,
                    hermesService: hermesService,
                    singleton: liveStageSingleton,
                    hostReachability: hostReachability
                )
                .inspectorColumnWidth(min: 320, ideal: 420, max: 560)
            }
            .environment(\.mobileBackgroundVisibility, rootBackgroundVisibility)

            SkillRunLiveStage(
                host: missionConsoleHost,
                pipController: skillRunPiPController
            )
            .zIndex(19)
        }
    }

    private var deskWithLifecycle: some View {
        deskChrome
        .onAppear { CLIAgentControlSession.presenter = liveStagePresenter }
        .environment(\.motionStore, motionStore)
        .environment(\.cloudSubscriptionStore, subscriptionStore)
        .environment(\.mobileAuthStore, authStore)
        .task {
            hermesService.bindElderWandEntitlement(to: subscriptionStore)
            pulseHermesService.bindElderWandEntitlement(to: subscriptionStore)
        }
        .task(id: authStore.currentIdentity?.uid) { await subscriptionStore.load() }
        .task(id: authStore.currentIdentity?.uid) { applyHermesE2EPromptIfNeeded() }
        .task(id: authStore.currentIdentity?.uid) { applyComputerUseE2EProofIfNeeded() }
        .task { missionActivityCenter.start() }
        .task {
            missionConsoleHost.start()
            claimPendingOsRouteIfNeeded()
        }
        .task { liveStagePresenter.observe(liveStageSingleton.state) }
        .onChange(of: liveStageSingleton.state.sessionId?.rawValue) { _, sessionId in
            if sessionId != nil {
                pinWatchInspector()
            }
        }
        .task { liveStageSingleton.installLiveActivityIntentRouter() }
        // Claims a push tap that landed BEFORE this view existed — a cold
        // launch from an AI Inbox notification posts `AIInboxDeepLink` while
        // the app is still in `didFinishLaunching`, so the `onReceive` below
        // has no subscriber yet and the stash is the only surviving record of
        // it. Same shape as `applyPendingGatewayPairingDeepLink`.
        .task { claimPendingAIInboxDeepLink() }
        .task { claimPendingInsightsDeepLink() }
        .task {
            liveStageSingleton.configurePictureInPicture(
                onDidStart: { liveStagePresenter.setPiPActive(true) },
                onDidStop: { liveStagePresenter.enterMaximizeFromPiP() }
            )
        }
        .task(id: liveStageEvaluationKey) {
            liveStageSingleton.evaluate(
                authUID: authStore.currentIdentity?.uid,
                hermesService: hermesService
            )
        }
        .onAppear {
            applyScreenshotRouteIfNeeded()
            applyHermesE2EPromptIfNeeded()
            applyComputerUseE2EProofIfNeeded()
            updateColumnVisibility(animated: false)
        }
        .onChange(of: selection) { _, _ in
            updateColumnVisibility()
            applyDeskSearch(deskSearchText)
        }
        .onChange(of: deskSearchText) { _, query in
            applyDeskSearch(query)
        }
        .onChange(of: router.pendingDestination) { _, destination in
            handleRouter(destination)
        }
    }

    private var deskWithPrimaryNotifications: some View {
        deskWithLifecycle
        .onReceive(NotificationCenter.default.publisher(for: .init("ShowAgentWatch"))) { _ in
            openWatchWindow()
        }
        .onReceive(NotificationCenter.default.publisher(for: IPadAwayDeskNotifications.selectInbox)) { _ in
            selectDeskDestination(.inbox)
        }
        .onReceive(NotificationCenter.default.publisher(for: IPadAwayDeskNotifications.selectAgents)) { _ in
            selectDeskDestination(.agents)
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("ShowHermesChat"))) { _ in
            selectDeskDestination(.agents)
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("ShowAssistantsTab"))) { _ in
            selectDeskDestination(.agents)
        }
        .onReceive(NotificationCenter.default.publisher(for: IPadAwayDeskNotifications.selectQuota)) { _ in
            selectDeskDestination(.burn)
        }
        .onReceive(NotificationCenter.default.publisher(for: IPadAwayDeskNotifications.selectYou)) { _ in
            selectDeskDestination(.you)
        }
        .onReceive(NotificationCenter.default.publisher(for: IPadAwayDeskNotifications.pinWatch)) { _ in
            pinWatchInspector()
        }
        .onReceive(NotificationCenter.default.publisher(for: IPadAwayDeskNotifications.openWatchWindow)) { _ in
            openWatchWindow()
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("ShowSettings"))) { _ in
            openSettingsRoute()
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("ShowDevices"))) { _ in
            guard case .devices = MobilePendingOsRouteStore.shared.consume() else { return }
            openDevicesRoute()
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("NavigateToDashboard"))) { _ in
            selection = .pulse
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("ShowBurnTab"))) { _ in
            selection = .burn
        }
    }

    private var deskWithNotifications: some View {
        deskWithPrimaryNotifications
        // Both of these drain the stash on the live path too: the tap has been
        // served here, so leaving it parked would let `claimPendingOsRouteIfNeeded`
        // re-raise the same surface later.
        .onReceive(NotificationCenter.default.publisher(for: .init("ShowMercuryCall")), perform: handleShowMercuryCall)
        .onReceive(NotificationCenter.default.publisher(for: .init("ShowMissionConsole")), perform: handleShowMissionConsole)
        .onReceive(NotificationCenter.default.publisher(for: .init("ShowStreamsTab"))) { _ in
            selection = .streams
        }
        .onReceive(NotificationCenter.default.publisher(for: InsightsDeepLink.notificationName)) { _ in
            handleShowInsights()
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("ShowRecap"))) { _ in
            handleShowRecap()
        }
        .onReceive(NotificationCenter.default.publisher(for: HermesGatewayPairingDeepLink.notificationName), perform: openHermesGatewayPairingRoute)
        .onReceive(NotificationCenter.default.publisher(for: AIInboxDeepLink.notificationName), perform: handleShowAIInbox)
        .onReceive(NotificationCenter.default.publisher(for: .cloudStoreChromeVisibilityChanged), perform: handleCloudStoreChromeVisibilityChanged)
    }

    private var deskWithPresentation: some View {
        deskWithNotifications
        .sheet(isPresented: $showMissionConsole) {
            MobileMissionConsoleSheet(host: missionConsoleHost) {
                showMissionConsole = false
            }
        }
        .sheet(isPresented: $showMercuryCall) {
            MercuryRoutedIncomingSheet(connectionId: pendingMercuryConnectionId) {
                showMercuryCall = false
            }
        }
    }

    /// Inbox is three columns (destinations | rail | canvas). Everything else
    /// is two columns (destinations | canvas) so Agents keeps the destination
    /// sidebar — `.doubleColumn` on a three-column split would hide it.
    private var deskSplit: some View {
        deskSplitColumns
            .iPadDeskSearchable(
                text: $deskSearchText,
                prompt: IPadAwayDeskNavigation.searchPrompt(for: selection)
            )
    }

    @ViewBuilder
    private var deskSplitColumns: some View {
        switch IPadAwayDeskNavigation.columnMode(for: selection) {
        case .threeColumn:
            NavigationSplitView(columnVisibility: $columnVisibility) {
                sidebarColumn
            } content: {
                rail
                    .navigationSplitViewColumnWidth(min: 320, ideal: 360, max: 420)
            } detail: {
                canvas
            }
        case .twoColumn:
            NavigationSplitView(columnVisibility: $columnVisibility) {
                sidebarColumn
            } detail: {
                canvas
            }
        }
    }

    private var sidebarColumn: some View {
        sidebar
            .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 280)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        ZStack {
            Rectangle().fill(.clear).background(.regularMaterial)
            List {
                Section {
                    sidebarLogoHeader
                    ForEach(customization.primaryDestinations, id: \.self) { destination in
                        sidebarItem(destination)
                    }
                }
                Section("Account") {
                    ForEach(customization.secondaryDestinations, id: \.self) { destination in
                        sidebarItem(destination)
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showWatchInspector.toggle()
                    } label: {
                        Label("Watch", systemImage: "macbook.and.ipad")
                    }
                    .accessibilityIdentifier("ipad.watch.toggle")
                    .accessibilityLabel(showWatchInspector ? "Hide Watch" : "Show Watch")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            sidebarFooter
        }
    }

    private var sidebarLogoHeader: some View {
        VStack(spacing: 6) {
            Image("AppLogo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: 40)
            Text("BurnBar")
                .font(.system(size: 13, weight: .medium, design: .default))
                .foregroundStyle(MobileTheme.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        .padding(.bottom, 16)
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        .listRowBackground(Color.clear)
    }

    private func sidebarItem(_ destination: AppDestination) -> some View {
        IPadSidebarDestinationRow(
            destination: destination,
            isSelected: selection == destination,
            unreadCount: destination == .inbox ? streamsInboxStore.unreadCount : 0,
            userPhotoURL: authStore.currentIdentity?.photoURL,
            userDisplayName: authStore.currentIdentity?.displayName
                ?? authStore.currentIdentity?.email
        ) {
            selectDeskDestination(destination)
        }
        .animation(.spring(response: 0.30, dampingFraction: 0.78), value: selection)
    }

    private var sidebarFooter: some View {
        Group {
            if #available(iOS 26, *) {
                // Liquid Glass: no bar plate. The sync pill carries its own
                // glass (`.auroraGlass`) and the Hermes button keeps its opaque
                // mercury-foil identity — a material here would sit UNDER the
                // pill's glassEffect and block it from sampling the sidebar
                // list scrolling beneath.
                sidebarFooterContent
            } else {
                sidebarFooterContent
                    .background(.ultraThinMaterial)
            }
        }
        .sheet(isPresented: $showHermesSheet) {
            NavigationStack {
                HermesChatView(service: hermesService, route: .new)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showHermesSheet = false }
                        }
                    }
            }
            .presentationDetents([.large])
        }
    }

    private var sidebarFooterContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(syncDotColor)
                    .frame(width: 8, height: 8)
                Text(syncStatusText)
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
                    .lineLimit(1)
                if let lastSync = syncHealthStore.lastPublishedAt, syncHealthStore.health != .macNotSyncing {
                    Text("· \(lastSync, style: .relative)")
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.Colors.textMuted.opacity(0.7))
                        .lineLimit(1)
                }
            }
            HostReachabilityStatusLine(status: hostReachability.status, opacity: 0.8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Detail

    private var liveStageEvaluationKey: String {
        let uid = authStore.currentIdentity?.uid ?? ""
        let conn = hermesService.selectedConnection.id
        return "\(uid)|\(conn)"
    }

    private var rootBackgroundVisibility: MobileBackgroundVisibility {
        if isCloudStoreChromeHidden || showHermesSheet {
            return .obscured
        }
        switch liveStagePresenter.mode {
        case .hidden, .dock:
            return .prominent
        case .split:
            return .subtle
        case .maximize:
            return .obscured
        }
    }

    @ViewBuilder
    private var rail: some View {
        NavigationStack {
            switch selection {
            case .inbox:
                IPadInboxRail(store: streamsInboxStore)
            case .agents:
                IPadAgentsRail(
                    hermesService: hermesService,
                    missionHost: missionConsoleHost,
                    controller: agentsDesk,
                    searchQuery: deskSearchText
                )
            case .burn:
                IPadQuotaRail(
                    quotaStore: burnQuotaStore,
                    selectedProvider: $quotaProvider,
                    searchQuery: deskSearchText
                )
            case .you:
                IPadYouRail(
                    authStore: authStore,
                    selectedGroup: $youGroup,
                    searchQuery: deskSearchText
                )
            default:
                ContentUnavailableView(
                    selection.label,
                    systemImage: selection.fallbackIcon,
                    description: Text("The canvas on the right is the working surface.")
                )
                .navigationTitle(selection.label)
                .navigationBarTitleDisplayMode(.inline)
            }
        }
    }

    @ViewBuilder
    private var canvas: some View {
        switch selection {
        case .inbox:
            IPadInboxCanvas(store: streamsInboxStore)
        case .agents:
            IPadAgentsCanvas(
                hermesService: hermesService,
                missionHost: missionConsoleHost,
                controller: agentsDesk
            )
        case .burn:
            IPadQuotaCanvas(
                quotaStore: burnQuotaStore,
                selectedProvider: quotaProvider
            )
        case .you:
            IPadYouCanvas(
                authStore: authStore,
                syncStore: syncHealthStore,
                devicesStore: devicesStore,
                hermesService: hermesService,
                selectedGroup: youGroup,
                settingsRouter: settingsRouter
            )
        default:
            NavigationStack(path: $detailPath) {
                Group {
                    switch selection {
                    case .inbox, .agents, .burn, .you:
                        EmptyView()
                    case .pulse:
                        PulseView(
                            router: router,
                            dashboard: pulseDashboardStore,
                            quotaStore: pulseQuotaStore,
                            sessionsStore: pulseSessionsStore,
                            hermesService: pulseHermesService
                        )
                    case .insights:
                        AgentInsightsTabScreen(
                            dashboardStore: insightsDashboardStore,
                            hermesService: hermesService
                        )
                    case .streams:
                        StreamsView(inbox: streamsInboxStore)
                    case .settings:
                        SettingsHubView(authStore: authStore)
                            .environment(settingsRouter)
                    case .devices:
                        iPadDevicesSettingsView(store: devicesStore, hermesService: hermesService)
                    case .providers:
                        ProviderConnectionsView(showsDoneButton: false)
                    case .recap:
                        MobileRecapScreen(accountID: authStore.currentIdentity?.uid)
                    }
                }
                .navigationDestination(for: YouRoute.self) { route in
                    youRouteDestination(route)
                }
                .navigationDestination(for: SettingsPageRoute.self) { route in
                    SettingsHubView.destination(for: route, authStore: authStore)
                        .environment(settingsRouter)
                }
                .navigationDestination(for: TokenUsage.self) { usage in
                    SessionDetailView(usage: usage)
                }
                .navigationDestination(for: AIInboxDetailRoute.self) { route in
                    AIInboxDetailScreen(store: streamsInboxStore, itemID: route.itemID)
                }
            }
        }
    }

    @ViewBuilder
    private func youRouteDestination(_ route: YouRoute) -> some View {
        youRouteView(
            route,
            authStore: authStore,
            syncStore: syncHealthStore,
            devicesStore: devicesStore,
            hermesService: hermesService,
            settingsRouter: settingsRouter,
            onComputerUseAppear: pinWatchInspector
        )
    }

    // MARK: - Router

    private func handleRouter(_ destination: PulseRouter.Destination?) {
        guard let destination else { return }
        switch destination {
        case .burn:     selection = .burn
        case .streams:  selection = .streams
        case .hermes:   selection = .agents
        case .session:  selection = .streams
        case .project:  selection = .streams
        case .provider: selection = .burn
        }
        router.clear()
    }

    private func pinWatchInspector() {
        selection = IPadAwayDeskNavigation.destinationAfterPinningWatch(current: selection)
        showWatchInspector = true
    }

    private func openWatchWindow() {
        pinWatchInspector()
        openWindow(id: IPadAwayDeskNavigation.watchWindowID)
    }

    private func selectDeskDestination(_ destination: AppDestination) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
            selection = destination
        }
        HapticBus.tabChange()
        updateColumnVisibility()
    }

    private func openSettingsRoute() {
        selection = .settings
        detailPath = NavigationPath()
        updateColumnVisibility(animated: false)
    }

    /// Lands a device-approval banner or `openburnbar://approve-device` tap on
    /// the Devices sidebar destination. Review stays explicit; this never
    /// auto-approves.
    private func openDevicesRoute() {
        selection = .devices
        detailPath = NavigationPath()
        updateColumnVisibility(animated: false)
    }

    private func openHermesGatewayPairingRoute(_: Notification) {
        settingsRouter.prepareDeepLink(anchor: SettingsAnchor.hermesCloudGateway)
        selection = .settings
        detailPath = NavigationPath()
        detailPath.append(SettingsPageRoute.hermes)
        updateColumnVisibility(animated: false)
    }

    /// Lands a `burnbar://inbox[/{itemId}]` deep link from an AI Inbox P1 push.
    ///
    /// Inbox is a primary desk destination. This selects it and focuses the
    /// shared `AIInboxStore` so the rail + canvas show the item inline.
    private func openAIInboxRoute(itemID: String?) {
        // Drain the stash on the live path too. The tap has been served here, so
        // leaving it parked would let a later `.task` re-navigate the user back
        // to this item after they had moved on.
        _ = AIInboxDeepLink.consumePendingItemID()
        selection = .inbox
        detailPath = NavigationPath()
        streamsInboxStore.focus(itemID: itemID)
        updateColumnVisibility(animated: false)
    }

    private func claimPendingInsightsDeepLink() {
        guard InsightsDeepLink.hasPending else { return }
        selectDeskDestination(IPadAwayDeskNavigation.destinationAfterInsightsDeepLink())
    }

    /// Cold-launch counterpart to the `onReceive` above.
    ///
    /// A notification tap that launches the app posts its deep link during
    /// `didFinishLaunching`, before any SwiftUI view has subscribed, so the
    /// `AIInboxDeepLink` stash is the only surviving record. Claiming it here —
    /// once, as the root appears — is what makes a push tap from a terminated
    /// app land on the item instead of the default sidebar branch.
    private func claimPendingAIInboxDeepLink() {
        guard let itemID = AIInboxDeepLink.consumePendingItemID() else { return }
        openAIInboxRoute(itemID: itemID)
    }

    /// Cold-launch counterpart to the mission / Mercury-call `onReceive`
    /// handlers, for the same reason as `claimPendingAIInboxDeepLink` above:
    /// the push posts before this root has subscribed, so the stash is the only
    /// surviving record of the tap.
    private func claimPendingOsRouteIfNeeded() {
        switch MobilePendingOsRouteStore.shared.consume() {
        case .mercuryCall(let connectionId):
            presentMercuryCall(connectionId: connectionId)
        case .mission(let missionId):
            presentMissionConsole(missionId: missionId)
        case .devices:
            openDevicesRoute()
        case nil:
            break
        }
    }

    private func handleShowMercuryCall(_ notification: Notification) {
        guard case .mercuryCall = MobilePendingOsRouteStore.shared.consume() else { return }
        let connectionId = notification.userInfo?["connectionId"] as? String
        presentMercuryCall(connectionId: connectionId)
    }

    private func handleShowMissionConsole(_ notification: Notification) {
        guard case .mission = MobilePendingOsRouteStore.shared.consume() else { return }
        let missionId = notification.userInfo?["missionId"] as? String
        presentMissionConsole(missionId: missionId)
    }

    private func handleShowInsights() {
        selectDeskDestination(IPadAwayDeskNavigation.destinationAfterInsightsDeepLink())
    }

    private func handleShowRecap() {
        selection = .recap
        updateColumnVisibility(animated: false)
    }

    private func handleShowAIInbox(_ notification: Notification) {
        openAIInboxRoute(itemID: AIInboxDeepLink.itemID(from: notification))
    }

    private func handleCloudStoreChromeVisibilityChanged(_ notification: Notification) {
        isCloudStoreChromeHidden = notification.object as? Bool ?? false
    }

    private func presentMercuryCall(connectionId: String?) {
        pendingMercuryConnectionId = connectionId
        showMercuryCall = true
    }

    private func presentMissionConsole(missionId: String?) {
        if let missionId, !missionId.isEmpty {
            missionConsoleHost.focusMission(id: missionId)
        }
        selection = .agents
        showMissionConsole = true
    }

    private func applyDeskSearch(_ query: String) {
        if selection == .inbox {
            streamsInboxStore.searchQuery = query
        }
    }

    private func updateColumnVisibility(animated: Bool = true) {
        // Always keep the destination sidebar. Never `.detailOnly` (old Agents habit).
        let nextVisibility = NavigationSplitViewVisibility.all
        guard columnVisibility != nextVisibility else { return }
        if animated {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                columnVisibility = nextVisibility
            }
        } else {
            columnVisibility = nextVisibility
        }
    }

    private func applyScreenshotRouteIfNeeded() {
        guard AppStoreScreenshotMode.isEnabled, !didApplyScreenshotRoute else { return }
        didApplyScreenshotRoute = true
        switch AppStoreScreenshotMode.route {
        case "inbox":
            selection = .inbox
        case "burn", "quota":
            selection = .burn
        case "streams", "activity":
            selection = .streams
        case "pulse", "dashboard":
            selection = .pulse
        case "insights":
            selection = .insights
        case "hermes", "chat":
            selection = .agents
        case "you", "account":
            selection = .you
        case "settings":
            selection = .settings
        case "devices":
            selection = .devices
        case "providers", "connections":
            selection = .providers
        default:
            selection = IPadAwayDeskNavigation.launchDestination
        }
    }

    // MARK: - Sync Helpers

    private var syncStatusText: String {
        switch syncHealthStore.health {
        case .healthy: return "Synced"
        case .syncing: return "Syncing…"
        case .macNotSyncing: return syncHealthStore.macLastSeenText()
        case .offline: return "Offline"
        case .firebaseUnavailable: return "Firebase unavailable"
        case .appCheckBlocked: return "App Check blocked"
        case .permissionDenied: return "Permission denied"
        case .degraded: return "Degraded"
        case .networkDisabledOnThisDevice: return "Cloud sync off (compatibility)"
        case .unknown: return "Checking…"
        }
    }

    private var syncDotColor: Color {
        switch syncHealthStore.health {
        case .healthy: return MobileTheme.success
        case .syncing: return MobileTheme.amber
        case .macNotSyncing, .offline, .degraded, .networkDisabledOnThisDevice: return MobileTheme.warning
        case .firebaseUnavailable, .appCheckBlocked, .permissionDenied: return MobileTheme.error
        case .unknown: return MobileTheme.Colors.textMuted
        }
    }

    private func applyHermesE2EPromptIfNeeded() {
        #if DEBUG
        guard !didApplyHermesE2EPrompt else {
            Self.hermesE2ELogger.debug("Skipping Hermes E2E prompt because it was already applied")
            return
        }
        let prompt = ProcessInfo.processInfo.environment["OPENBURNBAR_E2E_HERMES_PROMPT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let prompt, !prompt.isEmpty else {
            Self.hermesE2ELogger.debug("Skipping Hermes E2E prompt because OPENBURNBAR_E2E_HERMES_PROMPT is empty")
            return
        }
        guard authStore.currentIdentity?.uid != nil else {
            Self.hermesE2ELogger.info("Skipping Hermes E2E prompt because auth state is \(authStateLabel(authStore.state), privacy: .public)")
            return
        }
        let modelID = ProcessInfo.processInfo.environment["OPENBURNBAR_E2E_HERMES_MODEL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedModelID = modelID.flatMap { $0.isEmpty ? nil : $0 } ?? "default"
        Self.hermesE2ELogger.info("Applying Hermes E2E prompt promptCharacters=\(prompt.count, privacy: .public) model=\(selectedModelID, privacy: .public)")
        didApplyHermesE2EPrompt = true
        selection = .agents
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await hermesService.refreshRuntime()
            hermesService.startNewSession()
            if let modelID, !modelID.isEmpty {
                Self.hermesE2ELogger.info("Selecting Hermes E2E model \(modelID, privacy: .public)")
                hermesService.selectModelIDForAutomation(modelID)
            }
            Self.hermesE2ELogger.info("Sending Hermes E2E prompt through selected mobile harness")
            hermesService.sendMessage(prompt)
        }
        #endif
    }

    private func applyComputerUseE2EProofIfNeeded() {
        #if DEBUG
        guard !didApplyComputerUseE2EProof else { return }
        guard ProcessInfo.processInfo.environment["OPENBURNBAR_E2E_COMPUTER_USE_PROOF"] == "1" else { return }
        guard authStore.currentIdentity?.uid != nil else {
            Self.computerUseE2ELogger.info("OpenBurnBarMobile ComputerUseE2E iPad skip auth unavailable")
            return
        }
        didApplyComputerUseE2EProof = true
        Task { @MainActor in
            Self.computerUseE2ELogger.info("OpenBurnBarMobile ComputerUseE2E iPad refresh_runtime_start")
            await hermesService.refreshRuntime()
            if hermesService.selectedConnection.id == HermesConnectionRecord.localDefault.id {
                let selected = hermesService.connectToSuggestedRelay(refresh: false)
                Self.computerUseE2ELogger.info("OpenBurnBarMobile ComputerUseE2E iPad suggested_relay_selected=\(selected, privacy: .public) selected=\(hermesService.selectedConnection.id, privacy: .public) mode=\(hermesService.selectedConnection.mode.rawValue, privacy: .public)")
            } else {
                Self.computerUseE2ELogger.info("OpenBurnBarMobile ComputerUseE2E iPad existing_connection selected=\(hermesService.selectedConnection.id, privacy: .public) mode=\(hermesService.selectedConnection.mode.rawValue, privacy: .public)")
            }
            selection = .you
            detailPath = NavigationPath()
            detailPath.append(YouRoute.computerUse)
            updateColumnVisibility(animated: false)
            Self.computerUseE2ELogger.info("OpenBurnBarMobile ComputerUseE2E iPad opened Agent Watch")
        }
        #endif
    }

    #if DEBUG
    private func authStateLabel(_ state: AuthState) -> String {
        switch state {
        case .signedOut:
            return "signedOut"
        case .signingIn:
            return "signingIn"
        case .signedIn:
            return "signedIn"
        case .deletingAccount:
            return "deletingAccount"
        case .firebaseUnavailable:
            return "firebaseUnavailable"
        case .firestoreUnavailable:
            return "firestoreUnavailable"
        }
    }
    #endif
}

#Preview {
    RootNavigationView(
        authStore: AuthStore(),
        syncHealthStore: CloudSyncHealthStore(),
        providerSummaryStore: ProviderSummaryStore(),
        devicesStore: DevicesStore(),
        transferStore: CredentialTransferStore()
    )
}
