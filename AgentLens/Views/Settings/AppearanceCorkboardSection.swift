import AppKit
import SwiftUI
import OpenBurnBarCore

struct AppearanceCorkboardSection: View {
    @Environment(SettingsRouter.self) private var router: SettingsRouter?
    @Bindable var settingsManager: SettingsManager
    @State private var isProviderGlyphCustomizerExpanded = true
    @State private var selectedSection: AppearanceSection = .theme

    enum AppearanceSection: String, CaseIterable, Identifiable {
        case theme
        case menuBar
        case background

        var id: String { rawValue }

        var label: String {
            switch self {
            case .theme: return "Theme"
            case .menuBar: return "Menu Bar & Launch"
            case .background: return "Background & Effects"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            AppearancePreviewCard(settingsManager: settingsManager)

            Picker("", selection: $selectedSection) {
                ForEach(AppearanceSection.allCases) { section in
                    Text(section.label).tag(section)
                }
            }
            .pickerStyle(.segmented)

            GlassCard {
                Group {
                    switch selectedSection {
                    case .theme:
                        themeSection
                    case .menuBar:
                        menuBarSection
                    case .background:
                        backgroundSection
                    }
                }
                .padding(DesignSystem.Spacing.lg)
            }

            applyAndRestartButton
        }
        .onAppear(perform: selectSectionForPendingAnchor)
        .onChange(of: router?.pendingAnchor) { _, _ in
            selectSectionForPendingAnchor()
        }
    }

    // MARK: - Theme section

    @ViewBuilder
    private var themeSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Appearance")
                            .font(DesignSystem.Typography.body)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                        Text("Choose whether OpenBurnBar follows the system, stays light, or stays dark.")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                    }
                    Spacer()
                    Picker("", selection: $settingsManager.appearanceMode) {
                        ForEach(AppearanceMode.allCases, id: \.self) { mode in
                            Text(modeLabel(mode)).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 220)
                    .onChange(of: settingsManager.appearanceMode) { _, newValue in
                        Analytics.shared.track(.settingsChanged, [
                            "setting_key": "appearance_mode",
                            "new_value": .string(newValue.rawValue)
                        ])
                    }
                }
                .settingsAnchor(SettingsAnchor.appearanceTheme)

