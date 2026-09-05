import SwiftUI
import OpenBurnBarCore

// MARK: - Settings Tab

/// Defines the available settings tabs in the settings navigation.
enum SettingsTab: String, CaseIterable, Identifiable {
    case home
    case general
    case aiInbox
    case updates
    case daemon
    case account
    case cloud
    case agents
    case modelProxy
    case alerts
    case notifications
    case devicesAndSync
    case textExpansion
    case media
    case dataPrivacy
    case computerUse
    case pets
    case receipts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .general: return "General"
        case .receipts: return "Receipts"
        case .aiInbox: return "AI Inbox"
        case .updates: return "Updates"
        case .daemon: return "Engine Room"
        case .account: return "Account"
        case .cloud: return "Cloud"
        case .agents: return "Agents"
        case .modelProxy: return "Model Proxy"
        case .alerts: return "Alerts"
        case .notifications: return "Notifications"
        case .devicesAndSync: return MacCopy.devicesAndSyncTitle
        case .textExpansion: return "Text Expansion"
        case .media: return "Media & Sharing"
        case .dataPrivacy: return "Data & Privacy"
        case .computerUse: return "Computer Use"
        case .pets: return "Pets"
        }
    }

    /// A short caption shown under the sidebar title so each entry says what
    /// lives behind it without forcing the user to click in.
    var subtitle: String {
        switch self {
        case .home:
            return "Health, attention items, and quick actions"
        case .general:
            return "Appearance, dashboard defaults, refresh, indexing, summaries"
        case .aiInbox:
            return "Background analyst, egress, cadence, and inbox budget"
        case .updates:
            return "App version, automatic updates, release channel"
        case .daemon:
            return "Daemon lifecycle, controller runtime"
        case .account:
            return "Sign-in, subscription, account actions"
        case .cloud:
            return "OpenBurnBar Cloud — hosted refresh, backup, Hermes anywhere"
        case .agents:
            return "Cloud keys, local CLIs, and local runtimes"
        case .modelProxy:
            return "Local gateway endpoint, routing strategy, model catalog"
        case .alerts:
            return "Spend thresholds, daily digest"
        case .notifications:
            return "Local pings, Telegram, calendar"
        case .devicesAndSync:
            return "Cloud sync, trusted devices, smart displays"
        case .textExpansion:
            return "&& triggers, snippets, keyboard sync, and LLM previews"
        case .media:
            return "Mercury file transfer, screen share, calls — permissions and partner preferences"
        case .dataPrivacy:
            return "Pensieve vault, exports, deletion, recovery, and panic controls"
        case .computerUse:
            return "Agent Watch, browser driving, Mac input, approvals, and audit chain"
        case .pets:
            return "Desktop companion, pet picker, agent brain, and summon hotkey"
        case .receipts:
            return "Session popups, thermal slips, quality reviews, and sounds"
        }
    }

    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .general: return "gearshape.fill"
        case .receipts: return "scroll.fill"
        case .aiInbox: return "tray.full.fill"
        case .updates: return "arrow.down.circle.fill"
        case .daemon: return "cpu.fill"
        case .account: return "person.crop.circle.fill"
        case .cloud: return "sparkles"
        case .agents: return "cpu.fill"
        case .modelProxy: return "network"
        case .alerts: return "bell.fill"
        case .notifications: return "bell.badge.fill"
        case .devicesAndSync: return "macbook.and.iphone"
        case .textExpansion: return "text.cursor"
        case .media: return "play.rectangle.on.rectangle"
        case .dataPrivacy: return "lock.shield.fill"
        case .computerUse: return "cursorarrow.click.2"
        case .pets: return "pawprint.fill"
        }
    }

    /// Optional whimsical SVG asset name rendered in place of the SF Symbol
    /// for settings tabs that have a matching custom icon.
    var customIcon: String? {
        switch self {
        case .general: return "SettingsIconSettingsB"
        case .cloud: return "SettingsIconCloud"
        case .agents: return "SettingsIconAgent"
        case .account: return "SettingsIconSignIn"
        case .devicesAndSync: return "SettingsIconConnections"
        case .dataPrivacy: return "SettingsIconData"
        default: return nil
        }
    }

    var accentColor: Color {
        switch self {
        case .home: return DesignSystem.Colors.ember
        case .general: return DesignSystem.Colors.amber
        case .receipts: return DesignSystem.Colors.amber
        case .aiInbox: return DesignSystem.Colors.ember
        case .updates: return DesignSystem.Colors.frost
        case .daemon: return DesignSystem.Colors.teal
        case .account: return DesignSystem.Colors.whimsy
        case .cloud: return DesignSystem.Colors.hermesAureate
        case .agents: return DesignSystem.Colors.ember
        case .modelProxy: return DesignSystem.Colors.purple
        case .alerts: return DesignSystem.Colors.blaze
        case .notifications: return DesignSystem.Colors.whimsy
        case .devicesAndSync: return DesignSystem.Colors.teal
        case .textExpansion: return DesignSystem.Colors.amber
        case .media: return DesignSystem.Colors.hermesMercury
        case .dataPrivacy: return DesignSystem.Colors.teal
        case .computerUse: return DesignSystem.Colors.blaze
        case .pets: return DesignSystem.Colors.amber
        }
    }

    var logoProviders: [AgentProvider] {
        switch self {
        case .agents:
            return [.claudeCode, .codex, .openCode, .hermes]
        case .modelProxy:
            return [.claudeCode, .openAI, .codex]
        default:
            return []
        }
    }

    // MARK: - Section grouping

    /// Which sidebar section this tab belongs to.
    var section: SettingsSection {
        switch self {
        case .home:            return .home
        case .agents, .modelProxy:
            return .agentsAndModels
        case .general, .receipts, .aiInbox:
            return .lookAndFeel
        case .account, .cloud, .alerts, .notifications, .devicesAndSync:
            return .accountAndSync
        case .daemon, .updates, .dataPrivacy:
            return .system
        case .textExpansion, .media, .computerUse, .pets:
            return .extras
        }
    }
}

