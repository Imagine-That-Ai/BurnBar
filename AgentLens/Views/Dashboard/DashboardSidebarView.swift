import AppKit
import SwiftUI

// MARK: - Sidebar

extension DashboardView {

    var sidebarView: some View {
        @Bindable var ds = dataStore

        return ScrollView {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                        Text("Command")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                            .textCase(.uppercase)

                        Text(viewMode == .agents ? "Agent providers" : "LLM Models")
                            .font(DesignSystem.Typography.title)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)

                        Text(viewMode == .agents
                            ? "Scan, compare spend, and drill into model behavior from one workspace."
                            : "Track spend and token volume across every model your agents use.")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 0)

                    Button(action: toggleDashboardSidebar) {
                        Image(systemName: "sidebar.left")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Hide sidebar")
                    .accessibilityLabel("Hide sidebar")
                }

                Picker("View Mode", selection: $viewMode) {
                    Text("Agents").tag(DashboardViewMode.agents)
                    Text("Models").tag(DashboardViewMode.models)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityIdentifier(OBBAccessibilityID.dashboardViewModeSwitcher)
                .onChange(of: viewMode) { _, _ in
                    withAnimation(DesignSystem.Animation.standard) {
                        routeHistory.removeAll()
                        mainRoute = .overview
                    }
                }

                VStack(spacing: DesignSystem.Spacing.sm) {
                    SidebarItem(
                        provider: nil,
                        isSelected: mainRoute == .overview,
                        primaryMetric: settingsManager.formatUsageMetric(cost: totalCostForTimeRange, tokens: totalTokensForTimeRange),
                        totalCost: totalCostForTimeRange,
                        sessionCount: dashboardUsageWindow.sessionCount
                    ) {
                        withAnimation(DesignSystem.Animation.standard) {
                            routeHistory.removeAll()
                            mainRoute = .overview
                        }
                    }

                    if viewMode == .agents {
                        ForEach(Array(dashboardProviderSummaries.enumerated()), id: \.element.id) { index, summary in
                            SidebarItem(
                                provider: summary.provider,
                                isSelected: mainRoute == .provider(summary.provider),
                                primaryMetric: settingsManager.formatUsageMetric(cost: summary.totalCost, tokens: summary.totalTokens),
                                totalCost: summary.totalCost,
                                sessionCount: summary.sessionCount
                            ) {
                                withAnimation(DesignSystem.Animation.standard) {
                                    navigate(to: .provider(summary.provider))
                                }
                            }
                            .opacity(sidebarAppeared ? 1 : 0)
                            .offset(y: sidebarAppeared ? 0 : 8)
                            .animation(
                                DesignSystem.Animation.standard.delay(Double(index) * 0.06),
                                value: sidebarAppeared
                            )
                        }
                    } else {
                        ForEach(Array(dashboardModelSummaries.enumerated()), id: \.element.id) { index, summary in
                            ModelSidebarItem(
                                summary: summary,
                                isSelected: mainRoute == .model(summary.modelName)
                            ) {
                                withAnimation(DesignSystem.Animation.standard) {
                                    navigate(to: .model(summary.modelName))
                                }
                            }
                            .opacity(sidebarAppeared ? 1 : 0)
                            .offset(y: sidebarAppeared ? 0 : 8)
                            .animation(
                                DesignSystem.Animation.standard.delay(Double(index) * 0.06),
                                value: sidebarAppeared
                            )
                        }
                    }
                }

                GlassCard {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                        Text("Window")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                            .textCase(.uppercase)

                        Text(selectedTimeRange.displayName)
                            .font(DesignSystem.Typography.headline)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)

                        Text("\(activeProviderCount) active providers")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DesignSystem.Spacing.md)
                }

                GlassCard {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                        Text("Cursor")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                            .textCase(.uppercase)

                        Button(action: openBurnBarCursorExtension) {
                            HStack(spacing: DesignSystem.Spacing.md) {
                                ZStack {
                                    Circle()
                                        .fill(DesignSystem.Colors.surfaceElevated)
                                        .frame(width: 36, height: 36)

                                    ProviderLogoView(provider: .cursor, size: 24, useFallbackColor: false)
                                }

                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Add OpenBurnBar to Cursor")
                                        .font(DesignSystem.Typography.body)
                                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                                        .multilineTextAlignment(.leading)

                                    Text("Opens the extension install page")
                                        .font(DesignSystem.Typography.tiny)
                                        .foregroundStyle(DesignSystem.Colors.textMuted)
                                }

                                Spacer(minLength: 0)

                                Image(systemName: "arrow.up.forward.circle.fill")
                                    .font(.system(size: 20))
                                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Install OpenBurnBar in Cursor (openburnbar.openburnbar)")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DesignSystem.Spacing.md)
                }

                if accountManager.isSignedIn {
                    DeviceBreakdownCard(
                        dataStore: dataStore,
                        isSyncing: cloudSyncService?.isSyncing ?? false
                    )
                }

                if viewMode == .agents ? dashboardProviderSummaries.isEmpty : dashboardModelSummaries.isEmpty {
                    Text(viewMode == .agents ? "No providers in this window" : "No models in this window")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, DesignSystem.Spacing.xl)
                }
            }
            .padding(DesignSystem.Spacing.lg)
        }
        .background {
            DashboardSidebarMaterial(
                liveBackdropActive: dashboardLiveBackdropActive,
                moodBand: dataStore.moodBand
            )
        }
        .scrollContentBackground(.hidden)
        .onMoveCommand { direction in
            let order = sidebarRouteOrder
            guard let idx = order.firstIndex(of: mainRoute) else { return }
            switch direction {
            case .up, .left:
                if idx > 0 { navigate(to: order[idx - 1]) }
            case .down, .right:
                if idx + 1 < order.count { navigate(to: order[idx + 1]) }
            default:
                break
            }
        }
        .onKeyPress(.escape) {
            withAnimation(DesignSystem.Animation.standard) {
                goBack()
            }
            return .handled
        }
        .onAppear { sidebarAppeared = true }
    }

    var sidebarRouteOrder: [DashboardMainRoute] {
        var routes: [DashboardMainRoute] = [.overview, .insights]
        if viewMode == .agents {
            routes.append(contentsOf: dashboardProviderSummaries.map { .provider($0.provider) })
        } else {
            routes.append(contentsOf: dashboardModelSummaries.map { .model($0.modelName) })
        }
        return routes
    }
}

