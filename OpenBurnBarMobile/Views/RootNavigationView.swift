import SwiftUI
import OpenBurnBarCore

// MARK: - Root Navigation View (iPad)

struct RootNavigationView: View {
    let authStore: AuthStore
    let syncHealthStore: CloudSyncHealthStore
    let providerSummaryStore: ProviderSummaryStore
    let devicesStore: DevicesStore
    let transferStore: CredentialTransferStore

    @State private var navigationModel = DashboardNavigationModel()
    @State private var showSettings = false
    @State private var showChat = false

    var body: some View {
        NavigationSplitView {
            DashboardSidebar(
                syncHealthStore: syncHealthStore,
                navigationModel: navigationModel,
                onShowSettings: { showSettings = true },
                onShowChat: { showChat = true }
            )
        } detail: {
            NavigationStack {
                detailContent(for: navigationModel.currentRoute)
                    .navigationTitle(navigationModel.routeTitle(navigationModel.currentRoute))
                    .toolbar {
                        if navigationModel.canGoBack {
                            ToolbarItem(placement: .navigationBarLeading) {
                                Button(action: { navigationModel.goBack() }) {
                                    Label(navigationModel.backButtonHelpText, systemImage: "chevron.left")
                                }
                            }
                        }
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button(action: { showChat = true }) {
                                Label("Hermes", systemImage: "bubble.left.and.bubble.right.fill")
                            }
                        }
                    }
            }
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                iPadSettingsView()
                    .navigationTitle("Settings")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showSettings = false }
                        }
                    }
            }
        }
        .sheet(isPresented: $showChat) {
            NavigationStack {
                ChatView()
                    .navigationTitle("Hermes")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showChat = false }
                        }
                    }
            }
        }
        .keyboardShortcutDiscovery()
    }

    @ViewBuilder private func detailContent(for route: iPadDashboardRoute) -> some View {
        switch route {
        case .overview: DashboardView()
        case .provider(let p): ProviderDashboardView(provider: p)
        case .model(let m): ModelDashboardView(modelName: m)
        case .sessionLogs: SessionLogsView()
        case .projects: ProjectsView()
        case .missions: MissionsView()
        case .activity: ActivityView()
        case .quota: QuotaView()
        case .account: AccountView()
        case .settings, .chat: EmptyView()
        }
    }
}

// MARK: - Dashboard Sidebar

struct DashboardSidebar: View {
    let syncHealthStore: CloudSyncHealthStore
    @Bindable var navigationModel: DashboardNavigationModel
    let onShowSettings: () -> Void
    let onShowChat: () -> Void