extension SettingsTab {
    /// Tabs this build ships. The build condition itself lives in
    /// `OpenBurnBarBuildGates`, which the Control Deck's `ControlKind.visibleKinds`
    /// also reads, so the sidebar and the deck can never disagree about which
    /// features exist in a given build. `ControlDeckRegistryTests` asserts they
    /// agree.
    static var visibleTabs: [SettingsTab] {
        var tabs: [SettingsTab] = [.home]
        for section in SettingsSection.visibleSections {
            tabs.append(contentsOf: section.tabs.filter(isAvailableInThisBuild))
        }
        return tabs
    }

    static func isAvailableInThisBuild(_ tab: SettingsTab) -> Bool {
        switch tab {
        case .computerUse: return OpenBurnBarBuildGates.agentControlAvailable
        case .updates: return OpenBurnBarBuildGates.updatesAvailable
        default: return true
        }
    }
}

// MARK: - Settings Section

/// Groups sidebar tabs into labeled sections so the sidebar reads as
/// organized categories rather than a flat list of entries.
enum SettingsSection: String, CaseIterable, Identifiable {
    case home
    case agentsAndModels
    case lookAndFeel
    case accountAndSync
    case system
    case extras

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home:             return ""
        case .agentsAndModels:  return "Agents & Models"
        case .lookAndFeel:      return "Look & Feel"
        case .accountAndSync:   return "Account & Sync"
        case .system:           return "System"
        case .extras:           return "More"
        }
    }

    /// Tabs in display order within this section.
    var tabs: [SettingsTab] {
        switch self {
        case .home:
            return [.home]
        case .agentsAndModels:
            return [.agents, .modelProxy]
        case .lookAndFeel:
            return [.general, .receipts, .aiInbox]
        case .accountAndSync:
            return [.account, .cloud, .devicesAndSync, .alerts, .notifications]
        case .system:
            return [.daemon, .updates, .dataPrivacy]
        case .extras:
            return [.textExpansion, .media, .computerUse, .pets]
        }
    }

    /// Sections that should render in the sidebar, in order (home handled separately).
    static var visibleSections: [SettingsSection] {
        allCases.filter { $0 != .home }
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
        case "gateway", "proxy", "modelProxy":
            return .modelProxy
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
                if let icon {
                    Image(systemName: icon)
                        .font(DesignSystem.Typography.body)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .frame(width: 20)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(DesignSystem.Typography.body)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)

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
