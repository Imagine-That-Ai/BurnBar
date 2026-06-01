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
        // Native grouped Settings — the `Form` supplies the system grouped
        // background; the ZStack only swaps the live search results in.
        ZStack {
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
        case .account:
            SettingsDeepLinkScrollContainer(route: .account) { _ in
                AccountSettingsView(authStore: authStore)
            }
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
                    NavigationLink(value: SettingsPageRoute.account) {
                        SettingsProfileHeader(authStore: authStore, cloudStatus: bannerCloudStatus)
                    }
                }

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

                Section {
                    UIModePicker(selection: $uiMode)
                        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                        .settingsAnchor(SettingsAnchor.uiMode)
                        .listRowBackground(Color.clear)
                } header: { groupHeader("UI Mode") }

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
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                    .settingsAnchor(SettingsAnchor.dailyBudget)
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
                        SettingsLabel(icon: "gear", color: .gray, title: "Open system Notifications…")
                    }
                    .settingsAnchor(SettingsAnchor.openSystemNotifications)
                } header: { groupHeader("Notifications") }

                Section {
                    transcriptCacheSettingsControl
                        .settingsAnchor(SettingsAnchor.transcriptCache)
                } header: {
                    groupHeader("Storage")
                } footer: {
                    Text("Transcript cache stores encrypted stream downloads on this device only. Default limit is 250 MB.")
                }

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

                Section {
                    MissionFABResurrectToggle()
                } header: { groupHeader("Experimental") } footer: {
                    Text("The Mission Console orb toggle controls the floating action button. The orb auto-restores when an approval is waiting or a mission fails, regardless of this setting.")
                }

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
            }
        }
    }

    /// Status line shown under the account name in the profile banner.
    private var bannerCloudStatus: String {
        if authStore.currentIdentity == nil {
            return "Sign in to sync quota, backups & Hermes"
        }
        if subscriptionStore.isActive {
            return "OpenBurnBar Cloud · Active"
        }
        return "Free plan · Tap to upgrade"
    }

    private var subscriptionStore: HostedQuotaSubscriptionStore {
        sharedSubscriptionStore ?? localSubscriptionStore
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
                            .font(.body)
                            .foregroundStyle(.primary)
                        Text(transcriptCacheLimitLabel)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack {
                Label("Used", systemImage: "chart.pie")
                    .font(.callout)
                Spacer()
                Text(transcriptCacheUsageLabel)
                    .font(.callout)
                    .foregroundStyle(.secondary)
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
            .font(.callout)

            if let transcriptCacheStatus {
                Text(transcriptCacheStatus)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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

    /// Plain header text — the inset-grouped `Form` supplies the native
    /// uppercased, secondary-gray section-header styling automatically.
    private func groupHeader(_ title: String) -> some View {
        Text(title)
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
        if logoProviders.isEmpty {
            Label {
                Text(title)
                    .font(.body)
                    .foregroundStyle(.primary)
            } icon: {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(color)
                        .frame(width: 29, height: 29)
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
        } else {
            // A multi-logo preview is wider than a standard icon, so a `Label`
            // would overlap it onto the title. Lay it out explicitly so the
            // title always flows after the full width of the logo cluster.
            HStack(spacing: 12) {
                SettingsProviderLogoStack(providers: logoProviders, size: 24, maxVisible: 4)
                Text(title)
                    .font(.body)
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
        }
    }
}
