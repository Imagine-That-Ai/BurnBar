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
