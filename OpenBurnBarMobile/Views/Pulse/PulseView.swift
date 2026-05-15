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
    @State private var timelineScope: PulseTimelineScope = .day
    @State private var liveNow = Date()
    @State private var liveUsageStart = PulseWindowMetricBuilder.todayStart()
    @State private var showCloudStore = false
    @AppStorage("cloudBannerDismissed") private var cloudBannerDismissed = false

    let router: PulseRouter

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.cloudSubscriptionStore) private var cloudStore

    var body: some View {
        ZStack {
            AuroraBackdrop()
            PulseDepthBackdrop()
            ScrollView {
                VStack(spacing: MobileTheme.Spacing.lg) {
                    if shouldShowCloudBanner {
                        CloudUpsellBanner(
                            priceText: cloudStore?.product?.displayPrice,
                            onTap: { showCloudStore = true },
                            onDismiss: { cloudBannerDismissed = true }
                        )
                        .padding(.horizontal, AuroraDesign.Layout.cardInset)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    HStack(alignment: .center, spacing: MobileTheme.Spacing.sm) {
                        TimelineScopePicker(selection: $timelineScope)
                        Spacer(minLength: MobileTheme.Spacing.sm)
                        PulseDisplayModeToggle(displayMode: $displayMode)
                    }
                    .padding(.horizontal, AuroraDesign.Layout.cardInset)
                    .staggeredEntrance(delay: 0.0)

                    let metrics = PulseWindowMetricBuilder.metrics(
                        scope: timelineScope,
                        rollupTotals: dashboard.windowTotals,
                        liveUsages: liveUsagesForPulse,
                        now: liveNow
                    )
                    PulseHeroBurnCard(
                        total: metrics.total,
                        trailingTotal: metrics.trailingTotal,
                        dailyPoints: dashboard.dailyPoints,
                        liveUsages: liveUsagesForPulse,
                        topProvider: topProvider,
                        displayMode: displayMode,
                        scope: timelineScope,
                        now: liveNow
                    )
                    .padding(.horizontal, AuroraDesign.Layout.cardInset)
                    .staggeredEntrance(delay: 0.05)

                    VelocityForecastCard(
                        todayTotals: dashboard.windowTotals[.today],
                        trailingTotals: dashboard.windowTotals[.sevenDays],
                        displayMode: displayMode
                    )
                    .padding(.horizontal, AuroraDesign.Layout.cardInset)
                    .staggeredEntrance(delay: 0.10)

                    QuotaPulseCard(
                        snapshots: quotaStore.snapshots,
                        onSelect: { providerKey in
                            router.openBurn(focus: providerKey)
                        },
                        onOpenBurn: { router.openBurn(focus: nil) }
                    )
                    .padding(.horizontal, AuroraDesign.Layout.cardInset)
                    .staggeredEntrance(delay: 0.15)

                    TrendAtlasCard(
                        dailyPoints: dashboard.dailyPoints,
                        displayMode: displayMode,
                        windowTotals: dashboard.windowTotals,
                        providerSummaries: dashboard.topProviders,
                        modelSummaries: dashboard.topModels,
                        deviceSummaries: dashboard.topDevices,
                        recentUsages: sessionsStore.rawUsages.isEmpty ? sessionsStore.usages : sessionsStore.rawUsages,
                        hermesService: hermesService
                    )
                    .padding(.horizontal, AuroraDesign.Layout.cardInset)
                    .staggeredEntrance(delay: 0.20)

                    HermesQuickAskCard(
                        service: hermesService,
                        suggestedPrompts: suggestedPrompts,
                        onOpenHermes: { router.openHermes() }
                    )
                    .padding(.horizontal, AuroraDesign.Layout.cardInset)
                    .staggeredEntrance(delay: 0.25)

                    RecentSessionsStripCard(
                        sessions: sessionsStore.usages,
                        onSelect: { router.openSession($0) },
                        onSeeAll: { router.openStreams() }
                    )
                    .padding(.horizontal, AuroraDesign.Layout.cardInset)
                    .staggeredEntrance(delay: 0.30)
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
        .sheet(isPresented: $showCloudStore) {
            NavigationStack {
                CloudStoreView(onClose: { showCloudStore = false })
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .animation(MobileTheme.Animation.gentle, value: shouldShowCloudBanner)
        .onDisappear {
            dashboard.stopListening()
            quotaStore.stopListening()
            sessionsStore.stopLiveUsageListening()
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { now in
            liveNow = now
            let todayStart = PulseWindowMetricBuilder.todayStart(now: now)
            guard todayStart != liveUsageStart else { return }
            liveUsageStart = todayStart
            sessionsStore.startLiveUsageListening(since: todayStart)
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await dashboard.refresh() }
            sessionsStore.startLiveUsageListening(since: liveUsageStart)
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
        .onChange(of: timelineScope) { _, scope in
            dashboard.setWindow(scope.rollupKey)
            Task { await dashboard.refresh() }
        }
    }

    // MARK: - Loading

    private func initialLoad() async {
        async let d: Void = dashboard.load()
        async let q: Void = quotaStore.load()
        async let s: Void = sessionsStore.loadInitial()
        async let live: Void = sessionsStore.loadLiveUsage(since: liveUsageStart)
        // Full runtime refresh so the saved Remote Relay / LAN connection is
        // attached before the user opens Chart Studio. `checkReachability`
        // alone leaves `selectedConnection == .localDefault`, which is fatal
        // on iPhone (no `localhost:8642` Hermes process).
        async let h: Void = hermesService.refreshRuntime()
        _ = await (d, q, s, live, h)
        quotaStore.startListening()
        sessionsStore.startLiveUsageListening(since: liveUsageStart)
    }

    private func reload() async {
        async let d: Void = dashboard.refresh()
        async let q: Void = quotaStore.refresh()
        async let s: Void = sessionsStore.refresh()
        async let live: Void = sessionsStore.loadLiveUsage(since: liveUsageStart)
        _ = await (d, q, s, live)
    }

    // MARK: - Derived

    private var shouldShowCloudBanner: Bool {
        guard let cloudStore else { return false }
        if cloudBannerDismissed { return false }
        return !cloudStore.isActive
    }

    private var topProvider: AgentProvider? {
        guard let topKey = dashboard.topProviders.first?.provider else { return nil }
        return AgentProvider.fromPersistedToken(topKey)
    }

    private var liveUsagesForPulse: [TokenUsage] {
        sessionsStore.liveUsages.isEmpty ? sessionsStore.rawUsages : sessionsStore.liveUsages
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
