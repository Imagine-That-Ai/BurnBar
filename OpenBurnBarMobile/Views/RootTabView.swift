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

    @State private var selection: TabSelection = .pulse
    @State private var router = PulseRouter()
    @State private var motionStore = MotionStore()
    @State private var hermesService = HermesService()

    // Per-tab navigation paths
    @State private var pulsePath = NavigationPath()
    @State private var burnPath = NavigationPath()
    @State private var streamsPath = NavigationPath()
    @State private var youPath = NavigationPath()

    enum TabSelection: Hashable, Equatable, Identifiable {
        case pulse
        case burn
        case streams
        case hermes
        case you

        var id: String {
            switch self {
            case .pulse:   return "pulse"
            case .burn:    return "burn"
            case .streams: return "streams"
            case .hermes:  return "hermes"
            case .you:     return "you"
            }
        }

        var label: String {
            switch self {
            case .pulse:   return "Pulse"
            case .burn:    return "Burn"
            case .streams: return "Streams"
            case .hermes:  return "Hermes"
            case .you:     return "You"
            }
        }

        var symbol: String {
            switch self {
            case .pulse:   return "waveform.path.ecg.rectangle.fill"
            case .burn:    return "flame.fill"
            case .streams: return "rectangle.stack.fill"
            case .hermes:  return "wand.and.stars"
            case .you:     return "person.crop.circle.fill"
            }
        }
    }

    var body: some View {
        Group {
            if #available(iOS 18.0, *) {
                modernTabView
            } else {
                legacyTabView
            }
        }
        .environment(\.motionStore, motionStore)
        .onChange(of: router.pendingDestination) { _, destination in
            handleRouter(destination)
        }
        .onChange(of: selection) { _, _ in
            HapticBus.tabChange()
        }
    }

    // MARK: - iOS 18+ Modern Tab Shape

    @available(iOS 18.0, *)
    @ViewBuilder
    private var modernTabView: some View {
        if #available(iOS 26.0, *) {
            modernTabContent
                .tabBarMinimizeBehavior(.onScrollDown)
        } else {
            modernTabContent
        }
    }

    @available(iOS 18.0, *)
    private var modernTabContent: some View {
        TabView(selection: $selection) {
            Tab(TabSelection.pulse.label, systemImage: TabSelection.pulse.symbol, value: TabSelection.pulse) {
                pulseStack
            }
            Tab(TabSelection.burn.label, systemImage: TabSelection.burn.symbol, value: TabSelection.burn) {
                burnStack
            }
            Tab(TabSelection.streams.label, systemImage: TabSelection.streams.symbol, value: TabSelection.streams) {
                streamsStack
            }
            Tab(TabSelection.hermes.label, systemImage: TabSelection.hermes.symbol, value: TabSelection.hermes) {
                hermesStack
            }
            Tab(TabSelection.you.label, systemImage: TabSelection.you.symbol, value: TabSelection.you) {
                youStack
            }
        }
    }

    // MARK: - iOS 17 Legacy Tab Shape

    private var legacyTabView: some View {
        TabView(selection: $selection) {
            pulseStack
                .tabItem { Label(TabSelection.pulse.label, systemImage: TabSelection.pulse.symbol) }
                .tag(TabSelection.pulse)
            burnStack
                .tabItem { Label(TabSelection.burn.label, systemImage: TabSelection.burn.symbol) }
                .tag(TabSelection.burn)
            streamsStack
                .tabItem { Label(TabSelection.streams.label, systemImage: TabSelection.streams.symbol) }
                .tag(TabSelection.streams)
            hermesStack
                .tabItem { Label(TabSelection.hermes.label, systemImage: TabSelection.hermes.symbol) }
                .tag(TabSelection.hermes)
            youStack
                .tabItem { Label(TabSelection.you.label, systemImage: TabSelection.you.symbol) }
                .tag(TabSelection.you)
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
        }
    }

    private var hermesStack: some View {
        NavigationStack {
            HermesTabView(service: hermesService)
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
