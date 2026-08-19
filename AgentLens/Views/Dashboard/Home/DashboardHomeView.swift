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
    let memoryApproval: InboxMemoryApprovalHandler?

    @Environment(\.backdropInk) private var ink
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @AppStorage(DashboardHomeInboxMode.storageKey) private var inboxModeRaw = DashboardHomeInboxMode.reader.rawValue
    @AppStorage(DashboardHomeFleetMode.storageKey) private var fleetModeRaw = DashboardHomeFleetMode.rows.rawValue
    @AppStorage(DashboardHomeQuotaMode.storageKey) private var quotaModeRaw = DashboardHomeQuotaMode.bars.rawValue
    @AppStorage(DashboardHomeRailMetrics.widthStorageKey) private var storedRailWidth =
        Double(DashboardHomeRailMetrics.defaultWidth)
    @AppStorage(DashboardHomeRailMetrics.collapsedStorageKey) private var railCollapsed = false

    @State private var band: DashboardHomeRailMetrics.Band = .wide
    /// Live drag width, so a drag never writes `@AppStorage` per frame.
    @State private var dragWidth: Double?
    @State private var brief: InsightAnalysisResult?
    @State private var briefKey: String = ""

    // MARK: Mode bindings

    private var inboxMode: Binding<DashboardHomeInboxMode> {
        Binding(
            get: { DashboardHomeInboxMode(rawValue: inboxModeRaw) ?? .reader },
            set: { inboxModeRaw = $0.rawValue }
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
        DashboardHomeRailMetrics.railIsExpanded(userWantsRail: railCollapsed == false, band: band)
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
                    inboxRegion
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
                    } else if band == .narrow || railCollapsed {
                        collapsedStub
                            .transition(.opacity)
                    }
                }
            }
            .onAppear { updateBand(width: geo.size.width) }
            .onChange(of: geo.size.width) { _, width in updateBand(width: width) }
        }
        .accessibilityIdentifier(OBBAccessibilityID.dashboardHomeRoot)
    }

    // MARK: - Header

    private var homeHeaderStrip: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Text("INBOX")
                .font(DesignSystem.Typography.caption)
                .fontWeight(.semibold)
                .tracking(0.8)
                .foregroundStyle(ink.secondary)

            Spacer(minLength: 0)

            GlassSegmentedSwitcher(
                selection: inboxMode,
                iconOnly: false,
                accessibilityID: OBBAccessibilityID.dashboardHomeInboxSwitcher
            )

            Button {
                withAnimation(reduceMotion ? .easeOut(duration: 0.12) : DesignSystem.Animation.snappy) {
                    railCollapsed.toggle()
                }
            } label: {
                Image(systemName: railCollapsed ? "sidebar.trailing" : "sidebar.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ink.icon)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(OBBAccessibilityID.dashboardHomeRailToggle)
            .help(railCollapsed ? "Show fleet and quota (⌘⌥R)" : "Hide fleet and quota (⌘⌥R)")
        }
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, DesignSystem.Spacing.xs)
    }

    // MARK: - Inbox region

    @ViewBuilder
    private var inboxRegion: some View {
        switch inboxMode.wrappedValue {
        case .reader:
            inboxSurface(paneStyle: .listAndDetail)
        case .triage:
            inboxSurface(paneStyle: .listOnly)
        case .board:
            InboxPriorityBoard(
                model: inboxModel,
                ink: ink,
                onOpenItem: { onOpenInbox($0) }
            )
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
                    railCollapsed = false
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
