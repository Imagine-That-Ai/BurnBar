import SwiftUI
import OpenBurnBarCore

// MARK: - Settings Hub View
//
// Aurora-styled grouped settings. Replaces the hodge-podge of `iPad*Settings`
// forms with one cohesive surface that re-uses native `Form` while restyling
// the chrome.

struct SettingsHubView: View {
    let authStore: AuthStore

    @Environment(\.cloudSubscriptionStore) private var sharedSubscriptionStore
    @State private var localSubscriptionStore = HostedQuotaSubscriptionStore()
    @State private var didLoadLocalSubscription = false
    @State private var showDeleteAccountConfirmation = false
    @State private var accountDeletionError: String?
    @State private var router = SettingsRouter()

    @AppStorage("preferredAppearance") private var preferredAppearance: String = "system"
    @AppStorage("usageDisplayMode") private var usageDisplayMode: String = "currency"
    @AppStorage("uiMode") private var uiMode: String = UIMode.standard.rawValue
    @AppStorage("dailyBudget") private var dailyBudget: Double = 50.0
    @AppStorage("dailyDigestEnabled") private var dailyDigestEnabled: Bool = false
    @AppStorage("dailyDigestHour") private var dailyDigestHour: Int = 9
    @AppStorage("sessionNotifications") private var sessionNotifications: Bool = false
    @AppStorage("tokenAlertEnabled") private var tokenAlertEnabled: Bool = false
    @AppStorage("tokenAlertThreshold") private var tokenAlertThreshold: Int = 100_000
    @AppStorage("costAlertEnabled") private var costAlertEnabled: Bool = false
    @AppStorage("costAlertThreshold") private var costAlertThreshold: Double = 10.0

    var body: some View {
        hubContent
            .navigationDestination(for: SettingsPageRoute.self) { route in
                destination(for: route)
                    .environment(router)
            }
            .environment(router)
    }

