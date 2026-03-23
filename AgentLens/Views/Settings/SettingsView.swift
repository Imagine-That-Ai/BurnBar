import AppKit
import AuthenticationServices
import SwiftUI

// MARK: - Settings Tab

private enum SettingsTab: String, CaseIterable, Identifiable {
    case general, account, providers, alerts, notifications
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .account: return "Account"
        case .providers: return "Providers"
        case .alerts: return "Alerts"
        case .notifications: return "Notifications"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape.fill"
        case .account: return "person.crop.circle.fill"
        case .providers: return "externaldrive.connected.to.line.below"
        case .alerts: return "bell.fill"
        case .notifications: return "bell.badge.fill"
        }
    }

    var accentColor: Color {
        switch self {
        case .general: return DesignSystem.Colors.amber
        case .account: return DesignSystem.Colors.whimsy
        case .providers: return DesignSystem.Colors.ember
        case .alerts: return DesignSystem.Colors.blaze
        case .notifications: return DesignSystem.Colors.whimsy
        }
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @Bindable var settingsManager: SettingsManager
    var accountManager: AccountManager
    var cloudSyncService: CloudSyncService?
    var dataStore: DataStore
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab: SettingsTab? = .general

    init(
        settingsManager: SettingsManager,
        accountManager: AccountManager = .shared,
        cloudSyncService: CloudSyncService? = nil,
        dataStore: DataStore
    ) {
        self._settingsManager = Bindable(settingsManager)
        self.accountManager = accountManager
        self.cloudSyncService = cloudSyncService
        self.dataStore = dataStore
    }

    var body: some View {
        NavigationSplitView {
            List(SettingsTab.allCases, selection: $selectedTab) { tab in
                Label {
                    Text(tab.title)
                } icon: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(tab.accentColor)
                            .frame(width: 26, height: 26)
                        Image(systemName: tab.icon)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
                .tag(tab)
            }
            .listStyle(.sidebar)
            .navigationTitle("Settings")
            .navigationSplitViewColumnWidth(min: 165, ideal: 190)
        } detail: {
            detailContent
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                            .keyboardShortcut(.cancelAction)
                    }
                }
        }
        .frame(width: 720, height: 530)
    }

    @ViewBuilder
    private var detailContent: some View {
        switch selectedTab ?? .general {
        case .general:
            GeneralSettingsView(settingsManager: settingsManager, dataStore: dataStore)
                .navigationTitle("General")
        case .account:
            AccountSettingsView(
                accountManager: accountManager,
                cloudSyncService: cloudSyncService,
                settingsManager: settingsManager
            )
            .navigationTitle("Account")
        case .providers:
            ProvidersSettingsView(settingsManager: settingsManager, dataStore: dataStore)
                .navigationTitle("Providers")
        case .alerts:
            AlertsSettingsView(settingsManager: settingsManager)
                .navigationTitle("Alerts")
        case .notifications:
            NotificationsSettingsView(settingsManager: settingsManager, dataStore: dataStore)
                .navigationTitle("Notifications")
        }
    }
}

// MARK: - Section Header Helper

private func sectionHeader(_ title: String) -> some View {
    Text(title)
        .font(DesignSystem.Typography.caption)
        .fontWeight(.semibold)
        .foregroundStyle(DesignSystem.Colors.textSecondary)
        .padding(.top, DesignSystem.Spacing.xs)
}

// MARK: - General Settings

