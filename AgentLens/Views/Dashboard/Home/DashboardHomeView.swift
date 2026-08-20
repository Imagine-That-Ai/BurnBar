import SwiftUI
import OpenBurnBarInsights
import OpenBurnBarKernel

// MARK: - Dashboard Home
//
// The launch surface: the AI Inbox filling the main area, with a live fleet +
// quota rail beside it.
//
// Layout is one `GeometryReader` driving every breakpoint. Not a
// `NavigationSplitView`: `InboxView` is already a hand-rolled `HStack`, and
// this whole view sits inside `DashboardView`'s split view — three column
// systems is one too many.

struct DashboardHomeView: View {
    let dataStore: DataStore
    let settingsManager: SettingsManager
    let inboxModel: InboxModel
    let fleetModel: LiveFleetModel
    let onOpenSessionLog: (String) -> Void
    let onOpenSettings: () -> Void
    let onOpenInbox: (String?) -> Void
    let onOpenQuota: () -> Void
    /// Hands a question to the chat surface. Only the `ask` shell calls it.
    let onAsk: (String) -> Void
    let memoryApproval: InboxMemoryApprovalHandler?

    @Environment(\.backdropInk) private var ink
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @AppStorage(DashboardHomeInboxMode.storageKey) private var inboxModeRaw = DashboardHomeInboxMode.reader.rawValue
    @AppStorage(DashboardHomeFleetMode.storageKey) private var fleetModeRaw = DashboardHomeFleetMode.rows.rawValue
    @AppStorage(DashboardHomeQuotaMode.storageKey) private var quotaModeRaw = DashboardHomeQuotaMode.bars.rawValue
    @AppStorage(DashboardHomeRailMetrics.widthStorageKey) private var storedRailWidth =
        Double(DashboardHomeRailMetrics.defaultWidth)
    @AppStorage(DashboardHomeRailMetrics.collapsedStorageKey) private var railCollapsed = false
    /// Opt-in that brings the rail back on the shells whose whole point is not
    /// having one (Focus, Ask, Canvas). Separate from `railCollapsed` so
    /// hiding the rail on Ledger does not also hide it on Cockpit, and so
    /// showing it on Canvas is remembered as the deliberate choice it was.
    @AppStorage(DashboardHomeComposition.ambientRailStorageKey) private var railAmbientOptIn = false

    @State private var band: DashboardHomeRailMetrics.Band = .wide
    /// Live drag width, so a drag never writes `@AppStorage` per frame.
    @State private var dragWidth: Double?
    @State private var brief: InsightAnalysisResult?
    @State private var briefKey: String = ""
    /// Quota snapshots for the widened digest.
    ///
    /// Held the way `DashboardHomeQuotaPanel` holds it — the `@Observable`
    /// service itself, so a refreshed snapshot redraws whatever reads it — and
    /// held *here* rather than only in the rail, because the three shells that
    /// hide the rail need headroom just as much as the five that show it.
    @State private var quotaService = ProviderQuotaService.shared

    // MARK: Composition

    /// How the active `DashboardLayout` wants Home arranged.
    ///
    /// Read from `settingsManager` rather than `DashboardLayout.current` so the
    /// surface re-renders the moment the switcher writes a new layout, instead of
    /// waiting for the next unrelated invalidation.
    private var composition: DashboardHomeComposition {
        DashboardHomeComposition.resolve(layout: settingsManager.dashboardLayout)
    }

    // MARK: Mode bindings

    private var inboxMode: Binding<DashboardHomeInboxMode> {
        Binding(
            get: {
                // A layout that owns its own rendering dictates the mode; only
                // the list-shaped shells let the switcher speak.
                guard composition.honorsInboxMode else { return composition.inboxMode }
                return DashboardHomeInboxMode(rawValue: inboxModeRaw) ?? .reader
            },
            set: { inboxModeRaw = $0.rawValue }
        )
    }

    /// Whether the user wants the rail beside *this* shell.
    ///
    /// Two keys, one meaning: rail-forward shells read the collapse flag, ambient
    /// shells read the opt-in. Writing through the binding always touches the key
    /// that governs the shell currently on screen.
    private var railWanted: Binding<Bool> {
        Binding(
            get: { composition.prefersRail ? railCollapsed == false : railAmbientOptIn },
            set: { wanted in
                if composition.prefersRail {
                    railCollapsed = (wanted == false)
                } else {
                    railAmbientOptIn = wanted
                }
            }
        )
    }

