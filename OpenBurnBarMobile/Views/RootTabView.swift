import SwiftUI
import OpenBurnBarCore
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

    @State private var selection: AuroraNavItem = .canonical(.pulse)
    /// Live preview item during a nav-tray scrub. When non-nil, the content
    /// area shows this tab so the user sees what they're about to commit.
    /// Cleared on commit (selection binding updates) or cancel.
    @State private var scrubPreview: AuroraNavItem?
    /// Horizontal swipe gesture state for root page swiping. Tracks whether
    /// a recognized horizontal swipe has already committed, so one swipe =
    /// one tab advance.
    @State private var rootSwipeCommitted = false
    /// The user's tab-bar layout (order, membership, inbox presets) and the
    /// swipe-navigation toggle live here; the tray renders whatever this says.
    @StateObject private var customization = AppCustomization.shared

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

    // Per-tab navigation paths
    @State private var pulsePath = NavigationPath()
    @State private var burnPath = NavigationPath()
    @State private var streamsPath = NavigationPath()
    @State private var hermesPath = NavigationPath()
    @State private var youPath = NavigationPath()
    @State private var fleetPath = NavigationPath()
    /// Inbox paths are keyed by nav-item instance id: two inbox tabs are two
    /// distinct navigation stacks even though they share one store.
    @State private var inboxPaths: [String: NavigationPath] = [:]

    private var navItems: [AuroraNavItem] { customization.navItems }

    /// The item whose content is on screen: the scrub preview, else the
    /// committed selection.
    private var activeItem: AuroraNavItem { scrubPreview ?? selection }

    var body: some View {
        ZStack {
            if selection.kind == .hermes {
                contentForSelection
                    .environment(\.mobileBackgroundVisibility, rootBackgroundVisibility)
            } else {
                contentForSelection
                    .environment(\.mobileBackgroundVisibility, rootBackgroundVisibility)
                    .ignoresSafeArea(.keyboard)
            }

            VStack(spacing: 0) {
                Spacer()
                AuroraNavigationTray(
                    selection: $selection,
                    items: navItems,
                    userPhotoURL: authStore.currentIdentity?.photoURL,
                    userDisplayName: authStore.currentIdentity?.displayName
                                  ?? authStore.currentIdentity?.email,
                    isCloudMember: subscriptionStore.isActive,
                    onScrubPreview: { item in
                        scrubPreview = item
                    },
                    onScrubCommit: { _ in
                        scrubPreview = nil
                    }
                )
                .opacity(isHermesKeyboardVisible || isCloudStoreChromeHidden ? 0 : 1)
                .animation(.easeInOut(duration: 0.2), value: isHermesKeyboardVisible)
                .animation(.easeInOut(duration: 0.2), value: isCloudStoreChromeHidden)
                .allowsHitTesting(!isHermesKeyboardVisible && !isCloudStoreChromeHidden)
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
                onTapHermesTab: { select(kind: .hermes) }
            )
            .zIndex(20)

            SkillRunLiveStage(
                host: missionConsoleHost,
                pipController: skillRunPiPController
            )
            .zIndex(19)
        }
        .environment(\.motionStore, motionStore)
        .environment(\.chartStudioPresenter, studioPresenter)
        .environment(\.cloudSubscriptionStore, subscriptionStore)
        .environment(\.mobileAuthStore, authStore)
        .simultaneousGesture(rootSwipeGesture)
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
        .onAppear {
            // Land on the user's leftmost configured tab (the initial `.pulse`
            // placeholder may not exist in a customized layout).
            if navItems.contains(selection) == false, let first = navItems.first {
                selection = first
            }
            applyScreenshotRouteIfNeeded()
            applyHermesE2EPromptIfNeeded()
            applyComputerUseE2EProofIfNeeded()
            // First visible tab is a screen view too (the launch destination).
            MobileAnalytics.shared.track(.screenViewed, [
                "surface": Self.surface(for: selection.kind),
                "is_first_view": .bool(true)
            ])
        }
        .onChange(of: selection) { oldValue, newValue in
            // A preset-pinned inbox tab applies its filter on commit; the
            // shared store keeps whatever the user picked otherwise.
            if let preset = newValue.inboxFilterPreset {
                streamsInboxStore.filter = preset
            }
            // A deliberate tab switch: the primary navigation action on iPhone.
            MobileAnalytics.shared.track(.mobileTabSelected, ["tab": Self.routeLabel(newValue.kind)])
            MobileAnalytics.shared.track(.navRouteChanged, [
                "from_route": Self.routeLabel(oldValue.kind),
                "to_route": Self.routeLabel(newValue.kind)
            ])
            MobileAnalytics.shared.track(.screenViewed, ["surface": Self.surface(for: newValue.kind)])
        }
        .onChange(of: customization.navItems) { _, items in
            // The editor can rewrite an item in place (same id, new preset) or
            // remove the selected tab entirely. Track the live value; fall back
            // to the first tab when the selection is gone. Transient selections
            // (deep links to kinds not in the tray) are deliberately left alone.
            if let updated = items.first(where: { $0.id == selection.id }) {
                if updated != selection { selection = updated }
            } else if selection.id.hasPrefix("transient.") == false {
                selection = items.first ?? .canonical(.pulse)
            }
        }
        .onChange(of: router.pendingDestination) { _, destination in
            handleRouter(destination)
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("ShowHermesChat"))) { _ in
            select(kind: .hermes)
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("ShowAssistantsTab"))) { notification in
            let runtime = notification.userInfo?["runtime"] as? String
            if runtime == nil || runtime == AssistantRuntimeID.hermes.rawValue {
                select(kind: .hermes)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("ShowAgentWatch"))) { _ in
            openAgentWatchRoute()
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("ShowSettings"))) { _ in
            openSettingsRoute()
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("NavigateToDashboard"))) { _ in
            select(kind: .pulse)
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("ShowBurnTab"))) { _ in
            select(kind: .burn)
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("ShowFleetTab"))) { _ in
            select(kind: .fleet)
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("ShowMercuryCall"))) { notification in
            guard case .mercuryCall = MobilePendingOsRouteStore.shared.consume() else { return }
            presentMercuryCall(connectionId: notification.userInfo?["connectionId"] as? String)
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("ShowMissionConsole"))) { notification in
            guard case .mission = MobilePendingOsRouteStore.shared.consume() else { return }
            presentMissionConsole(missionId: notification.userInfo?["missionId"] as? String)
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("ShowStreamsTab"))) { _ in
            select(kind: .streams)
        }
        .onReceive(NotificationCenter.default.publisher(for: HermesGatewayPairingDeepLink.notificationName)) { notification in
            openHermesGatewayPairingRoute(notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: AIInboxDeepLink.notificationName)) { notification in
            openAIInboxRoute(itemID: AIInboxDeepLink.itemID(from: notification))
        }
        .onReceive(NotificationCenter.default.publisher(for: .hermesKeyboardFocusChanged)) { notification in
            isHermesKeyboardVisible = notification.userInfo?["focused"] as? Bool ?? false
        }
        .onReceive(NotificationCenter.default.publisher(for: .cloudStoreChromeVisibilityChanged)) { notification in
            isCloudStoreChromeHidden = notification.object as? Bool ?? false
        }
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

    @ViewBuilder
    private var contentForSelection: some View {
        switch activeItem.kind {
        case .pulse:    pulseStack
        case .burn:     burnStack
        case .insights: insightsStack
        case .streams:  streamsStack
        case .hermes:   hermesStack
        case .inbox:    inboxStack(for: activeItem)
        case .fleet:    fleetStack
        case .you:      youStack
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
    /// the user turned the gesture off in Settings → Navigation, and when
    /// any full-screen control surface is active so the gesture doesn't
    /// fight with the overlay or change tabs underneath a modal.
    private var isRootSwipeEnabled: Bool {
        customization.isSwipeNavigationEnabled
            && !isHermesKeyboardVisible
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
                guard let next = AuroraNavGestureModel.adjacent(
                    current: activeItem,
                    direction: direction,
                    destinations: navItems
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
    /// two Firestore listeners each time. Shared by BOTH inbox surfaces — the
    /// Streams segment and any first-class inbox tabs — so there is exactly one
    /// pair of listeners and one triage state no matter how many entry points
    /// the user configures.
    @State private var streamsInboxStore = AIInboxStore()
    /// Hoisted for the same reason: the fleet mirror listener survives tab
    /// swaps instead of re-opening on every return to the Fleet tab.
    @State private var fleetStore = MobileFleetStore()

    private var insightsStack: some View {
        AgentInsightsTabScreen(
            dashboardStore: insightsDashboardStore,
            hermesService: hermesService
        )
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

    /// A first-class AI Inbox tab. Each configured instance gets its own
    /// navigation stack (keyed by instance id) over the one shared store; a
    /// filter preset on the item is applied when the tab is committed (see the
    /// `selection` onChange).
    private func inboxStack(for item: AuroraNavItem) -> some View {
        NavigationStack(path: inboxPathBinding(for: item.id)) {
            AIInboxTabScreen(store: streamsInboxStore)
        }
    }

    private func inboxPathBinding(for id: String) -> Binding<NavigationPath> {
        Binding(
            get: { inboxPaths[id] ?? NavigationPath() },
            set: { inboxPaths[id] = $0 }
        )
    }

    private var fleetStack: some View {
        NavigationStack(path: $fleetPath) {
            FleetDashboardScreen(store: fleetStore)
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

    /// Selects the first configured tab of the given kind. A kind the user
    /// removed from the tray still opens — as a transient selection that
    /// renders the content without highlighting any tab — so deep links,
    /// pushes, and cross-surface routes never dead-end on a customized layout.
    private func select(kind: AuroraNavDestination) {
        if let item = navItems.first(where: { $0.kind == kind }) {
            selection = item
        } else {
            selection = AuroraNavItem(id: "transient.\(kind.rawValue)", kind: kind)
        }
    }

    private func handleRouter(_ destination: PulseRouter.Destination?) {
        guard let destination else { return }
        switch destination {
        case .burn(let focus):
            select(kind: .burn)
            // BurnView consumes focus through `initialFocus` — for runtime focus
            // (after the view is already mounted) we let the user reselect from
            // the constellation so we don't introduce store coupling.
            _ = focus
        case .streams:
            select(kind: .streams)
        case .hermes:
            select(kind: .hermes)
        case .session(let usage):
            select(kind: .pulse)
            pulsePath.append(usage)
        case .project:
            select(kind: .streams)
        case .provider(let provider):
            select(kind: .pulse)
            pulsePath.append(provider)
        }
        router.clear()
    }

    private func openAgentWatchRoute() {
        select(kind: .you)
        youPath = NavigationPath()
        youPath.append(YouRoute.computerUse)
    }

    private func openSettingsRoute() {
        select(kind: .you)
        youPath = NavigationPath()
        youPath.append(YouRoute.settings)
    }

    /// Lands a `burnbar://inbox[/{itemId}]` deep link — the tap target of an AI
    /// Inbox P1 push.
    ///
    /// When the user has a first-class Inbox tab, the link lands there (its own
    /// stack is reset and the item route pushed). Otherwise it falls back to the
    /// classic home inside the Streams stack. Either way `AIInboxDetailRoute`
    /// resolves the row from the live store, so an item the Mac resolved between
    /// the push and the tap shows the "this item is gone" pane rather than a
    /// blank screen.
    private func openAIInboxRoute(itemID: String?) {
        // Drain the stash on the live path too. The tap has been served here, so
        // leaving it parked would let a later `.task` re-navigate the user back
        // to this item after they had moved on.
        _ = AIInboxDeepLink.consumePendingItemID()
        streamsInboxStore.focus(itemID: itemID)
        if let inboxItem = navItems.first(where: { $0.kind == .inbox }) {
            selection = inboxItem
            var path = NavigationPath()
            if let itemID {
                path.append(AIInboxDetailRoute(itemID: itemID))
            }
            inboxPaths[inboxItem.id] = path
        } else {
            select(kind: .streams)
            streamsPath = NavigationPath()
            guard let itemID else { return }
            streamsPath.append(AIInboxDetailRoute(itemID: itemID))
        }
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
        select(kind: .hermes)
        showMissionConsole = true
    }

    private func openHermesGatewayPairingRoute(_: Notification) {
        settingsRouter.prepareDeepLink(anchor: SettingsAnchor.hermesCloudGateway)
        select(kind: .you)
        youPath = NavigationPath()
        youPath.append(YouRoute.settings)
        youPath.append(SettingsPageRoute.hermes)
    }

    private func applyScreenshotRouteIfNeeded() {
        guard AppStoreScreenshotMode.isEnabled, !didApplyScreenshotRoute else { return }
        didApplyScreenshotRoute = true
        switch AppStoreScreenshotMode.route {
        case "burn", "quota":
            select(kind: .burn)
        case "streams", "activity":
            select(kind: .streams)
        case "hermes", "chat":
            select(kind: .hermes)
        case "inbox":
            select(kind: .inbox)
        case "fleet":
            select(kind: .fleet)
        case "you", "account":
            select(kind: .you)
        default:
            select(kind: .pulse)
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
        select(kind: .hermes)
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
            select(kind: .you)
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
        case .inbox:    return "inbox"
        case .fleet:    return "fleet"
        case .you:      return "you"
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
        case .inbox:    return "inbox"
        case .fleet:    return "fleet"
        case .you:      return "account"
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
