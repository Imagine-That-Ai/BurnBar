import SwiftUI
import OpenBurnBarCore

// MARK: - Pulse View
//
// New iPhone home — story-driven feed of "moments". Drives navigation to
// Burn (Quota), Streams (Sessions/Activity/Projects), and Hermes via the
// shared `PulseRouter`.

struct PulseView: View {
    let router: PulseRouter
    // Stores are owned by the tab root (`RootTabView`/`RootNavigationView`)
    // and injected so they survive tab swaps: this view remounts on every
    // tab return (the root's `contentForSelection` is a switch), and
    // per-view `@State` stores used to re-run the full ~10-round-trip load
    // each time. See `initialLoad()` for the warm-return fast path.
    let dashboard: DashboardStore
    let quotaStore: QuotaStore
    let sessionsStore: ActivityStore
    let hermesService: HermesService
    @State private var displayMode: UsageDisplayMode = .currency
    @State private var timelineScope: PulseTimelineScope = .day
    @State private var liveUsageStart = PulseWindowMetricBuilder.liveQueryStart()
    @State private var showCloudStore = false
    @AppStorage("cloudBannerDismissed") private var cloudBannerDismissed = false

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.mobileBackgroundVisibility) private var backgroundVisibility
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.cloudSubscriptionStore) private var cloudStore

    var body: some View {
        ZStack {
            AuroraBackdrop(
                colorDriver: dashboard.swarmColorDriver,
                visibility: pulseBackgroundVisibility
            )
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

                    // The hero owns the 1Hz live clock (TimelineView inside
                    // PulseHeroBurnCard) so ticking never invalidates the
                    // rest of the feed.
                    PulseHeroBurnCard(
                        rollupTotals: dashboard.windowTotals,
                        dailyPoints: dashboard.dailyPoints,
                        liveUsages: liveUsagesForPulse,
                        topProvider: topProvider,
                        displayMode: displayMode,
                        scope: timelineScope,
                        clockPaused: !shouldRunLivePulseClock
                    )
                    .padding(.horizontal, AuroraDesign.Layout.cardInset)
                    .staggeredEntrance(delay: 0.05)

                    VelocityForecastCard(
                        todayTotals: dashboard.windowTotals[.today],
                        trailingTotals: dashboard.windowTotals[.sevenDays],
                        displayMode: displayMode,
                        liveUsages: liveUsagesForPulse
                    )
                    .padding(.horizontal, AuroraDesign.Layout.cardInset)
                    .staggeredEntrance(delay: 0.10)

                    // Pro vocabulary — forecast moment. Free users see a
                    // foil band hinting at the extended cloud forecast.
                    if shouldShowForecastBand {
                        MembershipBand(
                            title: "30-day forecast, on every device",
                            detail: "Cloud syncs your full burn history — see your spend curve a month out, anywhere you sign in.",
                            variant: .upsell,
                            icon: "chart.line.uptrend.xyaxis",
                            ctaLabel: "UNLOCK"
                        ) {
                            showCloudStore = true
                        }
                        .padding(.horizontal, AuroraDesign.Layout.cardInset)
                        .staggeredEntrance(delay: 0.12)
                    }

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
            .pulseScrollEdgeChrome()
            .scrollDismissesKeyboard(.interactively)
            .trackEasterEggScroll(tag: "pulse")
            .refreshable {
                HapticBus.refreshStarted()
                await reload()
                HapticBus.refreshFinished()
            }
        }
        // Title stays for navigation semantics (back labels from pushed
        // screens); the bar itself is hidden — the tab bar already says
        // Pulse, so the big headline was pure chrome.
        .navigationTitle("Pulse")
        .toolbar(.hidden, for: .navigationBar)
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
        .task(id: shouldRunLivePulseClock) { await runLiveUsageWindowMaintenance() }
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
        // Toggles re-derive synchronously from the cached rollup docs
        // (DashboardStore.reapplyCachedRollups) — no Firestore refetch.
        .onChange(of: displayMode) { _, mode in
            HapticBus.toggle()
            dashboard.setDisplayMode(mode)
        }
        .onChange(of: timelineScope) { _, scope in
            dashboard.setWindow(scope.rollupKey)
        }
    }

    private var shouldRunLivePulseClock: Bool {
        !showCloudStore
            && MobileDecorativeRenderPolicy.allowsLiveEffects(
                visibility: backgroundVisibility,
                scenePhaseActive: scenePhase == .active
            )
    }

    private var pulseBackgroundVisibility: MobileBackgroundVisibility {
        showCloudStore ? MobileBackgroundVisibility.obscured : MobileBackgroundVisibility.prominent
    }

    private func runLiveUsageWindowMaintenance() async {
        guard shouldRunLivePulseClock else { return }
        while !Task.isCancelled {
            await MainActor.run {
                let queryStart = PulseWindowMetricBuilder.liveQueryStart()
                if queryStart != liveUsageStart {
                    liveUsageStart = queryStart
                    sessionsStore.startLiveUsageListening(since: queryStart)
                }
            }
            // `liveQueryStart` only moves at hour boundaries, so a 60s poll
            // keeps the listener window a superset of the rolling day. A
            // late re-subscribe is harmless — metrics filter by `now`.
            try? await Task.sleep(nanoseconds: 60_000_000_000)
        }
    }

    // MARK: - Loading

    private func initialLoad() async {
        // The injected stores survive tab swaps, but this view's @State
        // selection chips reset to their defaults on every remount — re-sync
        // the store before painting so a warm return shows the window the
        // chips claim (cache-only when warm; on a cold mount both sides
        // already hold the defaults, so this is a no-op).
        if dashboard.selectedWindow != timelineScope.rollupKey {
            dashboard.setWindow(timelineScope.rollupKey)
        }
        if dashboard.displayMode != displayMode {
            dashboard.setDisplayMode(displayMode)
        }
        // Warm stores skip their refetch inside `loadIfNeeded`/`refresh
        // IfStale` and only restart the listeners `onDisappear` tore down,
        // so a tab return costs zero network round-trips.
        async let d: Void = dashboard.loadIfNeeded()
        async let q: Void = quotaStore.loadIfNeeded()
        async let s: Void = sessionsStore.loadInitialIfNeeded()
        async let live: Void = sessionsStore.loadLiveUsageIfNeeded(since: liveUsageStart)
        // Full runtime refresh so the saved Remote Relay / LAN connection is
        // attached before the user opens Chart Studio. `checkReachability`
        // alone leaves `selectedConnection == .localDefault`, which is fatal
        // on iPhone (no `localhost:8642` Hermes process). The catalog is
        // shared + coalesced across surfaces and skipped while fresh.
        async let h: Void = hermesService.refreshRuntimeIfStale()
        _ = await (d, q, s, live, h)
        quotaStore.startListening()
        sessionsStore.startLiveUsageListening(since: liveUsageStart)
    }

    private func reload() async {
        async let d: Void = dashboard.refresh()
        async let q: Void = quotaStore.refresh()
        async let s: Void = sessionsStore.refresh()
        async let live: Void = sessionsStore.loadLiveUsage(since: liveUsageStart)
        async let h: Void = hermesService.refreshRuntime()
        _ = await (d, q, s, live, h)
    }

    // MARK: - Derived

    private var shouldShowCloudBanner: Bool {
        guard let cloudStore else { return false }
        if cloudBannerDismissed { return false }
        return !cloudStore.isActive
    }

    /// The inline forecast band shows for free users only. It complements
    /// the top whisper without duplicating the same CTA — the whisper sells
    /// Cloud as a whole; the band sells one specific moment (longer
    /// forecast horizons).
    private var shouldShowForecastBand: Bool {
        guard let cloudStore else { return false }
        return !cloudStore.isActive
    }

    private var topProvider: AgentProvider? {
        guard let topKey = dashboard.topProviders.first?.provider else { return nil }
        return AgentProvider.fromCatalogProviderID(topKey) ?? AgentProvider.fromPersistedToken(topKey)
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
        if let topProvider {
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
    func openHermes() { pendingDestination = .hermes }
    func openSession(_ usage: TokenUsage) { pendingDestination = .session(usage) }
    func openProject(_ project: ProjectSummary) { pendingDestination = .project(project) }
    func openProvider(_ provider: AgentProvider) { pendingDestination = .provider(provider) }
    func clear() { pendingDestination = nil }
}

// MARK: - Pulse Scroll Chrome

private struct PulseScrollEdgeChrome: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.scrollEdgeEffectHidden(true, for: .top)
        } else {
            content
        }
    }
}

private extension View {
    func pulseScrollEdgeChrome() -> some View {
        modifier(PulseScrollEdgeChrome())
    }
}
