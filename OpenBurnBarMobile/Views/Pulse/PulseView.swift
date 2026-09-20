import SwiftUI
import OpenBurnBarCore
import OpenBurnBarUI

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
                if pulseLoadPresentation == .loading {
                    ProgressView()
                        .padding(.top, MobileTheme.Spacing.xxl)
                } else if pulseLoadPresentation == .failed {
                    AuroraStatePane(
                        kind: .error,
                        icon: "exclamationmark.icloud.fill",
                        title: "Pulse couldn't load",
                        message: dashboard.error ?? "Usage failed to load.",
                        ctaLabel: mayRetryPulse ? "Try Again" : nil,
                        onCTA: mayRetryPulse ? { Task { await dashboard.refresh() } } : nil
                    )
                    .padding(.top, MobileTheme.Spacing.xxl)
                    .padding(.horizontal, AuroraDesign.Layout.cardInset)
                } else if pulseLoadPresentation == .empty {
                    AuroraStatePane(
                        kind: .empty,
                        icon: "chart.line.uptrend.xyaxis",
                        title: "No usage yet",
                        message: "Start a session to see burn here."
                    )
                    .padding(.top, MobileTheme.Spacing.xxl)
                    .padding(.horizontal, AuroraDesign.Layout.cardInset)
                } else {
                    VStack(spacing: MobileTheme.Spacing.lg) {
                        if pulseLoadPresentation == .staleRefreshFailed, let dashboardError = dashboard.error {
                            dashboardErrorBanner(dashboardError)
                                .padding(.horizontal, AuroraDesign.Layout.cardInset)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }

                        if shouldShowCloudBanner,
                           MobileProductSurfacePolicy.disposition(actionId: "store.open") == .real {
                            CloudUpsellBanner(
                                priceText: cloudStore?.product?.displayPrice,
                                onTap: { showCloudStore = true },
                                onDismiss: { cloudBannerDismissed = true }
                            )
                            .padding(.horizontal, AuroraDesign.Layout.cardInset)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }

                        pulseFeed
                            .padding(.horizontal, AuroraDesign.Layout.cardInset)
                    }
                    .padding(.top, MobileTheme.Spacing.sm)
                    .padding(.bottom, MobileTheme.Spacing.xxl)
                }
            }
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
        .accessibilityIdentifier("screen.pulse")
        .toolbarBackground(.hidden, for: .navigationBar)
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

    // MARK: - Feed

    /// The Pulse feed, in order, as it actually exists this render.
    ///
    /// An explicit list rather than a `VStack` of literals because the feed is
    /// no longer a single column: `PulseFeedLayout` needs to know how many
    /// cards there are and how wide each one wants to be *before* it can pack
    /// them into rows, and the membership band only exists for some users.
    private enum PulseCard: Hashable {
        case controls, hero, velocity, membership, quota, atlas, hermes, recents

        /// How much of the feed this card wants when there is room for columns.
        ///
        /// Full-width for the three that are read *across*: the scope controls,
        /// the hero that carries the thesis, and the horizontally-scrolling
        /// session strip. Everything else pairs up on iPad.
        var span: PulseCardSpan {
            switch self {
            case .controls, .hero, .recents: return .full
            case .velocity, .membership, .quota, .atlas, .hermes: return .single
            }
        }
    }

    private var feedCards: [PulseCard] {
        var cards: [PulseCard] = [.controls, .hero, .velocity]
        if shouldShowForecastBand { cards.append(.membership) }
        cards.append(contentsOf: [.quota, .atlas, .hermes, .recents])
        return cards
    }

    /// One immutable card plan per SwiftUI render. The membership band can
    /// appear or disappear as entitlement state arrives; recomputing
    /// `feedCards` inside the layout's deferred card closure could therefore
    /// index a shorter array with rows produced from the previous, longer one.
    private var pulseFeed: some View {
        let cards = feedCards
        return PulseFeedLayout(items: cards, span: \.span) { card, index in
            feedCard(card, index: index)
        }
    }

    @ViewBuilder
    private func feedCard(_ card: PulseCard, index: Int) -> some View {
        Group {
            switch card {
            case .controls:
                HStack(alignment: .center, spacing: MobileTheme.Spacing.sm) {
                    TimelineScopePicker(selection: $timelineScope)
                    Spacer(minLength: MobileTheme.Spacing.sm)
                    PulseDisplayModeToggle(displayMode: $displayMode)
                }
            case .hero:
                // The hero owns the 1Hz live clock (TimelineView inside
                // PulseHeroBurnCard) so ticking never invalidates the rest of
                // the feed.
                PulseHeroBurnCard(
                    rollupTotals: dashboard.windowTotals,
                    dailyPoints: dashboard.dailyPoints,
                    liveUsages: liveUsagesForPulse,
                    topProvider: topProvider,
                    displayMode: displayMode,
                    scope: timelineScope,
                    clockPaused: !shouldRunLivePulseClock
                )
            case .velocity:
                VelocityForecastCard(
                    todayTotals: dashboard.windowTotals[.today],
                    trailingTotals: dashboard.windowTotals[.sevenDays],
                    displayMode: displayMode,
                    liveUsages: liveUsagesForPulse
                )
            case .membership:
                // Pro vocabulary — forecast moment. Free users see a foil band
                // hinting at the extended cloud forecast.
                MembershipBand(
                    title: "30-day forecast, on every device",
                    detail: "Cloud syncs your full burn history — see your spend curve a month out, anywhere you sign in.",
                    variant: .upsell,
                    icon: "chart.line.uptrend.xyaxis",
                    ctaLabel: "UNLOCK"
                ) {
                    showCloudStore = true
                }
            case .quota:
                QuotaPulseCard(
                    snapshots: quotaStore.snapshots,
                    onSelect: { providerKey in
                        router.openBurn(focus: providerKey)
                    },
                    onOpenBurn: { router.openBurn(focus: nil) }
                )
            case .atlas:
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
            case .hermes:
                HermesQuickAskCard(
                    service: hermesService,
                    suggestedPrompts: suggestedPrompts,
                    onOpenHermes: { router.openHermes() }
                )
            case .recents:
                RecentSessionsStripCard(
                    sessions: sessionsStore.usages,
                    onSelect: { router.openSession($0) },
                    onSeeAll: { router.openStreams() }
                )
            }
        }
        // Was eight hand-tuned delays (0.0/0.05/0.10/0.12/0.15/0.20/0.25/0.30)
        // that drifted every time a card was inserted. One token, one rule, and
        // Reduce Motion collapses the whole group to simultaneous.
        .staggeredEntrance(delay: MotionTokens.stagger(index: index, reduceMotion: reduceMotion))
    }

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
        // Full runtime refresh so the saved Remote Relay / LAN connection is
        // attached before the user opens Chart Studio. `checkReachability`
        // alone leaves `selectedConnection == .localDefault`, which is fatal
        // on iPhone (no `localhost:8642` Hermes process). The catalog is
        // shared + coalesced across surfaces and skipped while fresh.
        async let h: Void = hermesService.refreshRuntimeIfStale()
        _ = await (d, q, s, h)
        quotaStore.startListening()
        // Live usage is seeded by the listener's own initial snapshot rather
        // than a separate one-shot fetch: `listenToUsageSince` issues the same
        // `endTime`-ordered, `liveUsageDocumentLimit`-capped query a seed GET
        // would, so pairing the two doubled the read of up to 2,000 usage docs
        // on every cold open. Until the first delivery lands the cards fall
        // back to `rawUsages` (see `liveUsagesForPulse`) — the same path a warm
        // tab return already uses.
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

    // MARK: - Error surfacing

    /// True when the store holds any cached rollup docs worth painting.
    /// Gates the blocking error pane: with cached data on screen a failed
    /// refresh only earns the compact banner.
    private var hasDashboardData: Bool {
        !dashboard.rollupsByWindow.isEmpty
    }

    private var pulseLoadPresentation: MobilePulseLoadPresentation {
        MobilePulseWindowPolicy.loadPresentation(
            isLoading: dashboard.isLoading,
            failed: dashboard.error != nil,
            hasCachedData: hasDashboardData
        )
    }

    private var mayRetryPulse: Bool {
        MobileProductSurfacePolicy.disposition(actionId: "pulse.retry") == .real
    }

    /// Compact, non-blocking refresh-failure banner shown above the feed
    /// while cached dashboard data is still visible.
    private func dashboardErrorBanner(_ message: String) -> some View {
        HStack(spacing: MobileTheme.Spacing.sm) {
            Image(systemName: "exclamationmark.icloud.fill")
                .font(MobileTheme.Typography.headline)
                .foregroundStyle(MobileTheme.Colors.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text("Couldn't refresh usage")
                    .font(MobileTheme.Typography.caption.bold())
                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                Text(message)
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: MobileTheme.Spacing.sm)
            if mayRetryPulse {
                Button("Retry") {
                    Task { await dashboard.refresh() }
                }
                .font(MobileTheme.Typography.caption.bold())
                .foregroundStyle(MobileTheme.Colors.accent)
                .buttonStyle(.plain)
            }
        }
        .padding(MobileTheme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                .fill(MobileTheme.Colors.warning.opacity(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                        .stroke(MobileTheme.Colors.warning.opacity(0.35), lineWidth: 0.5)
                )
        )
        .accessibilityElement(children: .combine)
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