private struct GeneralSettingsView: View {
    @Bindable var settingsManager: SettingsManager
    var dataStore: DataStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {

                sectionHeader("Appearance")

                GlassCard {
                    VStack(spacing: 0) {
                        SettingsToggle(
                            title: "Show in Menu Bar",
                            subtitle: "Display BurnBar in the system menu bar",
                            isOn: $settingsManager.showInMenuBar
                        )
                        Divider().background(DesignSystem.Colors.border)
                        SettingsToggle(
                            title: "Launch at Login",
                            subtitle: "Start BurnBar when you log in",
                            isOn: $settingsManager.launchAtLogin
                        )
                    }
                }

                sectionHeader("Data Refresh")

                GlassCard {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Refresh Interval")
                                .font(DesignSystem.Typography.body)
                                .foregroundStyle(DesignSystem.Colors.textPrimary)
                            Text("How often to scan for new sessions")
                                .font(DesignSystem.Typography.caption)
                                .foregroundStyle(DesignSystem.Colors.textSecondary)
                        }
                        Spacer()
                        Picker("", selection: $settingsManager.refreshInterval) {
                            Text("30s").tag(TimeInterval(30))
                            Text("1m").tag(TimeInterval(60))
                            Text("5m").tag(TimeInterval(300))
                            Text("15m").tag(TimeInterval(900))
                        }
                        .pickerStyle(.menu)
                        .frame(width: 100)
                    }
                    .padding(DesignSystem.Spacing.lg)
                }

                sectionHeader("Privacy & Search")

                PrivacyIndexingSettingsView(settingsManager: settingsManager, dataStore: dataStore)

                sectionHeader("Default View")

                GlassCard {
                    HStack {
                        Text("Time Range")
                            .font(DesignSystem.Typography.body)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                        Spacer()
                        Picker("", selection: $settingsManager.defaultTimeRange) {
                            ForEach(TimeRange.allCases) { range in
                                Text(range.displayName).tag(range)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 160)
                    }
                    .padding(DesignSystem.Spacing.lg)
                }

                GlassCard {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Usage Display")
                                .font(DesignSystem.Typography.body)
                                .foregroundStyle(DesignSystem.Colors.textPrimary)
                            Text("Dashboard and menu bar show estimated USD or token volume (M/B).")
                                .font(DesignSystem.Typography.caption)
                                .foregroundStyle(DesignSystem.Colors.textSecondary)
                        }
                        Spacer()
                        Picker("", selection: $settingsManager.usageDisplayMode) {
                            Text("USD").tag(UsageDisplayMode.currency)
                            Text("Tokens").tag(UsageDisplayMode.tokens)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 200)
                    }
                    .padding(DesignSystem.Spacing.lg)
                }
            }
            .padding(DesignSystem.Spacing.lg)
        }
        .background(DesignSystem.Colors.background)
        .scrollContentBackground(.hidden)
    }
}

// MARK: - Privacy & Indexing

private struct PrivacyIndexingSettingsView: View {
    @Bindable var settingsManager: SettingsManager
    var dataStore: DataStore
    @State private var storageBytes: Int64 = 0
    @State private var deleteConfirm = false

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                SettingsToggle(
                    title: "Index Conversation Text",
                    subtitle: "Store transcripts locally for search and chat context. Never uploaded to the cloud.",
                    isOn: $settingsManager.conversationIndexingEnabled
                )

                Divider().background(DesignSystem.Colors.border)

                SettingsToggle(
                    title: "Allow Claude Code / Codex CLI",
                    subtitle: "Lets the in-app assistant run your local `claude` or `codex` binary. You can revoke this anytime.",
                    isOn: $settingsManager.cliAssistantAllowed
                )

                HStack {
                    Text("Approx. indexed text")
                        .font(DesignSystem.Typography.body)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Spacer()
                    Text(formatBytes(storageBytes))
                        .font(DesignSystem.Typography.monoSmall)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                }
                .padding(.horizontal, DesignSystem.Spacing.lg)
                .padding(.bottom, DesignSystem.Spacing.sm)