    var body: some View {
        List(selection: Binding(
            get: { navigationModel.currentRoute },
            set: { if let route = $0 { navigationModel.currentRoute = route } }
        )) {
            Section {
                sidebarItem(.overview, icon: "chart.bar.fill", label: "Overview")
                sidebarItem(.activity, icon: "list.bullet.rectangle", label: "Activity")
                sidebarItem(.quota, icon: "gauge.with.dots.needle.67percent", label: "Quota")
            }
            Section("Insights") {
                sidebarItem(.sessionLogs, icon: "doc.text.magnifyingglass", label: "Session Logs")
                sidebarItem(.projects, icon: "folder.fill", label: "Projects")
                sidebarItem(.missions, icon: "bolt.fill", label: "Missions")
            }
            Section("Account") {
                sidebarItem(.account, icon: "person.fill", label: "Account")
                Button(action: onShowSettings) { Label("Settings", systemImage: "gearshape.fill") }
                Button(action: onShowChat) { Label("Hermes", systemImage: "bubble.left.and.bubble.right.fill") }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("OpenBurnBar")
        .overlay(alignment: .bottom) {
            SyncHealthPill(store: syncHealthStore)
                .padding(.horizontal, MobileTheme.Spacing.md)
                .padding(.bottom, MobileTheme.Spacing.md)
        }
    }

    private func sidebarItem(_ route: iPadDashboardRoute, icon: String, label: String) -> some View {
        NavigationLink(value: route) { Label(label, systemImage: icon) }
    }
}

// MARK: - Sync Health Pill

private struct SyncHealthPill: View {
    let store: CloudSyncHealthStore

    var body: some View {
        HStack(spacing: MobileTheme.Spacing.sm) {
            Circle().fill(statusColor).frame(width: 8, height: 8)
            Text(statusText).font(MobileTheme.Typography.tiny).foregroundStyle(MobileTheme.Colors.textMuted).lineLimit(1)
        }
        .padding(.horizontal, MobileTheme.Spacing.md)
        .padding(.vertical, MobileTheme.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.full, style: .continuous)
                .fill(MobileTheme.Colors.surfaceElevated)
                .overlay(RoundedRectangle(cornerRadius: MobileTheme.Radius.full, style: .continuous).stroke(MobileTheme.Colors.border, lineWidth: 0.5))
        )
    }

    private var statusColor: Color {
        switch store.health {
        case .healthy: return MobileTheme.Colors.success
        case .syncing: return MobileTheme.Colors.warning
        case .degraded, .offline, .unknown: return MobileTheme.Colors.warning
        case .permissionDenied, .appCheckBlocked, .firebaseUnavailable: return MobileTheme.Colors.error
        }
    }

    private var statusText: String {
        switch store.health {
        case .healthy: return "Synced"
        case .syncing: return "Syncing…"
        case .degraded: return "Degraded"
        case .offline: return "Offline"
        case .permissionDenied: return "Permission denied"
        case .appCheckBlocked: return "App Check blocked"
        case .firebaseUnavailable: return "Firebase unavailable"
        case .unknown: return "Checking…"
        }
    }
}

// MARK: - Placeholder Views

struct ProjectsView: View {
    var body: some View {
        EmptyStateView(icon: "folder.fill", title: "Projects", message: "Track missions, questions, followups, and scheduled reviews across your codebase.")
            .background(MobileTheme.Colors.background.ignoresSafeArea())
    }
}

struct MissionsView: View {
    var body: some View {
        EmptyStateView(icon: "bolt.fill", title: "Missions", message: "Active missions and operational workflows from your Mac's daemon.")
            .background(MobileTheme.Colors.background.ignoresSafeArea())
    }
}

struct ModelDashboardView: View {
    let modelName: String
    var body: some View {
        ScrollView {
            VStack(spacing: MobileTheme.Spacing.xxl) {
                Circle()
                    .fill(MobileTheme.Colors.colorForModel(modelName).opacity(0.15))
                    .frame(width: 64, height: 64)
                    .overlay(Image(systemName: "cpu").font(.system(size: 28, weight: .semibold)).foregroundStyle(MobileTheme.Colors.colorForModel(modelName)))
                    .padding(.top, MobileTheme.Spacing.xxxl)
                Text(modelName).font(MobileTheme.Typography.title).foregroundStyle(MobileTheme.Colors.textPrimary)
                Text("Model usage breakdown across providers").font(MobileTheme.Typography.footnote).foregroundStyle(MobileTheme.Colors.textMuted).multilineTextAlignment(.center)
            }
            .padding(MobileTheme.Spacing.xxxl)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(MobileTheme.Colors.background.ignoresSafeArea())
    }
}

// MARK: - iPad Settings View

struct iPadSettingsView: View {
    @State private var selectedTab: iPadSettingsTab? = .general

