import AppKit
import Charts
import OpenBurnBarCore
import SwiftUI

// MARK: - Command Deck Toolbar
//
// A single ~52pt bar replacing the old toolbar + tab-card strip.
//
//   [navigation]    back · 🔥 OpenBurnBar · section switcher · ⌘K hint
//   [principal]     (empty — the section menu already names the route)
//   [primaryAction] BURN hero (range + unit in popover) · refresh · settings · ⋯

extension DashboardView {

    @ToolbarContentBuilder
    var toolbarContent: some ToolbarContent {

        // MARK: Navigation — back · brand · section switcher · ⌘K hint

        ToolbarItemGroup(placement: .navigation) {
            if canGoBack {
                Button(action: goBack) {
                    Image(systemName: "chevron.backward")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                }
                .help(backButtonHelpText)
            }

            BurnRailBrandMark()

            DashboardSectionSwitcher(
                currentRoute: mainRoute,
                activeChatBackend: chatController.chatBackend,
                pendingMemoryCount: pendingMemoryReviewCount,
                inboxUnreadCount: aiInboxUnreadCount,
                onNavigate: { route in
                    withAnimation(DesignSystem.Animation.standard) {
                        navigate(to: route)
                    }
                }
            )

            Button {
                showCommandPalette = true
            } label: {
                ShortcutChip(keys: ["\u{2318}", "K"])
            }
            .buttonStyle(.plain)
            .help("Command Palette (\u{2318}K)")
        }

        // MARK: Principal — long live glass island

        ToolbarItem(placement: .principal) {
            dashboardDynamicIsland
        }

        // MARK: Primary — refresh · pinned shortcuts · settings · appearance

        ToolbarItemGroup(placement: .primaryAction) {
            Button(action: runScan) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isScanning ? DesignSystem.Colors.ember : DesignSystem.Colors.textSecondary)
                    .rotationEffect(.degrees(isScanning ? 360 : 0))
                    .animation(
                        isScanning
                            ? .linear(duration: 0.8).repeatForever(autoreverses: false)
                            : .default,
                        value: isScanning
                    )
                    .frame(width: 30, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isScanning || aggregator == nil)
            .help(isScanning ? "Mining session logs…" : "Refresh token spend from session logs")
            .accessibilityLabel(isScanning ? "Refreshing token spend" : "Refresh token spend")
            .accessibilityHint("Mines session logs and updates the dashboard chart and Burn total.")
            .accessibilityIdentifier(OBBAccessibilityID.dashboardRefreshButton)

            BurnRailSettingsButton {
                presentSettings()
            }
            .accessibilityIdentifier(OBBAccessibilityID.dashboardSettingsButton)

            commandDeckOverflow
        }
    }

    /// The centered “dynamic island” keeps the live metric visually anchored
    /// between navigation and actions. It deliberately has one continuous
    /// glass surface instead of several competing pills.
    private var dashboardDynamicIsland: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.ember)
                .accessibilityHidden(true)

            commandDeckHero
                .fixedSize(horizontal: false, vertical: true)

            Divider()
                .frame(height: 22)
                .opacity(0.45)

            HStack(spacing: 5) {
                Circle()
                    .fill(isScanning ? DesignSystem.Colors.ember : DesignSystem.Colors.textMuted)
                    .frame(width: 6, height: 6)
                Text(isScanning ? "Mining logs" : selectedTimeRange.displayName)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(minWidth: 330, idealWidth: 430, maxWidth: 560)
        .background {
            if #available(macOS 26.0, *) {
                Capsule(style: .continuous)
                    .fill(.clear)
                    .liquidGlassEffect(.regular, in: Capsule(style: .continuous))
            } else {
                Capsule(style: .continuous)
                    .fill(.ultraThinMaterial)
            }
        }
        .overlay {
            Capsule(style: .continuous)
                .stroke(DesignSystem.Colors.border.opacity(0.42), lineWidth: 0.6)
        }
        .help("Live token spend for (selectedTimeRange.displayName). Click the metric to change range or unit.")
    }

    // MARK: - Full-width dashboard command deck

    var dashboardCommandDeck: some View {
        VStack(spacing: 8) {
            HStack(spacing: 14) {
                dashboardDeckLeading

                dashboardDeckChart
                    .layoutPriority(2)

                dashboardDeckActions
                    .layoutPriority(1)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .frame(minHeight: 116)
            .background(dashboardDeckSurface(cornerRadius: 34, opacity: 0.94))
            .overlay {
                RoundedRectangle(cornerRadius: 34, style: .continuous)
                    .stroke(DesignSystem.Colors.border.opacity(0.5), lineWidth: 0.75)
            }
            .clipShape(
                RoundedRectangle(cornerRadius: 34, style: .continuous),
                style: FillStyle(antialiased: true)
            )

            dashboardDeckStatusRail
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(Color.clear)
    }

    private var dashboardDeckLeading: some View {
        HStack(spacing: 10) {
            // The logo is the Home button. "Logo goes home" is universal, and
            // it costs zero width — which matters, because the deck strip is
            // `.fixedSize(horizontal:)` and a seventh route button would push
            // the 116pt deck past the 1040pt window minimum.
            Button {
                withAnimation(DesignSystem.Animation.standard) {
                    navigate(to: .home)
                }
            } label: {
                AppLogoView(size: 36)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Home (⌘⇧H)")
            .accessibilityLabel("Home")

            DashboardSectionSwitcher(
                currentRoute: mainRoute,
                activeChatBackend: chatController.chatBackend,
                pendingMemoryCount: pendingMemoryReviewCount,
                inboxUnreadCount: aiInboxUnreadCount,
                onNavigate: { route in
                    withAnimation(DesignSystem.Animation.standard) {
                        navigate(to: route)
                    }
                }
            )

            Divider()
                .frame(height: 38)
                .opacity(0.4)

            HStack(spacing: 0) {
                dashboardDeckRouteButton(.overview)
                dashboardDeckRouteButton(.controlDeck)
                dashboardDeckRouteButton(.charts)
                dashboardDeckRouteButton(.insights)
                dashboardDeckRouteButton(.projects)
                dashboardDeckRouteButton(.sessionLogs)
            }
            .padding(3)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(DesignSystem.Colors.surface.opacity(0.48))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(DesignSystem.Colors.border.opacity(0.36), lineWidth: 0.5)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func dashboardDeckRouteButton(_ route: DashboardMainRoute) -> some View {
        let selected = route == mainRoute
        return Button {
            withAnimation(DesignSystem.Animation.standard) {
                navigate(to: route)
            }
        } label: {
            Group {
                if route == .insights {
                    DashboardAgentRobotGlyph()
                } else {
                    Image(systemName: route.systemImage(activeChatBackend: chatController.chatBackend))
                        .font(.system(size: 14, weight: .semibold))
                }
            }
                .foregroundStyle(selected ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textSecondary)
                .frame(width: 38, height: 38)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(DesignSystem.Colors.ember.opacity(0.18))
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(route.title(activeChatBackend: chatController.chatBackend))
        .accessibilityLabel(route.title(activeChatBackend: chatController.chatBackend))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var dashboardDeckChart: some View {
        HStack(spacing: 14) {
            Button {
                withAnimation(DesignSystem.Animation.standard) {
                    navigate(to: .charts)
                }
            } label: {
                HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Text("BURN RATE")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .tracking(1.1)
                        Circle()
                            .fill(burnRailIsLive ? DesignSystem.Colors.success : DesignSystem.Colors.textMuted)
                            .frame(width: 5, height: 5)
                    }
                    .foregroundStyle(DesignSystem.Colors.textMuted)

                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(settingsManager.formatUsageMetric(
                            cost: totalCostForTimeRange,
                            tokens: totalTokensForTimeRange
                        ))
                        .font(.system(size: 27, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                        .contentTransition(.numericText())

                        if let delta = burnRailDeltaPercent {
                            Text(delta.formatted(.number.precision(.fractionLength(1)).sign(strategy: .always())) + "%")
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundStyle(delta <= 0 ? DesignSystem.Colors.success : DesignSystem.Colors.amber)
                        }
                    }
                }
                .frame(minWidth: 122, alignment: .leading)

                DashboardIslandSparkline(
                    samples: burnRailSparkline,
                    range: burnRailDisplayRange,
                    timeRange: selectedTimeRange
                )
                    .frame(minWidth: 220, maxWidth: .infinity)
                    .frame(height: 74)
                }
            }
            .buttonStyle(.plain)
            .frame(minWidth: 360, maxWidth: .infinity)
            .help("Open Charts — the full analytics gallery")
            .accessibilityLabel("Open Charts")
            .accessibilityIdentifier(OBBAccessibilityID.dashboardDeckChartButton)

            Button {
                showHeroPopover.toggle()
            } label: {
                VStack(spacing: 2) {
                    Text(selectedTimeRange.displayName.uppercased())
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                }
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(DesignSystem.Colors.surface.opacity(0.52))
                )
                .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("Change Burn chart range or unit")
            .accessibilityLabel("Burn chart range and unit")
            .popover(isPresented: $showHeroPopover, arrowEdge: .bottom) {
                commandDeckHeroPopover
                    .frame(width: 240)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .frame(minWidth: 440, maxWidth: .infinity)
        .background(dashboardDeckInsetSurface(cornerRadius: 24, opacity: 0.62))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(DesignSystem.Colors.ember.opacity(0.24), lineWidth: 0.75)
        }
        .clipShape(
            RoundedRectangle(cornerRadius: 24, style: .continuous),
            style: FillStyle(antialiased: true)
        )
        .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var dashboardDeckActions: some View {
        HStack(spacing: 8) {
            Button(action: runScan) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isScanning ? DesignSystem.Colors.ember : DesignSystem.Colors.textSecondary)
                    .rotationEffect(.degrees(isScanning ? 360 : 0))
                    .animation(isScanning ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default, value: isScanning)
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .disabled(isScanning || aggregator == nil)
            .help(isScanning ? "Mining session logs…" : "Refresh token spend")

            BurnRailSettingsButton { presentSettings() }

            commandDeckOverflow
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var dashboardDeckStatusRail: some View {
        let scale = dashboardStatusRailControlScale
        return HStack(spacing: 12 * scale) {
            Circle()
                .fill(DesignSystem.Colors.success)
                .frame(width: 7 * scale, height: 7 * scale)
            Text(mainRoute.title(activeChatBackend: chatController.chatBackend))
                .font(.system(size: 12 * scale, weight: .semibold, design: .rounded))
            Text("Updated")
                .foregroundStyle(DesignSystem.Colors.textMuted)
            if let lastRefresh = dataStore.lastRefresh {
                Text(lastRefresh, style: .time)
                    .monospacedDigit()
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            } else {
                Text("Waiting")
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }

            Divider()
                .frame(height: 22 * scale)
                .opacity(0.35)

            Text(isScanning ? "Mining session logs" : "Live usage ready")
                .foregroundStyle(isScanning ? DesignSystem.Colors.ember : DesignSystem.Colors.textMuted)

            Divider()
                .frame(height: 22 * scale)
                .opacity(0.35)

            DashboardLayoutSwitcher(selection: dashboardDeckLayoutBinding, scale: scale)
                .accessibilityIdentifier(OBBAccessibilityID.dashboardLayoutSwitcher)

            Spacer(minLength: 12)

            DashboardQuickAccessRail(
                onRoute: { route in
                    withAnimation(DesignSystem.Animation.standard) {
                        navigate(to: route)
                    }
                },
                onSettingsItem: { itemID in
                    presentSettings(itemID: itemID)
                },
                onChatBackend: { backend in
                    chatController.setChatBackend(backend)
                    withAnimation(DesignSystem.Animation.standard) {
                        navigate(to: .chat)
                    }
                },
                compact: true,
                scale: scale
            )
            .layoutPriority(2)

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 1) {
                Text(selectedTimeRange.displayName.uppercased())
                    .font(.system(size: 10 * scale, weight: .bold, design: .rounded))
                    .tracking(0.8)
                Text(isScanning ? "Refreshing spend…" : "Spend is live")
                    .font(.system(size: 9.5 * scale, design: .rounded))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
            .foregroundStyle(DesignSystem.Colors.textSecondary)

            Button(action: runScan) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 11 * scale, weight: .semibold))
                    .foregroundStyle(isScanning ? DesignSystem.Colors.ember : DesignSystem.Colors.textSecondary)
                    .rotationEffect(.degrees(isScanning ? 360 : 0))
                    .animation(
                        isScanning
                            ? .linear(duration: 0.8).repeatForever(autoreverses: false)
                            : .default,
                        value: isScanning
                    )
                    .frame(width: 28 * scale, height: 28 * scale)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(isScanning || aggregator == nil)
            .help(isScanning ? "Refreshing token spend" : "Refresh token spend")

            Divider()
                .frame(height: 22 * scale)
                .opacity(0.35)

            BurnRailAppearanceQuickMenu(
                settingsManager: settingsManager,
                onOpenAppearanceSettings: {
                    presentSettings(itemID: "general.appearance.theme")
                },
                scale: scale
            )
        }
        .font(.system(size: 11.5 * scale, design: .rounded))
        .padding(.horizontal, 18)
        .frame(height: dashboardStatusRailHeight)
        .background(dashboardDeckSurface(cornerRadius: dashboardStatusRailHeight / 2, opacity: 0.78))
        .overlay {
            RoundedRectangle(cornerRadius: dashboardStatusRailHeight / 2, style: .continuous)
                .stroke(DesignSystem.Colors.border.opacity(0.38), lineWidth: 0.6)
        }
        .overlay(alignment: .bottom) {
            dashboardStatusRailResizeHandle
        }
        .clipShape(
            RoundedRectangle(cornerRadius: dashboardStatusRailHeight / 2, style: .continuous),
            style: FillStyle(antialiased: true)
        )
    }

    private var dashboardStatusRailHeight: CGFloat {
        CGFloat(min(max(storedDashboardStatusRailHeight, 46), 82))
    }

    private var dashboardStatusRailControlScale: CGFloat {
        min(max(dashboardStatusRailHeight / 52, 0.92), 1.35)
    }

    private var dashboardStatusRailResizeHandle: some View {
        Capsule(style: .continuous)
            .fill(DesignSystem.Colors.textMuted.opacity(0.48))
            .frame(width: 42, height: 3)
            .frame(width: 96, height: 13)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if dashboardStatusRailResizeOrigin == nil {
                            dashboardStatusRailResizeOrigin = storedDashboardStatusRailHeight
                        }
                        let origin = dashboardStatusRailResizeOrigin ?? storedDashboardStatusRailHeight
                        storedDashboardStatusRailHeight = min(max(origin + value.translation.height, 46), 82)
                    }
                    .onEnded { _ in dashboardStatusRailResizeOrigin = nil }
            )
            .accessibilityLabel("Resize shortcut bar")
            .accessibilityHint("Drag vertically to resize the bar and its controls")
            .accessibilityAdjustableAction { direction in
                let delta = direction == .increment ? 4.0 : -4.0
                storedDashboardStatusRailHeight = min(max(storedDashboardStatusRailHeight + delta, 46), 82)
            }
    }

    private var dashboardDeckLayoutBinding: Binding<DashboardLayout> {
        Binding(
            get: { settingsManager.dashboardLayout },
            set: { newValue in
                guard newValue != settingsManager.dashboardLayout else { return }
                settingsManager.dashboardLayout = newValue
                Analytics.shared.track(.settingsChanged, [
                    "setting_key": "dashboard_layout",
                    "new_value": .string(newValue.rawValue),
                    "source": "command_deck_status_rail"
                ])
            }
        )
    }

    @ViewBuilder
    private func dashboardDeckSurface(cornerRadius: CGFloat, opacity: Double) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            shape
                .fill(.clear)
                .liquidGlassEffect(.regular, in: shape)
        } else {
            ZStack {
                shape.fill(.ultraThinMaterial)
                shape.fill(DesignSystem.Colors.surface.opacity(opacity * 0.55))
            }
        }
    }

    private func dashboardDeckInsetSurface(cornerRadius: CGFloat, opacity: Double) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(DesignSystem.Colors.surface.opacity(opacity))
    }

    // MARK: - BURN hero with range + unit popover

    private var commandDeckHero: some View {
        Button {
            showHeroPopover.toggle()
        } label: {
            BurnRailTelemetryHero(
                telemetry: BurnRailTelemetry(
                    headlineValue: settingsManager.formatUsageMetric(
                        cost: totalCostForTimeRange,
                        tokens: totalTokensForTimeRange
                    ),
                    headlineSuffix: settingsManager.usageDisplayMode == .tokens ? "tok" : nil,
                    deltaPercent: burnRailDeltaPercent,
                    sparkline: burnRailSparkline,
                    isLive: burnRailIsLive
                )
            )
        }
        .buttonStyle(.plain)
        .help("Burn in \(selectedTimeRange.displayName). Click to change range or unit.")
        .popover(isPresented: $showHeroPopover, arrowEdge: .bottom) {
            commandDeckHeroPopover
                .frame(width: 240)
        }
    }

    private var commandDeckHeroPopover: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            Text("Time Range")
                .font(.system(size: 9.5, weight: .bold, design: .rounded))
                .tracking(1.0)
                .foregroundStyle(DesignSystem.Colors.textMuted)

            VStack(spacing: 2) {
                ForEach(TimeRange.allCases) { range in
                    let isSelected = selectedTimeRange == range
                    Button {
                        selectedTimeRange = range
                        Analytics.shared.track(.dashboardTimeRangeChanged, ["time_range": .string(range.rawValue)])
                    } label: {
                        HStack {
                            if isSelected {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(DesignSystem.Colors.ember)
                            }
                            Text(range.displayName)
                                .font(.system(size: 12, weight: isSelected ? .semibold : .regular, design: .rounded))
                                .foregroundStyle(isSelected ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textSecondary)
                            Spacer()
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(isSelected ? DesignSystem.Colors.ember.opacity(0.1) : Color.clear)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider().opacity(0.4)

            HStack {
                Text("Unit")
                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
                    .tracking(1.0)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                Spacer()
                BurnRailUnitToggle(
                    unit: Binding(
                        get: { BurnRailUnit(fromUsageMode: settingsManager.usageDisplayMode) },
                        set: {
                            settingsManager.usageDisplayMode = $0.toUsageDisplayMode
                            Analytics.shared.track(.dashboardUnitToggled, ["unit": .string($0.toUsageDisplayMode.rawValue)])
                        }
                    )
                )
            }
        }
        .padding(DesignSystem.Spacing.md)
    }

    // MARK: - Overflow menu (Appearance · Import · Recount · Settings)

    private var commandDeckOverflow: some View {
        Menu {
            Section("Appearance") {
                ForEach(AppearanceMode.allCases, id: \.self) { mode in
                    Button {
                        settingsManager.appearanceMode = mode
                    } label: {
                        if settingsManager.appearanceMode == mode {
                            Label(mode.quickMenuLabel, systemImage: "checkmark")
                        } else {
                            Text(mode.quickMenuLabel)
                        }
                    }
                }
            }

            Section("App Skin") {
                ForEach(AppSkin.allCases, id: \.self) { skin in
                    Button {
                        settingsManager.appearanceSkin = skin
                    } label: {
                        if settingsManager.appearanceSkin == skin {
                            Label(skin.quickMenuLabel, systemImage: "checkmark")
                        } else {
                            Text(skin.quickMenuLabel)
                        }
                    }
                }
            }

            Section {
                Button {
                    toggleDashboardSidebar()
                } label: {
                    Label(
                        isDashboardSidebarVisible ? "Hide Sidebar" : "Show Sidebar",
                        systemImage: "sidebar.left"
                    )
                }

                Button("Import Sessions") { runScan() }
                    .disabled(isScanning)

                Button("Recount Totals") { runRecount() }
                    .disabled(!canRunRecount)

                Divider()

                Button("Settings…") { presentSettings() }
                    .accessibilityIdentifier(OBBAccessibilityID.dashboardSettingsButton)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "paintbrush.pointed.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isScanning ? DesignSystem.Colors.ember : DesignSystem.Colors.textSecondary)
                    .rotationEffect(.degrees(isScanning ? -12 : 0))
            }
            .frame(width: 28, height: 24)
            .background(
                Capsule(style: .continuous)
                    .fill(DesignSystem.Colors.surface.opacity(0.4))
            )
            .accessibilityIdentifier(OBBAccessibilityID.dashboardOverflowButton)
            .overlay(
                Capsule(style: .continuous)
                    .stroke(DesignSystem.Colors.border.opacity(0.4), lineWidth: 0.5)
            )
            .contentShape(Capsule(style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Customize appearance and more actions")
        .accessibilityLabel("Customize appearance")
        .accessibilityHint("Choose an appearance, app skin, or dashboard action")
    }
}

private struct DashboardIslandSparkline: View {
    let samples: [Double]
    let range: ClosedRange<Date>
    let timeRange: TimeRange

    private var points: [DashboardIslandSparklinePoint] {
        let denominator = max(samples.count - 1, 1)
        let span = max(range.upperBound.timeIntervalSince(range.lowerBound), 1)
        return samples.enumerated().map { index, sample in
            DashboardIslandSparklinePoint(
                index: index,
                date: range.lowerBound.addingTimeInterval(span * Double(index) / Double(denominator)),
                value: clamp(sample)
            )
        }
    }

    private var labelDates: [Date] {
        let span = range.upperBound.timeIntervalSince(range.lowerBound)
        return [
            range.lowerBound,
            range.lowerBound.addingTimeInterval(span * 0.5),
            range.upperBound
        ]
    }

    var body: some View {
        Chart {
            RuleMark(y: .value("Baseline", 0))
                .foregroundStyle(DesignSystem.Colors.border.opacity(0.32))

            ForEach(points) { point in
                AreaMark(
                    x: .value("Time", point.date),
                    y: .value("Normalized token spend", point.value)
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(
                    LinearGradient(
                        colors: [
                            DesignSystem.Colors.ember.opacity(0.48),
                            DesignSystem.Colors.whimsy.opacity(0.20),
                            .clear
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

                LineMark(
                    x: .value("Time", point.date),
                    y: .value("Normalized token spend", point.value)
                )
                .interpolationMethod(.monotone)
                .lineStyle(StrokeStyle(lineWidth: 2.1, lineCap: .round, lineJoin: .round))
                .foregroundStyle(
                    LinearGradient(
                        colors: [DesignSystem.Colors.whimsy, DesignSystem.Colors.ember, DesignSystem.Colors.blaze],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
            }
        }
        .chartXScale(domain: range)
        .chartYScale(domain: 0...1.04)
        .chartXAxis {
            AxisMarks(position: .bottom, values: labelDates) { value in
                if let date = value.as(Date.self) {
                    AxisValueLabel(anchor: labelAnchor(for: date)) {
                        Text(label(for: date))
                            .font(.system(size: 8.5, weight: .medium, design: .rounded))
                            .foregroundStyle(DesignSystem.Colors.textMuted.opacity(0.9))
                            .monospacedDigit()
                    }
                }
            }
        }
        .chartYAxis(.hidden)
        .chartPlotStyle { plot in
            plot.background(.clear)
        }
        .accessibilityLabel("Token spend from \(label(for: range.lowerBound)) to \(label(for: range.upperBound))")
    }

    private func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }

    private func labelAnchor(for date: Date) -> UnitPoint {
        if abs(date.timeIntervalSince(range.lowerBound)) < 1 { return .topLeading }
        if abs(date.timeIntervalSince(range.upperBound)) < 1 { return .topTrailing }
        return .top
    }

    private func label(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        switch timeRange {
        case .today:
            formatter.setLocalizedDateFormatFromTemplate("jm")
        case .last7Days, .last30Days, .thisMonth:
            formatter.setLocalizedDateFormatFromTemplate("MMM d")
        case .allTime:
            formatter.setLocalizedDateFormatFromTemplate("MMM y")
        }
        return formatter.string(from: date)
    }
}

private struct DashboardIslandSparklinePoint: Identifiable {
    let index: Int
    let date: Date
    let value: Double
    var id: Int { index }
}

private struct DashboardAgentRobotGlyph: View {
    var body: some View {
        VStack(spacing: 0) {
            Circle()
                .fill(.foreground)
                .frame(width: 2.5, height: 2.5)
            Rectangle()
                .fill(.foreground)
                .frame(width: 1.2, height: 2)
            ZStack {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(.foreground, lineWidth: 1.35)
                HStack(spacing: 4) {
                    Circle().fill(.foreground).frame(width: 2.4, height: 2.4)
                    Circle().fill(.foreground).frame(width: 2.4, height: 2.4)
                }
                Capsule()
                    .fill(.foreground)
                    .frame(width: 6, height: 1.2)
                    .offset(y: 3.4)
            }
            .frame(width: 17, height: 13)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Enum bridges (UsageDisplayMode ↔ BurnRailUnit)

private extension BurnRailUnit {
    init(fromUsageMode mode: UsageDisplayMode) {
        switch mode {
        case .currency: self = .cost
        case .tokens:   self = .tokens
        }
    }
    var toUsageDisplayMode: UsageDisplayMode {
        switch self {
        case .cost:   return .currency
        case .tokens: return .tokens
        }
    }
}

// MARK: - Dashboard quick access rail

/// A user-owned row of persistent shortcuts that lives below the compact
/// macOS titlebar toolbar. The defaults make the high-frequency destinations
/// discoverable, while the editor lets users add, remove, and reorder their
/// own links without learning the Settings navigation tree.
struct DashboardQuickAccessRail: View {
    private static let storageKey = "dashboard.quickAccess.v1"
    private static let widthKey = "dashboard.quickAccess.width"

    let onRoute: (DashboardMainRoute) -> Void
    let onSettingsItem: (String) -> Void
    let onChatBackend: (ChatBackendID) -> Void
    var compact = false
    var scale: CGFloat = 1

    @AppStorage(Self.storageKey) private var storedItems = ""
    @AppStorage(Self.widthKey) private var storedCompactWidth = 520.0
    @State private var items: [DashboardQuickAccessItem] = []
    @State private var isEditing = false
    @State private var resizeOrigin: Double?

    var body: some View {
        HStack(spacing: 8 * scale) {
            if !compact {
                Image(systemName: "bolt.horizontal.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.amber)
                    .accessibilityHidden(true)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(items) { item in
                        DashboardQuickAccessChip(item: item, scale: scale) {
                            activate(item)
                        }
                    }
                }
                .padding(.vertical, 2)
            }

            Button {
                isEditing = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11 * scale, weight: .bold))
                    .frame(width: 25 * scale, height: 25 * scale)
            }
            .buttonStyle(.plain)
            .background(railCapsuleFill)
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(DesignSystem.Colors.border.opacity(0.55), lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .help("Customize quick access")
            .accessibilityLabel("Customize quick access")
            .accessibilityHint("Add, remove, or reorder shortcuts")

            if compact {
                Image(systemName: "arrow.left.and.right")
                    .font(.system(size: 8 * scale, weight: .bold))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .frame(width: 13 * scale, height: 25 * scale)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                if resizeOrigin == nil { resizeOrigin = storedCompactWidth }
                                let origin = resizeOrigin ?? storedCompactWidth
                                storedCompactWidth = min(max(origin + value.translation.width, 300), 760)
                            }
                            .onEnded { _ in resizeOrigin = nil }
                    )
                    .help("Drag to resize shortcuts")
                    .accessibilityLabel("Resize shortcuts")
                    .accessibilityHint("Drag horizontally to show more or fewer shortcuts")
                    .accessibilityAdjustableAction { direction in
                        let delta = direction == .increment ? 24.0 : -24.0
                        storedCompactWidth = min(max(storedCompactWidth + delta, 300), 760)
                    }
            }
        }
        .padding(.horizontal, (compact ? 5 : 14) * scale)
        .padding(.vertical, (compact ? 4 : 7) * scale)
        .frame(width: compact ? CGFloat(min(max(storedCompactWidth, 300), 760)) : nil)
        .frame(maxWidth: compact ? nil : .infinity)
        .background(railBackground)
        .clipShape(
            RoundedRectangle(cornerRadius: 14, style: .continuous),
            style: FillStyle(antialiased: true)
        )
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(DesignSystem.Colors.border.opacity(compact ? 0.32 : 0.4), lineWidth: 0.5))
        .onAppear { loadItemsIfNeeded() }
        .sheet(isPresented: $isEditing) {
            DashboardQuickAccessEditor(
                items: $items,
                onSave: persistItems,
                onCancel: { isEditing = false }
            )
            .frame(minWidth: 560, minHeight: 520)
        }
    }

    private func activate(_ item: DashboardQuickAccessItem) {
        switch item.destination {
        case .settings(let itemID): onSettingsItem(itemID)
        case .route(let rawValue):
            guard let route = DashboardMainRoute.quickAccessRoute(rawValue: rawValue) else { return }
            onRoute(route)
        case .chat(let backend): onChatBackend(backend)
        }
    }

    private func loadItemsIfNeeded() {
        guard items.isEmpty else { return }
        if let data = storedItems.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([DashboardQuickAccessItem].self, from: data),
           !decoded.isEmpty {
            items = decoded
        } else {
            items = DashboardQuickAccessItem.defaults
            persistItems()
        }
    }

    private func persistItems() {
        guard let data = try? JSONEncoder().encode(items),
              let json = String(data: data, encoding: .utf8) else { return }
        storedItems = json
    }

    @ViewBuilder
    private var railBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        if compact {
            shape.fill(DesignSystem.Colors.surface.opacity(0.44))
        } else if #available(macOS 26.0, *) {
            shape.fill(.clear).liquidGlassEffect(.regular, in: shape)
        } else {
            shape.fill(DesignSystem.Colors.surface.opacity(0.42))
        }
    }

    private var railCapsuleFill: some ShapeStyle {
        DesignSystem.Colors.surface.opacity(0.55)
    }
}

private struct DashboardQuickAccessChip: View {
    let item: DashboardQuickAccessItem
    var scale: CGFloat = 1
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let provider {
                    // The deck rail is always dark glass regardless of app
                    // appearance, so declare a dark surface: dark brand glyphs
                    // (Codex, Hermes, xAI…) get their contrast disc instead of
                    // vanishing black-on-black, and asset-less providers fall
                    // back to a light symbol rather than a dark brand colour.
                    ProviderLogoView(
                        provider: provider,
                        size: 20 * scale,
                        useFallbackColor: false,
                        surfaceScheme: .dark
                    )
                } else {
                    Image(systemName: item.systemImage)
                        .font(.system(size: 11 * scale, weight: .semibold))
                        .frame(width: 20 * scale, height: 20 * scale)
                        .background(DesignSystem.Colors.ember.opacity(0.16), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }

                if !isChatShortcut {
                    Text(displayTitle)
                        .font(.system(size: 11.5 * scale, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(DesignSystem.Colors.textPrimary)
            .padding(.horizontal, (isChatShortcut ? 4 : 8) * scale)
            .padding(.vertical, 3 * scale)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(DesignSystem.Colors.surface.opacity(0.62)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(DesignSystem.Colors.border.opacity(0.42), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help(item.subtitle)
        .accessibilityLabel(item.title)
        .accessibilityHint(item.subtitle)
    }

    private var provider: AgentProvider? {
        guard case .chat(let backend) = item.destination else { return nil }
        return backend.agentProvider
    }

    private var isChatShortcut: Bool {
        if case .chat = item.destination { return true }
        return false
    }

    private var displayTitle: String {
        switch item.destination {
        case .chat(let backend): return backend.shortLabel
        default:
            if item.title == "Wand models" { return "Wand" }
            return item.title
        }
    }
}

private struct DashboardQuickAccessEditor: View {
    @Binding var items: [DashboardQuickAccessItem]
    let onSave: () -> Void
    let onCancel: () -> Void

    @State private var searchQuery = ""

    private var filteredSettings: [SettingsItem] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return Array(SettingsManifest.all.prefix(18)) }
        return Array(SettingsSearchEngine.search(query, in: SettingsManifest.all).prefix(18))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text("Pin the places you reach most. Drag to reorder; remove anything you do not need.")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)

                List {
                    Section("Your shortcuts") {
                        ForEach($items) { $item in
                            HStack(spacing: 10) {
                                Image(systemName: "line.3.horizontal")
                                    .foregroundStyle(DesignSystem.Colors.textMuted)
                                Image(systemName: item.systemImage)
                                    .foregroundStyle(DesignSystem.Colors.ember)
                                Text(item.title)
                                Spacer()
                                Button(role: .destructive) {
                                    items.removeAll { $0.id == item.id }
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Remove \(item.title)")
                            }
                        }
                        .onMove { items.move(fromOffsets: $0, toOffset: $1) }
                    }

                    Section("Add a destination") {
                        TextField("Search Settings destinations", text: $searchQuery)
                            .textFieldStyle(.roundedBorder)

                        ForEach(filteredSettings) { setting in
                            Button {
                                add(setting)
                            } label: {
                                HStack {
                                    Image(systemName: setting.tab.icon)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(setting.title)
                                        if let subtitle = setting.subtitle {
                                            Text(subtitle)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                    }
                                    Spacer()
                                    Image(systemName: contains(setting.id) ? "checkmark" : "plus")
                                }
                            }
                            .disabled(contains(setting.id))
                        }

                        ForEach(ChatBackendID.allCases) { backend in
                            Button {
                                addChat(backend)
                            } label: {
                                Label("Chat · \(backend.displayName)", systemImage: "bubble.left.and.bubble.right")
                            }
                            .disabled(containsChat(backend))
                        }
                    }
                }
                .listStyle(.inset)
            }
            .navigationTitle("Customize Quick Access")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onSave()
                        onCancel()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private func add(_ setting: SettingsItem) {
        guard !contains(setting.id) else { return }
        items.append(DashboardQuickAccessItem(
            title: setting.title,
            subtitle: setting.subtitle ?? setting.tab.title,
            systemImage: setting.tab.icon,
            destination: .settings(setting.id)
        ))
    }

    private func addChat(_ backend: ChatBackendID) {
        guard !containsChat(backend) else { return }
        items.append(DashboardQuickAccessItem(
            title: "Chat · \(backend.shortLabel)",
            subtitle: "Open Chat with \(backend.displayName) selected",
            systemImage: "bubble.left.and.bubble.right",
            destination: .chat(backend)
        ))
    }

    private func contains(_ settingID: String) -> Bool {
        items.contains { $0.destination == .settings(settingID) }
    }

    private func containsChat(_ backend: ChatBackendID) -> Bool {
        items.contains { $0.destination == .chat(backend) }
    }
}

private struct DashboardQuickAccessItem: Identifiable, Codable, Hashable {
    enum Destination: Codable, Hashable {
        case settings(String)
        case route(String)
        case chat(ChatBackendID)
    }

    let id: UUID
    var title: String
    var subtitle: String
    var systemImage: String
    var destination: Destination

    init(id: UUID = UUID(), title: String, subtitle: String, systemImage: String, destination: Destination) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.destination = destination
    }

    static let defaults: [DashboardQuickAccessItem] = [
        .init(title: "Glyphs", subtitle: "Customize provider glyphs in Appearance", systemImage: "square.grid.2x2", destination: .settings("general.appearance.desktopWallpaperProviderGlyphs")),
        .init(title: "Wand models", subtitle: "Choose the Elder Wand analysis panel and judge", systemImage: "wand.and.stars", destination: .settings("agents.analysisConfigurator")),
        .init(title: "Chat · Codex", subtitle: "Open Chat with Codex selected", systemImage: "bubble.left.and.bubble.right", destination: .chat(.codex)),
        .init(title: "Chat · Claude", subtitle: "Open Chat with Claude Code selected", systemImage: "bubble.left.and.bubble.right", destination: .chat(.claude)),
        .init(title: "Chat · Hermes", subtitle: "Open Chat with Hermes selected", systemImage: "bubble.left.and.bubble.right", destination: .chat(.hermes))
    ]
}

// Internal rather than file-private so `DashboardViewIntegrationTests` can
// round-trip the identifiers persisted in `dashboard.quickAccess.v1`.
extension DashboardMainRoute {
    static func quickAccessRoute(rawValue: String) -> DashboardMainRoute? {
        switch rawValue {
        case "overview": return .overview
        case "insights": return .insights
        case "charts": return .charts
        case "database": return .database
        case "projects": return .projects
        case "missions": return .missions
        case "sessionLogs": return .sessionLogs
        case "memoryReview": return .memoryReview
        case "inbox": return .inbox
        case "chat": return .chat
        case "quota": return .quota
        case "controlDeck": return .controlDeck
        case "home": return .home
        case "fleet": return .fleet
        default: return nil
        }
    }
}