    @ViewBuilder
    private var hubContent: some View {
        ZStack {
            AuroraBackdrop(density: .subtle)
            if router.isSearching {
                SettingsSearchResultsView(router: router)
                    .environment(router)
            } else {
                hubForm
            }
        }
        .searchable(
            text: $router.query,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search settings"
        )
        .navigationTitle("Settings")
        .confirmationDialog(
            "Delete OpenBurnBar account?",
            isPresented: $showDeleteAccountConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete account", role: .destructive) {
                Task { await deleteAccount() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes your OpenBurnBar cloud data, provider account records, devices, usage history, and sign-in. This cannot be undone.")
        }
        .alert("Account deletion failed", isPresented: deletionErrorBinding) {
            Button("OK", role: .cancel) {
                accountDeletionError = nil
            }
        } message: {
            Text(accountDeletionError ?? "Try signing in again, then delete the account from Settings.")
        }
        .task {
            if sharedSubscriptionStore == nil, !didLoadLocalSubscription {
                didLoadLocalSubscription = true
                await localSubscriptionStore.load()
            }
        }
    }

    @ViewBuilder
    private func destination(for route: SettingsPageRoute) -> some View {
        switch route {
        case .hubRoot:
            hubContent
        case .cloud:
            SettingsDeepLinkScrollContainer(route: .cloud) { _ in
                CloudStoreView()
            }
        case .providerConnections:
            ProviderConnectionsView(showsDoneButton: false)
        case .hermes:
            SettingsDeepLinkScrollContainer(route: .hermes) { _ in
                HermesSettingsView(
                    service: HermesService(),
                    authStore: authStore
                )
            }
        case .pi:
            SettingsDeepLinkScrollContainer(route: .pi) { _ in
                PiSettingsView(service: PiService(), authStore: authStore)
            }
        case .chatTiles:
            SettingsDeepLinkScrollContainer(route: .chatTiles) { _ in
                ChatTilesSettingsView()
            }
        }
    }

    private var hubForm: some View {
        SettingsDeepLinkScrollContainer(route: .hubRoot) { _ in
            Form {
                Section {
                    Picker(selection: $preferredAppearance) {
                        Text("System").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    } label: {
                        SettingsLabel(icon: "paintpalette.fill", color: MobileTheme.amber, title: "Theme")
                    }
                    .settingsAnchor(SettingsAnchor.theme)
                    Picker(selection: $usageDisplayMode) {
                        Text("Currency").tag("currency")
                        Text("Tokens").tag("tokens")
                    } label: {
                        SettingsLabel(icon: "number.square.fill", color: MobileTheme.ember, title: "Default display")
                    }
                    .settingsAnchor(SettingsAnchor.usageDisplay)
                } header: { groupHeader("Appearance") }

                Section {
                    UIModePicker(selection: $uiMode)
                        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                        .listRowBackground(Color.clear)
                        .settingsAnchor(SettingsAnchor.uiMode)
                } header: { groupHeader("UI Mode") }

                Section {
                    HStack {
                        SettingsLabel(icon: "dollarsign.circle.fill", color: MobileTheme.amber, title: "Daily budget")
                        Spacer()
                        Text("$\(dailyBudget, specifier: "%.2f")")
                            .font(MobileTheme.Typography.caption)
                            .foregroundStyle(MobileTheme.Colors.textSecondary)
                    }
                    .settingsAnchor(SettingsAnchor.dailyBudget)
                    Slider(value: $dailyBudget, in: 1...500, step: 5) {
                        Text("Daily budget")
                    } minimumValueLabel: {
                        Text("$1").font(MobileTheme.Typography.tiny).foregroundStyle(MobileTheme.Colors.textMuted)
                    } maximumValueLabel: {
                        Text("$500").font(MobileTheme.Typography.tiny).foregroundStyle(MobileTheme.Colors.textMuted)
                    }
                    .tint(MobileTheme.ember)
                    Toggle(isOn: $costAlertEnabled) {
                        SettingsLabel(icon: "bell.badge.fill", color: MobileTheme.warning, title: "Cost alerts")
                    }
                    .tint(MobileTheme.ember)
                    .settingsAnchor(SettingsAnchor.costAlerts)
                    if costAlertEnabled {
                        Stepper("Threshold: $\(costAlertThreshold, specifier: "%.2f")", value: $costAlertThreshold, step: 1)
                    }
                    Toggle(isOn: $tokenAlertEnabled) {
                        SettingsLabel(icon: "number.circle.fill", color: MobileTheme.amber, title: "Token alerts")
                    }
                    .tint(MobileTheme.ember)
                    .settingsAnchor(SettingsAnchor.tokenAlerts)
                    if tokenAlertEnabled {
                        Stepper("Threshold: \(tokenAlertThreshold.formatted()) tokens", value: $tokenAlertThreshold, step: 10_000)
                    }
                } header: { groupHeader("Budget") }

                Section {
                    Toggle(isOn: $dailyDigestEnabled) {
                        SettingsLabel(icon: "envelope.badge.fill", color: MobileTheme.whimsy, title: "Daily digest")
                    }
                    .tint(MobileTheme.ember)
                    .settingsAnchor(SettingsAnchor.dailyDigest)
                    if dailyDigestEnabled {
                        Picker("Delivery time", selection: $dailyDigestHour) {
                            ForEach(6..<24, id: \.self) { hour in Text("\(hour):00").tag(hour) }
                        }
                    }
                    Toggle(isOn: $sessionNotifications) {
                        SettingsLabel(icon: "bell.fill", color: MobileTheme.amber, title: "Session pings")
                    }
                    .tint(MobileTheme.ember)
                    .settingsAnchor(SettingsAnchor.sessionPings)
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        SettingsLabel(icon: "gear", color: MobileTheme.Colors.textSecondary, title: "Open system Notifications…")
                    }
                    .foregroundStyle(MobileTheme.ember)
                    .settingsAnchor(SettingsAnchor.openSystemNotifications)
                } header: { groupHeader("Notifications") }

                Section {
                    NavigationLink(value: SettingsPageRoute.cloud) {
                        cloudSettingsRow
                    }
                    .settingsAnchor(SettingsAnchor.cloudRow)
                } header: { groupHeader("Cloud") }

                Section {
                    if let identity = authStore.currentIdentity {
                        LabeledContent("Signed in", value: identity.email ?? identity.displayName ?? "OpenBurnBar account")
                            .settingsAnchor(SettingsAnchor.accountRow)
                    }
                    Button(role: .destructive) {
                        showDeleteAccountConfirmation = true
                    } label: {
                        HStack(spacing: 10) {
                            if authStore.isDeletingAccount {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "person.crop.circle.badge.xmark")
                                    .foregroundStyle(MobileTheme.Colors.error)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(authStore.isDeletingAccount ? "Deleting account..." : "Delete account")
                                    .font(MobileTheme.Typography.body)
                                Text("Permanently removes your OpenBurnBar cloud data and sign-in.")
                                    .font(MobileTheme.Typography.tiny)
                                    .foregroundStyle(MobileTheme.Colors.textMuted)
                            }
                        }
                    }
                    .disabled(!authStore.state.isSignedIn || authStore.isDeletingAccount)
                    .accessibilityIdentifier("settings.deleteAccount")
                    .accessibilityHint("Permanently deletes your OpenBurnBar account and cloud data.")
                    .settingsAnchor(SettingsAnchor.deleteAccount)
                } header: { groupHeader("Account") }

                Section {
                    NavigationLink(value: SettingsPageRoute.providerConnections) {
                        SettingsLabel(
                            icon: "externaldrive.connected.to.line.below",
                            color: MobileTheme.ember,
                            title: "Provider connections",
                            logoProviders: [.claudeCode, .openCode, .factory, .openAI]
                        )
                    }
                    .settingsAnchor(SettingsAnchor.providersRow)
                } header: { groupHeader("Providers") }

                Section {
                    NavigationLink(value: SettingsPageRoute.chatTiles) {
                        SettingsLabel(
                            icon: "bubble.left.and.bubble.right.fill",
                            color: MobileTheme.amber,
                            title: "Chat tiles",
                            logoProviders: [.hermes, .piAgent, .openClaw, .claudeCode, .codex]
                        )
                    }

                    NavigationLink(value: SettingsPageRoute.hermes) {
                        SettingsLabel(
                            icon: "antenna.radiowaves.left.and.right",
                            color: MobileTheme.hermesAureate,
                            title: "Hermes",
                            logoProviders: [.hermes]
                        )
                    }
                    .settingsAnchor(SettingsAnchor.hermesRow)

                    NavigationLink(value: SettingsPageRoute.pi) {
                        SettingsLabel(
                            icon: "circle.hexagongrid.fill",
                            color: MobileTheme.whimsy,
                            title: "Pi",
                            logoProviders: [.piAgent]
                        )
                    }
                    .settingsAnchor(SettingsAnchor.piRow)
                } header: { groupHeader("AI Environments") }

                Section {
                    HermesSquarePhaseAToggle()
                } header: { groupHeader("Experimental") } footer: {
                    Text("Hermes Square is the unified inbox + pinned grid + federated search surface that replaces the runtime pill. Phase A is the foundation; later phases ship dispatch fan-out, mini-program cards, and voice.")
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                }

                Section {
                    LabeledContent("Version", value: marketingVersion)
                        .settingsAnchor(SettingsAnchor.aboutVersion)
                    LabeledContent("Build", value: buildVersion)
                    Link(destination: URL(string: "https://openburnbar.com/legal/privacy-policy")!) {
                        SettingsLabel(icon: "hand.raised.fill", color: MobileTheme.whimsy, title: "Privacy policy")
                    }
                    .settingsAnchor(SettingsAnchor.aboutPrivacy)
                    Link(destination: URL(string: "https://openburnbar.com/legal/terms")!) {
                        SettingsLabel(icon: "doc.text.fill", color: MobileTheme.amber, title: "Terms of service")
                    }
                    .settingsAnchor(SettingsAnchor.aboutTerms)
                } header: { groupHeader("About") }
            }
            .scrollContentBackground(.hidden)
        }
    }

    private var deletionErrorBinding: Binding<Bool> {
        Binding(
            get: { accountDeletionError != nil },
            set: { if !$0 { accountDeletionError = nil } }
        )
    }

    private func deleteAccount() async {
        await authStore.deleteAccount()
        if let error = authStore.lastError {
            accountDeletionError = error.label
        }
    }

    private var subscriptionStore: HostedQuotaSubscriptionStore {
        sharedSubscriptionStore ?? localSubscriptionStore
    }

    @ViewBuilder
    private var cloudSettingsRow: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text("OpenBurnBar Cloud")
                    .font(MobileTheme.Typography.body)
                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                Text(cloudRowSubtitle)
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
                    .lineLimit(1)
            }
        } icon: {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(UnifiedDesignSystem.mercuryGradient)
                    .frame(width: 26, height: 26)
                Image(systemName: "cloud.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
    }

    private var cloudRowSubtitle: String {
        if subscriptionStore.isActive {
            if let expires = subscriptionStore.expirationDate {
                let formatted = expires.formatted(.dateTime.month(.abbreviated).day())
                return "Active · renews \(formatted)"
            }
            return "Active"
        }
        if let priceText = subscriptionStore.product?.displayPrice {
            return "Upgrade — \(priceText)/mo"
        }
        return "Quota, backups, Hermes — anywhere"
    }

    private func groupHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(MobileTheme.Typography.tiny)
            .fontWeight(.semibold)
            .tracking(1.4)
            .foregroundStyle(MobileTheme.Colors.textMuted)
    }

    private var marketingVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    private var buildVersion: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }
}

// MARK: - Settings Label

private struct SettingsLabel: View {
    let icon: String
    let color: Color
    let title: String
    var logoProviders: [AgentProvider] = []

    var body: some View {
        Label {
            Text(title)
                .font(MobileTheme.Typography.body)
                .foregroundStyle(MobileTheme.Colors.textPrimary)
        } icon: {
            if logoProviders.isEmpty {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(color)
                        .frame(width: 26, height: 26)
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                }
            } else {
                SettingsProviderLogoStack(providers: logoProviders, size: 26, maxVisible: 5)
            }
        }
    }
}
