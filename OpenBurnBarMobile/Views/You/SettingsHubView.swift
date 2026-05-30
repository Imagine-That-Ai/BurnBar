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
    @Environment(\.colorScheme) private var colorScheme
    @State private var localSubscriptionStore = HostedQuotaSubscriptionStore()
    @State private var didLoadLocalSubscription = false
    @State private var showDeleteAccountConfirmation = false
    @State private var accountDeletionError: String?
    @State private var showSignIn = false
    @State private var transcriptCacheLimitMegabytes = CloudTranscriptCacheSettings.shared.maxMegabytes
    @State private var transcriptCacheSnapshot = CloudTranscriptCacheSnapshot(
        usageBytes: 0,
        maxBytes: CloudTranscriptCacheSettings.shared.maxBytes
    )
    @State private var transcriptCacheStatus: String?
    @Environment(SettingsRouter.self) private var environmentRouter: SettingsRouter?
    @State private var localRouter = SettingsRouter()

    private var router: SettingsRouter {
        environmentRouter ?? localRouter
    }

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
    @AppStorage("costAlertThreshold") private var costAlertThreshold: Double = 25.0
    @AppStorage("usePremiumSOTAUX") private var usePremiumSOTAUX: Bool = false
    @AppStorage("useWebsiteBackground") private var useWebsiteBackground: Bool = false

    var body: some View {
        hubContent
            .environment(router)
    }

    @ViewBuilder
    private var hubContent: some View {
        @Bindable var router = router
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
        .sheet(isPresented: $showSignIn) {
            SignInScene(authStore: authStore)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .onChange(of: authStore.state.isSignedIn) { _, isSignedIn in
            if isSignedIn {
                showSignIn = false
            }
        }
        .task {
            if sharedSubscriptionStore == nil, !didLoadLocalSubscription {
                didLoadLocalSubscription = true
                await localSubscriptionStore.load()
            }
            await refreshTranscriptCacheSnapshot()
        }
        .onChange(of: transcriptCacheLimitMegabytes) { _, newValue in
            CloudTranscriptCacheSettings.shared.maxMegabytes = newValue
            transcriptCacheStatus = newValue <= 0 ? "Cache off" : "Cache limit saved"
            Task {
                await CloudTranscriptCache.shared.trimToLimit()
                await refreshTranscriptCacheSnapshot()
            }
        }
    }

    @ViewBuilder
    static func destination(for route: SettingsPageRoute, authStore: AuthStore) -> some View {
        switch route {
        case .hubRoot:
            EmptyView()
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
        case .media:
            SettingsDeepLinkScrollContainer(route: .media) { _ in
                MediaSettingsView()
            }
        case .textExpansion:
            SettingsDeepLinkScrollContainer(route: .textExpansion) { _ in
                MobileTextExpansionSettingsView()
            }
        case .theme:
            SettingsDeepLinkScrollContainer(route: .theme) { _ in
                ThemeSettingsView()
            }
        case .quotaCustomization:
            SettingsDeepLinkScrollContainer(route: .quotaCustomization) { _ in
                QuotaCustomizationSettingsView()
            }
        }
    }

    private var hubForm: some View {
        SettingsDeepLinkScrollContainer(route: .hubRoot) { _ in
            Form {
                Section {
                    NavigationLink(value: SettingsPageRoute.theme) {
                        SettingsLabel(icon: "paintpalette.fill", color: MobileTheme.amber, title: "Theme")
                    }
                    .settingsAnchor(SettingsAnchor.theme)

                    NavigationLink(value: SettingsPageRoute.quotaCustomization) {
                        SettingsLabel(icon: "gauge.with.dots.needle.67percent", color: MobileTheme.ember, title: "Quota Customization")
                    }
                    .settingsAnchor(SettingsAnchor.quotaCustomization)
                    Picker(selection: $usageDisplayMode) {
                        Text("Currency").tag("currency")
                        Text("Tokens").tag("tokens")
                    } label: {
                        SettingsLabel(icon: "number.square.fill", color: MobileTheme.ember, title: "Default display")
                    }
                    .settingsAnchor(SettingsAnchor.usageDisplay)

                    Toggle(isOn: $usePremiumSOTAUX) {
                        SettingsLabel(icon: "sparkles", color: MobileTheme.blaze, title: "Premium SOTA UX")
                    }
                    .tint(MobileTheme.ember)
                    .settingsAnchor(SettingsAnchor.usePremiumSOTAUX)

                    Toggle(isOn: $useWebsiteBackground) {
                        SettingsLabel(icon: "sparkles", color: MobileTheme.whimsy, title: "Swarm Background")
                    }
                    .tint(MobileTheme.ember)
                    .settingsAnchor(SettingsAnchor.useWebsiteBackground)
                } header: { groupHeader("Appearance") }
                .listRowBackground(Color.white.opacity(colorScheme == .dark ? 0.08 : 0.60))

                Section {
                    UIModePicker(selection: $uiMode)
                        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                        .listRowBackground(Color.clear)
                        .settingsAnchor(SettingsAnchor.uiMode)
                } header: { groupHeader("UI Mode") }
                .listRowBackground(Color.white.opacity(colorScheme == .dark ? 0.08 : 0.60))

                Section {
                    Button {
                        // Navigate to Insights tab → Budgets section
                        NotificationCenter.default.post(
                            name: .init("ShowInsightsTab"),
                            object: nil,
                            userInfo: ["section": "budgets"]
                        )
                    } label: {
                        HStack {
                            SettingsLabel(icon: "dollarsign.circle.fill", color: MobileTheme.amber, title: "Budget Center")
                            Spacer()
                            Text("Manage rules")
                                .font(MobileTheme.Typography.caption)
                                .foregroundStyle(MobileTheme.Colors.textSecondary)
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(MobileTheme.Colors.textMuted)
                        }
                    }
                    .buttonStyle(.plain)
                    .settingsAnchor(SettingsAnchor.dailyBudget)
                } header: { groupHeader("Budget") }
                .listRowBackground(Color.white.opacity(colorScheme == .dark ? 0.08 : 0.60))


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
                .listRowBackground(Color.white.opacity(colorScheme == .dark ? 0.08 : 0.60))

                Section {
                    NavigationLink(value: SettingsPageRoute.cloud) {
                        cloudSettingsRow
                    }
                    .settingsAnchor(SettingsAnchor.cloudRow)

                    transcriptCacheSettingsControl
                        .settingsAnchor(SettingsAnchor.transcriptCache)
                } header: {
                    groupHeader("Cloud")
                } footer: {
                    Text("Transcript cache stores encrypted stream downloads on this device only. Default limit is 250 MB.")
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                }
                .listRowBackground(Color.white.opacity(colorScheme == .dark ? 0.08 : 0.60))

                Section {
                    if let identity = authStore.currentIdentity {
                        LabeledContent("Signed in", value: identity.email ?? identity.displayName ?? "OpenBurnBar account")
                            .settingsAnchor(SettingsAnchor.accountRow)
                    } else {
                        Button {
                            showSignIn = true
                        } label: {
                            SettingsLabel(
                                icon: "person.crop.circle.badge.checkmark",
                                color: MobileTheme.ember,
                                title: "Sign in for Cloud"
                            )
                        }
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
                .listRowBackground(Color.white.opacity(colorScheme == .dark ? 0.08 : 0.60))

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
                .listRowBackground(Color.white.opacity(colorScheme == .dark ? 0.08 : 0.60))

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

                    // Mercury media — per-partner save preferences,
                    // iPad multi-cam toggle, stats overlay. Lives in
                    // its own row rather than nested under Hermes so
                    // the SKU rollout (`hosted_media_sync`) can be
                    // surfaced with its own privacy + entitlement copy.
                    NavigationLink(value: SettingsPageRoute.media) {
                        SettingsLabel(
                            icon: "play.rectangle.on.rectangle",
                            color: MobileTheme.hermesAureate,
                            title: "Media",
                            logoProviders: [.hermes]
                        )
                    }
                    .settingsAnchor(SettingsAnchor.mediaRow)

                    NavigationLink(value: SettingsPageRoute.textExpansion) {
                        SettingsLabel(
                            icon: "keyboard",
                            color: MobileTheme.ember,
                            title: "Text Expansion"
                        )
                    }
                    .settingsAnchor(SettingsAnchor.textExpansionRow)
                } header: { groupHeader("AI Environments") }
                .listRowBackground(Color.white.opacity(colorScheme == .dark ? 0.08 : 0.60))

                Section {
                    MissionFABResurrectToggle()
                } header: { groupHeader("Experimental") } footer: {
                    Text("The Mission Console orb toggle controls the floating action button. The orb auto-restores when an approval is waiting or a mission fails, regardless of this setting.")
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                }
                .listRowBackground(Color.white.opacity(colorScheme == .dark ? 0.08 : 0.60))

                Section {
                    LabeledContent("Version", value: marketingVersion)
                        .settingsAnchor(SettingsAnchor.aboutVersion)
                    LabeledContent("Build", value: buildVersion)
                    Link(destination: URL(string: "https://burnbar.ai/legal/privacy-policy")!) {
                        SettingsLabel(icon: "hand.raised.fill", color: MobileTheme.whimsy, title: "Privacy policy")
                    }
                    .settingsAnchor(SettingsAnchor.aboutPrivacy)
                    Link(destination: URL(string: "https://burnbar.ai/legal/terms")!) {
                        SettingsLabel(icon: "doc.text.fill", color: MobileTheme.amber, title: "Terms of service")
                    }
                    .settingsAnchor(SettingsAnchor.aboutTerms)
                } header: { groupHeader("About") }
                .listRowBackground(Color.white.opacity(colorScheme == .dark ? 0.08 : 0.60))
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

    @ViewBuilder
    private var transcriptCacheSettingsControl: some View {
        VStack(alignment: .leading, spacing: 12) {
            Stepper(value: $transcriptCacheLimitMegabytes, in: 0...CloudTranscriptCacheSettings.maximumMegabytes, step: 50) {
                HStack(spacing: 10) {
                    Image(systemName: "internaldrive")
                        .foregroundStyle(MobileTheme.ember)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Transcript cache")
                            .font(MobileTheme.Typography.body)
                            .foregroundStyle(MobileTheme.Colors.textPrimary)
                        Text(transcriptCacheLimitLabel)
                            .font(MobileTheme.Typography.tiny)
                            .foregroundStyle(MobileTheme.Colors.textMuted)
                    }
                }
            }

            HStack {
                Label("Used", systemImage: "chart.pie")
                    .font(MobileTheme.Typography.caption)
                Spacer()
                Text(transcriptCacheUsageLabel)
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
                    .monospacedDigit()
            }

            HStack(spacing: 12) {
                Button(role: .destructive) {
                    Task {
                        try? await CloudTranscriptCache.shared.clear()
                        transcriptCacheStatus = "Cache cleared"
                        await refreshTranscriptCacheSnapshot()
                    }
                } label: {
                    Label("Clear cache", systemImage: "trash")
                }
                .disabled(transcriptCacheSnapshot.usageBytes == 0)

                Button {
                    transcriptCacheLimitMegabytes = CloudTranscriptCacheSettings.defaultMaxMegabytes
                } label: {
                    Label("Use default", systemImage: "arrow.counterclockwise")
                }
                .disabled(transcriptCacheLimitMegabytes == CloudTranscriptCacheSettings.defaultMaxMegabytes)
            }
            .font(MobileTheme.Typography.caption)

            if let transcriptCacheStatus {
                Text(transcriptCacheStatus)
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
            }
        }
        .onAppear {
            transcriptCacheLimitMegabytes = CloudTranscriptCacheSettings.shared.maxMegabytes
        }
    }

    private var transcriptCacheLimitLabel: String {
        if transcriptCacheLimitMegabytes <= 0 { return "Off" }
        return CloudTranscriptCacheSettings.formatBytes(
            Int64(transcriptCacheLimitMegabytes) * CloudTranscriptCacheSettings.bytesPerMegabyte
        )
    }

    private var transcriptCacheUsageLabel: String {
        if transcriptCacheSnapshot.isDisabled {
            return "\(CloudTranscriptCacheSettings.formatBytes(transcriptCacheSnapshot.usageBytes)) / Off"
        }
        return "\(CloudTranscriptCacheSettings.formatBytes(transcriptCacheSnapshot.usageBytes)) / \(CloudTranscriptCacheSettings.formatBytes(transcriptCacheSnapshot.maxBytes))"
    }

    private func refreshTranscriptCacheSnapshot() async {
        transcriptCacheSnapshot = await CloudTranscriptCache.shared.snapshot()
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

struct SettingsLabel: View {
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