    var body: some View {
        NavigationSplitView {
            List(iPadSettingsTab.allCases, selection: $selectedTab) { tab in
                Label {
                    Text(tab.title)
                } icon: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6, style: .continuous).fill(tab.accentColor).frame(width: 26, height: 26)
                        Image(systemName: tab.icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    }
                }
                .tag(tab)
            }
            .listStyle(.sidebar)
            .navigationTitle("Settings")
            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
        } detail: {
            detailContent.navigationTitle(selectedTab?.title ?? "")
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        switch selectedTab ?? .general {
        case .general: iPadGeneralSettingsView()
        case .account: iPadAccountSettingsView()
        case .providers: iPadProvidersSettingsView()
        case .alerts: iPadAlertsSettingsView()
        case .notifications: iPadNotificationsSettingsView()
        case .devicesAndSync: iPadDevicesSettingsView()
        case .switcher: iPadAccountSwitcherSettingsView()
        }
    }
}

// MARK: - Settings Detail Views

struct iPadGeneralSettingsView: View {
    @AppStorage("preferredAppearance") private var preferredAppearance: String = "system"
    @AppStorage("usageDisplayMode") private var usageDisplayMode: String = "currency"
    @AppStorage("dailyDigestEnabled") private var dailyDigestEnabled: Bool = false
    @AppStorage("dailyDigestHour") private var dailyDigestHour: Int = 9

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $preferredAppearance) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                Picker("Usage Display", selection: $usageDisplayMode) {
                    Text("Currency").tag("currency")
                    Text("Tokens").tag("tokens")
                }
            }
            Section("Daily Digest") {
                Toggle("Enable Digest", isOn: $dailyDigestEnabled)
                if dailyDigestEnabled {
                    Picker("Delivery Time", selection: $dailyDigestHour) {
                        ForEach(6..<24, id: \.self) { hour in Text("\(hour):00").tag(hour) }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct iPadProvidersSettingsView: View {
    @State private var store = ProviderConnectionStore()

    var body: some View {
        Form {
            Section("Connections") {
                if store.connections.isEmpty {
                    Text("No provider connections yet. Add connections on your Mac to see them here.")
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                } else {
                    ForEach(store.connections) { conn in
                        HStack {
                            if let provider = AgentProvider.fromPersistedToken(conn.provider) {
                                ProviderBadge(provider: provider, size: 28)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(conn.provider)
                                    .font(MobileTheme.Typography.body)
                                Text(conn.redactedLabel)
                                    .font(MobileTheme.Typography.caption)
                                    .foregroundStyle(MobileTheme.Colors.textMuted)
                            }
                            Spacer()
                            Text(conn.status.rawValue.capitalized)
                                .font(MobileTheme.Typography.caption)
                                .foregroundStyle(conn.status == .connected ? MobileTheme.Colors.success : MobileTheme.Colors.textMuted)
                        }
                    }
                }
            }
            Section("Plan Tiers") {
                Text("Manage provider plan tiers and quota tracking on your Mac.")
                    .foregroundStyle(MobileTheme.Colors.textMuted)
            }
        }
        .formStyle(.grouped)
        .task { await store.load() }
        .refreshable { await store.load() }
    }
}

struct iPadAlertsSettingsView: View {
    @AppStorage("dailyBudget") private var dailyBudget: Double = 50.0
    @AppStorage("tokenAlertEnabled") private var tokenAlertEnabled: Bool = false
    @AppStorage("tokenAlertThreshold") private var tokenAlertThreshold: Int = 100_000
    @AppStorage("costAlertEnabled") private var costAlertEnabled: Bool = false
    @AppStorage("costAlertThreshold") private var costAlertThreshold: Double = 10.0

    var body: some View {
        Form {
            Section("Budget") {
                LabeledContent("Daily Budget") { Text("$\(dailyBudget, specifier: "%.2f")").foregroundStyle(MobileTheme.Colors.textSecondary) }
                Slider(value: $dailyBudget, in: 1...500, step: 5) {
                    Text("Daily Budget")
                } minimumValueLabel: {
                    Text("$1").font(MobileTheme.Typography.caption)
                } maximumValueLabel: {
                    Text("$500").font(MobileTheme.Typography.caption)
                }
            }
            Section("Token Alerts") {
                Toggle("Enable Token Alerts", isOn: $tokenAlertEnabled)
                if tokenAlertEnabled {
                    Stepper("Threshold: \(tokenAlertThreshold.formatted()) tokens", value: $tokenAlertThreshold, step: 10_000)
                }
            }
            Section("Cost Alerts") {
                Toggle("Enable Cost Alerts", isOn: $costAlertEnabled)
                if costAlertEnabled {
                    Stepper("Threshold: $\(costAlertThreshold, specifier: "%.2f")", value: $costAlertThreshold, step: 1)
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct iPadNotificationsSettingsView: View {
    @AppStorage("dailyDigestEnabled") private var dailyDigestEnabled: Bool = false
    @AppStorage("dailyDigestHour") private var dailyDigestHour: Int = 9
    @AppStorage("sessionNotifications") private var sessionNotifications: Bool = false

    var body: some View {
        Form {
            Section("Digest") {
                Toggle("Daily Spend Digest", isOn: $dailyDigestEnabled)
                if dailyDigestEnabled {
                    Picker("Delivery Time", selection: $dailyDigestHour) {
                        ForEach(6..<24, id: \.self) { hour in Text("\(hour):00").tag(hour) }
                    }
                }
            }
            Section("Session") {
                Toggle("Notify on New Sessions", isOn: $sessionNotifications)
            }
            Section {
                Button("Open System Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .foregroundStyle(MobileTheme.Colors.accent)
            }
        }
        .formStyle(.grouped)
    }
}

struct iPadAccountSwitcherSettingsView: View {
    @State private var store = AccountStore()
    @State private var showAddSheet = false

    var body: some View {
        Form {
            Section("Active Profile") {
                if let profile = store.activeProfile {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(profile.displayName)
                                .font(MobileTheme.Typography.body)
                            Text(profile.email ?? "No email")
                                .font(MobileTheme.Typography.footnote)
                                .foregroundStyle(MobileTheme.Colors.textMuted)
                        }
                        Spacer()
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(MobileTheme.Colors.success)
                    }
                } else {
                    Text("No active profile")
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                }
            }
            Section("All Profiles") {
                if store.profiles.isEmpty {
                    Text("Sign in with additional accounts to manage profiles here.")
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                } else {
                    ForEach(store.profiles) { profile in
                        Button {
                            Task { await store.switchTo(profile) }
                        } label: {
                            HStack {
                                Text(profile.displayName)
                                Spacer()
                                if profile.id == store.activeProfile?.id {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(MobileTheme.Colors.accent)
                                }
                            }
                        }
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task { await store.loadProfiles() }
    }
}
