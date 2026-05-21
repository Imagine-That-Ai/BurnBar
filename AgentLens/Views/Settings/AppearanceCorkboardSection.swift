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
                    subtitle: "Active, reconverging token-ember swarms pulled from burnbar.ai. Particles drift and reform into $, </>, quota rings, and router failover paths.",
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

                Divider().background(DesignSystem.Colors.border)

                SettingsToggle(
                    title: "AMOLED Dark Mode Background",
                    subtitle: "Use a pitch-black wallpaper background to optimize OLED screens and save battery.",
                    icon: "moon.stars.fill",
                    isOn: $settingsManager.amoledDarkBackground
                )

                Divider().background(DesignSystem.Colors.border)

                SettingsToggle(
                    title: "Cycle Shapes (Screensaver)",
                    subtitle: "Periodically reform the screensaver swarms into $, </>, quota rings, and failover curves.",
                    icon: "arrow.triangle.2.circlepath",
                    isOn: $settingsManager.cycleShapesScreensaver
                )
            }
            .padding(DesignSystem.Spacing.lg)
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
