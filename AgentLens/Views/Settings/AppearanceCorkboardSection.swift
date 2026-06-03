import AppKit
import SwiftUI
import OpenBurnBarCore

struct AppearanceCorkboardSection: View {
    @Bindable var settingsManager: SettingsManager
    @State private var isProviderGlyphCustomizerExpanded = true

    var body: some View {
        GlassCard {
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
                }
                .settingsAnchor(SettingsAnchor.appearanceSkin)

                Divider().background(DesignSystem.Colors.border)

                SettingsToggle(
                    title: "Show in Menu Bar",
                    subtitle: "Keep OpenBurnBar available as a menu-bar utility.",
                    icon: "menubar.rectangle",
                    isOn: $settingsManager.showInMenuBar
                )
                .settingsAnchor(SettingsAnchor.appearanceMenuBar)

                Divider().background(DesignSystem.Colors.border)

                SettingsToggle(
                    title: "Colorful Menu Bar Icon",
                    subtitle: "Use a full-color icon instead of a monochrome template.",
                    icon: "paintpalette",
                    isOn: $settingsManager.colorfulMenuBarIcon
                )

                Divider().background(DesignSystem.Colors.border)

                SettingsToggle(
                    title: "Launch at Login",
                    subtitle: "Start OpenBurnBar when you sign in to macOS.",
                    icon: "person.crop.circle.badge.checkmark",
                    isOn: $settingsManager.launchAtLogin
                )
                .settingsAnchor(SettingsAnchor.appearanceLaunchAtLogin)

                Divider().background(DesignSystem.Colors.border)

                SettingsToggle(
                    title: "Premium SOTA UX",
                    subtitle: "Enable cinematic spring physics and specular shimmers globally.",
                    icon: "sparkles",
                    isOn: $settingsManager.usePremiumSOTAUX
                )
                .settingsAnchor(SettingsAnchor.usePremiumSOTAUX)

                Divider().background(DesignSystem.Colors.border)

                SettingsToggle(
                    title: "Swarm Background",
                    subtitle: "Active, reconverging token-ember swarms pulled from burnbar.ai. Particles drift and reform into $, </>, the BurnBar logo, quota rings, and router failover paths.",
                    icon: "sparkles",
                    isOn: $settingsManager.useWebsiteBackground
                )
                .settingsAnchor(SettingsAnchor.useWebsiteBackground)

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

                Divider().background(DesignSystem.Colors.border)

                SettingsToggle(
                    title: "Enable Desktop Swarm Wallpaper",
                    subtitle: "Render the dynamic token ember swarm simulation directly as your macOS desktop wallpaper.",
                    icon: "desktopcomputer",
                    isOn: $settingsManager.enableDesktopWallpaper
                )
                .settingsAnchor(SettingsAnchor.desktopWallpaperEnabled)

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

                Divider().background(DesignSystem.Colors.border)

                SettingsToggle(
                    title: "Cycle Shapes (Screensaver)",
                    subtitle: "Periodically reform the screensaver swarms into $, </>, the BurnBar logo, quota rings, and failover curves.",
                    icon: "arrow.triangle.2.circlepath",
                    isOn: $settingsManager.cycleShapesScreensaver
                )

                Divider().background(DesignSystem.Colors.border)

                SettingsToggle(
                    title: "Enable Screensaver Sparkles",
                    subtitle: "Render an elegant, gentle twinkling shimmer on particles while they hold a reformed shape.",
                    icon: "sparkles",
                    isOn: $settingsManager.enableSwarmSparkles
                )

                Divider().background(DesignSystem.Colors.border)

                SettingsToggle(
                    title: "Click Desktop to Cycle Shapes",
                    subtitle: "Click anywhere on your empty desktop background to manually cycle through all available swarm shapes and provider logos.",
                    icon: "hand.tap",
                    isOn: $settingsManager.clickDesktopToCycleSwarm
                )
                .settingsAnchor(SettingsAnchor.desktopWallpaperClickCycle)

                Divider().background(DesignSystem.Colors.border)

                applyAndRestartButton
            }
            .padding(DesignSystem.Spacing.lg)
        }
    }

    private var applyAndRestartButton: some View {
        ApplyAndRestartRow(applyAction: applyAndRestart)
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
