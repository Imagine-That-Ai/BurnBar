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

    /// Drawn *in* the window titlebar, not via `.toolbar`.
    ///
    /// The window is `fullSizeContentView` + transparent title, so a SwiftUI
    /// `.toolbar` on the nested `NavigationSplitView` never becomes the window
    /// toolbar — that is why the strip stayed empty after the first pass.
    /// This row ignores the top safe area and sits beside the traffic lights.
    var dashboardWindowTitleStrip: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                titleChromeStepButton(
                    systemImage: "chevron.backward",
                    enabled: canGoBack,
                    help: backButtonHelpText,
                    action: goBack
                )
                .accessibilityLabel("Back")
                .accessibilityIdentifier(OBBAccessibilityID.dashboardBackButton)

                titleChromeStepButton(
                    systemImage: "chevron.forward",
                    enabled: canGoForward,
                    help: forwardButtonHelpText,
                    action: goForward
                )
                .accessibilityLabel("Forward")
            }

            Button {
                showCommandPalette = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(dashboardChromeInk.icon)
                    Text("Jump or search")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(dashboardChromeInk.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text("⌘K")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(dashboardChromeInk.subtle)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(
                            Capsule(style: .continuous)
                                .fill(DesignSystem.Colors.surface.opacity(0.35))
                        )
                }
                .padding(.horizontal, 10)
                .frame(maxWidth: 380, minHeight: 24)
                // The app's own material, not the system effect. `liquidGlassEffect`
                // over the old web-view backdrop had nothing to sample and rendered as
                // flat frost; this pill sits on the live field like everything else, and
                // carries its own rim rather than a hand-drawn hairline.
                .burnBarGlassControl(.cockpit, height: 24)
                .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .help("Command Palette (⌘K)")
            .accessibilityLabel("Command palette")
            .accessibilityHint("Jump to a section or search sessions")
            .accessibilityIdentifier(OBBAccessibilityID.dashboardCommandPaletteButton)

            Spacer(minLength: 8)

            Button(action: toggleDashboardSidebar) {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(dashboardChromeInk.icon)
                    .frame(width: 24, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isDashboardSidebarVisible ? "Hide sidebar" : "Show sidebar")
            .accessibilityLabel(isDashboardSidebarVisible ? "Hide sidebar" : "Show sidebar")
        }
        // Traffic lights occupy the leading ~70pt of the titlebar.
        .padding(.leading, 84)
        .padding(.trailing, 16)
        .padding(.vertical, 4)
        .frame(height: 32)
        // Deliberately plateless.
        //
        // A first pass gave this strip its own `burnBarGlass` slab, on the theory that
        // "the top bar is part of the material system" meant "the top bar needs a plate".
        // It does not: a full-width square plate sitting above the window's own rounded
        // content reads as a black band bolted on top, which is worse than the bare
        // glyphs it replaced. The strip belongs to the material system by sitting *on*
        // the field — which it now genuinely does, because the native backdrop paints
        // under the transparent titlebar. The only thing here that earns a plate is the
        // ⌘K pill, because it is a control.
    }

    @ViewBuilder
    private func titleChromeStepButton(
        systemImage: String,
        enabled: Bool,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(enabled ? dashboardChromeInk.primary : dashboardChromeInk.subtle)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
    }

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

            BurnBarProfileAvatarButton(
                size: .toolbar,
                onOpenSettings: { presentSettings() },
                onOpenSettingsTab: { tab in
                    UserDefaults.standard.set(tab.rawValue, forKey: SettingsDeepLinkRouting.pendingTabKey)
                    presentSettings()
                },
                onOpenSettingsItem: { item in
                    presentSettings(itemID: item)
                },
                isScanning: isScanning,
                onImport: { runScan() },
                onRecount: { runRecount() },
                canRunRecount: canRunRecount,
                mtdSpendFormatted: settingsManager.formatUsageMetric(
                    cost: totalCostForTimeRange,
                    tokens: totalTokensForTimeRange
                )
            )
            .accessibilityIdentifier(OBBAccessibilityID.dashboardSettingsButton)
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
        // Single unified unibody glass deck container: the upper command deck
        // and lower status rail sample and refract together within one cohesive plate.
        // Was wrapped in a `LiquidGlassGroup` (a `GlassEffectContainer`). That exists to
        // unify *system* glass shapes into one pass, and it has nothing to unify now the
        // deck's material is a shader — while it does elevate the z-order of its
        // descendants above its own content, which is the documented trap that has
        // already shipped twice as a blank frosted slab over invisible copy
        // (`BackdropLegibleSurface.swift:229`, `:352`).
        Group {
            VStack(spacing: 0) {
                HStack(spacing: 14 * dashboardDeckScale) {
                    dashboardDeckLeading

                    dashboardDeckChart
                        .layoutPriority(2)

                    dashboardDeckActions
                        .layoutPriority(1)
                }
                .padding(.horizontal, 16 * dashboardDeckScale)
                .padding(.vertical, 6)
                .frame(height: dashboardDeckHeight)

                Rectangle()
                    .fill(dashboardChromeInk.hairline)
                    .frame(height: 0.5)
                    .opacity(0.35)

                dashboardDeckStatusRail
            }
            // One piece of real glass for the whole deck.
            //
            // `backdropChromePlate` routed to the system `glassEffect`, which over a
            // `WKWebView` backdrop had nothing to sample and rendered as flat frost —
            // the top bar was the most visible casualty of that, and the reason it never
            // matched the content below it. This is the same material every
            // `DashboardSection` uses, so the deck now refracts the same field the page
            // does, continuous across the seam.
            .burnBarGlass(
                .cockpit,
                role: .chrome,
                cornerRadius: dashboardDeckCornerRadius
            )
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(Color.clear)
        // One resolve for the whole chrome, so a bar can never end up
        // half-adaptive: every label below reads `\.backdropInk` and gets the
        // family the sampler sized for whatever the kernel is painting.
        .resolvingBackdropInk(
            liveBackdropActive: dashboardLiveBackdropActive,
            profile: dashboardActiveReadabilityProfile
        )
    }

    // MARK: Deck geometry
    //
    // Both bars share one drag, so both derive from the same clamp and the same
    // control scale. Type, glyphs, and corner radii all track the height —
    // "thinner" has to mean retuned, not clipped.

    private var dashboardDeckHeight: CGFloat {
        CGFloat(min(max(storedDashboardDeckHeight, 60), 116))
    }

    /// Interior scale for the upper row, pinned to 1.0 at the default height.
    private var dashboardDeckScale: CGFloat {
        min(max(dashboardDeckHeight / 72, 0.9), 1.3)
    }

    /// Corner radius tracks height so the deck reads as one continuous
    /// capsule-ish body at 60pt and at 116pt, rather than a fixed 34pt radius
    /// that looks like a stadium when short and a soft box when tall.
    private var dashboardDeckCornerRadius: CGFloat {
        min(28, dashboardDeckHeight / 2.4)
    }

    /// The ink the chrome draws with.
    ///
    /// Resolved here rather than read from `\.backdropInk` because the deck rows
    /// are computed properties of `DashboardView` itself, and a view cannot read
    /// an environment value it injects into its own output. The injection in
    /// `dashboardCommandDeck` is still what serves the real child views —
    /// `DashboardLayoutSwitcher`, `DashboardQuickAccessRail`,
    /// `BurnRailAppearanceQuickMenu` — so both paths resolve the same family.
    var dashboardChromeInk: BackdropInk {
        BackdropInk.resolve(
            liveBackdropActive: dashboardLiveBackdropActive,
            profile: dashboardActiveReadabilityProfile
        )
    }

    /// The tone of the chrome plate, for the few places that need a
    /// `ColorScheme` rather than a colour — brand glyph contrast discs, mostly.
    ///
    /// Under a live backdrop the sampled profile knows better than the app's
    /// appearance does, which is the whole reason it is sampled.
    var dashboardChromeColorScheme: ColorScheme {
        dashboardLiveBackdropActive
            ? dashboardActiveReadabilityProfile.interfaceColorScheme
            : dashboardKernelColorScheme
    }

    private var dashboardDeckLeading: some View {
        HStack(spacing: 9 * dashboardDeckScale) {
            // The logo is the Home button. "Logo goes home" is universal, and
            // it costs zero width — which matters, because the deck strip is
            // `.fixedSize(horizontal:)` and a seventh route button would push
            // the deck past the 1040pt window minimum.
            Button {
                withAnimation(DesignSystem.Animation.standard) {
                    navigate(to: .home)
                }
            } label: {
                AppLogoView(size: 26 * dashboardDeckScale)
                    .frame(width: 32 * dashboardDeckScale, height: 32 * dashboardDeckScale)
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

            Rectangle()
                .fill(dashboardChromeInk.hairline)
                .frame(width: 1, height: 22 * dashboardDeckScale)
                .opacity(0.5)

            HStack(spacing: 0) {
                dashboardDeckRouteButton(.overview)
                dashboardDeckRouteButton(.controlDeck)
                dashboardDeckRouteButton(.charts)
                dashboardDeckRouteButton(.insights)
                dashboardDeckRouteButton(.projects)
                dashboardDeckRouteButton(.sessionLogs)
            }
            .padding(2.5)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(DesignSystem.Colors.surface.opacity(0.34))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(dashboardChromeInk.hairline.opacity(0.5), lineWidth: 0.5)
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
                        .font(.system(size: 12.5 * dashboardDeckScale, weight: .semibold))
                }
            }
                .foregroundStyle(selected ? dashboardChromeInk.primary : dashboardChromeInk.icon)
                .frame(width: 30 * dashboardDeckScale, height: 30 * dashboardDeckScale)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: 9.5, style: .continuous)
                            .fill(DesignSystem.Colors.ember.opacity(0.2))
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 9.5, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(route.title(activeChatBackend: chatController.chatBackend))
        .accessibilityLabel(route.title(activeChatBackend: chatController.chatBackend))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var dashboardDeckChart: some View {
        let insetShape = RoundedRectangle(
            cornerRadius: min(20, dashboardDeckHeight / 3.2),
            style: .continuous
        )
        return HStack(spacing: 12 * dashboardDeckScale) {
            Button {
                withAnimation(DesignSystem.Animation.standard) {
                    navigate(to: .charts)
                }
            } label: {
                HStack(spacing: 12 * dashboardDeckScale) {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 5) {
                            Text("BURN RATE")
                                .font(.system(size: 9 * dashboardDeckScale, weight: .bold, design: .rounded))
                                .tracking(1.1)
                            Circle()
                                .fill(burnRailIsLive ? DesignSystem.Colors.success : dashboardChromeInk.hairline)
                                .frame(width: 5, height: 5)
                        }
                        .foregroundStyle(dashboardChromeInk.subtle)

                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Text(settingsManager.formatUsageMetric(
                                cost: totalCostForTimeRange,
                                tokens: totalTokensForTimeRange
                            ))
                            .font(.system(size: 22 * dashboardDeckScale, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(dashboardChromeInk.primary)
                            .contentTransition(.numericText())

                            if let delta = burnRailDeltaPercent {
                                Text(delta.formatted(.number.precision(.fractionLength(1)).sign(strategy: .always())) + "%")
                                    .font(.system(size: 10.5 * dashboardDeckScale, weight: .bold, design: .rounded))
                                    .foregroundStyle(delta <= 0 ? DesignSystem.Colors.success : DesignSystem.Colors.amber)
                            }
                        }
                    }
                    .frame(minWidth: 112 * dashboardDeckScale, alignment: .leading)

                    DashboardIslandSparkline(
                        samples: burnRailSparkline,
                        range: burnRailDisplayRange,
                        timeRange: selectedTimeRange
                    )
                        .frame(minWidth: 200, maxWidth: .infinity)
                        // The sparkline is the one element that has real room to
                        // give back: at 74pt it set the deck's floor by itself.
                        .frame(height: max(30, dashboardDeckHeight - 32))
                }
            }
            .buttonStyle(.plain)
            .frame(minWidth: 340, maxWidth: .infinity)
            .help("Open Charts — the full analytics gallery")
            .accessibilityLabel("Open Charts")
            .accessibilityIdentifier(OBBAccessibilityID.dashboardDeckChartButton)

            Button {
                showHeroPopover.toggle()
            } label: {
                HStack(spacing: 4) {
                    Text(selectedTimeRange.displayName.uppercased())
                        .font(.system(size: 9.5 * dashboardDeckScale, weight: .bold, design: .rounded))
                        .tracking(0.6)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                }
                .foregroundStyle(dashboardChromeInk.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(
                    Capsule(style: .continuous)
                        .fill(DesignSystem.Colors.surface.opacity(0.4))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(dashboardChromeInk.hairline.opacity(0.6), lineWidth: 0.5)
                )
                .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .help("Change Burn chart range or unit")
            .accessibilityLabel("Burn chart range and unit")
            .popover(isPresented: $showHeroPopover, arrowEdge: .bottom) {
                commandDeckHeroPopover
                    .frame(width: 240)
            }
        }
        .padding(.horizontal, 14 * dashboardDeckScale)
        .padding(.vertical, 5)
        .frame(minWidth: 420, maxWidth: .infinity)
        .background(insetShape.fill(DesignSystem.Colors.surface.opacity(0.3)))
        .overlay {
            insetShape.stroke(DesignSystem.Colors.ember.opacity(0.2), lineWidth: 0.75)
        }
        .clipShape(insetShape, style: FillStyle(antialiased: true))
        .contentShape(insetShape)
    }

    private var dashboardDeckActions: some View {
        BurnBarProfileAvatarButton(
            size: .toolbar,
            onOpenSettings: { presentSettings() },
                onOpenSettingsTab: { tab in
                    UserDefaults.standard.set(tab.rawValue, forKey: SettingsDeepLinkRouting.pendingTabKey)
                    presentSettings()
                },
                onOpenSettingsItem: { item in
                    presentSettings(itemID: item)
                },
                isScanning: isScanning,
                onImport: { runScan() },
                onRecount: { runRecount() },
                canRunRecount: canRunRecount,
                mtdSpendFormatted: settingsManager.formatUsageMetric(
                    cost: totalCostForTimeRange,
                    tokens: totalTokensForTimeRange
                )
            )
            .accessibilityIdentifier(OBBAccessibilityID.dashboardSettingsButton)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var dashboardDeckStatusRail: some View {
        let scale = dashboardStatusRailControlScale
        let ink = dashboardChromeInk
        return HStack(spacing: 10 * scale) {
            Circle()
                .fill(DesignSystem.Colors.success)
                .frame(width: 6 * scale, height: 6 * scale)
            Text(mainRoute.title(activeChatBackend: chatController.chatBackend))
                .font(.system(size: 11.5 * scale, weight: .semibold, design: .rounded))
                .foregroundStyle(ink.primary)
            Text("Updated")
                .foregroundStyle(ink.subtle)
            if let lastRefresh = dataStore.lastRefresh {
                Text(lastRefresh, style: .time)
                    .monospacedDigit()
                    .foregroundStyle(ink.secondary)
            } else {
                Text("Waiting")
                    .foregroundStyle(ink.subtle)
            }

            dashboardRailHairline(scale: scale)

            Text(isScanning ? "Mining session logs" : "Live usage ready")
                .foregroundStyle(isScanning ? DesignSystem.Colors.ember : ink.subtle)

            dashboardRailHairline(scale: scale)

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
                scale: scale,
                surfaceScheme: dashboardChromeColorScheme
            )
            .layoutPriority(2)

            Spacer(minLength: 12)

            BurnRailAppearanceQuickMenu(
                settingsManager: settingsManager,
                onOpenAppearanceSettings: {
                    presentSettings(itemID: "general.appearance.theme")
                },
                scale: scale
            )
        }
        .font(.system(size: 11 * scale, design: .rounded))
        .padding(.horizontal, 16)
        .frame(height: dashboardStatusRailHeight)
        .overlay(alignment: .bottom) {
            dashboardDeckResizeHandle
        }
    }

    /// A hairline separator that reads through the chrome ink rather than the
    /// system `Divider`, which paints its own opaque grey and shows as a bar
    /// over a live kernel.
    private func dashboardRailHairline(scale: CGFloat) -> some View {
        Rectangle()
            .fill(dashboardChromeInk.hairline)
            .frame(width: 1, height: 16 * scale)
            .opacity(0.55)
    }

    private var dashboardStatusRailHeight: CGFloat {
        CGFloat(min(max(storedDashboardStatusRailHeight, 36), 64))
    }

    private var dashboardStatusRailControlScale: CGFloat {
        min(max(dashboardStatusRailHeight / 40, 0.9), 1.3)
    }

    /// One handle for the whole deck.
    ///
    /// Two independent handles meant the two bars drifted out of proportion with
    /// each other, and the upper one had no handle at all. The drag moves the
    /// deck row at full rate and the rail at half, because the rail's range is
    /// half as wide — so both hit their stops together and the pair keeps its
    /// ratio the whole way.
    private var dashboardDeckResizeHandle: some View {
        let railRate = 0.5
        return Capsule(style: .continuous)
            .fill(dashboardChromeInk.subtle.opacity(0.4))
            .frame(width: 34, height: 2.5)
            .frame(width: 96, height: 12)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if dashboardDeckResizeOrigin == nil {
                            dashboardDeckResizeOrigin = storedDashboardDeckHeight
                            dashboardStatusRailResizeOrigin = storedDashboardStatusRailHeight
                        }
                        let deckOrigin = dashboardDeckResizeOrigin ?? storedDashboardDeckHeight
                        let railOrigin = dashboardStatusRailResizeOrigin ?? storedDashboardStatusRailHeight
                        resizeDeck(
                            deckHeight: deckOrigin + value.translation.height,
                            railHeight: railOrigin + value.translation.height * railRate
                        )
                    }
                    .onEnded { _ in
                        dashboardDeckResizeOrigin = nil
                        dashboardStatusRailResizeOrigin = nil
                    }
            )
            .onHover { NSCursor.resizeUpDown.set(); if !$0 { NSCursor.arrow.set() } }
            .accessibilityLabel("Resize toolbar")
            .accessibilityHint("Drag vertically to resize both toolbar rows and their controls")
            .accessibilityAdjustableAction { direction in
                let delta = direction == .increment ? 6.0 : -6.0
                resizeDeck(
                    deckHeight: storedDashboardDeckHeight + delta,
                    railHeight: storedDashboardStatusRailHeight + delta * railRate
                )
            }
    }

    private func resizeDeck(deckHeight: Double, railHeight: Double) {
        storedDashboardDeckHeight = min(max(deckHeight, 60), 116)
        storedDashboardStatusRailHeight = min(max(railHeight, 36), 64)
    }

    private var dashboardDeckLayoutBinding: Binding<DashboardLayout> {
        Binding(
            get: { settingsManager.dashboardLayout },
            set: { newValue in
                // No route change: Home and Overview both re-render themselves
                // through the layout, so yanking the user to Overview to prove
                // the switcher worked would be the wrong kind of feedback.
                settingsManager.dashboardLayout = newValue
                Analytics.shared.track(.settingsChanged, [
                    "setting_key": "dashboard_layout",
                    "new_value": .string(newValue.rawValue),
                    "source": "command_deck_status_rail"
                ])
            }
        )
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
                .foregroundStyle(DesignSystem.Colors.textSecondary)

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
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
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

    // MARK: - Overflow menu (Sidebar · Import · Recount · Settings)

    private var commandDeckOverflow: some View {
        Menu {
            Button {
                toggleDashboardSidebar()
            } label: {
                Label(
                    isDashboardSidebarVisible ? "Hide Sidebar" : "Show Sidebar",
                    systemImage: "sidebar.left"
                )
            }

            Button("Import Sessions…") { runScan() }
                .disabled(isScanning)

            Button("Recount Totals") { runRecount() }
                .disabled(!canRunRecount)

            Divider()

            Button("Settings…") { presentSettings() }
                .accessibilityIdentifier(OBBAccessibilityID.dashboardSettingsButton)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11.5 * dashboardDeckScale, weight: .bold))
                    .foregroundStyle(isScanning ? DesignSystem.Colors.ember : dashboardChromeInk.icon)
            }
            .frame(width: 26 * dashboardDeckScale, height: 22 * dashboardDeckScale)
            .background(
                Capsule(style: .continuous)
                    .fill(DesignSystem.Colors.surface.opacity(0.3))
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
        .help("More actions")
        .accessibilityLabel("More actions")
        .accessibilityHint("Toggle sidebar, import sessions, recount totals, or open settings")
    }
}