    private var fleetMode: Binding<DashboardHomeFleetMode> {
        Binding(
            get: {
                let stored = DashboardHomeFleetMode(rawValue: fleetModeRaw) ?? .rows
                // A mode can become unavailable underneath the user — the
                // watchers disarm on display sleep. Fall back rather than
                // rendering a timeline that has nothing honest to plot.
                return availableFleetModes.contains(stored) ? stored : .rows
            },
            set: { fleetModeRaw = $0.rawValue }
        )
    }

    private var quotaMode: Binding<DashboardHomeQuotaMode> {
        Binding(
            get: { DashboardHomeQuotaMode(rawValue: quotaModeRaw) ?? .bars },
            set: { quotaModeRaw = $0.rawValue }
        )
    }

    private var availableFleetModes: [DashboardHomeFleetMode] {
        DashboardHomeFleetMode.availableCases(hasRealTimeCoverage: fleetModel.hasRealTimeCoverage)
    }

    private var railIsExpanded: Bool {
        DashboardHomeRailMetrics.railIsExpanded(userWantsRail: railWanted.wrappedValue, band: band)
    }

    var body: some View {
        GeometryReader { geo in
            let resolvedWidth = DashboardHomeRailMetrics.resolvedWidth(
                stored: CGFloat(dragWidth ?? storedRailWidth),
                band: band
            )

            VStack(spacing: 0) {
                homeHeaderStrip

                HStack(spacing: 0) {
                    shellRegion
                        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)

                    if railIsExpanded {
                        ResizableSectionDivider(
                            axis: .vertical,
                            onDrag: { delta in
                                // Dragging left grows the rail, so the delta is
                                // inverted relative to the rail's leading edge.
                                let base = dragWidth ?? storedRailWidth
                                dragWidth = min(
                                    max(base - Double(delta), Double(DashboardHomeRailMetrics.minWidth)),
                                    Double(DashboardHomeRailMetrics.maxWidth)
                                )
                            },
                            onCommit: {
                                if let dragWidth { storedRailWidth = dragWidth }
                                dragWidth = nil
                            },
                            onReset: {
                                dragWidth = nil
                                storedRailWidth = Double(DashboardHomeRailMetrics.defaultWidth)
                            }
                        )

                        rail
                            .frame(width: resolvedWidth)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    } else if band == .narrow || railWanted.wrappedValue == false {
                        collapsedStub
                            .transition(.opacity)
                    }
                }
            }
            .onAppear { updateBand(width: geo.size.width) }
            .onChange(of: geo.size.width) { _, width in updateBand(width: width) }
        }
        .accessibilityIdentifier(OBBAccessibilityID.dashboardHomeRoot)
        // Home reads headroom on every shell now, so the refresh belongs to
        // Home rather than to the rail panel — otherwise the three shells that
        // hide the rail, and any shell whose rail the user collapsed, would show
        // a permanently empty quota signal. `refreshIfNeeded` is age-gated, so
        // the extra call site costs nothing when the rail already refreshed.
        .task { await quotaService.refreshIfNeeded(dataStore: dataStore) }
    }

    // MARK: - Header

    private var homeHeaderStrip: some View {
        let layout = settingsManager.dashboardLayout

        return HStack(spacing: DesignSystem.Spacing.sm) {
            Text(layout.displayName.uppercased())
                .font(DesignSystem.Typography.caption)
                .fontWeight(.semibold)
                .tracking(0.8)
                .foregroundStyle(ink.secondary)

            Text(layout.tagline)
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(ink.subtle)
                .lineLimit(1)

            Spacer(minLength: 0)

            // Shown only where its three options actually change something. The
            // bespoke shells own their rendering, so a switcher here would offer
            // choices the surface ignores.
            if composition.honorsInboxMode {
                GlassSegmentedSwitcher(
                    selection: inboxMode,
                    iconOnly: false,
                    accessibilityID: OBBAccessibilityID.dashboardHomeInboxSwitcher
                )
            }

            Button {
                withAnimation(reduceMotion ? .easeOut(duration: 0.12) : DesignSystem.Animation.snappy) {
                    railWanted.wrappedValue.toggle()
                }
            } label: {
                Image(systemName: railWanted.wrappedValue ? "sidebar.right" : "sidebar.trailing")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ink.icon)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(OBBAccessibilityID.dashboardHomeRailToggle)
            .help(railWanted.wrappedValue ? "Hide fleet and quota (⌘⌥R)" : "Show fleet and quota (⌘⌥R)")
        }
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, DesignSystem.Spacing.xs)
    }

    // MARK: - Shell region

    /// The main area, rendered as whatever shell the active layout resolves to.
    ///
    /// The two list-shaped shells stay on `InboxView` / `InboxPriorityBoard` —
    /// those already *are* "every row in order" and "equal tiles". The other six
    /// read `HomeInboxDigest` and draw their own surface, and because they do not
    /// mount `InboxView` they take the shared cadence themselves.
    @ViewBuilder
    private var shellRegion: some View {
        switch composition.shell {
        case .ledger:
            inboxSurface(paneStyle: inboxMode.wrappedValue == .triage ? .listOnly : .listAndDetail)
        case .bento:
            InboxPriorityBoard(
                model: inboxModel,
                ink: ink,
                onOpenItem: { onOpenInbox($0) }
            )
        case .focus:
            bespokeShell {
                HomeFocusShell(
                    digest: digest,
                    ink: ink,
                    spend: spendCube,
                    onOpenItem: { onOpenInbox($0) },
                    onOpenInbox: { onOpenInbox(nil) }
                )
            }
        case .canvas:
            bespokeShell {
                HomeCanvasShell(
                    digest: digest,
                    ink: ink,
                    onOpenItem: { onOpenInbox($0) }
                )
            }
        case .stream:
            bespokeShell {
                HomeStreamShell(
                    digest: digest,
                    ink: ink,
                    onOpenItem: { onOpenInbox($0) }
                )
            }
        case .atlas:
            bespokeShell {
                HomeAtlasShell(
                    digest: digest,
                    ink: ink,
                    onOpenItem: { onOpenInbox($0) }
                )
            }
        case .cockpit:
            bespokeShell {
                HomeCockpitShell(
                    digest: digest,
                    ink: ink,
                    activeAgentCount: fleetModel.activeCount,
                    onOpenItem: { onOpenInbox($0) }
                )
            }
        case .ask:
            bespokeShell {
                HomeAskShell(
                    digest: digest,
                    ink: ink,
                    onAsk: onAsk,
                    onOpenItem: { onOpenInbox($0) }
                )
            }
        }
    }

    /// The lighting environment for everything on Home, derived from live spend.
    private var ambient: BurnBarAmbient {
        .from(
            providerSummaries: dataStore.providerSummaries,
            totalCostToday: dataStore.totalCostToday
        )
    }

    /// Live 24h spend for the hero shells' chart band, cut every way the chart can
    /// render it.
    ///
    /// Derived here rather than inside a shell so the shells stay pure functions of
    /// their inputs — the same reason `digest` is computed at this level. Cut once
    /// rather than per breakdown so switching HARNESS→MODEL is a re-render and not a
    /// re-scan of every usage row.
    private var spendCube: HomeSpendCube {
        HomeSpendSeries.cube(dataStore.usages)
    }

    /// The single cut of the system every bespoke shell reads.
    ///
    /// One derivation for eight surfaces: widening it here upgrades every shell
    /// at once, because they all read this same value rather than reaching into
    /// a store apiece. Computed once per render pass, exactly as the inbox-only
    /// version was.
    private var digest: HomeInboxDigest {
        HomeInboxDigest(rows: inboxModel.visibleRows, signals: signals)
    }

    /// Everything on this screen that is not the inbox.
    ///
    /// Reads the *today* window rather than an arbitrary range: Home is the
    /// launch surface, and the question it answers is "what is happening now".
    /// Sources that have not produced anything stay `nil` or empty here and are
    /// rendered as unknown downstream — never as a zero.
    private var signals: HomeSignalDigest {
        HomeSignalDigest.derive(
            window: dataStore.usageWindowSummary(for: .today),
            rollingDailyAverage: dataStore.rollingDailyAverage,
            isScanning: dataStore.isLoading,
            quotaSnapshots: Array(quotaService.snapshotsByProvider.values),
            fleet: HomeFleetSignal(
                rows: fleetModel.rows,
                hasRealTimeCoverage: fleetModel.hasRealTimeCoverage,
                lastScanAt: fleetModel.lastScanAt,
                sleepGapReason: fleetModel.sleepGapReason
            )
        )
    }

    /// Loading and live-refresh wiring for the shells that do not mount
    /// `InboxView`.
    ///
    /// `InboxModel.load` short-circuits on an unchanged marker, so riding the
    /// shared cadence here costs one aggregate query per quiet tick — the same
    /// bargain `InboxView` makes.
    @ViewBuilder
    private func bespokeShell<Shell: View>(@ViewBuilder _ shell: () -> Shell) -> some View {
        shell()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // The lighting environment reaches every surface below, so a plate's tint
            // and its shadow come from what the fleet is doing rather than a constant.
            .burnBarAmbient(ambient)
            // …and the material personality for this theme. Declared once here rather
            // than per call site, so no view ever names a theme.
            .burnBarGlassSpec(settingsManager.dashboardLayout.glassSpec)
            .task { await inboxModel.load() }
            .onReceive(NotificationCenter.default.publisher(
                for: DashboardView.inboxBadgeRefreshNotification
            )) { _ in
                Task { await inboxModel.load() }
            }
    }

    private func inboxSurface(paneStyle: InboxView.PaneStyle) -> some View {
        InboxView(
            model: inboxModel,
            onOpenSessionLog: onOpenSessionLog,
            onOpenSettings: onOpenSettings,
            memoryApproval: memoryApproval,
            openItemID: nil,
            paneStyle: paneStyle,
            // Home is a live surface, so it subscribes to the shared cadence.
            // `InboxModel.load` short-circuits on an unchanged marker, so a
            // quiet tick costs one aggregate query.
            refreshNotification: DashboardView.inboxBadgeRefreshNotification,
            onActivateItem: { onOpenInbox($0) }
        )
    }

    // MARK: - Rail

    private var rail: some View {
        DashboardHomeRail(
            ink: ink,
            fleetMode: fleetMode,
            quotaMode: quotaMode,
            availableFleetModes: availableFleetModes,
            activeAgentCount: fleetModel.activeCount,
            fleetContent: {
                LiveAgentFleetPanel(
                    model: fleetModel,
                    mode: fleetMode.wrappedValue,
                    ink: ink,
                    onOpenAgent: { _ in onOpenQuota() }
                )
            },
            quotaContent: {
                DashboardHomeQuotaPanel(
                    dataStore: dataStore,
                    settingsManager: settingsManager,
                    mode: quotaMode.wrappedValue,
                    ink: ink,
                    onOpenQuota: onOpenQuota
                )
            }
        )
    }

    /// Collapsed ≠ blind. The stub keeps the two facts worth a glance: how many
    /// agents are active, and the tightest quota chip.
    private var collapsedStub: some View {
        VStack(spacing: DesignSystem.Spacing.sm) {
            Button {
                withAnimation(reduceMotion ? .easeOut(duration: 0.12) : DesignSystem.Animation.snappy) {
                    railWanted.wrappedValue = true
                }
            } label: {
                Image(systemName: "sidebar.trailing")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ink.icon)
            }
            .buttonStyle(.plain)
            .help("Show fleet and quota")

            if fleetModel.activeCount > 0 {
                Text("\(fleetModel.activeCount)")
                    .font(DesignSystem.Typography.monoTiny)
                    .foregroundStyle(DesignSystem.Colors.success)
            }

            Spacer(minLength: 0)
        }
        .frame(width: DashboardHomeRailMetrics.collapsedStubWidth)
        .padding(.vertical, DesignSystem.Spacing.sm)
        .background(alignment: .leading) {
            Rectangle()
                .fill(DesignSystem.Colors.borderSubtle.opacity(0.72))
                .frame(width: 0.75)
        }
    }

    // MARK: - Band

    private func updateBand(width: CGFloat) {
        let next = DashboardHomeRailMetrics.band(forWidth: width, current: band)
        guard next != band else { return }
        withAnimation(reduceMotion ? .easeOut(duration: 0.12) : DesignSystem.Animation.snappy) {
            band = next
        }
    }
}
