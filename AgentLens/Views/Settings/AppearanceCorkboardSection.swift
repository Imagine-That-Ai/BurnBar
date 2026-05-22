import SwiftUI
import OpenBurnBarCore

struct AppearanceCorkboardSection: View {
    @Bindable var settingsManager: SettingsManager
    @State private var isProviderGlyphCustomizerExpanded = false

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
                    title: "Cycle Shapes (Screensaver)",
                    subtitle: "Periodically reform the screensaver swarms into $, </>, the BurnBar logo, quota rings, and failover curves.",
                    icon: "arrow.triangle.2.circlepath",
                    isOn: $settingsManager.cycleShapesScreensaver
                )

                Divider().background(DesignSystem.Colors.border)

                SettingsToggle(
                    title: "Click Desktop to Cycle Shapes",
                    subtitle: "Click anywhere on your empty desktop background to manually cycle through all available swarm shapes and provider logos.",
                    icon: "hand.tap",
                    isOn: $settingsManager.clickDesktopToCycleSwarm
                )
                .settingsAnchor(SettingsAnchor.desktopWallpaperClickCycle)
            }
            .padding(DesignSystem.Spacing.lg)
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
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    Button("All") {
                        withAnimation(.snappy(duration: 0.18)) {
                            settingsManager.desktopWallpaperProviderGlyphs = SwarmProviderGlyphSelection.allProviders
                        }
                    }
                    .buttonStyle(.borderless)
                    .disabled(settingsManager.desktopWallpaperProviderGlyphs == SwarmProviderGlyphSelection.allProviders)

                    Button("None") {
                        withAnimation(.snappy(duration: 0.18)) {
                            settingsManager.desktopWallpaperProviderGlyphs = []
                        }
                    }
                    .buttonStyle(.borderless)
                    .disabled(settingsManager.desktopWallpaperProviderGlyphs.isEmpty)

                    Spacer()
                }
                .padding(.leading, 32)

                LazyVGrid(columns: desktopWallpaperProviderGlyphColumns, alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                    ForEach(SwarmProviderGlyphSelection.allProviders) { provider in
                        providerGlyphToggle(provider)
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
            GridItem(.adaptive(minimum: 142, maximum: 188), spacing: DesignSystem.Spacing.sm, alignment: .leading)
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

    private func providerGlyphToggle(_ provider: AgentProvider) -> some View {
        Toggle(isOn: providerGlyphBinding(for: provider)) {
            HStack(spacing: DesignSystem.Spacing.xs) {
                Circle()
                    .fill(DesignSystemColors.primary(for: provider))
                    .frame(width: 8, height: 8)
                    .overlay(Circle().stroke(.white.opacity(0.24), lineWidth: 0.5))

                Text(provider.displayName)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
        }
        .toggleStyle(.checkbox)
        .padding(.vertical, 2)
        .accessibilityLabel(provider.displayName)
    }

    private func providerGlyphBinding(for provider: AgentProvider) -> Binding<Bool> {
        Binding {
            settingsManager.desktopWallpaperProviderGlyphs.contains(provider)
        } set: { isEnabled in
            var selected = Set(settingsManager.desktopWallpaperProviderGlyphs)
            if isEnabled {
                selected.insert(provider)
            } else {
                selected.remove(provider)
            }
            settingsManager.desktopWallpaperProviderGlyphs = SwarmProviderGlyphSelection.allProviders.filter {
                selected.contains($0)
            }
        }
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