private struct DashboardIslandSparkline: View {
    let samples: [Double]
    let range: ClosedRange<Date>
    let timeRange: TimeRange
    @Environment(\.backdropInk) private var ink

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
                            .foregroundStyle(ink.subtle)
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
    /// Tone of the plate the rail is drawn on, forwarded to the chips so brand
    /// glyphs resolve their contrast treatment against the real surface.
    var surfaceScheme: ColorScheme = .dark

    @AppStorage(Self.storageKey) private var storedItems = ""
    @AppStorage(Self.widthKey) private var storedCompactWidth = 520.0
    @State private var items: [DashboardQuickAccessItem] = []
    @State private var isEditing = false
    @State private var resizeOrigin: Double?
    /// Compact is the in-chrome placement, so it inherits the deck's resolved
    /// ink rather than reaching for tokens that assume a static canvas.
    @Environment(\.backdropInk) private var ink

    var body: some View {
        HStack(spacing: 8 * scale) {
            if !compact {
                Image(systemName: "bolt.horizontal.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.amber)
                    .accessibilityHidden(true)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(items) { item in
                        DashboardQuickAccessChip(
                            item: item,
                            scale: scale,
                            surfaceScheme: surfaceScheme
                        ) {
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
                    .font(.system(size: 10.5 * scale, weight: .bold))
                    .foregroundStyle(compact ? ink.icon : DesignSystem.Colors.textSecondary)
                    .frame(width: 22 * scale, height: 22 * scale)
            }
            .buttonStyle(.plain)
            .background(railCapsuleFill)
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(strokeInk.opacity(0.55), lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .help("Customize quick access")
            .accessibilityLabel("Customize quick access")
            .accessibilityHint("Add, remove, or reorder shortcuts")

            if compact {
                Image(systemName: "arrow.left.and.right")
                    .font(.system(size: 8 * scale, weight: .bold))
                    .foregroundStyle(ink.icon)
                    .frame(width: 13 * scale, height: 22 * scale)
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
        .padding(.horizontal, (compact ? 4 : 14) * scale)
        .padding(.vertical, (compact ? 3 : 7) * scale)
        .frame(width: compact ? CGFloat(min(max(storedCompactWidth, 300), 760)) : nil)
        .frame(maxWidth: compact ? nil : .infinity)
        .background(railBackground)
        .clipShape(
            RoundedRectangle(cornerRadius: 12, style: .continuous),
            style: FillStyle(antialiased: true)
        )
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(strokeInk.opacity(compact ? 0.32 : 0.4), lineWidth: 0.5))
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

    /// Hairlines follow the chrome ink when the rail is in the chrome, and the
    /// design token when it is standalone.
    private var strokeInk: Color {
        compact ? ink.hairline : DesignSystem.Colors.border
    }

    @ViewBuilder
    private var railBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        if compact {
            // Inside the chrome the deck plate is already the substrate, so the
            // rail only needs a whisper to separate the chips from it. A second
            // opaque slab here is what made the bar look like boxes in boxes.
            shape.fill(DesignSystem.Colors.surface.opacity(0.26))
        } else if #available(macOS 26.0, *) {
            shape.fill(.clear).liquidGlassEffect(.regular, in: shape)
        } else {
            shape.fill(DesignSystem.Colors.surface.opacity(0.42))
        }
    }

    private var railCapsuleFill: some ShapeStyle {
        DesignSystem.Colors.surface.opacity(compact ? 0.4 : 0.55)
    }
}

private struct DashboardQuickAccessChip: View {
    let item: DashboardQuickAccessItem
    var scale: CGFloat = 1
    /// The tone of the plate this chip sits on, so brand glyphs pick the right
    /// contrast treatment. Previously hardcoded `.dark` on the belief that the
    /// deck is always dark glass — it is not, and in Light mode that inverted
    /// every provider logo's contrast disc.
    var surfaceScheme: ColorScheme = .dark
    let action: () -> Void
    @Environment(\.backdropInk) private var ink

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let provider {
                    ProviderLogoView(
                        provider: provider,
                        size: 18 * scale,
                        useFallbackColor: false,
                        surfaceScheme: surfaceScheme
                    )
                } else {
                    Image(systemName: item.systemImage)
                        .font(.system(size: 10.5 * scale, weight: .semibold))
                        .frame(width: 18 * scale, height: 18 * scale)
                        .background(DesignSystem.Colors.ember.opacity(0.16), in: RoundedRectangle(cornerRadius: 5.5, style: .continuous))
                }

                if !isChatShortcut {
                    Text(displayTitle)
                        .font(.system(size: 11 * scale, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(ink.primary)
            .padding(.horizontal, (isChatShortcut ? 3 : 7) * scale)
            .padding(.vertical, 2.5 * scale)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(DesignSystem.Colors.surface.opacity(0.44)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(ink.hairline.opacity(0.5), lineWidth: 0.5))
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
        case "recap": return .recap
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
