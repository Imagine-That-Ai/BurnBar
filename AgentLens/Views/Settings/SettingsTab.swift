import SwiftUI

// MARK: - Settings Tab

/// Defines the available settings tabs in the settings navigation.
enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case daemon
    case account
    case providers
    case routingPools
    case alerts
    case notifications
    case devicesAndSync
    case switcher
    case hermes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .daemon: return "Daemon"
        case .account: return "Account"
        case .providers: return "Providers"
        case .routingPools: return "Routing pools"
        case .alerts: return "Alerts"
        case .notifications: return "Notifications"
        case .devicesAndSync: return MacCopy.devicesAndSyncTitle
        case .switcher: return "Account Switcher"
        case .hermes: return "AI Environments"
        }
    }

    /// A short caption shown under the sidebar title so each entry says what
    /// lives behind it without forcing the user to click in.
    var subtitle: String {
        switch self {
        case .general:
            return "Appearance, refresh, default view, indexing, summaries"
        case .daemon:
            return "Lifecycle, HTTP gateway, controller runtime"
        case .account:
            return "Sign-in, subscription, account actions"
        case .providers:
            return "Routed plans, accounts, CLI auth, log sources"
        case .routingPools:
            return "Fire Hydrant pools, Claude Code + Codex wiring"
        case .alerts:
            return "Spend thresholds, daily digest"
        case .notifications:
            return "Local pings, Telegram, calendar"
        case .devicesAndSync:
            return "Cloud sync, trusted devices, smart displays"
        case .switcher:
            return "Browser and CLI profile launcher"
        case .hermes:
            return "Hermes, Pi, gateways, remote relay"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape.fill"
        case .daemon: return "cpu.fill"
        case .account: return "person.crop.circle.fill"
        case .providers: return "externaldrive.connected.to.line.below"
        case .routingPools: return "point.3.connected.trianglepath.dotted"
        case .alerts: return "bell.fill"
        case .notifications: return "bell.badge.fill"
        case .devicesAndSync: return "macbook.and.iphone"
        case .switcher: return "arrow.triangle.2.circlepath"
        case .hermes: return "antenna.radiowaves.left.and.right"
        }
    }

    var accentColor: Color {
        switch self {
        case .general: return DesignSystem.Colors.amber
        case .daemon: return DesignSystem.Colors.teal
        case .account: return DesignSystem.Colors.whimsy
        case .providers: return DesignSystem.Colors.ember
        case .routingPools: return DesignSystem.Colors.hermesMercury
        case .alerts: return DesignSystem.Colors.blaze
        case .notifications: return DesignSystem.Colors.whimsy
        case .devicesAndSync: return DesignSystem.Colors.teal
        case .switcher: return DesignSystem.Colors.amber
        case .hermes: return DesignSystem.Colors.hermesAureate
        }
    }
}

// MARK: - Shared Settings Components

struct SettingsSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(DesignSystem.Typography.caption)
            .fontWeight(.semibold)
            .foregroundStyle(DesignSystem.Colors.textSecondary)
            .padding(.top, DesignSystem.Spacing.xs)
    }
}

struct SettingsToggle: View {
    let title: String
    let subtitle: String?
    let icon: String?
    @Binding var isOn: Bool

    init(title: String, subtitle: String? = nil, icon: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self._isOn = isOn
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: DesignSystem.Spacing.md) {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: 14))
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .frame(width: 20)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)

                    if let subtitle {
                        Text(subtitle)
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                    }
                }
            }
        }
        .toggleStyle(SwitchToggleStyle(tint: DesignSystem.Colors.blaze))
    }
}