                Button(role: .destructive) {
                    deleteConfirm = true
                } label: {
                    Text("Delete all indexed conversations")
                        .font(DesignSystem.Typography.caption)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, DesignSystem.Spacing.lg)
                .padding(.bottom, DesignSystem.Spacing.md)
            }
        }
        .onAppear { refreshStorage() }
        .onChange(of: settingsManager.conversationIndexingEnabled) { _, _ in
            refreshStorage()
        }
        .confirmationDialog(
            "Delete indexed conversation text?",
            isPresented: $deleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                try? dataStore.deleteAllIndexedConversations()
                refreshStorage()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Token usage totals are kept. Only locally indexed transcripts are removed.")
        }
    }

    private func refreshStorage() {
        storageBytes = (try? dataStore.approximateConversationStorageBytes()) ?? 0
    }

    private func formatBytes(_ n: Int64) -> String {
        if n < 1024 { return "\(n) B" }
        let kb = Double(n) / 1024
        if kb < 1024 { return String(format: "%.1f KB", kb) }
        return String(format: "%.1f MB", kb / 1024)
    }
}

// MARK: - Providers Settings

private struct ProvidersSettingsView: View {
    @Bindable var settingsManager: SettingsManager
    var dataStore: DataStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                BurnBarDaemonCard(dataStore: dataStore)

                Text("Connect Cursor with your own model providers, then keep the existing parser paths below for everything else.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .padding(.bottom, DesignSystem.Spacing.sm)

                CursorConnectorView(dataStore: dataStore)

                sectionHeader("Log File Paths")

                ForEach(AgentProvider.allCases) { provider in
                    ProviderSettingsRow(
                        provider: provider,
                        path: Binding(
                            get: { settingsManager.logPaths[provider] ?? provider.logDirectory },
                            set: {
                                settingsManager.logPaths[provider] = $0.isEmpty ? provider.logDirectory : $0
                            }
                        ),
                        onBrowse: {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = true
                            panel.canChooseFiles = false
                            panel.allowsMultipleSelection = false
                            panel.directoryURL = URL(fileURLWithPath: (provider.logDirectory as NSString).expandingTildeInPath)

                            DispatchQueue.main.async {
                                if panel.runModal() == .OK, let url = panel.url {
                                    settingsManager.logPaths[provider] = url.path
                                }
                            }
                        },
                        pathExists: settingsManager.pathExists(for: provider)
                    )
                }
            }
            .padding(DesignSystem.Spacing.lg)
        }
        .background(DesignSystem.Colors.background)
        .scrollContentBackground(.hidden)
    }
}

private struct BurnBarDaemonCard: View {
    let dataStore: DataStore
    @State private var daemonManager = BurnBarDaemonManager.shared

    private var statusColor: Color {
        switch daemonManager.status {
        case .healthy:
            return DesignSystem.Colors.success
        case .notInstalled:
            return DesignSystem.Colors.textMuted
        case .checking:
            return DesignSystem.Colors.warning
        case .unhealthy:
            return DesignSystem.Colors.error
        }
    }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                        Text("BurnBar Daemon")
                            .font(DesignSystem.Typography.headline)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                        Text("The local daemon owns BurnBar runtime state, provider routing, and recovery once the app is closed.")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer()

