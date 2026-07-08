import SwiftUI
import OpenBurnBarCore

// MARK: - Settings Home View

/// The default landing page when Settings opens. Shows a live status hero
/// for every subsystem, an attention strip for anything that needs action,
/// and task cards for the most common things people come to Settings for.
struct SettingsHomeView: View {
    @Bindable var settingsManager: SettingsManager
    var accountManager: AccountManager
    var dataStore: DataStore
    var daemonManager: OpenBurnBarDaemonManager
    var cloudSyncService: CloudSyncService?
    var runtimeContext: OpenBurnBarRuntimeContext?
    var router: SettingsRouter?

    @State private var providerAccounts: [ProviderAccountDoc] = []
    @State private var quotaService = ProviderQuotaService.shared

    var body: some View {
        SettingsDeepLinkScrollContainer(route: .homeRoot) { _ in
            ScrollView {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xl) {
                    // Hero greeting + status strip
                    heroSection

                    // Attention items (only if something needs action)
                    if !attentionItems.isEmpty {
                        attentionSection
                    }

                    // Status grid
                    statusGrid

                    // Task cards
                    taskCardsSection
                }
                .padding(DesignSystem.Spacing.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(DesignSystem.Colors.background)
        .scrollContentBackground(.hidden)
        .navigationTitle("Home")
        .task { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }
        }
    }

    // MARK: - Hero

    private var heroSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text("OpenBurnBar Settings")
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(DesignSystem.Colors.textPrimary)

            Text("Everything that matters at a glance. Click any card to manage it, or search above to ask the copilot.")
                .font(DesignSystem.Typography.body)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .settingsAnchor(SettingsAnchor.homeOverview)
    }

    // MARK: - Attention strip

    private var attentionSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text("Needs your attention")
                .font(DesignSystem.Typography.caption)
                .fontWeight(.semibold)
                .foregroundStyle(DesignSystem.Colors.warning)

