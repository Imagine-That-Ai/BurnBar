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

    // Per-tab navigation paths
    @State private var pulsePath = NavigationPath()
    @State private var burnPath = NavigationPath()
    @State private var streamsPath = NavigationPath()
    @State private var youPath = NavigationPath()

    private let destinations = AuroraNavDestination.allCases

    var body: some View {
        ZStack {
            contentForSelection
                .ignoresSafeArea(.keyboard)

            VStack(spacing: 0) {
                Spacer()
                AuroraNavigationTray(
                    selection: $selection,
                    destinations: destinations
                )
            }
        }
        .environment(\.motionStore, motionStore)
        .onAppear {
            applyScreenshotRouteIfNeeded()
        }
        .onChange(of: router.pendingDestination) { _, destination in
            handleRouter(destination)
        }
    }

    @ViewBuilder
    private var contentForSelection: some View {
        switch selection {
        case .pulse:   pulseStack
        case .burn:    burnStack
        case .streams: streamsStack
        case .hermes:  hermesStack
        case .you:     youStack
        }
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
            HermesConversationListView(service: hermesService)
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
                case .settings: SettingsHubView()
                case .devices:  iPadDevicesSettingsView()
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
