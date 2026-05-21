import SwiftUI

struct AppearanceCorkboardSection: View {
    @Bindable var settingsManager: SettingsManager

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

                SettingsToggle(
                    title: "Cycle Shapes (Screensaver)",
                    subtitle: "Periodically reform the screensaver swarms into $, </>, the BurnBar logo, quota rings, and failover curves.",
                    icon: "arrow.triangle.2.circlepath",
                    isOn: $settingsManager.cycleShapesScreensaver
                )
            }
            .padding(DesignSystem.Spacing.lg)
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