                    HStack(spacing: DesignSystem.Spacing.xs) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 8, height: 8)
                        Text(daemonManager.status.label)
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                    }
                }

                Text(daemonManager.detailText)
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(daemonManager.socketPathDisplay)
                    .font(DesignSystem.Typography.monoTiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .textSelection(.enabled)

                Text(daemonManager.runtimeStateSource.detailText)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !daemonManager.providerConfigurations.isEmpty {
                    Divider().background(DesignSystem.Colors.border)

                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                        Text("Daemon-backed providers")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.textMuted)

                        ForEach(daemonManager.providerConfigurations) { configuration in
                            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                                HStack(spacing: DesignSystem.Spacing.sm) {
                                    Text(configuration.displayName)
                                        .font(DesignSystem.Typography.body)
                                        .foregroundStyle(DesignSystem.Colors.textPrimary)

                                    Toggle(
                                        configuration.isEnabled ? "Enabled" : "Disabled",
                                        isOn: Binding(
                                            get: { configuration.isEnabled },
                                            set: { newValue in
                                                Task {
                                                    await daemonManager.updateProviderConfiguration(
                                                        providerID: configuration.providerID,
                                                        isEnabled: newValue
                                                    )
                                                }
                                            }
                                        )
                                    )
                                    .toggleStyle(.switch)
                                    .labelsHidden()

                                    Spacer()
                                }

                                TextField(
                                    "Base URL",
                                    text: Binding(
                                        get: { configuration.baseURL },
                                        set: { newValue in
                                            Task {
                                                await daemonManager.updateProviderConfiguration(
                                                    providerID: configuration.providerID,
                                                    baseURL: newValue
                                                )
                                            }
                                        }
                                    )
                                )
                                .font(DesignSystem.Typography.monoTiny)
                                .textFieldStyle(.plain)
                                .padding(DesignSystem.Spacing.sm)
                                .background(DesignSystem.Colors.background)
                                .clipShape(.rect(cornerRadius: DesignSystem.Radius.sm, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                                        .stroke(DesignSystem.Colors.border, lineWidth: 0.5)
                                )

                                if !configuration.preferredModelIDs.isEmpty {
                                    TextField(
                                        "Preferred models",
                                        text: Binding(
                                            get: { configuration.preferredModelIDs.joined(separator: ", ") },
                                            set: { newValue in
                                                let models = newValue
                                                    .split(separator: ",")
                                                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                                                    .filter { !$0.isEmpty }
                                                Task {
                                                    await daemonManager.updateProviderConfiguration(
                                                        providerID: configuration.providerID,
                                                        preferredModelIDs: models
                                                    )
                                                }
                                            }
                                        )
                                    )
                                    .font(DesignSystem.Typography.caption)
                                    .textFieldStyle(.plain)
                                    .padding(DesignSystem.Spacing.sm)
                                    .background(DesignSystem.Colors.background)
                                    .clipShape(.rect(cornerRadius: DesignSystem.Radius.sm, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                                            .stroke(DesignSystem.Colors.border, lineWidth: 0.5)
                                    )
                                }
                            }
                        }
                    }
                }

                Divider().background(DesignSystem.Colors.border)

                VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                    Text("Recent daemon usage")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textMuted)

                    if daemonManager.recentUsage.isEmpty {
                        Text("No daemon usage has been mirrored into BurnBar yet.")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                    } else {
                        Text("\(daemonManager.usageLedgerCount) daemon usage record\(daemonManager.usageLedgerCount == 1 ? "" : "s") available in BurnBar's local history.")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)

                        ForEach(daemonManager.recentUsage.prefix(4)) { usage in
                            HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                                    Text("\(usage.provider.displayName) · \(usage.model)")
                                        .font(DesignSystem.Typography.body)
                                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                                    Text(usage.recordedAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(DesignSystem.Typography.caption)
                                        .foregroundStyle(DesignSystem.Colors.textMuted)
                                }

                                Spacer()

                                VStack(alignment: .trailing, spacing: DesignSystem.Spacing.xs) {
                                    Text(usage.cost.formatAsCost())
                                        .font(DesignSystem.Typography.monoSmall)
                                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                                    Text("\(usage.totalTokens) tokens")
                                        .font(DesignSystem.Typography.caption)
                                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                                }
                            }
                        }
                    }
                }

                if !daemonManager.recentEvents.isEmpty {
                    Divider().background(DesignSystem.Colors.border)

                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                        Text("Recent daemon events")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.textMuted)

                        ForEach(Array(daemonManager.recentEvents.enumerated()), id: \.offset) { _, event in
                            Text(event)
                                .font(DesignSystem.Typography.monoTiny)
                                .foregroundStyle(DesignSystem.Colors.textSecondary)
                                .textSelection(.enabled)
                        }
                    }
                }

                HStack(spacing: DesignSystem.Spacing.md) {
                    GlassButton(title: "Install", icon: "arrow.down.circle", style: .prominent) {
                        Task { await daemonManager.installAndStart() }
                    }

                    GlassButton(title: "Repair", icon: "wrench.and.screwdriver", style: .regular) {
                        Task { await daemonManager.repair() }
                    }

                    GlassButton(title: "Check", icon: "waveform.path.ecg", style: .regular) {
                        Task { await daemonManager.refreshHealth() }
                    }

                    GlassButton(title: "Uninstall", icon: "trash", style: .regular) {
                        Task { await daemonManager.uninstall() }
                    }
                }
                .disabled(daemonManager.isBusy)

                if let error = daemonManager.lastError, !error.isEmpty {
                    Text(error)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.warning)
                }

                Text("Provider settings now save through the daemon when it is healthy. If the daemon is unavailable, BurnBar falls back to the local mirror in read-only mode.")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
            .padding(DesignSystem.Spacing.lg)
        }
        .task {
            daemonManager.attach(dataStore: dataStore)
            await daemonManager.refreshHealth()
        }
    }
}

