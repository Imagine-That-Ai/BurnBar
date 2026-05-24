import SwiftUI
import OpenBurnBarCore
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
    #endif

    let authStore: AuthStore
    let syncHealthStore: CloudSyncHealthStore
    let providerSummaryStore: ProviderSummaryStore
    let devicesStore: DevicesStore
    let transferStore: CredentialTransferStore

    @State private var selection: AuroraNavDestination = .pulse
    @State private var didApplyScreenshotRoute = false
    #if DEBUG
    @State private var didApplyHermesE2EPrompt = false
    @State private var didApplyComputerUseE2EProof = false
    #endif
    @State private var router = PulseRouter()
    @State private var motionStore = MotionStore()
    @State private var hermesService = HermesService()
    @State private var studioPresenter = ChartStudioPresenter()
    @State private var missionActivityCenter = MobileMissionActivityCenter()
    @State private var missionConsoleHost = MobileMissionConsoleHost()
    @State private var missionConsoleFABOffset: CGSize = .zero
    @State private var isMissionConsolePresented = false
    @State private var isHermesKeyboardVisible = false
    @State private var isCloudStoreChromeHidden = false
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

    private let destinations = AuroraNavDestination.allCases

    var body: some View {
        ZStack {
            if selection == .hermes {
                contentForSelection
            } else {
                contentForSelection
                    .ignoresSafeArea(.keyboard)
            }

            VStack(spacing: 0) {
                Spacer()
                AuroraNavigationTray(
                    selection: $selection,
                    destinations: destinations,
                    userPhotoURL: authStore.currentIdentity?.photoURL,
                    userDisplayName: authStore.currentIdentity?.displayName
                                  ?? authStore.currentIdentity?.email,
                    isCloudMember: subscriptionStore.isActive
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

            // Floating Mission Console launcher — sibling to Chart Studio's
            // FAB. Anchored bottom-LEFT by default so the two FABs don't
            // collide. Hidden when Chart Studio is fullscreen.
            MobileMissionFAB(
                host: missionConsoleHost,
                isVisible: studioPresenter.mode != .fullscreen && !isCloudStoreChromeHidden,
                anchorOffset: $missionConsoleFABOffset
            ) {
                isMissionConsolePresented = true
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
        .task(id: authStore.currentIdentity?.uid) { await subscriptionStore.load() }
        .task(id: authStore.currentIdentity?.uid) { applyHermesE2EPromptIfNeeded() }
        .task(id: authStore.currentIdentity?.uid) { applyComputerUseE2EProofIfNeeded() }
        .task { missionActivityCenter.start() }
        .task { missionConsoleHost.start() }
        .task { liveStagePresenter.observe(liveStageSingleton.state) }
        .task { liveStageSingleton.installLiveActivityIntentRouter() }
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
        .sheet(isPresented: $isMissionConsolePresented) {
            MobileMissionConsoleSheet(host: missionConsoleHost) {
                isMissionConsolePresented = false
            }
        }
        .onAppear {
            applyScreenshotRouteIfNeeded()
            applyHermesE2EPromptIfNeeded()
            applyComputerUseE2EProofIfNeeded()
        }
        .onChange(of: router.pendingDestination) { _, destination in
            handleRouter(destination)
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("ShowHermesChat"))) { _ in
            selection = .hermes
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("ShowAssistantsTab"))) { notification in
            let runtime = notification.userInfo?["runtime"] as? String
            if runtime == nil || runtime == AssistantRuntimeID.hermes.rawValue {
                selection = .hermes
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("ShowAgentWatch"))) { _ in
            openAgentWatchRoute()
        }
        .onReceive(NotificationCenter.default.publisher(for: .hermesKeyboardFocusChanged)) { notification in
            isHermesKeyboardVisible = notification.userInfo?["focused"] as? Bool ?? false
        }
        .onReceive(NotificationCenter.default.publisher(for: .cloudStoreChromeVisibilityChanged)) { notification in
            isCloudStoreChromeHidden = notification.object as? Bool ?? false
        }
    }

    @ViewBuilder
    private var contentForSelection: some View {
        switch selection {
        case .pulse:    pulseStack
        case .burn:     burnStack
        case .insights: insightsStack
        case .streams:  streamsStack
        case .hermes:   hermesStack
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

    @State private var insightsDashboardStore = DashboardStore()

    private var insightsStack: some View {
        AgentInsightsTabScreen(
            dashboardStore: insightsDashboardStore,
            hermesService: hermesService
        )
    }

    // MARK: - Stacks

    private var pulseStack: some View {
        NavigationStack(path: $pulsePath) {
            PulseView(router: router)
                .navigationDestination(for: TokenUsage.self) { SessionDetailView(usage: $0) }
                .navigationDestination(for: AgentProvider.self) { ProviderDashboardView(provider: $0) }
        }
    }

    private var burnStack: some View {
        NavigationStack(path: $burnPath) {
            BurnView()
                .navigationDestination(for: AgentProvider.self) { ProviderDashboardView(provider: $0) }
        }
    }

    private var streamsStack: some View {
        NavigationStack(path: $streamsPath) {
            StreamsView()
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
                case .devices:  iPadDevicesSettingsView(store: devicesStore, hermesService: hermesService)
                case .providers: ProviderConnectionsView(showsDoneButton: false)
                case .computerUse: AgentWatchScreen(
                    authUID: authStore.currentIdentity?.uid,
                    hermesService: hermesService
                )
                }
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
            print("OpenBurnBarMobile Hermes E2E RootTab skip alreadyApplied")
            Self.hermesE2ELogger.debug("Skipping Hermes E2E prompt because it was already applied")
            return
        }
        let prompt = ProcessInfo.processInfo.environment["OPENBURNBAR_E2E_HERMES_PROMPT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let prompt, !prompt.isEmpty else {
            print("OpenBurnBarMobile Hermes E2E RootTab skip emptyPrompt")
            Self.hermesE2ELogger.debug("Skipping Hermes E2E prompt because OPENBURNBAR_E2E_HERMES_PROMPT is empty")
            return
        }
        guard authStore.currentIdentity?.uid != nil else {
            print("OpenBurnBarMobile Hermes E2E RootTab skip authState=\(authStateLabel(authStore.state))")
            Self.hermesE2ELogger.info("Skipping Hermes E2E prompt because auth state is \(authStateLabel(authStore.state), privacy: .public)")
            return
        }
        let modelID = ProcessInfo.processInfo.environment["OPENBURNBAR_E2E_HERMES_MODEL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedModelID = (modelID?.isEmpty == false) ? modelID! : "default"
        print("OpenBurnBarMobile Hermes E2E RootTab apply promptCharacters=\(prompt.count) model=\(selectedModelID)")
        Self.hermesE2ELogger.info("Applying Hermes E2E prompt promptCharacters=\(prompt.count, privacy: .public) model=\(selectedModelID, privacy: .public)")
        didApplyHermesE2EPrompt = true
        selection = .hermes
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await hermesService.refreshRuntime()
            hermesService.startNewSession()
            if let modelID, !modelID.isEmpty {
                print("OpenBurnBarMobile Hermes E2E RootTab selectingModel=\(modelID)")
                Self.hermesE2ELogger.info("Selecting Hermes E2E model \(modelID, privacy: .public)")
                hermesService.selectModelIDForAutomation(modelID)
            }
            print("OpenBurnBarMobile Hermes E2E RootTab send")
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
            print("OpenBurnBarMobile ComputerUseE2E skip auth unavailable")
            return
        }
        didApplyComputerUseE2EProof = true
        Task { @MainActor in
            print("OpenBurnBarMobile ComputerUseE2E refresh_runtime_start")
            await hermesService.refreshRuntime()
            if hermesService.selectedConnection.id == HermesConnectionRecord.localDefault.id {
                let selected = hermesService.connectToSuggestedRelay(refresh: false)
                print("OpenBurnBarMobile ComputerUseE2E suggested_relay_selected=\(selected) selected=\(hermesService.selectedConnection.id) mode=\(hermesService.selectedConnection.mode.rawValue)")
            } else {
                print("OpenBurnBarMobile ComputerUseE2E existing_connection selected=\(hermesService.selectedConnection.id) mode=\(hermesService.selectedConnection.mode.rawValue)")
            }
            selection = .you
            if youPath.isEmpty {
                youPath.append(YouRoute.computerUse)
            }
            print("OpenBurnBarMobile ComputerUseE2E opened Agent Watch")
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
