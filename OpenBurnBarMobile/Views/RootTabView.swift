import SwiftUI
import OpenBurnBarCore
import OpenBurnBarRecap
import OpenBurnBarAnalytics
#if DEBUG
import OSLog
#endif

// MARK: - Root Tab View (iPhone)
//
// Aurora navigation shape: Pulse / Burn / Streams / Hermes / You.
// All tabs share a single MotionStore via the environment so the parallax
// backdrop and hero cards drift in unison.

struct RootTabView: View {
    #if DEBUG
    private static let hermesE2ELogger = Logger(subsystem: "com.openburnbar.mobile", category: "HermesE2E")
    private static let computerUseE2ELogger = Logger(subsystem: "com.openburnbar.mobile", category: "ComputerUseE2E")
    #endif

    let authStore: AuthStore
    let syncHealthStore: CloudSyncHealthStore
    let providerSummaryStore: ProviderSummaryStore
    let devicesStore: DevicesStore
    let transferStore: CredentialTransferStore

    @State private var selection: AuroraNavDestination = .pulse
    /// Live preview destination during a nav-tray scrub. When non-nil, the
    /// content area shows this tab so the user sees what they're about to
    /// commit. Cleared on commit (selection binding updates) or cancel.
    @State private var scrubPreview: AuroraNavDestination?
    /// Horizontal swipe gesture state for root page swiping. Tracks whether
    /// a recognized horizontal swipe has already committed, so one swipe =
    /// one tab advance.
    @State private var rootSwipeCommitted = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var didApplyScreenshotRoute = false
    #if DEBUG
    @State private var didApplyHermesE2EPrompt = false
    @State private var didApplyComputerUseE2EProof = false
    #endif
    @State private var router = PulseRouter()
    @State private var settingsRouter = SettingsRouter()
    @State private var motionStore = MotionStore()
    @State private var hermesService = HermesService(runtimeStore: .shared)
    @State private var studioPresenter = ChartStudioPresenter()
    @State private var missionActivityCenter = MobileMissionActivityCenter()
    @State private var missionConsoleHost = MobileMissionConsoleHost()
    @State private var isHermesKeyboardVisible = false
    @State private var isCloudStoreChromeHidden = false
    @State private var showMissionConsole = false
    @State private var showMercuryCall = false
    @State private var pendingMercuryConnectionId: String?
    /// Shared OpenBurnBar Cloud / Hosted Quota Sync store, hoisted here so a
    /// single StoreKit observer feeds the Settings row, the Pulse upsell
    /// banner, and the dedicated `CloudStoreView`.
    @State private var subscriptionStore = HostedQuotaSubscriptionStore()

    /// App-scope Agent Watch overlay singleton — holds the persistent
    /// iroh control stream so the live mirror auto-opens the moment the
    /// Mac begins a Computer Use session, regardless of which tab the
    /// user is on. See `AgentWatchOverlaySingleton`.
    @ObservedObject private var liveStageSingleton = AgentWatchOverlaySingleton.shared
    /// Stage state machine (dock → split → maximize). Survives tab
    /// swaps via `@StateObject`. Observes the singleton's session-id on
    /// `.onAppear` and auto-opens to dock on session start.
    @StateObject private var liveStagePresenter = AgentLiveStagePresenter()
    @StateObject private var skillRunPiPController = SkillRunTextPiPController()

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var showRecap = false

    // Per-tab navigation paths
    @State private var pulsePath = NavigationPath()
    @State private var burnPath = NavigationPath()
    @State private var streamsPath = NavigationPath()
    @State private var hermesPath = NavigationPath()
    @State private var youPath = NavigationPath()

    /// Recap joins the tray only where there is room for a seventh
    /// destination; on iPhone it is reached from the Insights banner.
    private var destinations: [AuroraNavDestination] {
        AuroraNavDestination.trayDestinations(compact: horizontalSizeClass == .compact)
    }

    var body: some View {
        rootWithSheets
    }