                Divider().background(DesignSystem.Colors.border)

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("App Skin")
                            .font(DesignSystem.Typography.body)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                        Text("Aurora is the signature ember look. Editorial is the light, paper-bright app.burnbar.ai console skin — one coral accent, ink text, hairlines. Applies fully after Apply & Restart (below).")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                    }
                    Spacer()
                    Picker("", selection: $settingsManager.appearanceSkin) {
                        Text("Aurora").tag(AppSkin.aurora)
                        Text("Editorial").tag(AppSkin.editorial)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 220)
                    .onChange(of: settingsManager.appearanceSkin) { _, newValue in
                        Analytics.shared.track(.settingsChanged, [
                            "setting_key": "appearance_skin",
                            "new_value": .string(newValue.rawValue)
                        ])
                    }
                }
                .settingsAnchor(SettingsAnchor.appearanceSkin)

                Divider().background(DesignSystem.Colors.border)

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Dashboard Layout")
                            .font(DesignSystem.Typography.body)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                        Text(
                            """
                            How the Overview arranges itself — each layout is a different way of \
                            reading the same data, not a different backdrop. \
                            \(settingsManager.dashboardLayout.displayName): \
                            \(settingsManager.dashboardLayout.tagline.lowercased()). \
                            The Overview's top bar has a preview gallery for switching.
                            """
                        )
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                    }
                    Spacer()
                    Picker("", selection: $settingsManager.dashboardLayout) {
                        ForEach(DashboardLayout.allCases, id: \.self) { layout in
                            Label("\(layout.displayName) — \(layout.tagline)", systemImage: layout.symbolName)
                                .tag(layout)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 240)
                    .onChange(of: settingsManager.dashboardLayout) { _, newValue in
                        Analytics.shared.track(.settingsChanged, [
                            "setting_key": "dashboard_layout",
                            "new_value": .string(newValue.rawValue)
                        ])
                    }
                }

                Divider().background(DesignSystem.Colors.border)

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Opens On")
                            .font(DesignSystem.Typography.body)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                        Text("Which screen the dashboard window shows when it opens. Home is the inbox with your agent fleet and quota beside it; Overview is the spend dashboard in your chosen layout.")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                    }
                    Spacer()
                    Picker("", selection: $settingsManager.dashboardLaunchSurface) {
                        ForEach(DashboardLaunchSurface.allCases, id: \.self) { surface in
                            Label(surface.displayName, systemImage: surface.symbolName).tag(surface)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 220)
                    .onChange(of: settingsManager.dashboardLaunchSurface) { _, newValue in
                        Analytics.shared.track(.settingsChanged, [
                            "setting_key": "dashboard_launch_surface",
                            "new_value": .string(newValue.rawValue)
                        ])
                    }
                }

                Divider().background(DesignSystem.Colors.border)

                LiquidGlassTransparencyRow()
                    .settingsAnchor(SettingsAnchor.appearanceGlassTransparency)

                Divider().background(DesignSystem.Colors.border)

                LiquidGlassLiquidityRow()
                    .settingsAnchor(SettingsAnchor.appearanceGlassRefraction)

                Divider().background(DesignSystem.Colors.border)

                LiquidGlassContentSurfacesToggleRow()
        }
    }

    // MARK: - Menu Bar & Launch section

    private var menuBarSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            SettingsToggle(
                    title: "Show in Menu Bar",
                    subtitle: "Keep OpenBurnBar available as a menu-bar utility.",
                    icon: "menubar.rectangle",
                    isOn: $settingsManager.showInMenuBar
                )
                .settingsAnchor(SettingsAnchor.appearanceMenuBar)
                .onChange(of: settingsManager.showInMenuBar) { _, newValue in
                    Analytics.shared.track(.settingsChanged, [
                        "setting_key": "menu_bar_visibility",
                        "new_value": .bool(newValue)
                    ])
                }

                Divider().background(DesignSystem.Colors.border)

                SettingsToggle(
                    title: "Colorful Menu Bar Icon",
                    subtitle: "Use a full-color icon instead of a monochrome template.",
                    icon: "paintpalette",
                    isOn: $settingsManager.colorfulMenuBarIcon
                )
                .onChange(of: settingsManager.colorfulMenuBarIcon) { _, newValue in
                    Analytics.shared.track(.settingsChanged, [
                        "setting_key": "menu_bar_icon_colorful",
                        "new_value": .bool(newValue)
                    ])
                }

                Divider().background(DesignSystem.Colors.border)

                SettingsToggle(
                    title: "Launch at Login",
                    subtitle: "Start OpenBurnBar when you sign in to macOS.",
                    icon: "person.crop.circle.badge.checkmark",
                    isOn: $settingsManager.launchAtLogin
                )
                .settingsAnchor(SettingsAnchor.appearanceLaunchAtLogin)
                .onChange(of: settingsManager.launchAtLogin) { _, newValue in
                    Analytics.shared.track(.settingsChanged, [
                        "setting_key": "launch_at_login",
                        "new_value": .bool(newValue)
                    ])
                }

                Divider().background(DesignSystem.Colors.border)

                SettingsToggle(
                    title: "Premium SOTA UX",
                    subtitle: "Enable cinematic spring physics and specular shimmers globally.",
                    icon: "sparkles",
                    isOn: $settingsManager.usePremiumSOTAUX
                )
                .settingsAnchor(SettingsAnchor.usePremiumSOTAUX)
                .onChange(of: settingsManager.usePremiumSOTAUX) { _, newValue in
                    Analytics.shared.track(.settingsChanged, [
                        "setting_key": "premium_sota_ux",
                        "new_value": .bool(newValue)
                    ])
                }
        }
    }

    // MARK: - Background & Effects section

    private var backgroundSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            SettingsToggle(
                title: "Swarm Background",
                subtitle: "Active, reconverging token-ember swarms pulled from burnbar.ai. Particles drift and reform into $, </>, the BurnBar logo, quota rings, and router failover paths.",
                icon: "sparkles",
                    isOn: $settingsManager.useWebsiteBackground
                )
                .settingsAnchor(SettingsAnchor.useWebsiteBackground)
                .onChange(of: settingsManager.useWebsiteBackground) { _, newValue in
                    Analytics.shared.track(.settingsChanged, [
                        "setting_key": "desktop_swarm_background",
                        "new_value": .bool(newValue)
                    ])
                }

                Divider().background(DesignSystem.Colors.border)

                SettingsToggle(
                    title: "Constellation Style",
                    subtitle: "Switch the swarm background to a calm, slow constellation: one crest or provider logo at a time resolves from coloured dots, shimmers in place, then dissolves as the next forms somewhere new. Requires Swarm Background.",
                    icon: "sparkle",
                    isOn: $settingsManager.useConstellationBackground
                )
                .disabled(!settingsManager.useWebsiteBackground)
                .opacity(settingsManager.useWebsiteBackground ? 1.0 : 0.45)
                .settingsAnchor(SettingsAnchor.useConstellationBackground)
                .onChange(of: settingsManager.useConstellationBackground) { _, newValue in
                    Analytics.shared.track(.settingsChanged, [
                        "setting_key": "desktop_constellation_background",
                        "new_value": .bool(newValue)
                    ])
                }

                Divider().background(DesignSystem.Colors.border)

                KernelBackdropSettingsRow()

                Divider().background(DesignSystem.Colors.border)

                SwarmSubstrateSettingsRow()

                Divider().background(DesignSystem.Colors.border)

                SettingsToggle(
                    title: "Enable Desktop Swarm Wallpaper",
                    subtitle: "Render the dynamic token ember swarm simulation directly as your macOS desktop wallpaper.",
                    icon: "desktopcomputer",
                    isOn: $settingsManager.enableDesktopWallpaper
                )
                .settingsAnchor(SettingsAnchor.desktopWallpaperEnabled)
                .onChange(of: settingsManager.enableDesktopWallpaper) { _, newValue in
                    Analytics.shared.track(.settingsChanged, [
                        "setting_key": "desktop_wallpaper_enabled",
                        "new_value": .bool(newValue)
                    ])
                }

                Divider().background(DesignSystem.Colors.border)

                desktopWallpaperBackgroundPicker
                    .settingsAnchor(SettingsAnchor.desktopWallpaperBackground)

                Divider().background(DesignSystem.Colors.border)

                desktopWallpaperSpeedDial
                    .settingsAnchor(SettingsAnchor.desktopWallpaperSpeed)

                Divider().background(DesignSystem.Colors.border)

                desktopWallpaperProviderGlyphCustomizer
                    .settingsAnchor(SettingsAnchor.desktopWallpaperProviderGlyphs)

                Divider().background(DesignSystem.Colors.border)

                SettingsToggle(
                    title: "Exclude Brand Shapes",
                    subtitle: "Skip brand shapes (BurnBar logo, dollar sign, code symbols, rings, router flow) during the cycle, leaving only AI provider logos.",
                    icon: "eye.slash.fill",
                    isOn: $settingsManager.excludeBrandShapesFromSwarm
                )
                .onChange(of: settingsManager.excludeBrandShapesFromSwarm) { _, newValue in
                    Analytics.shared.track(.settingsChanged, [
                        "setting_key": "desktop_exclude_brand_shapes",
                        "new_value": .bool(newValue)
                    ])
                }

                Divider().background(DesignSystem.Colors.border)

                SettingsToggle(
                    title: "Cycle Shapes (Screensaver)",
                    subtitle: "Periodically reform the screensaver swarms into $, </>, the BurnBar logo, quota rings, and failover curves.",
                    icon: "arrow.triangle.2.circlepath",
                    isOn: $settingsManager.cycleShapesScreensaver
                )
                .onChange(of: settingsManager.cycleShapesScreensaver) { _, newValue in
                    Analytics.shared.track(.settingsChanged, [
                        "setting_key": "desktop_cycle_shapes_screensaver",
                        "new_value": .bool(newValue)
                    ])
                }

                Divider().background(DesignSystem.Colors.border)

                SettingsToggle(
                    title: "Enable Screensaver Sparkles",
                    subtitle: "Render an elegant, gentle twinkling shimmer on particles while they hold a reformed shape.",
                    icon: "sparkles",
                    isOn: $settingsManager.enableSwarmSparkles
                )
                .onChange(of: settingsManager.enableSwarmSparkles) { _, newValue in
                    Analytics.shared.track(.settingsChanged, [
                        "setting_key": "desktop_enable_sparkles",
                        "new_value": .bool(newValue)
                    ])
                }

                Divider().background(DesignSystem.Colors.border)

                SettingsToggle(
                    title: "Click Desktop to Cycle Shapes",
                    subtitle: "Click anywhere on your empty desktop background to manually cycle through all available swarm shapes and provider logos.",
                    icon: "hand.tap",
                    isOn: $settingsManager.clickDesktopToCycleSwarm
                )
                .settingsAnchor(SettingsAnchor.desktopWallpaperClickCycle)
                .onChange(of: settingsManager.clickDesktopToCycleSwarm) { _, newValue in
                    Analytics.shared.track(.settingsChanged, [
                        "setting_key": "desktop_click_cycle",
                        "new_value": .bool(newValue)
                    ])
            }
        }
    }

    private var applyAndRestartButton: some View {
        ApplyAndRestartRow(applyAction: applyAndRestart)
    }

    static func section(containingAnchor anchor: String) -> AppearanceSection? {
        switch anchor {
        case SettingsAnchor.appearanceTheme,
             SettingsAnchor.appearanceSkin,
             SettingsAnchor.appearanceGlassTransparency,
             SettingsAnchor.appearanceGlassRefraction:
            return .theme
        case SettingsAnchor.appearanceMenuBar,
             SettingsAnchor.appearanceLaunchAtLogin,
             SettingsAnchor.usePremiumSOTAUX:
            return .menuBar
        case SettingsAnchor.useWebsiteBackground,
             SettingsAnchor.useConstellationBackground,
             SettingsAnchor.desktopWallpaperEnabled,
             SettingsAnchor.desktopWallpaperBackground,
             SettingsAnchor.desktopWallpaperSpeed,
             SettingsAnchor.desktopWallpaperProviderGlyphs,
             SettingsAnchor.desktopWallpaperClickCycle,
             SettingsAnchor.useKernelBackdrop,
             SettingsAnchor.backdropKernel:
            return .background
        default:
            return nil
        }
    }

    private func selectSectionForPendingAnchor() {
        guard let anchor = router?.pendingAnchor,
              let section = Self.section(containingAnchor: anchor) else {
            return
        }
        selectedSection = section
    }

    private func applyAndRestart() {
        settingsManager.save()
        // For LSUIElement (menu-bar-only) apps, `/usr/bin/open` on a
        // running bundle just activates the existing process — it won't
        // relaunch after termination.  Write a small helper script that
        // polls until the current PID exits, then opens the bundle.
        let appPath = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        #!/bin/bash
        while kill -0 \(pid) 2>/dev/null; do
            sleep 0.15
        done
        sleep 0.4
        open "\(appPath)"
        rm -f "$0"
        """
        let scriptPath = NSTemporaryDirectory() + "com.openburnbar.relaunch.sh"
        guard let scriptData = script.data(using: .utf8) else { return }
        do {
            try scriptData.write(to: URL(fileURLWithPath: scriptPath), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)

            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/bash")
            task.arguments = [scriptPath]
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            try task.run()

            NSApplication.shared.terminate(nil)
        } catch {
            // Fallback: try a simple open + terminate if script setup fails
            let fallbackTask = Process()
            fallbackTask.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            fallbackTask.arguments = [appPath]
            try? fallbackTask.run()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    private var desktopWallpaperSpeedDial: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack(alignment: .center, spacing: DesignSystem.Spacing.md) {
                Image(systemName: "speedometer")
                    .foregroundStyle(DesignSystem.Colors.ember)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Desktop Wallpaper Speed")
                        .font(DesignSystem.Typography.body)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Text("Controls how quickly the desktop swarm drifts, reforms, and cycles between logo formations.")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }

                Spacer(minLength: DesignSystem.Spacing.md)

                Text("\(settingsManager.desktopWallpaperSpeed, specifier: "%.2f")x")
                    .font(DesignSystem.Typography.caption.weight(.semibold))
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .monospacedDigit()
                    .frame(width: 52, alignment: .trailing)
            }

            HStack(spacing: DesignSystem.Spacing.sm) {
                Image(systemName: "tortoise.fill")
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .frame(width: 18)

                Slider(value: $settingsManager.desktopWallpaperSpeed, in: 0.35...2.5, step: 0.05)
                    .tint(DesignSystem.Colors.ember)
                    .onChange(of: settingsManager.desktopWallpaperSpeed) { _, newValue in
                        Analytics.shared.track(.settingsChanged, [
                            "setting_key": "desktop_wallpaper_speed",
                            "new_value": .string(AnalyticsBuckets.percent(newValue * 100))
                        ])
                    }

                Image(systemName: "hare.fill")
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .frame(width: 18)
            }
            .padding(.leading, 32)
        }
    }

    private var desktopWallpaperBackgroundPicker: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack(alignment: .center, spacing: DesignSystem.Spacing.md) {
                Image(systemName: settingsManager.desktopWallpaperBackground.iconName)
                    .foregroundStyle(DesignSystem.Colors.ember)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Desktop Wallpaper Background")
                        .font(DesignSystem.Typography.body)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Text(settingsManager.desktopWallpaperBackground.detailText)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }

                Spacer(minLength: DesignSystem.Spacing.md)
            }

            LazyVGrid(columns: desktopWallpaperBackgroundColumns, alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                ForEach(DesktopWallpaperBackground.allCases) { background in
                    wallpaperBackgroundOption(background)
                }
            }
        }
    }

    private var desktopWallpaperBackgroundColumns: [GridItem] {
        [
            GridItem(.adaptive(minimum: 132, maximum: 172), spacing: DesignSystem.Spacing.sm, alignment: .leading)
        ]
    }

    private func wallpaperBackgroundOption(_ background: DesktopWallpaperBackground) -> some View {
        let isSelected = settingsManager.desktopWallpaperBackground == background

        return Button {
            withAnimation(.snappy(duration: 0.18)) {
                settingsManager.desktopWallpaperBackground = background
            }
            Analytics.shared.track(.settingsChanged, [
                "setting_key": "desktop_wallpaper_background",
                "new_value": .string(background.rawValue)
            ])
        } label: {
            HStack(spacing: DesignSystem.Spacing.sm) {
                wallpaperBackgroundSwatch(background)

                Text(background.displayName)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)

                Spacer(minLength: 0)

                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.ember)
                    .opacity(isSelected ? 1 : 0)
            }
            .padding(.horizontal, DesignSystem.Spacing.sm)
            .padding(.vertical, 7)
            .frame(minHeight: 36)
            .background(isSelected ? DesignSystem.Colors.ember.opacity(0.12) : DesignSystem.Colors.surface)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? DesignSystem.Colors.ember : DesignSystem.Colors.border, lineWidth: isSelected ? 1.25 : 1)
            )
            .clipShape(.rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(background.displayName)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
    }

    private var desktopWallpaperProviderGlyphCustomizer: some View {
        DisclosureGroup(isExpanded: $isProviderGlyphCustomizerExpanded) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    Text(providerGlyphCountText)
                        .font(DesignSystem.Typography.tiny.weight(.semibold))
                        .foregroundStyle(DesignSystem.Colors.textMuted)

                    Spacer()

                    providerGlyphQuickAction(
                        title: "All",
                        isActive: settingsManager.desktopWallpaperProviderGlyphs == SwarmProviderGlyphSelection.allProviders
                    ) {
                        withAnimation(.snappy(duration: 0.18)) {
                            settingsManager.desktopWallpaperProviderGlyphs = SwarmProviderGlyphSelection.allProviders
                        }
                    }

                    providerGlyphQuickAction(
                        title: "None",
                        isActive: settingsManager.desktopWallpaperProviderGlyphs.isEmpty
                    ) {
                        withAnimation(.snappy(duration: 0.18)) {
                            settingsManager.desktopWallpaperProviderGlyphs = []
                        }
                    }
                }
                .padding(.leading, 32)

                LazyVGrid(columns: desktopWallpaperProviderGlyphColumns, alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                    ForEach(SwarmProviderGlyphSelection.allProviders) { provider in
                        providerGlyphCard(provider)
                    }
                }
                .padding(.leading, 32)
            }
            .padding(.top, DesignSystem.Spacing.sm)
        } label: {
            HStack(alignment: .center, spacing: DesignSystem.Spacing.md) {
                Image(systemName: "slider.horizontal.3")
                    .foregroundStyle(DesignSystem.Colors.ember)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Customize Provider Glyphs")
                        .font(DesignSystem.Typography.body)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Text(providerGlyphSummaryText)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }

                Spacer(minLength: DesignSystem.Spacing.md)
            }
        }
        .animation(.snappy(duration: 0.18), value: isProviderGlyphCustomizerExpanded)
        .animation(.snappy(duration: 0.18), value: settingsManager.desktopWallpaperProviderGlyphs)
    }

    private var desktopWallpaperProviderGlyphColumns: [GridItem] {
        [
            GridItem(.adaptive(minimum: 168, maximum: 220), spacing: DesignSystem.Spacing.sm, alignment: .leading)
        ]
    }

    private var providerGlyphSummaryText: String {
        let count = settingsManager.desktopWallpaperProviderGlyphs.count
        let total = SwarmProviderGlyphSelection.allProviders.count
        if count == total {
            return "All \(total) provider logos render in the swarm cycle."
        }
        if count == 0 {
            return "Provider logo formations are hidden; symbols and BurnBar shapes still cycle."
        }
        return "\(count) of \(total) provider logos render in the swarm cycle."
    }

    private var providerGlyphCountText: String {
        let count = settingsManager.desktopWallpaperProviderGlyphs.count
        let total = SwarmProviderGlyphSelection.allProviders.count
        if count == total { return "All providers selected" }
        if count == 0 { return "No provider glyphs selected" }
        return "\(count) of \(total) selected"
    }

    private func providerGlyphQuickAction(
        title: String,
        isActive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(DesignSystem.Typography.tiny.weight(.bold))
                .foregroundStyle(isActive ? .white : DesignSystem.Colors.textMuted)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    Capsule(style: .continuous)
                        .fill(isActive ? DesignSystem.Colors.ember : DesignSystem.Colors.surface)
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(
                            isActive ? DesignSystem.Colors.ember.opacity(0.1) : DesignSystem.Colors.border.opacity(0.7),
                            lineWidth: 1
                        )
                )
        }
        .buttonStyle(.plain)
    }

    private func providerGlyphCard(_ provider: AgentProvider) -> some View {
        let isSelected = settingsManager.desktopWallpaperProviderGlyphs.contains(provider)
        let providerColor = DesignSystemColors.primary(for: provider)

        return Button {
            withAnimation(.snappy(duration: 0.18)) {
                var selected = Set(settingsManager.desktopWallpaperProviderGlyphs)
                if isSelected {
                    selected.remove(provider)
                } else {
                    selected.insert(provider)
                }
                settingsManager.desktopWallpaperProviderGlyphs = SwarmProviderGlyphSelection.allProviders.filter {
                    selected.contains($0)
                }
            }
            Analytics.shared.track(.settingsChanged, [
                "setting_key": "desktop_wallpaper_provider_glyphs",
                "new_value": .string(AnalyticsBuckets.count(settingsManager.desktopWallpaperProviderGlyphs.count))
            ])
        } label: {
            HStack(spacing: DesignSystem.Spacing.sm) {
                ZStack(alignment: .bottomTrailing) {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(DesignSystem.Colors.surfaceElevated)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(DesignSystem.Colors.border.opacity(0.7), lineWidth: 1)
                        )

                    ProviderLogoView(provider: provider, size: 30, useFallbackColor: false)

                    Circle()
                        .fill(providerColor)
                        .frame(width: 8, height: 8)
                        .offset(x: 2, y: 2)
                }
                .frame(width: 42, height: 42)

                Text(provider.displayName)
                    .font(DesignSystem.Typography.tiny.weight(.semibold))
                    .foregroundStyle(isSelected ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textMuted)
                    .lineLimit(2)
                    .minimumScaleFactor(0.78)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(isSelected ? providerColor : DesignSystem.Colors.textMuted.opacity(0.42))
            }
            .padding(.horizontal, DesignSystem.Spacing.sm)
            .padding(.vertical, 9)
            .frame(minHeight: 62)
            .background(isSelected ? providerColor.opacity(0.14) : DesignSystem.Colors.surface)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(isSelected ? providerColor.opacity(0.72) : DesignSystem.Colors.border.opacity(0.56), lineWidth: isSelected ? 1.4 : 1)
            )
            .clipShape(.rect(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(provider.displayName)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
    }

    @ViewBuilder
    private func wallpaperBackgroundSwatch(_ background: DesktopWallpaperBackground) -> some View {
        if background.isTransparent {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: background.swatchPreviewColors,
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.35), radius: 1, x: 0, y: 1)
            }
            .frame(width: 28, height: 22)
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(background.swatchPreviewStrokeColor.opacity(0.95), lineWidth: 1.5)
            )
        } else {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: background.swatchPreviewColors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 28, height: 22)
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(background.swatchPreviewStrokeColor.opacity(0.95), lineWidth: 1.5)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(.white.opacity(0.22), lineWidth: 1)
                        .padding(2)
                )
        }
    }

    private func modeLabel(_ mode: AppearanceMode) -> String {
        switch mode {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

// MARK: - Window backdrop (kernel) row

/// Master toggle + 30-kernel picker for the WebGL2 "Window Backdrop" field.
/// Both controls bind directly to the shared `@AppStorage` keys that
/// ``KernelBackdropView`` reads, so a selection applies to the live backdrop
/// immediately. Kernels render independently from the native swarm so enabling
/// this option does not start a second animated background renderer.
private struct KernelBackdropSettingsRow: View {
    @AppStorage(KernelBackdropPreferences.enabledKey) private var useKernelBackdrop: Bool = false
    @AppStorage(KernelBackdropPreferences.kernelKey) private var backdropKernel: String = KernelCatalog.defaultID

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            SettingsToggle(
                title: "Window Backdrop",
                subtitle: "Replace the swarm with a live WebGL2 backdrop field rendered behind the dashboard. Pick from 30 animated kernels below; a static plate stays behind the renderer as a cheap fallback.",
                icon: "square.stack.3d.up.fill",
                isOn: $useKernelBackdrop
            )
            .settingsAnchor(SettingsAnchor.useKernelBackdrop)
            .onChange(of: useKernelBackdrop) { _, newValue in
                Analytics.shared.track(.settingsChanged, [
                    "setting_key": "window_backdrop_kernel_enabled",
                    "new_value": .bool(newValue)
                ])
            }

            HStack(alignment: .center, spacing: DesignSystem.Spacing.md) {
                Image(systemName: "paintpalette.fill")
                    .foregroundStyle(DesignSystem.Colors.ember)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Backdrop Kernel")
                        .font(DesignSystem.Typography.body)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Text("Choose which of the 30 animated fields renders as the window backdrop.")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }

                Spacer(minLength: DesignSystem.Spacing.md)

                Picker("", selection: $backdropKernel) {
                    ForEach(KernelCatalog.all) { kernel in
                        Text(kernel.label).tag(kernel.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 200)
                .onChange(of: backdropKernel) { _, newValue in
                    Analytics.shared.track(.settingsChanged, [
                        "setting_key": "window_backdrop_kernel",
                        "new_value": .string(newValue)
                    ])
                }
            }
            .padding(.leading, 32)
            .opacity(useKernelBackdrop ? 1.0 : 0.55)
            .disabled(!useKernelBackdrop)
            .settingsAnchor(SettingsAnchor.backdropKernel)
        }
    }
}

// MARK: - Swarm substrate picker (per-theme, coupled to the active kernel)

/// Lets the user pick the *substrate* — the material that composes the provider
/// glyph swarm — from the active backdrop theme's family suite, exactly like the
/// imaginethat-llc lab gallery. The offered styles re-couple live when the
/// backdrop kernel changes; the selection persists to the shared
/// `swarmSubstrate` key honored by the dashboard, wallpaper, and iOS.
private struct SwarmSubstrateSettingsRow: View {
    @AppStorage(SwarmSubstratePreferences.enabledKey) private var substrateEnabled: Bool = false
    // cov:ignore-start -- Core-decomposition merge: pure module qualification of a SwiftUI default.
    @AppStorage(SwarmSubstratePreferences.substrateKey)
    private var substrateID: String = OpenBurnBarUI.SubstrateCatalog.plainID
    // cov:ignore-end
    @AppStorage(KernelBackdropPreferences.kernelKey) private var backdropKernel: String = KernelCatalog.defaultID

    private var family: SubstrateFamily { SubstrateFamily.forKernel(backdropKernel) }
    // cov:ignore-start -- Core-decomposition merge: pure module qualification in a SwiftUI property.
    private var styles: [SubstrateDescriptor] {
        OpenBurnBarUI.SubstrateCatalog.styles(forKernel: backdropKernel)
    }
    // cov:ignore-end

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            SettingsToggle(
                title: "Swarm Substrate",
                subtitle: "Compose the provider-glyph swarm from a material drawn from the active theme — twinkling stars, glass ribbons, caustic light, crepuscular shafts. Pick a style below; it re-couples to whichever backdrop theme is active.",
                icon: "circle.hexagongrid.fill",
                isOn: $substrateEnabled
            )
            .onChange(of: substrateEnabled) { _, newValue in
                Analytics.shared.track(.settingsChanged, [
                    "setting_key": "swarm_substrate_enabled",
                    "new_value": .bool(newValue)
                ])
            }

            HStack(spacing: 6) {
                Image(systemName: family.symbolName)
                    .font(.caption)
                    .foregroundStyle(DesignSystem.Colors.ember)
                Text(family.displayName)
                    .font(DesignSystem.Typography.caption.weight(.semibold))
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text("· substrate")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
            .padding(.leading, 32)

            // Tall, horizontally-scrollable cards — each a real mini-render of the
            // substrate's material (not a flat swatch), so it's easy to tell what
            // each style is. Mirrors the iOS picker; the live preview is the mini
            // SwarmCanvasView in `AppearancePreviewCard` above, which swaps the
            // instant a card is tapped.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    ForEach(styles) { style in
                        MacSubstrateCard(
                            descriptor: style,
                            isSelected: substrateID == style.id,
                            action: {
                                substrateID = style.id
                                Analytics.shared.track(.settingsChanged, [
                                    "setting_key": "swarm_substrate",
                                    "new_value": .string(style.id)
                                ])
                            }
                        )
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 4)
            }
            .padding(.leading, 32)
            .opacity(substrateEnabled ? 1.0 : 0.55)
            .disabled(!substrateEnabled)
        }
    }
}

private struct ApplyAndRestartRow: View {
    let applyAction: () -> Void
    @State private var showRestartConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack(spacing: DesignSystem.Spacing.md) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(DesignSystem.Colors.ember)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Apply & Restart")
                        .font(DesignSystem.Typography.body)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Text("Flush all pending settings and relaunch OpenBurnBar so appearance changes take full effect.")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }

                Spacer(minLength: DesignSystem.Spacing.md)

                Button {
                    showRestartConfirmation = true
                } label: {
                    Text("Apply & Restart")
                        .font(DesignSystem.Typography.caption.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(DesignSystem.Colors.ember)
                .controlSize(.small)
            }
        }
        .alert("Apply & Restart?", isPresented: $showRestartConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Apply & Restart", role: .destructive) {
                applyAction()
            }
        } message: {
            Text("OpenBurnBar will flush all pending settings and relaunch. Any unsaved changes in other panes will be preserved.")
        }
    }
}

// MARK: - Liquid Glass transparency row

/// Slider for `LiquidGlassTransparency`, mirroring the iOS control in
/// `ThemeSettingsView`. Zero follows the system (including Reduce
/// transparency); the surrounding `GlassCard` renders through the shared
/// adapters, so the whole settings card live-previews the change as you drag.
private struct LiquidGlassTransparencyRow: View {
    @AppStorage(LiquidGlassTransparency.storageKey) private var rawTransparency: Double = 0
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// Magnetic detent: snap to the system center when the thumb lands close.
    private var sliderValue: Binding<Double> {
        Binding(
            get: { LiquidGlassTransparency.effective(rawTransparency, reduceTransparency: false) },
            set: { rawTransparency = abs($0) < 0.06 ? 0 : $0 }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack(alignment: .center, spacing: DesignSystem.Spacing.md) {
                Image(systemName: "circle.bottomrighthalf.pattern.checkered")
                    .foregroundStyle(DesignSystem.Colors.ember)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Liquid Glass Transparency")
                        .font(DesignSystem.Typography.body)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Text(statusText)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }

                Spacer(minLength: DesignSystem.Spacing.md)

                if rawTransparency != 0 {
                    Button("Reset") { rawTransparency = 0 }
                        .font(DesignSystem.Typography.tiny.weight(.semibold))
                        .buttonStyle(.borderless)
                        .tint(DesignSystem.Colors.ember)
                }
            }

            HStack(spacing: DesignSystem.Spacing.sm) {
                Text("Frosted")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)

                Slider(value: sliderValue, in: LiquidGlassTransparency.range)
                    .tint(DesignSystem.Colors.ember)
                    .accessibilityLabel("Glass transparency")
                    .accessibilityValue(accessibilityDescription)

                Text("Clear")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
            .padding(.leading, 32)
        }
    }

    private var statusText: String {
        if reduceTransparency && rawTransparency > 0 {
            return "Reduce transparency is on in System Settings — glass stays frosted until it's turned off."
        }
        let t = LiquidGlassTransparency.effective(rawTransparency, reduceTransparency: false)
        if t == 0 { return "Matching this Mac's appearance settings." }
        let percent = Int((abs(t) * 100).rounded())
        return t > 0 ? "\(percent)% clearer than system." : "\(percent)% frostier than system."
    }

    private var accessibilityDescription: String {
        let t = LiquidGlassTransparency.effective(rawTransparency, reduceTransparency: false)
        if t == 0 { return "System default" }
        let percent = Int((abs(t) * 100).rounded())
        return t > 0 ? "\(percent) percent clearer" : "\(percent) percent frostier"
    }
}

// MARK: - Liquid Glass liquidity

/// The second axis: how much the glass *bends*, as opposed to how much you see through.
///
/// Opacity and refraction are independent physical properties — dense clear glass and
/// thin frosted glass are both real materials — and the app shipped with only the first
/// one exposed. That is a large part of why the transparency slider felt inert: at the
/// frosted end it added haze and at the clear end it removed substrate, and neither end
/// ever touched the optics. This drives `GlassSpec.lensing` / `dispersion` / `thickness`
/// / `scatter`, which are the terms the Metal lens actually integrates.
private struct LiquidGlassLiquidityRow: View {
    @AppStorage(LiquidGlassTransparency.liquidityKey)
    private var rawLiquidity: Double = LiquidGlassTransparency.liquidityDefault
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// Magnetic detent at the authored midpoint, matching the transparency row's feel.
    private var sliderValue: Binding<Double> {
        Binding(
            get: { rawLiquidity },
            set: { rawLiquidity = abs($0 - LiquidGlassTransparency.liquidityDefault) < 0.03
                ? LiquidGlassTransparency.liquidityDefault
                : $0 }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack(alignment: .center, spacing: DesignSystem.Spacing.md) {
                Image(systemName: "drop.halffull")
                    .foregroundStyle(DesignSystem.Colors.ember)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Liquid Glass Refraction")
                        .font(DesignSystem.Typography.body)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Text(statusText)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }

                Spacer(minLength: DesignSystem.Spacing.md)

                if rawLiquidity != LiquidGlassTransparency.liquidityDefault {
                    Button("Reset") { rawLiquidity = LiquidGlassTransparency.liquidityDefault }
                        .font(DesignSystem.Typography.tiny.weight(.semibold))
                        .buttonStyle(.borderless)
                        .tint(DesignSystem.Colors.ember)
                }
            }

            HStack(spacing: DesignSystem.Spacing.sm) {
                Text("Flat")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)

                Slider(value: sliderValue, in: LiquidGlassTransparency.liquidityRange)
                    .tint(DesignSystem.Colors.ember)
                    .accessibilityLabel("Glass refraction")
                    .accessibilityValue(accessibilityDescription)

                Text("Liquid")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
            .padding(.leading, 32)
        }
    }

    private var multiplier: Double {
        LiquidGlassTransparency.liquidityMultiplier(rawLiquidity, reduceTransparency: reduceTransparency)
    }

    private var statusText: String {
        if reduceTransparency && rawLiquidity > LiquidGlassTransparency.liquidityDefault {
            return "Reduce transparency is on in System Settings — refraction is held at the theme default."
        }
        if rawLiquidity == LiquidGlassTransparency.liquidityDefault {
            return "Refracting exactly as this theme intends."
        }
        let percent = Int((multiplier * 100).rounded())
        return multiplier < 1
            ? "\(percent)% of this theme's refraction — flatter, calmer."
            : "\(percent)% of this theme's refraction — a heavier optical block."
    }

    private var accessibilityDescription: String {
        if rawLiquidity == LiquidGlassTransparency.liquidityDefault { return "Theme default" }
        return "\(Int((multiplier * 100).rounded())) percent of theme refraction"
    }
}

// MARK: - Liquid Glass content-surfaces toggle

/// Master on/off toggle for Liquid Glass on content surfaces (cards, panels,
/// toolbars). When off, glass adapters render their fallback material
/// exclusively. System chrome (sheet material, window backdrop) always uses
/// glass when available. Gated to macOS 26+; hidden on earlier systems.
private struct LiquidGlassContentSurfacesToggleRow: View {
    @AppStorage(LiquidGlassTransparency.contentSurfacesEnabledKey) private var contentSurfacesEnabled: Bool = LiquidGlassTransparency.defaultContentSurfacesEnabled

    var body: some View {
        if #available(macOS 26, *) {
            SettingsToggle(
                title: "Liquid Glass on content surfaces",
                subtitle: subtitleText,
                icon: "circle.bottomrighthalf.pattern.checkered",
                isOn: $contentSurfacesEnabled
            )
        } else {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: DesignSystem.Spacing.md) {
                    Image(systemName: "circle.bottomrighthalf.pattern.checkered")
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Liquid Glass on content surfaces")
                            .font(DesignSystem.Typography.body)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                        Text("Requires macOS 26 or later.")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                    }
                    Spacer()
                }
            }
        }
    }

    private var subtitleText: String {
        contentSurfacesEnabled
            ? "Glass surfaces are active. Use the transparency slider to tune clarity."
            : "Turn on to render cards, panels, and toolbars with Liquid Glass instead of flat material."
    }
}