private struct ProviderSettingsRow: View {
    let provider: AgentProvider
    @Binding var path: String
    let onBrowse: () -> Void
    let pathExists: Bool

    private var theme: ProviderTheme { ProviderTheme.theme(for: provider) }

    private var statusColor: Color {
        switch provider.supportLevel {
        case .supported: return DesignSystem.Colors.success
        case .partial: return DesignSystem.Colors.warning
        case .unsupported: return DesignSystem.Colors.textMuted
        }
    }

    private var supportLevelText: String {
        switch provider.supportLevel {
        case .supported: return "Supported"
        case .partial: return "Partial support"
        case .unsupported: return "Not yet supported"
        }
    }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                HStack(spacing: DesignSystem.Spacing.md) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 7.5, style: .continuous)
                            .fill(theme.primaryColor.opacity(0.15))
                            .frame(width: 32, height: 32)
                        ProviderLogoView(provider: provider, size: 20, useFallbackColor: false)
                    }

                    Text(provider.displayName)
                        .font(DesignSystem.Typography.headline)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)

                    Spacer()

                    HStack(spacing: DesignSystem.Spacing.xs) {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(statusColor)
                        Text(supportLevelText)
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                    }
                }

                HStack(spacing: DesignSystem.Spacing.sm) {
                    TextField("Path", text: $path)
                        .font(DesignSystem.Typography.monoSmall)
                        .textFieldStyle(.plain)
                        .padding(DesignSystem.Spacing.sm)
                        .background(DesignSystem.Colors.background)
                        .clipShape(.rect(cornerRadius: DesignSystem.Radius.sm, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                                .stroke(DesignSystem.Colors.border, lineWidth: 0.5)
                        )

                    Image(systemName: pathExists ? "checkmark.circle.fill" : "xmark.circle")
                        .font(.system(size: 14))
                        .foregroundStyle(pathExists ? DesignSystem.Colors.success : DesignSystem.Colors.textMuted)
                        .help(pathExists ? "Path exists" : "Path not found")

                    Button("Browse...") { onBrowse() }
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .padding(.horizontal, DesignSystem.Spacing.md)
                        .padding(.vertical, DesignSystem.Spacing.sm)
                        .background(DesignSystem.Colors.surface)
                        .clipShape(.rect(cornerRadius: DesignSystem.Radius.sm, style: .continuous))
                }

                HStack(spacing: DesignSystem.Spacing.xs) {
                    Text("Default:")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                    Text(provider.logDirectory)
                        .font(DesignSystem.Typography.monoTiny)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                }

                if provider.supportLevel == .unsupported {
                    Text("Log parsing for \(provider.displayName) is not yet implemented. Data will appear once support is added.")
                        .font(DesignSystem.Typography.caption)
                        .italic()
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                }
            }
            .padding(DesignSystem.Spacing.lg)
        }
    }
}

// MARK: - Alerts Settings

