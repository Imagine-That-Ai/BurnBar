import SwiftUI
import OpenBurnBarCore

// MARK: - Pulse View
//
// New iPhone home — story-driven feed of "moments". Drives navigation to
// Burn (Quota), Streams (Sessions/Activity/Projects), and Hermes via the
// shared `PulseRouter`.

struct PulseView: View {
    @State private var dashboard = DashboardStore()
    @State private var quotaStore = QuotaStore()
    @State private var sessionsStore = ActivityStore()
    @State private var hermesService = HermesService()
    @State private var displayMode: UsageDisplayMode = .currency

    let router: PulseRouter

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            AuroraBackdrop()
            ScrollView {
                VStack(spacing: MobileTheme.Spacing.lg) {
                    PulseHeroBurnCard(
                        total: dashboard.windowTotals[.today],
                        trailingTotal: dashboard.windowTotals[.sevenDays],
                        dailyPoints: dashboard.dailyPoints,
                        topProvider: topProvider,
                        displayMode: $displayMode
                    )
                    .padding(.horizontal, AuroraDesign.Layout.cardInset)
                    .staggeredEntrance(delay: 0.0)

                    VelocityForecastCard(
                        todayTotals: dashboard.windowTotals[.today],
                        trailingTotals: dashboard.windowTotals[.sevenDays],
                        displayMode: displayMode
                    )
                    .padding(.horizontal, AuroraDesign.Layout.cardInset)
                    .staggeredEntrance(delay: 0.05)

                    QuotaPulseCard(
                        snapshots: quotaStore.snapshots,
                        onSelect: { providerKey in
                            router.openBurn(focus: providerKey)
                        },
                        onOpenBurn: { router.openBurn(focus: nil) }
                    )
                    .padding(.horizontal, AuroraDesign.Layout.cardInset)
                    .staggeredEntrance(delay: 0.10)

                    TrendAtlasCard(
                        dailyPoints: dashboard.dailyPoints,
                        displayMode: displayMode,
                        windowTotals: dashboard.windowTotals,
                        providerSummaries: dashboard.topProviders,
                        modelSummaries: dashboard.topModels,
                        deviceSummaries: dashboard.topDevices,
                        recentUsages: sessionsStore.usages,
                        hermesService: hermesService
                    )
                    .padding(.horizontal, AuroraDesign.Layout.cardInset)
                    .staggeredEntrance(delay: 0.15)

                    HermesQuickAskCard(
                        service: hermesService,
                        suggestedPrompts: suggestedPrompts,
                        onOpenHermes: { router.openHermes() }
                    )
                    .padding(.horizontal, AuroraDesign.Layout.cardInset)
                    .staggeredEntrance(delay: 0.20)

                    RecentSessionsStripCard(
                        sessions: sessionsStore.usages,
                        onSelect: { router.openSession($0) },
                        onSeeAll: { router.openStreams() }
                    )
                    .padding(.horizontal, AuroraDesign.Layout.cardInset)
                    .staggeredEntrance(delay: 0.25)
                }
                .padding(.top, MobileTheme.Spacing.sm)
                .padding(.bottom, MobileTheme.Spacing.xxl)
            }
            .scrollDismissesKeyboard(.interactively)
            .refreshable {
                HapticBus.refreshStarted()
                await reload()
                HapticBus.refreshFinished()
            }
        }
        .navigationTitle("Pulse")
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(.hidden, for: .navigationBar)
        .task { await initialLoad() }
        .onDisappear {
            dashboard.stopListening()
            quotaStore.stopListening()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await dashboard.refresh() }
            // Re-load the full Hermes runtime (connections + reachability +
            // models) when Pulse comes back to the foreground so Chart Studio
            // inherits the user's saved Remote Relay / LAN endpoint instead of
            // the localhost default.
            Task { await hermesService.refreshRuntime() }
        }
        .onChange(of: displayMode) { _, mode in
            HapticBus.toggle()
            dashboard.setDisplayMode(mode)
            Task { await dashboard.refresh() }
        }
    }

    // MARK: - Loading

    private func initialLoad() async {
        async let d: Void = dashboard.load()
        async let q: Void = quotaStore.load()
        async let s: Void = sessionsStore.loadInitial()
        // Full runtime refresh so the saved Remote Relay / LAN connection is
        // attached before the user opens Chart Studio. `checkReachability`
        // alone leaves `selectedConnection == .localDefault`, which is fatal
        // on iPhone (no `localhost:8642` Hermes process).
        async let h: Void = hermesService.refreshRuntime()
        _ = await (d, q, s, h)
        quotaStore.startListening()
    }

    private func reload() async {
        async let d: Void = dashboard.refresh()
        async let q: Void = quotaStore.refresh()
        async let s: Void = sessionsStore.refresh()
        _ = await (d, q, s)
    }

    // MARK: - Derived

    private var topProvider: AgentProvider? {
        guard let topKey = dashboard.topProviders.first?.provider else { return nil }
        return AgentProvider.fromPersistedToken(topKey)
    }

    private var suggestedPrompts: [String] {
        var prompts: [String] = [
            "Why did I burn so much today?",
            "Show my biggest sessions",
            "Forecast end-of-day spend"
        ]
        if let topProvider = topProvider {
            prompts.append("Why is \(topProvider.displayName) so dominant?")
        }
        return prompts
    }
}

// MARK: - Pulse Router

@Observable
@MainActor
final class PulseRouter {
    enum Destination: Hashable {
        case burn(focus: String?)
        case streams
        case hermes
        case session(TokenUsage)
        case project(ProjectSummary)
        case provider(AgentProvider)
    }

    var pendingDestination: Destination?

    func openBurn(focus: String?) { pendingDestination = .burn(focus: focus) }
    func openStreams() { pendingDestination = .streams }
    func openHermes()  { pendingDestination = .hermes }
    func openSession(_ usage: TokenUsage) { pendingDestination = .session(usage) }
    func openProject(_ project: ProjectSummary) { pendingDestination = .project(project) }
    func openProvider(_ provider: AgentProvider) { pendingDestination = .provider(provider) }
    func clear() { pendingDestination = nil }
}
