import SwiftUI
import OpenBurnBarCore

// MARK: - Settings Tab

/// Defines the available settings tabs in the settings navigation.
enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case daemon
    case account
    case cloud
    case agents
    case alerts
    case notifications
    case devicesAndSync
    case media
    case computerUse

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .daemon: return "Daemon"
        case .account: return "Account"
        case .cloud: return "Cloud"
        case .agents: return "Agents"
        case .alerts: return "Alerts"
        case .notifications: return "Notifications"
        case .devicesAndSync: return MacCopy.devicesAndSyncTitle
        case .media: return "Media & Sharing"
        case .computerUse: return "Computer Use"
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
        case .cloud:
            return "OpenBurnBar Cloud — hosted refresh, backup, Hermes anywhere"
        case .agents:
            return "Cloud keys, local CLIs, and local runtimes"
        case .alerts:
            return "Spend thresholds, daily digest"
        case .notifications:
            return "Local pings, Telegram, calendar"
        case .devicesAndSync:
            return "Cloud sync, trusted devices, smart displays"
        case .media:
            return "Mercury file transfer, screen share, calls — permissions and partner preferences"
        case .computerUse:
            return "Agent Watch, browser driving, Mac input, approvals, and audit chain"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape.fill"
        case .daemon: return "cpu.fill"
        case .account: return "person.crop.circle.fill"
        case .cloud: return "sparkles"
        case .agents: return "cpu.fill"
        case .alerts: return "bell.fill"
        case .notifications: return "bell.badge.fill"
        case .devicesAndSync: return "macbook.and.iphone"
        case .media: return "play.rectangle.on.rectangle"
        case .computerUse: return "cursorarrow.click.2"
        }
    }

    var accentColor: Color {
        switch self {
        case .general: return DesignSystem.Colors.amber
        case .daemon: return DesignSystem.Colors.teal
        case .account: return DesignSystem.Colors.whimsy
        case .cloud: return DesignSystem.Colors.hermesAureate
        case .agents: return DesignSystem.Colors.ember
        case .alerts: return DesignSystem.Colors.blaze
        case .notifications: return DesignSystem.Colors.whimsy
        case .devicesAndSync: return DesignSystem.Colors.teal
        case .media: return DesignSystem.Colors.hermesMercury
        case .computerUse: return DesignSystem.Colors.blaze
        }
    }

    var logoProviders: [AgentProvider] {
        switch self {
        case .agents:
            return [.claudeCode, .codex, .openCode, .hermes]
        default:
            return []
        }
    }
}

extension SettingsTab {
    static var visibleTabs: [SettingsTab] {
        #if DISTRIBUTION_MAS
        return allCases.filter { $0 != .computerUse }
        #else
        return allCases
        #endif
    }
}

extension SettingsTab {
    /// Legacy raw values that used to identify sidebar tabs. Resolved to the
    /// new tab they were rolled into so deep links saved as
    /// `UserDefaults["settings.pendingTab"]` still land somewhere sensible.
    static func resolving(legacyRawValue raw: String) -> SettingsTab? {
        if let exact = SettingsTab(rawValue: raw) { return exact }
        switch raw {
        case "providers", "routingPools", "connections", "switcher", "hermes":
            return .agents
        default:
            return nil
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