private struct AlertsSettingsView: View {
    @Bindable var settingsManager: SettingsManager
    @State private var alertEnabled: Bool = false
    @State private var alertThreshold: Double = 10.0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {

                sectionHeader("Daily Cost Alert")

                GlassCard {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                        Toggle(isOn: $alertEnabled) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Enable Alert")
                                    .font(DesignSystem.Typography.body)
                                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                                Text("Get notified when daily spending exceeds threshold")
                                    .font(DesignSystem.Typography.caption)
                                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                            }
                        }
                        .toggleStyle(.switch)
                        .onChange(of: alertEnabled) { _, newValue in
                            settingsManager.costAlertThreshold = newValue ? alertThreshold : nil
                        }

                        if alertEnabled {
                            HStack {
                                Text("Alert when daily cost exceeds")
                                    .font(DesignSystem.Typography.body)
                                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                                Spacer()
                                TextField("", value: $alertThreshold, format: .number)
                                    .textFieldStyle(.plain)
                                    .font(DesignSystem.Typography.mono)
                                    .padding(DesignSystem.Spacing.sm)
                                    .background(DesignSystem.Colors.background)
                                    .frame(width: 80)
                                    .clipShape(.rect(cornerRadius: DesignSystem.Radius.sm, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                                            .stroke(DesignSystem.Colors.border, lineWidth: 0.5)
                                    )
                                    .onChange(of: alertThreshold) { _, newValue in
                                        settingsManager.costAlertThreshold = newValue
                                    }
                                Text("USD")
                                    .font(DesignSystem.Typography.caption)
                                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                            }
                        }
                    }
                    .padding(DesignSystem.Spacing.lg)
                }

                sectionHeader("About")

                GlassCard {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("BurnBar")
                                .font(DesignSystem.Typography.headline)
                                .foregroundStyle(DesignSystem.Colors.textPrimary)
                            Text("Version 1.0.0")
                                .font(DesignSystem.Typography.caption)
                                .foregroundStyle(DesignSystem.Colors.textSecondary)
                        }
                        Spacer()
                    }
                    .padding(DesignSystem.Spacing.lg)
                }
            }
            .padding(DesignSystem.Spacing.lg)
        }
        .background(DesignSystem.Colors.background)
        .scrollContentBackground(.hidden)
        .onAppear {
            alertEnabled = settingsManager.costAlertThreshold != nil
            alertThreshold = settingsManager.costAlertThreshold ?? 10.0
        }
    }
}

// MARK: - Notifications Settings

private struct NotificationsSettingsView: View {
    @Bindable var settingsManager: SettingsManager
    var dataStore: DataStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {

                sectionHeader("Daily Digest")

                GlassCard {
                    VStack(spacing: 0) {
                        SettingsToggle(
                            title: "Daily Digest",
                            subtitle: "Brief summary of today's agent spend at the chosen hour",
                            isOn: $settingsManager.dailyDigestEnabled
                        )

                        Divider().background(DesignSystem.Colors.border)

                        HStack {
                            Text("Send at")
                                .font(DesignSystem.Typography.body)
                                .foregroundStyle(DesignSystem.Colors.textPrimary)
                            Spacer()
                            Picker("Hour", selection: $settingsManager.dailyDigestHour) {
                                ForEach(0..<24, id: \.self) { h in
                                    Text(String(format: "%02d:00", h)).tag(h)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 100)
                        }
                        .padding(DesignSystem.Spacing.lg)
                    }
                }
            }
            .padding(DesignSystem.Spacing.lg)
        }
        .background(DesignSystem.Colors.background)
        .scrollContentBackground(.hidden)
        .onChange(of: settingsManager.dailyDigestEnabled) { _, on in
            Task {
                if on {
                    await DailyDigestManager.shared.requestAuthorization()
                    DailyDigestManager.shared.scheduleDigest(from: dataStore, at: settingsManager.dailyDigestHour)
                } else {
                    DailyDigestManager.shared.cancelDigest()
                }
            }
        }
        .onChange(of: settingsManager.dailyDigestHour) { _, h in
            if settingsManager.dailyDigestEnabled {
                DailyDigestManager.shared.scheduleDigest(from: dataStore, at: h)
            }
        }
        .onAppear {
            if settingsManager.dailyDigestEnabled {
                DailyDigestManager.shared.scheduleDigest(from: dataStore, at: settingsManager.dailyDigestHour)
            }
        }
    }
}