private struct DashboardSidebarMaterial: View {
    let liveBackdropActive: Bool
    let moodBand: MoodBand

    var body: some View {
        if liveBackdropActive {
            liveGlass
        } else {
            staticSurface
        }
    }

    private var liveGlass: some View {
        ZStack {
            DashboardBackdrop(moodBand: moodBand)
                .allowsHitTesting(false)

            Color.clear
                .liquidGlassSurface(in: Rectangle(), fallback: .ultraThinMaterial)

            LinearGradient(
                colors: [
                    Color.white.opacity(0.055),
                    DesignSystem.Colors.surface.opacity(0.12),
                    Color.black.opacity(0.18)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .allowsHitTesting(false)
        }
    }

    private var staticSurface: some View {
        ZStack {
            DesignSystem.Colors.surface.opacity(0.92)

            LinearGradient(
                colors: [
                    DesignSystem.Colors.textPrimary.opacity(0.02),
                    Color.clear
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
}

/// SwiftUI's sidebar-toggle placement is reapplied after this manually hosted
/// dashboard window mounts, and the split view also projects
/// `NSTitlebarBackgroundView` chrome strips across the top of the window. Keep
/// the chrome minimal and predictable: drop any toolbar the split view
/// creates, remove titlebar accessories, and hide the split view's duplicate
/// titlebar strips — which also reseats the standard macOS sidebar toggle in
/// its normal titlebar position next to the traffic lights, where it stays as
/// the platform-conventional sidebar control. Once a toolbar holds no items it
/// is dropped entirely so the command deck renders full-bleed under the
/// traffic lights. Passes repeat on a timer because SwiftUI re-inserts chrome
/// whenever its toolbar state invalidates.
struct DashboardSidebarToolbarItemRemover: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        DashboardSidebarToolbarScrubberView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? DashboardSidebarToolbarScrubberView)?.removeSystemSidebarToggle()
    }
}

@MainActor
private final class DashboardSidebarToolbarScrubberView: NSView {
    private var windowUpdateObserver: NSObjectProtocol?
    private var scrubTimer: Timer?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeSystemSidebarToggle()
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.removeSystemSidebarToggle()
        }
        // SwiftUI re-adds the sidebar toggle asynchronously after mount; a
        // later pass catches stragglers the immediate passes miss.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            self?.removeSystemSidebarToggle()
        }
        installWindowUpdateObserver()
        startScrubTimer()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            if let observer = windowUpdateObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            windowUpdateObserver = nil
            scrubTimer?.invalidate()
            scrubTimer = nil
        }
        super.viewWillMove(toWindow: newWindow)
    }

    /// SwiftUI has been observed to recreate the toolbar well after the
    /// immediate passes run (split-view state settling, tab/visibility
    /// churn). Window updates are the practical signal that a toolbar came
    /// back — scrub again whenever one actually exists.
    private func installWindowUpdateObserver() {
        guard windowUpdateObserver == nil else { return }
        windowUpdateObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didUpdateNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.window?.toolbar != nil else { return }
                self.removeSystemSidebarToggle()
            }
        }
    }

    /// The dashboard's live status rail invalidates SwiftUI toolbar state on a
    /// similar cadence, which can re-insert the system toggle after one-shot
    /// passes. A repeating scrub bounds any reappearance to a flicker. The
    /// pass is a no-op while no toolbar exists.
    private func startScrubTimer() {
        guard scrubTimer == nil else { return }
        scrubTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.removeSystemSidebarToggle()
            }
        }
    }

    func removeSystemSidebarToggle() {
        if let toolbar = window?.toolbar {
            for index in toolbar.items.indices.reversed()
                where toolbar.items[index].itemIdentifier == .toggleSidebar {
                toolbar.removeItem(at: index)
            }
            if toolbar.items.isEmpty {
                window?.toolbar = nil
            }
        }
        // With no toolbar to host it, AppKit/SwiftUI falls back to rendering
        // the system sidebar toggle as a titlebar accessory (a clipped
        // capsule overlapping the traffic lights). The dashboard installs no
        // legitimate accessories, so drop them all.
        while window?.titlebarAccessoryViewControllers.isEmpty == false {
            window?.removeTitlebarAccessoryViewController(at: 0)
        }
        // Last channel: SwiftUI's split view projects NSTitlebarBackgroundView
        // chrome strips across the top of the window (one per column); in that
        // configuration the system sidebar toggle renders as a clipped capsule
        // overlapping the traffic lights. The command deck owns the top band
        // now, so those strips are pure noise — hiding them also reseats the
        // toggle in its standard titlebar position.
        hideSplitViewTitlebarChrome()
    }

    private func hideSplitViewTitlebarChrome() {
        guard let window, let frameView = window.contentView?.superview else { return }
        hideSplitViewTitlebarChrome(under: frameView)
    }

    private func hideSplitViewTitlebarChrome(under view: NSView) {
        for subview in view.subviews {
            if String(describing: type(of: subview)) == "NSTitlebarBackgroundView", !subview.isHidden {
                subview.isHidden = true
            }
            hideSplitViewTitlebarChrome(under: subview)
        }
    }
}
