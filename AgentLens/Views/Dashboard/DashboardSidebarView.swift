import AppKit
import SwiftUI

// MARK: - Sidebar

extension DashboardView {

    var sidebarView: some View {
        @Bindable var ds = dataStore
        let adaptiveColors = BackdropAdaptiveColors(profile: dashboardActiveReadabilityProfile)

        return ScrollView {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                        Text("Command")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(adaptiveColors.muted)
                            .textCase(.uppercase)

                        Text(viewMode == .agents ? "Agent providers" : "LLM Models")
                            .font(DesignSystem.Typography.title)
                            .foregroundStyle(adaptiveColors.primary)

                        Text(viewMode == .agents
                            ? "Scan, compare spend, and drill into model behavior from one workspace."
                            : "Track spend and token volume across every model your agents use.")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(adaptiveColors.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 0)

                    Button(action: toggleDashboardSidebar) {
                        Image(systemName: "sidebar.left")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(adaptiveColors.secondary)
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
                            .foregroundStyle(adaptiveColors.muted)
                            .textCase(.uppercase)

                        Text(selectedTimeRange.displayName)
                            .font(DesignSystem.Typography.headline)
                            .foregroundStyle(adaptiveColors.primary)

                        Text("\(activeProviderCount) active providers")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(adaptiveColors.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DesignSystem.Spacing.md)
                }

                GlassCard {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                        Text("Cursor")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(adaptiveColors.muted)
                            .textCase(.uppercase)

                        Button(action: openBurnBarCursorExtension) {
                            HStack(spacing: DesignSystem.Spacing.md) {
                                ZStack {
                                    Circle()
                                        .fill(adaptiveColors.primary.opacity(0.08))
                                        .frame(width: 36, height: 36)

                                    ProviderLogoView(provider: .cursor, size: 24, useFallbackColor: false)
                                }

                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Add OpenBurnBar to Cursor")
                                        .font(DesignSystem.Typography.body)
                                        .foregroundStyle(adaptiveColors.primary)
                                        .multilineTextAlignment(.leading)

                                    Text("Opens the extension install page")
                                        .font(DesignSystem.Typography.tiny)
                                        .foregroundStyle(adaptiveColors.muted)
                                }

                                Spacer(minLength: 0)

                                Image(systemName: "arrow.up.forward.circle.fill")
                                    .font(.system(size: 20))
                                    .foregroundStyle(adaptiveColors.secondary)
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
                        .foregroundStyle(adaptiveColors.muted)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, DesignSystem.Spacing.xl)
                }
            }
            .padding(DesignSystem.Spacing.lg)
        }
        .background {
            DashboardSidebarMaterial(
                liveBackdropActive: dashboardLiveBackdropActive,
                moodBand: dataStore.moodBand,
                kernelColorScheme: dashboardKernelColorScheme
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
        var routes: [DashboardMainRoute] = [.overview, .insights, .recap]
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
    /// The app's appearance, passed in explicitly because the sidebar subtree
    /// runs under a `\.colorScheme` override chosen for foreground contrast.
    /// Without it `KernelBackdropView` here would read that overridden value
    /// and drive the sidebar's kernel WKWebView with a palette opposite to the
    /// main backdrop's.
    let kernelColorScheme: ColorScheme

    var body: some View {
        if liveBackdropActive {
            liveGlass
        } else {
            staticSurface
        }
    }

    private var liveGlass: some View {
        ZStack {
            DashboardBackdrop(moodBand: moodBand, kernelColorScheme: kernelColorScheme)
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

/// SwiftUI's sidebar-removal placement is occasionally reapplied after this
/// manually hosted dashboard window mounts. Keep the window chrome clean by
/// removing only the system toggle item; the in-sidebar button remains the
/// single visible control for this action.
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
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeSystemSidebarToggle()
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.removeSystemSidebarToggle()
        }
    }

    func removeSystemSidebarToggle() {
        guard let toolbar = window?.toolbar else { return }
        for index in toolbar.items.indices.reversed()
            where toolbar.items[index].itemIdentifier == .toggleSidebar {
            toolbar.removeItem(at: index)
        }
    }
}