// MARK: - Settings Toggle

private struct SettingsToggle: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text(subtitle)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
        }
        .toggleStyle(.switch)
        .padding(DesignSystem.Spacing.lg)
    }
}

// MARK: - Account Settings

private struct AccountSettingsView: View {
    var accountManager: AccountManager
    var cloudSyncService: CloudSyncService?
    @Bindable var settingsManager: SettingsManager

    @State private var isSigningInGoogle = false
    @State private var isSigningInApple = false
    @State private var signInError: String?

    /// Prefers Firebase/Auth `userInfo` keys over the generic `localizedDescription` (e.g. keychain errors).
    private static func signInErrorMessage(_ error: Error) -> String {
        let ns = error as NSError
        if let reason = ns.userInfo[NSLocalizedFailureReasonErrorKey] as? String, !reason.isEmpty {
            return reason
        }
        if let suggestion = ns.userInfo[NSLocalizedRecoverySuggestionErrorKey] as? String, !suggestion.isEmpty {
            return suggestion
        }
        return error.localizedDescription
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                if accountManager.isFirebaseAvailable {
                    signedInContent
                } else {
                    notConfiguredBanner
                }
            }
            .padding(DesignSystem.Spacing.lg)
        }
        .background(DesignSystem.Colors.background)
        .scrollContentBackground(.hidden)
    }

    // MARK: - Not Configured

    private var notConfiguredBanner: some View {
        accountPanel {
            HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(DesignSystem.Colors.warning)

                VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                    Text("Firebase not configured")
                        .font(DesignSystem.Typography.headline)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Text("Add GoogleService-Info.plist to enable account sync. See the README for setup instructions.")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Signed-in / Signed-out Content

    @ViewBuilder
    private var signedInContent: some View {
        sectionHeader("Account")

        if accountManager.isSignedIn {
            accountPanel {
                HStack(spacing: DesignSystem.Spacing.md) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(DesignSystem.Colors.whimsy.opacity(0.15))
                            .frame(width: 40, height: 40)
                        Image(systemName: "person.fill")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(DesignSystem.Colors.whimsy)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(accountManager.userDisplayName ?? "Signed in")
                            .font(DesignSystem.Typography.headline)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                        if let email = accountManager.userEmail {
                            Text(email)
                                .font(DesignSystem.Typography.caption)
                                .foregroundStyle(DesignSystem.Colors.textSecondary)
                        }
                    }

                    Spacer()

                    Button("Sign Out") {
                        try? accountManager.signOut()
                    }
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.error)
                    .padding(.horizontal, DesignSystem.Spacing.md)
                    .padding(.vertical, DesignSystem.Spacing.sm)
                    .background(DesignSystem.Colors.error.opacity(0.12))
                    .clipShape(.rect(cornerRadius: DesignSystem.Radius.md, style: .continuous))
                    .buttonStyle(.plain)
                }
            }

            sectionHeader("Cloud Sync")

            accountPanel {
                VStack(spacing: 0) {
                    SettingsToggle(
                        title: "Enable Cloud Sync",
                        subtitle: "Upload token usage to Firestore for cross-device totals",
                        isOn: Binding(
                            get: { accountManager.isCloudSyncEnabled },
                            set: { accountManager.setCloudSyncEnabled($0) }
                        )
                    )

                    Divider().background(DesignSystem.Colors.border)

                    SettingsToggle(
                        title: "Back Up Session History",
                        subtitle: "Syncs session metadata (not full text) to iCloud for recall across devices",
                        isOn: $settingsManager.conversationCloudBackupEnabled
                    )
                    .disabled(!accountManager.isSignedIn || !accountManager.isCloudSyncEnabled)

                    Divider().background(DesignSystem.Colors.border)

                    syncStatusRow
                }
            }
        } else {
            accountPanel {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Cloud Sync")
                            .font(DesignSystem.Typography.headline)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                        Text("Sign in with Google or Apple to sync usage totals across your Macs. Data stays in your Firebase project.")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let error = signInError {
                        Text(error)
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.error)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(spacing: DesignSystem.Spacing.sm) {
                        GoogleSignInBrandButton(isLoading: isSigningInGoogle) {
                            guard let window = NSApp.keyWindow ?? NSApp.windows.first else { return }
                            Task { @MainActor in
                                isSigningInGoogle = true
                                signInError = nil
                                defer { isSigningInGoogle = false }
                                do {
                                    try await accountManager.signInWithGoogle(presentingWindow: window)
                                } catch {
                                    signInError = Self.signInErrorMessage(error)
                                }
                            }
                        }

                        SignInWithAppleButton(.signIn) { request in
                            request.requestedScopes = [.fullName, .email]
                            request.nonce = accountManager.appleSignInNonceHash()
                        } onCompletion: { result in
                            Task { @MainActor in
                                switch result {
                                case .success(let authorization):
                                    isSigningInApple = true
                                    signInError = nil
                                    defer { isSigningInApple = false }
                                    do {
                                        try await accountManager.signInWithAppleAuthorization(authorization)
                                    } catch {
                                        if (error as NSError).code != ASAuthorizationError.canceled.rawValue {
                                            signInError = Self.signInErrorMessage(error)
                                        }
                                    }
                                case .failure(let error):
                                    if (error as NSError).code != ASAuthorizationError.canceled.rawValue {
                                        signInError = Self.signInErrorMessage(error)
                                    }
                                }
                            }
                        }
                        .signInWithAppleButtonStyle(.white)
                        .frame(height: 44)
                        .frame(maxWidth: .infinity)
                        .overlay {
                            if isSigningInApple {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(Color.black.opacity(0.08))
                                    ProgressView()
                                        .controlSize(.small)
                                }
                            }
                        }
                        .disabled(isSigningInApple)
                    }
                }
            }
        }
    }

    private func accountPanel<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(DesignSystem.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                        .fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                        .fill(DesignSystem.Colors.surface.opacity(0.55))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.12), DesignSystem.Colors.border.opacity(0.35)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.5
                    )
            )
    }

    // MARK: - Sync Status Row

    private var syncStatusRow: some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Last sync")
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)

                Group {
                    if let error = cloudSyncService?.lastSyncError {
                        Text("Error: \(error)")
                            .foregroundStyle(DesignSystem.Colors.error)
                    } else if let date = cloudSyncService?.lastSyncDate {
                        Text(date.formatted(.relative(presentation: .named)))
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                    } else {
                        Text("Never")
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                    }
                }
                .font(DesignSystem.Typography.caption)
            }

            Spacer()

            if cloudSyncService?.isSyncing == true {
                HStack(spacing: DesignSystem.Spacing.xs) {
                    ProgressView().controlSize(.small)
                    Text("Syncing")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                }
            } else {
                Image(systemName: cloudSyncService?.lastSyncError != nil ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(
                        cloudSyncService?.lastSyncError != nil
                            ? DesignSystem.Colors.error
                            : DesignSystem.Colors.success
                    )
            }
        }
        .padding(DesignSystem.Spacing.lg)
    }
}

/// Google's branded "Sign in with Google" treatment (light background + stroke).
/// GoogleSignInSwift's `GoogleSignInButton` is excluded on arm64 in the SDK, so we match the guidelines manually.
private struct GoogleSignInBrandButton: View {
    var isLoading: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text("G")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(Color(hex: "4285F4"))
                }
                Text(isLoading ? "Signing in…" : "Sign in with Google")
                    .font(.system(size: 14, weight: .medium, design: .default))
                    .foregroundStyle(Color(hex: "3C4043"))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color(hex: "747775").opacity(0.38), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
    }
}

#Preview {
    SettingsView(settingsManager: SettingsManager.shared, dataStore: DataStore())
}
