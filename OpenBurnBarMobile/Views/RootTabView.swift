import SwiftUI
import OpenBurnBarCore

// MARK: - Root Tab View (iPhone)
//
// Aurora navigation shape: Pulse / Burn / Streams / Hermes / You.
// All tabs share a single MotionStore via the environment so the parallax
// backdrop and hero cards drift in unison.

struct RootTabView: View {
    let authStore: AuthStore
    let syncHealthStore: CloudSyncHealthStore
    let providerSummaryStore: ProviderSummaryStore
    let devicesStore: DevicesStore
    let transferStore: CredentialTransferStore

    @State private var selection: AuroraNavDestination = .pulse
    @State private var didApplyScreenshotRoute = false
    @State private var router = PulseRouter()
    @State private var motionStore = MotionStore()
    @State private var hermesService = HermesService()
    @State private var studioPresenter = ChartStudioPresenter()
    @State private var missionActivityCenter = MobileMissionActivityCenter()
    @State private var missionConsoleHost = MobileMissionConsoleHost()
    @State private var missionConsoleFABOffset: CGSize = .zero
    @State private var isMissionConsolePresented = false
    @State private var isHermesKeyboardVisible = false
    /// Shared OpenBurnBar Cloud / Hosted Quota Sync store, hoisted here so a
    /// single StoreKit observer feeds the Settings row, the Pulse upsell
    /// banner, and the dedicated `CloudStoreView`.
    @State private var subscriptionStore = HostedQuotaSubscriptionStore()

    // Per-tab navigation paths
    @State private var pulsePath = NavigationPath()
    @State private var burnPath = NavigationPath()
    @State private var streamsPath = NavigationPath()
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
                                  ?? authStore.currentIdentity?.email
                )
                .opacity(isHermesKeyboardVisible ? 0 : 1)
                .animation(.easeInOut(duration: 0.2), value: isHermesKeyboardVisible)
                .allowsHitTesting(!isHermesKeyboardVisible)
            }

            // Floating Chart Studio button — only visible while Studio is
            // minimized. Sits above the nav tray, follows the user across
            // tabs.
            ChartStudioFloatingButton(presenter: studioPresenter)

            // Floating Mission Console launcher — sibling to Chart Studio's
            // FAB. Anchored bottom-LEFT by default so the two FABs don't
            // collide. Hidden when Chart Studio is fullscreen.
            MobileMissionFAB(
                host: missionConsoleHost,
                isVisible: studioPresenter.mode != .fullscreen,
                anchorOffset: $missionConsoleFABOffset
            ) {
                isMissionConsolePresented = true
            }

            MobileMissionActivityOverlay(center: missionActivityCenter)
                .padding(.bottom, 86)
                .zIndex(8)

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
        }
        .environment(\.motionStore, motionStore)
        .environment(\.chartStudioPresenter, studioPresenter)
        .environment(\.cloudSubscriptionStore, subscriptionStore)
        .task { await subscriptionStore.load() }
        .task { missionActivityCenter.start() }
        .task { missionConsoleHost.start() }
        .sheet(isPresented: $isMissionConsolePresented) {
            MobileMissionConsoleSheet(host: missionConsoleHost) {
                isMissionConsolePresented = false
            }
        }
        .onAppear {
            applyScreenshotRouteIfNeeded()
        }
        .onChange(of: router.pendingDestination) { _, destination in
            handleRouter(destination)
        }
        .onReceive(NotificationCenter.default.publisher(for: .hermesKeyboardFocusChanged)) { notification in
            isHermesKeyboardVisible = notification.userInfo?["focused"] as? Bool ?? false
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
        NavigationStack {
            // Plan 2: the legacy `.hermes` destination now hosts the dual
            // runtime Assistants surface. The enum case stays `.hermes` so
            // existing routing/screenshot tooling remains valid.
            AssistantsTabRoot(hermesService: hermesService, dashboardSnapshot: nil)
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
                case .devices:  iPadDevicesSettingsView(hermesService: hermesService)
                case .providers: ProviderConnectionsView(showsDoneButton: false)
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