    private var rootChrome: some View {
        ZStack {
            Group {
                if selection == .hermes {
                    contentForSelection
                        .environment(\.mobileBackgroundVisibility, rootBackgroundVisibility)
                } else {
                    contentForSelection
                        .environment(\.mobileBackgroundVisibility, rootBackgroundVisibility)
                        .ignoresSafeArea(.keyboard)
                }
            }
            // The tray remains a visual overlay so its glass can float above
            // every tab, but the root owns one real safe-area reservation for
            // it. Scroll views, editors and pushed chat screens therefore stop
            // above the pill instead of each guessing a different bottom
            // padding and letting live content sit underneath the controls.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear
                    .frame(height: MobileTrayMetrics.reservedHeight(isVisible: isNavigationTrayVisible))
                    .accessibilityHidden(true)
                    .transaction { transaction in
                        transaction.disablesAnimations = true
                    }
            }

            VStack(spacing: 0) {
                Spacer()
                AuroraNavigationTray(
                    selection: $selection,
                    destinations: destinations,
                    userPhotoURL: authStore.currentIdentity?.photoURL,
                    userDisplayName: authStore.currentIdentity?.displayName
                                  ?? authStore.currentIdentity?.email,
                    isCloudMember: subscriptionStore.isActive,
                    onScrubPreview: { dest in
                        scrubPreview = dest
                    },
                    onScrubCommit: { _ in
                        scrubPreview = nil
                    }
                )
                .opacity(isNavigationTrayVisible ? 1 : 0)
                .animation(.easeInOut(duration: 0.2), value: isHermesKeyboardVisible)
                .animation(.easeInOut(duration: 0.2), value: isCloudStoreChromeHidden)
                .allowsHitTesting(isNavigationTrayVisible)
            }

            // Floating Chart Studio button — only visible while Studio is
            // minimized. Sits above the nav tray, follows the user across
            // tabs.
            if !isCloudStoreChromeHidden {
                ChartStudioFloatingButton(presenter: studioPresenter)
            }

            // Full-screen Studio overlay. We host it here (not as a
            // `.fullScreenCover` on an individual card) so the user can
            // minimize it and keep navigating.
            if studioPresenter.mode == .fullscreen, let snap = studioPresenter.snapshot {
                ChartStudioView(
                    digest: snap.digest,
                    hermesService: hermesService,
                    onClose: { studioPresenter.dismiss() },
                    onMinimize: { studioPresenter.minimize() }
                )
                .ignoresSafeArea(.keyboard, edges: .bottom)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(10)
            }

            // Agent Live Stage — auto-opens the live Mac mirror when a
            // Computer Use session starts. Lives above the rest of the
            // chrome so split/maximize layouts can take over the screen,
            // and floats above the nav tray as a 320×180 dock tile when
            // the agent is just working in the background.
            AgentLiveStage(
                singleton: liveStageSingleton,
                presenter: liveStagePresenter,
                hermesService: hermesService,
                onTapHermesTab: { selection = .hermes }
            )
            .onAppear { CLIAgentControlSession.presenter = liveStagePresenter }
            .zIndex(20)

            SkillRunLiveStage(
                host: missionConsoleHost,
                pipController: skillRunPiPController
            )
            .zIndex(19)
        }
    }

    private var rootWithEnvironment: some View {
        rootChrome
            .environment(\.motionStore, motionStore)
            .environment(\.chartStudioPresenter, studioPresenter)
            .environment(\.cloudSubscriptionStore, subscriptionStore)
            .environment(\.mobileAuthStore, authStore)
            .simultaneousGesture(rootSwipeGesture)
    }

    private var rootWithLifecycle: some View {
        rootWithEnvironment
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
            .task { liveStageSingleton.installLiveActivityIntentRouter() }
            // Claims a push tap that landed BEFORE this view existed — a cold
            // launch from an AI Inbox notification posts `AIInboxDeepLink` while
            // the app is still in `didFinishLaunching`, so the `onReceive` below
            // has no subscriber yet and the stash is the only surviving record of
            // it. Same shape as `applyPendingGatewayPairingDeepLink`.
            .task { claimPendingAIInboxDeepLink() }
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
    }

    private var rootWithAnalytics: some View {
        rootWithLifecycle
            .onAppear {
                applyScreenshotRouteIfNeeded()
                applyHermesE2EPromptIfNeeded()
                applyComputerUseE2EProofIfNeeded()
                // First visible tab is a screen view too (the launch destination).
                MobileAnalytics.shared.track(.screenViewed, [
                    "surface": Self.surface(for: selection),
                    "is_first_view": .bool(true)
                ])
            }
            .onChange(of: selection) { oldValue, newValue in
                // A deliberate tab switch: the primary navigation action on iPhone.
                MobileAnalytics.shared.track(.mobileTabSelected, ["tab": Self.routeLabel(newValue)])
                MobileAnalytics.shared.track(.navRouteChanged, [
                    "from_route": Self.routeLabel(oldValue),
                    "to_route": Self.routeLabel(newValue)
                ])
                MobileAnalytics.shared.track(.screenViewed, ["surface": Self.surface(for: newValue)])
            }
            .onChange(of: router.pendingDestination) { _, destination in
                handleRouter(destination)
            }
    }

    private var rootWithPrimaryRoutes: some View {
        rootWithAnalytics
            .onReceive(NotificationCenter.default.publisher(for: .init("ShowHermesChat"))) { _ in
                selection = .hermes
            }
            .onReceive(NotificationCenter.default.publisher(for: .init("ShowAssistantsTab"))) { notification in
                handleAssistantsTabRoute(notification)
            }
            .onReceive(NotificationCenter.default.publisher(for: .init("ShowAgentWatch"))) { _ in
                openAgentWatchRoute()
            }
            .onReceive(NotificationCenter.default.publisher(for: .init("ShowSettings"))) { _ in
                openSettingsRoute()
            }
            .onReceive(NotificationCenter.default.publisher(for: .init("NavigateToDashboard"))) { _ in
                selection = .pulse
            }
            .onReceive(NotificationCenter.default.publisher(for: .init("ShowBurnTab"))) { _ in
                selection = .burn
            }
    }

    private var rootWithOsRoutes: some View {
        rootWithPrimaryRoutes
            // Both of these drain the stash on the live path too: the tap has been
            // served here, so leaving it parked would let `claimPendingOsRouteIfNeeded`
            // re-raise the same surface later.
            .onReceive(NotificationCenter.default.publisher(for: .init("ShowMercuryCall"))) { notification in
                guard case .mercuryCall = MobilePendingOsRouteStore.shared.consume() else { return }
                presentMercuryCall(connectionId: notification.userInfo?["connectionId"] as? String)
            }
            .onReceive(NotificationCenter.default.publisher(for: .init("ShowMissionConsole"))) { notification in
                guard case .mission = MobilePendingOsRouteStore.shared.consume() else { return }
                presentMissionConsole(missionId: notification.userInfo?["missionId"] as? String)
            }
            .onReceive(NotificationCenter.default.publisher(for: .init("ShowStreamsTab"))) { _ in
                selection = .streams
            }
            .onReceive(NotificationCenter.default.publisher(for: HermesGatewayPairingDeepLink.notificationName)) { notification in
                openHermesGatewayPairingRoute(notification)
            }
            .onReceive(NotificationCenter.default.publisher(for: AIInboxDeepLink.notificationName)) { notification in
                openAIInboxRoute(itemID: AIInboxDeepLink.itemID(from: notification))
            }
    }

    private var rootWithVisibilityRoutes: some View {
        rootWithOsRoutes
            .onReceive(NotificationCenter.default.publisher(for: .hermesKeyboardFocusChanged)) { notification in
                isHermesKeyboardVisible = notification.userInfo?["focused"] as? Bool ?? false
            }
            .onReceive(NotificationCenter.default.publisher(for: .cloudStoreChromeVisibilityChanged)) { notification in
                isCloudStoreChromeHidden = notification.object as? Bool ?? false
            }
    }

    private var rootWithSheets: some View {
        rootWithVisibilityRoutes
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

    private var isNavigationTrayVisible: Bool {
        !isHermesKeyboardVisible && !isCloudStoreChromeHidden
    }

    private func handleAssistantsTabRoute(_ notification: Notification) {
        guard let runtime = notification.userInfo?["runtime"] as? String else {
            selection = .hermes
            return
        }
        if runtime == AssistantRuntimeID.hermes.rawValue {
            selection = .hermes
        }
    }

    @ViewBuilder
    private var contentForSelection: some View {
        let active = scrubPreview ?? selection
        switch active {
        case .pulse:    pulseStack
        case .burn:     burnStack
        case .insights: insightsStack
        case .streams:  streamsStack
        case .hermes:   hermesStack
        case .you:      youStack
        case .recap:    MobileRecapScreen(accountID: authStore.currentIdentity?.uid)
        }
    }

    /// Composite key the Agent Live Stage `.task(id:)` listens on so the
    /// singleton re-evaluates whenever the signed-in user OR the
    /// currently selected Hermes connection changes.
    private var liveStageEvaluationKey: String {
        let uid = authStore.currentIdentity?.uid ?? ""
        let conn = hermesService.selectedConnection.id
        return "\(uid)|\(conn)"
    }

    private var rootBackgroundVisibility: MobileBackgroundVisibility {
        if isCloudStoreChromeHidden || studioPresenter.mode == .fullscreen {
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

    // MARK: - Root swipe gating

    /// Whether root-level page swiping is currently enabled. Disabled when
    /// any full-screen control surface is active so the gesture doesn't
    /// fight with the overlay or change tabs underneath a modal.
    private var isRootSwipeEnabled: Bool {
        !isHermesKeyboardVisible
            && !isCloudStoreChromeHidden
            && studioPresenter.mode != .fullscreen
            && liveStagePresenter.mode != .split
            && liveStagePresenter.mode != .maximize
            && scrubPreview == nil
    }

    // MARK: - Root horizontal swipe gesture

    /// Horizontal drag on the root content area. Recognizes clear horizontal
    /// intent (translation.width dominates translation.height), advances one
    /// destination per completed swipe, and preserves vertical scrolling
    /// inside the current tab via the `minimumDistance` threshold.
    private var rootSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 30)
            .onChanged { value in
                guard isRootSwipeEnabled, !rootSwipeCommitted else { return }
                guard let direction = AuroraNavGestureModel.swipeDirection(
                    translation: value.translation
                ) else { return }
                let active = scrubPreview ?? selection
                guard let next = AuroraNavGestureModel.adjacent(
                    current: active,
                    direction: direction,
                    destinations: destinations
                ) else { return }
                rootSwipeCommitted = true
                withAnimation(AuroraNavGestureModel.transitionAnimation(reduceMotion: reduceMotion)) {
                    selection = next
                }
                HapticBus.tabChange()
            }
            .onEnded { _ in
                rootSwipeCommitted = false
            }
    }

    @State private var insightsDashboardStore = DashboardStore()

    // Pulse/Burn data stores hoisted to the tab root (precedent:
    // `insightsDashboardStore`) so a tab return reuses warm stores: the
    // remounted view restarts the listeners its `onDisappear` tore down
    // instead of re-running the full network load (previously ~10+
    // round-trips per return to Pulse).
    @State private var pulseDashboardStore = DashboardStore()
    @State private var pulseQuotaStore = QuotaStore()
    @State private var pulseSessionsStore = ActivityStore()
    /// Pulse quick-ask keeps its own conversation surface (per-surface
    /// transcript, shared runtime catalog) and now survives tab swaps.
    @State private var pulseHermesService = HermesService(runtimeStore: .shared)
    @State private var burnQuotaStore = QuotaStore()
    @State private var burnDashboardStore = DashboardStore()
    @State private var burnActivityStore = ActivityStore()
    /// Hoisted for the same reason as the Pulse/Burn stores: Streams remounts on
    /// every tab return, and a per-view inbox store would tear down and re-open
    /// two Firestore listeners each time.
    @State private var streamsInboxStore = AIInboxStore()

    private var insightsStack: some View {
        VStack(spacing: 0) {
            // iPhone's route into the recap. On iPad it is a tray destination
            // instead, so the banner would be a second door to the same room.
            if horizontalSizeClass == .compact {
                RecapEntryBanner(window: .mostRecentCompleted()) { showRecap = true }
                    .padding(.horizontal, MobileTheme.Spacing.lg)
                    .padding(.top, MobileTheme.Spacing.sm)
                    .padding(.bottom, MobileTheme.Spacing.xs)
            }
            AgentInsightsTabScreen(
                dashboardStore: insightsDashboardStore,
                hermesService: hermesService
            )
        }
        .fullScreenCover(isPresented: $showRecap) {
            MobileRecapScreen(accountID: authStore.currentIdentity?.uid, onDismiss: { showRecap = false })
        }
    }

    // MARK: - Stacks

    private var pulseStack: some View {
        NavigationStack(path: $pulsePath) {
            PulseView(
                router: router,
                dashboard: pulseDashboardStore,
                quotaStore: pulseQuotaStore,
                sessionsStore: pulseSessionsStore,
                hermesService: pulseHermesService
            )
                .navigationDestination(for: TokenUsage.self) { SessionDetailView(usage: $0) }
                .navigationDestination(for: AgentProvider.self) { ProviderDashboardView(provider: $0) }
        }
    }

    private var burnStack: some View {
        NavigationStack(path: $burnPath) {
            BurnView(
                quotaStore: burnQuotaStore,
                dashboard: burnDashboardStore,
                activityStore: burnActivityStore
            )
                .navigationDestination(for: AgentProvider.self) { ProviderDashboardView(provider: $0) }
        }
    }

    private var streamsStack: some View {
        NavigationStack(path: $streamsPath) {
            StreamsView(inbox: streamsInboxStore)
                .navigationDestination(for: TokenUsage.self) { SessionDetailView(usage: $0) }
        }
    }

    private var hermesStack: some View {
        NavigationStack(path: $hermesPath) {
            // Hermes Square is the only Assistants surface. The split-
            // view automatically falls back to the single-column root on
            // compact widths (< 720pt) — same code path, no flag.
            HermesSquareSplitLayout(
                hermesService: hermesService,
                missionHost: missionConsoleHost
            )
        }
    }

    private var youStack: some View {
        NavigationStack(path: $youPath) {
            YouView(
                authStore: authStore,
                syncStore: syncHealthStore,
                devicesStore: devicesStore
            )
            .navigationDestination(for: YouRoute.self) { route in
                switch route {
                case .sync: CloudSyncDetailsView(syncStore: syncHealthStore)
                case .settings: SettingsHubView(authStore: authStore)
                    .environment(settingsRouter)
                case .devices:  iPadDevicesSettingsView(store: devicesStore, hermesService: hermesService)
                case .providers: ProviderConnectionsView(showsDoneButton: false)
                case .computerUse: AgentWatchScreen(
                    authUID: authStore.currentIdentity?.uid,
                    hermesService: hermesService
                )
                case .dataVault: DataVaultAdaptiveControlView()
                case .memory: PensieveMemorySearchView()
                }
            }
            .navigationDestination(for: SettingsPageRoute.self) { route in
                SettingsHubView.destination(for: route, authStore: authStore)
                    .environment(settingsRouter)
            }
        }
    }

    // MARK: - Router Bridge

    private func handleRouter(_ destination: PulseRouter.Destination?) {
        guard let destination else { return }
        switch destination {
        case .burn(let focus):
            selection = .burn
            // BurnView consumes focus through `initialFocus` — for runtime focus
            // (after the view is already mounted) we let the user reselect from
            // the constellation so we don't introduce store coupling.
            _ = focus
        case .streams:
            selection = .streams
        case .hermes:
            selection = .hermes
        case .session(let usage):
            selection = .pulse
            pulsePath.append(usage)
        case .project:
            selection = .streams
        case .provider(let provider):
            selection = .pulse
            pulsePath.append(provider)
        }
        router.clear()
    }

    private func openAgentWatchRoute() {
        selection = .you
        youPath = NavigationPath()
        youPath.append(YouRoute.computerUse)
    }

    private func openSettingsRoute() {
        selection = .you
        youPath = NavigationPath()
        youPath.append(YouRoute.settings)
    }

    /// Lands a `burnbar://inbox[/{itemId}]` deep link — the tap target of an AI
    /// Inbox P1 push.
    ///
    /// The Inbox lives inside the Streams stack, so this selects that tab, resets
    /// its path (the user may have been deep inside a session), and pushes the
    /// item route. `AIInboxDetailRoute` resolves the row from the live store, so
    /// an item the Mac resolved between the push and the tap shows the
    /// "this item is gone" pane rather than a blank screen.
    private func openAIInboxRoute(itemID: String?) {
        // Drain the stash on the live path too. The tap has been served here, so
        // leaving it parked would let a later `.task` re-navigate the user back
        // to this item after they had moved on.
        _ = AIInboxDeepLink.consumePendingItemID()
        selection = .streams
        streamsPath = NavigationPath()
        streamsInboxStore.focus(itemID: itemID)
        guard let itemID else { return }
        streamsPath.append(AIInboxDetailRoute(itemID: itemID))
    }

    /// Cold-launch counterpart to the `onReceive` above.
    ///
    /// A notification tap that launches the app posts its deep link during
    /// `didFinishLaunching`, before any SwiftUI view has subscribed, so the
    /// `AIInboxDeepLink` stash is the only surviving record. Claiming it here —
    /// once, as the root appears — is what makes a push tap from a terminated
    /// app land on the item instead of the default tab.
    private func claimPendingAIInboxDeepLink() {
        guard let itemID = AIInboxDeepLink.consumePendingItemID() else { return }
        openAIInboxRoute(itemID: itemID)
    }

    /// Cold-launch counterpart to the two `onReceive` handlers above.
    ///
    /// A mission or Mercury-call push that launches the app posts during
    /// `didFinishLaunching`, before this root has subscribed, so the stash is the
    /// only surviving record of the tap. Same shape as
    /// `claimPendingAIInboxDeepLink`.
    private func claimPendingOsRouteIfNeeded() {
        switch MobilePendingOsRouteStore.shared.consume() {
        case .mercuryCall(let connectionId):
            presentMercuryCall(connectionId: connectionId)
        case .mission(let missionId):
            presentMissionConsole(missionId: missionId)
        case nil:
            break
        }
    }

    private func presentMercuryCall(connectionId: String?) {
        pendingMercuryConnectionId = connectionId
        showMercuryCall = true
    }

    private func presentMissionConsole(missionId: String?) {
        if let missionId, !missionId.isEmpty {
            missionConsoleHost.focusMission(id: missionId)
        }
        selection = .hermes
        showMissionConsole = true
    }

    private func openHermesGatewayPairingRoute(_: Notification) {
        settingsRouter.prepareDeepLink(anchor: SettingsAnchor.hermesCloudGateway)
        selection = .you
        youPath = NavigationPath()
        youPath.append(YouRoute.settings)
        youPath.append(SettingsPageRoute.hermes)
    }

    private func applyScreenshotRouteIfNeeded() {
        guard AppStoreScreenshotMode.isEnabled, !didApplyScreenshotRoute else { return }
        didApplyScreenshotRoute = true
        switch AppStoreScreenshotMode.route {
        case "burn", "quota":
            selection = .burn
        case "streams", "activity":
            selection = .streams
        case "hermes", "chat":
            selection = .hermes
        case "you", "account":
            selection = .you
        default:
            selection = .pulse
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
        let selectedModelID = (modelID?.isEmpty == false) ? modelID! : "default"
        Self.hermesE2ELogger.info("Applying Hermes E2E prompt promptCharacters=\(prompt.count, privacy: .public) model=\(selectedModelID, privacy: .public)")
        didApplyHermesE2EPrompt = true
        selection = .hermes
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
            Self.computerUseE2ELogger.info("OpenBurnBarMobile ComputerUseE2E skip auth unavailable")
            return
        }
        didApplyComputerUseE2EProof = true
        Task { @MainActor in
            Self.computerUseE2ELogger.info("OpenBurnBarMobile ComputerUseE2E refresh_runtime_start")
            await hermesService.refreshRuntime()
            if hermesService.selectedConnection.id == HermesConnectionRecord.localDefault.id {
                let selected = hermesService.connectToSuggestedRelay(refresh: false)
                Self.computerUseE2ELogger.info("OpenBurnBarMobile ComputerUseE2E suggested_relay_selected=\(selected, privacy: .public) selected=\(hermesService.selectedConnection.id, privacy: .public) mode=\(hermesService.selectedConnection.mode.rawValue, privacy: .public)")
            } else {
                Self.computerUseE2ELogger.info("OpenBurnBarMobile ComputerUseE2E existing_connection selected=\(hermesService.selectedConnection.id, privacy: .public) mode=\(hermesService.selectedConnection.mode.rawValue, privacy: .public)")
            }
            selection = .you
            if youPath.isEmpty {
                youPath.append(YouRoute.computerUse)
            }
            Self.computerUseE2ELogger.info("OpenBurnBarMobile ComputerUseE2E opened Agent Watch")
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

    // MARK: - Analytics route/surface mapping (bounded enum values only)

    /// A stable, bounded label for a tab — the analytics `tab`/route value. Never a
    /// raw enum description that could drift; an explicit closed mapping.
    private static func routeLabel(_ destination: AuroraNavDestination) -> AnalyticsValue {
        switch destination {
        case .pulse:    return "pulse"
        case .burn:     return "burn"
        case .insights: return "insights"
        case .streams:  return "streams"
        case .hermes:   return "hermes"
        case .you:      return "you"
        case .recap:    return "recap"
        }
    }

    /// The canonical cross-platform `surface` value for a tab (taxonomy enum).
    private static func surface(for destination: AuroraNavDestination) -> AnalyticsValue {
        switch destination {
        case .pulse:    return "dashboard"
        case .burn:     return "dashboard"
        case .insights: return "insights"
        case .streams:  return "dashboard_activity"
        case .hermes:   return "chat"
        case .you:      return "account"
        // The recap is a monthly read of the same numbers Insights shows, so it
        // reports the existing taxonomy surface rather than minting a new one.
        case .recap:    return "insights"
        }
    }

    // MARK: - Destination Mapping (for external router compatibility)

    enum TabSelection: Hashable, Equatable, Identifiable {
        case pulse, burn, streams, hermes, you

        var id: String { String(describing: self) }
        var label: String {
            switch self {
            case .pulse:   return "Pulse"
            case .burn:    return "Burn"
            case .streams: return "Streams"
            case .hermes:  return "Hermes"
            case .you:     return "You"
            }
        }
    }
}

#Preview {
    RootTabView(
        authStore: AuthStore(),
        syncHealthStore: CloudSyncHealthStore(),
        providerSummaryStore: ProviderSummaryStore(),
        devicesStore: DevicesStore(),
        transferStore: CredentialTransferStore()
    )
}