            ForEach(attentionItems, id: \.id) { item in
                Button {
                    router?.selectedTab = item.tab
                    router?.path.removeAll()
                } label: {
                    HStack(spacing: DesignSystem.Spacing.sm) {
                        Image(systemName: item.icon)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(item.tint)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .font(DesignSystem.Typography.body)
                                .foregroundStyle(DesignSystem.Colors.textPrimary)
                            Text(item.detail)
                                .font(DesignSystem.Typography.tiny)
                                .foregroundStyle(DesignSystem.Colors.textMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Text("Fix")
                            .font(DesignSystem.Typography.tiny)
                            .fontWeight(.semibold)
                            .foregroundStyle(item.tint)
                    }
                    .padding(DesignSystem.Spacing.md)
                    .background(
                        RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                            .fill(item.tint.opacity(0.08))
                            .overlay(
                                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                                    .stroke(item.tint.opacity(0.25), lineWidth: 0.5)
                            )
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Status grid

    private var statusGrid: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text("System health")
                .font(DesignSystem.Typography.caption)
                .fontWeight(.semibold)
                .foregroundStyle(DesignSystem.Colors.textSecondary)

            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: DesignSystem.Spacing.sm),
                GridItem(.flexible(), spacing: DesignSystem.Spacing.sm)
            ], spacing: DesignSystem.Spacing.sm) {
                statusCard(
                    title: "Daemon",
                    icon: "cpu.fill",
                    status: daemonStatusText,
                    tint: daemonStatusTint,
                    tab: .daemon
                )
                statusCard(
                    title: "Model Proxy",
                    icon: "network",
                    status: settingsManager.gatewayEnabled ? "\(settingsManager.gatewayHost):\(settingsManager.gatewayPort)" : "Off",
                    tint: settingsManager.gatewayEnabled ? DesignSystem.Colors.success : DesignSystem.Colors.textMuted,
                    tab: .modelProxy
                )
                statusCard(
                    title: "Accounts",
                    icon: "key.fill",
                    status: accountsStatusText,
                    tint: accountsStatusTint,
                    tab: .agents
                )
                statusCard(
                    title: "Hermes",
                    icon: "antenna.radiowaves.left.and.right",
                    status: settingsManager.launchHermesWithOpenBurnBar ? "Auto" : "Manual",
                    tint: settingsManager.launchHermesWithOpenBurnBar ? DesignSystem.Colors.success : DesignSystem.Colors.textMuted,
                    tab: .agents
                )
                statusCard(
                    title: "Cloud Sync",
                    icon: "arrow.triangle.2.circlepath",
                    status: settingsManager.conversationCloudBackupEnabled ? "On" : "Off",
                    tint: settingsManager.conversationCloudBackupEnabled ? DesignSystem.Colors.success : DesignSystem.Colors.textMuted,
                    tab: .devicesAndSync
                )
                statusCard(
                    title: "Indexing",
                    icon: "magnifyingglass.circle.fill",
                    status: settingsManager.conversationIndexingEnabled ? "On" : "Off",
                    tint: settingsManager.conversationIndexingEnabled ? DesignSystem.Colors.success : DesignSystem.Colors.textMuted,
                    tab: .general
                )
            }
        }
    }

    private func statusCard(title: String, icon: String, status: String, tint: Color, tab: SettingsTab) -> some View {
        Button {
            router?.selectedTab = tab
            router?.path.removeAll()
        } label: {
            HStack(spacing: DesignSystem.Spacing.sm) {
                ZStack {
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                        .fill(tint.opacity(0.16))
                        .frame(width: 30, height: 30)
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(tint)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(DesignSystem.Typography.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Text(status)
                        .font(DesignSystem.Typography.monoTiny)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
            }
            .padding(DesignSystem.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .fill(DesignSystem.Colors.surfaceElevated.opacity(0.36))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .stroke(DesignSystem.Colors.border.opacity(0.45), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Task cards

    private var taskCardsSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text("Quick actions")
                .font(DesignSystem.Typography.caption)
                .fontWeight(.semibold)
                .foregroundStyle(DesignSystem.Colors.textSecondary)

            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: DesignSystem.Spacing.sm),
                GridItem(.flexible(), spacing: DesignSystem.Spacing.sm)
            ], spacing: DesignSystem.Spacing.sm) {
                taskCard(
                    title: "Add an Account",
                    subtitle: "Bring API keys for OpenAI, Anthropic, and more",
                    icon: "key.fill",
                    tint: DesignSystem.Colors.ember,
                    tab: .agents
                )
                taskCard(
                    title: "Model Proxy",
                    subtitle: "Expose your models to Cursor, VS Code, or any OpenAI client",
                    icon: "network",
                    tint: DesignSystem.Colors.purple,
                    tab: .modelProxy
                )
                taskCard(
                    title: "Appearance",
                    subtitle: "Dark mode, skins, backgrounds, menu bar",
                    icon: "paintpalette.fill",
                    tint: DesignSystem.Colors.coral,
                    tab: .general
                )
                taskCard(
                    title: "Text Expansion",
                    subtitle: "&& triggers, snippets, LLM-powered rewrites",
                    icon: "text.cursor",
                    tint: DesignSystem.Colors.amber,
                    tab: .textExpansion
                )
                taskCard(
                    title: "Cloud",
                    subtitle: "Hosted refresh, backup, remote access",
                    icon: "sparkles",
                    tint: DesignSystem.Colors.hermesAureate,
                    tab: .cloud
                )
                taskCard(
                    title: "Data & Privacy",
                    subtitle: "Vault inventory, exports, deletion, panic revoke",
                    icon: "lock.shield.fill",
                    tint: DesignSystem.Colors.teal,
                    tab: .dataPrivacy
                )
            }
        }
    }

    private func taskCard(title: String, subtitle: String, icon: String, tint: Color, tab: SettingsTab) -> some View {
        Button {
            router?.selectedTab = tab
            router?.path.removeAll()
        } label: {
            HStack(spacing: DesignSystem.Spacing.sm) {
                ZStack {
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                        .fill(tint)
                        .frame(width: 36, height: 36)
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(DesignSystem.Typography.body)
                        .fontWeight(.semibold)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Text(subtitle)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineLimit(2)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
            .padding(DesignSystem.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .fill(DesignSystem.Colors.surfaceElevated.opacity(0.36))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .stroke(DesignSystem.Colors.border.opacity(0.45), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Derived state

    private struct AttentionItem: Identifiable {
        let id = UUID()
        let title: String
        let detail: String
        let icon: String
        let tint: Color
        let tab: SettingsTab
    }

    private var attentionItems: [AttentionItem] {
        var items: [AttentionItem] = []

        // Daemon not healthy
        switch daemonManager.status {
        case .notInstalled:
            items.append(AttentionItem(
                title: "Daemon not installed",
                detail: "The local daemon needs to be installed for model proxy and controller runtime.",
                icon: "exclamationmark.octagon.fill",
                tint: DesignSystem.Colors.error,
                tab: .daemon
            ))
        case .unhealthy:
            items.append(AttentionItem(
                title: "Daemon unhealthy",
                detail: "The daemon is installed but not responding. Click Repair in Engine Room.",
                icon: "exclamationmark.triangle.fill",
                tint: DesignSystem.Colors.warning,
                tab: .daemon
            ))
        default:
            break
        }

        // No accounts
        if providerAccounts.filter({ $0.status != .deleted }).isEmpty {
            items.append(AttentionItem(
                title: "No API keys yet",
                detail: "Add your first provider key to start tracking usage and routing requests.",
                icon: "key.slash.fill",
                tint: DesignSystem.Colors.warning,
                tab: .agents
            ))
        }

        return items
    }

    private var daemonStatusText: String {
        daemonManager.status.label
    }

    private var daemonStatusTint: Color {
        switch daemonManager.status {
        case .healthy: return DesignSystem.Colors.success
        case .checking: return DesignSystem.Colors.textSecondary
        case .notInstalled, .unhealthy: return DesignSystem.Colors.error
        }
    }

    private var accountsStatusText: String {
        let active = providerAccounts.filter { $0.status != .deleted }
        if active.isEmpty { return "None" }
        let providers = Set(active.map(\.providerID)).count
        return "\(providers) provider\(providers == 1 ? "" : "s")"
    }

    private var accountsStatusTint: Color {
        let active = providerAccounts.filter { $0.status != .deleted }
        if active.isEmpty { return DesignSystem.Colors.textMuted }
        if active.contains(where: { $0.status == .error }) { return DesignSystem.Colors.warning }
        return DesignSystem.Colors.success
    }

    // MARK: - Refresh

    private func refresh() async {
        await daemonManager.refreshHealth()
        await quotaService.refreshIfNeeded(dataStore: dataStore)
        providerAccounts = (try? await dataStore.fetchProviderAccounts()) ?? []
    }
}
