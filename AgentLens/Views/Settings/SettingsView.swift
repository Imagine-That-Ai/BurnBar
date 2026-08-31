import AppKit
import AuthenticationServices
import OpenBurnBarCore
import SwiftUI

// MARK: - Settings View

struct SettingsView: View {
    @Bindable var settingsManager: SettingsManager
    var accountManager: AccountManager
    var cloudSyncService: CloudSyncService?
    var iCloudSessionMirrorService: ICloudSessionMirrorService?
    var dataStore: DataStore
    var runtimeContext: OpenBurnBarRuntimeContext?
    let chatController: ChatSessionController?
    @Environment(\.dismiss) private var dismiss
    @State private var router: SettingsRouter
    @State private var presentationWindow: NSWindow?
    @State private var hermesRuntimeLauncher = HermesRuntimeLauncher()
    @State private var piAgentRuntimeAdapter = PiAgentRuntimeAdapter()
    @State private var isShowingDataControlCenter = false
    @State private var actionRegistry: SettingsActionRegistry?
    @State private var copilotController: SettingsCopilotController?
    @State private var cliBridge = CLIBridge()
    @State private var copilotMode = false
    @FocusState private var commandBarFocused: Bool

    init(
        settingsManager: SettingsManager,
        accountManager: AccountManager = .shared,
        cloudSyncService: CloudSyncService? = nil,
        iCloudSessionMirrorService: ICloudSessionMirrorService? = nil,
        dataStore: DataStore,
        runtimeContext: OpenBurnBarRuntimeContext? = nil,
        chatController: ChatSessionController? = nil,
        initialItemID: String? = nil
    ) {
        self._settingsManager = Bindable(settingsManager)
        self._router = State(initialValue: SettingsRouter(initialItemID: initialItemID))
        self.accountManager = accountManager
        self.cloudSyncService = cloudSyncService
        self.iCloudSessionMirrorService = iCloudSessionMirrorService
        self.dataStore = dataStore
        self.runtimeContext = runtimeContext
        self.chatController = chatController ?? runtimeContext?.chatController
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                commandBar
                    .accessibilityIdentifier(OBBAccessibilityID.settingsCommandBar)
                    .padding(.horizontal, DesignSystem.Spacing.md)
                    .padding(.top, DesignSystem.Spacing.sm)
                    .padding(.bottom, DesignSystem.Spacing.xs)

                List(selection: $router.selectedTab) {
                    // Home at top
                    NavigationLink(value: SettingsTab.home) {
                        sidebarRow(for: .home)
                    }
                    .tag(SettingsTab.home)
                    .accessibilityIdentifier(OBBAccessibilityID.settingsRow(SettingsTab.home.rawValue))

                    // Grouped sections
                    ForEach(SettingsSection.visibleSections) { section in
                        Section(section.title) {
                            ForEach(section.tabs.filter { SettingsTab.visibleTabs.contains($0) }) { tab in
                                NavigationLink(value: tab) {
                                    sidebarRow(for: tab)
                                }
                                .tag(tab)
                                .accessibilityIdentifier(OBBAccessibilityID.settingsRow(tab.rawValue))
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .accessibilityIdentifier(OBBAccessibilityID.settingsSidebar)
            }
            .navigationTitle("Settings")
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
            .onAppear {
                Analytics.shared.track(.screenViewed, ["surface": "settings"])
                setupCopilot()
                consumePendingSettingsDestination()
            }
        } detail: {
            NavigationStack(path: $router.path) {
                Group {
                    if copilotMode, let copilotController {
                        SettingsCopilotResultsView(router: router, copilot: copilotController)
                    } else if router.isSearching {
                        SettingsSearchResultsView(router: router)
                    } else {
                        detailContent
                    }
                }
                .navigationDestination(for: SettingsPageRoute.self) { route in
                    destination(for: route)
                }
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                            .keyboardShortcut(.cancelAction)
                    }
                }
            }
            .id(router.selectedTab)
            .environment(router)
        }
        .frame(
            minWidth: 820,
            idealWidth: 980,
            minHeight: 600,
            idealHeight: 720
        )
        .accessibilityIdentifier(OBBAccessibilityID.settingsRoot)
        .openBurnBarPreferredColorScheme(settingsManager.preferredSwiftUIColorScheme)
        .environment(settingsManager)
        .background(SettingsWindowReader(window: $presentationWindow))
        .sheet(isPresented: $isShowingDataControlCenter) {
            DataControlCenterView(accountManager: accountManager)
                .frame(minWidth: 980, minHeight: 680)
        }
        .onReceive(NotificationCenter.default.publisher(for: FeatureGateRouting.openCloudStoreNotification)) { _ in
            // A feature-gate unlock CTA fired while Settings is already open —
            // jump the live router straight to the Cloud store pane (the
            // parked `settings.pendingTab` only resolves on a fresh appear).
            router.selectedTab = .cloud
            router.path.removeAll()
            UserDefaults.standard.removeObject(forKey: SettingsDeepLinkRouting.pendingTabKey)
        }
        .onReceive(NotificationCenter.default.publisher(for: SettingsDeepLinkRouting.openSettingsItemNotification)) { notification in
            let itemID = notification.object as? String
            routeToSettingsItem(id: itemID)
        }
    }

    private var commandBar: some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            Image(systemName: copilotMode ? "sparkles" : "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(copilotMode ? DesignSystem.Colors.hermesAureate : DesignSystem.Colors.textMuted)
            TextField(copilotMode ? "Ask anything…" : "Search or ask — try: make it dark",
                      text: $router.query)
                .textFieldStyle(.plain)
                .font(DesignSystem.Typography.body)
                .focused($commandBarFocused)
                .accessibilityLabel("Search or ask the settings copilot")
                .onChange(of: router.query) { _, newValue in
                    copilotMode = false
                    copilotController?.updateSearchResults(query: newValue)
                }
                .onSubmit {
                    guard !router.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                    askCopilot()
                }
            if copilotMode || router.isSearching {
                Button {
                    copilotMode = false
                    router.reset()
                    copilotController?.reset()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear")
            } else {
                Button {
                    askCopilot()
                } label: {
                    Image(systemName: "sparkles")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DesignSystem.Colors.hermesAureate)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Ask copilot")
                .help("Ask the Settings Copilot")
            }
        }
        .padding(.horizontal, DesignSystem.Spacing.sm)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(DesignSystem.Colors.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(copilotMode
                                ? DesignSystem.Colors.hermesAureate.opacity(0.4)
                                : DesignSystem.Colors.borderSubtle,
                                lineWidth: copilotMode ? 1 : 0.5)
                )
        )
    }

    private func askCopilot() {
        guard let copilotController else { return }
        let query = router.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        copilotMode = true
        copilotController.updateSearchResults(query: query)
        Task { await copilotController.ask(query) }
    }

    private func sidebarRow(for tab: SettingsTab) -> some View {
        HStack(alignment: .center, spacing: DesignSystem.Spacing.md) {
            if !tab.logoProviders.isEmpty {
                SettingsProviderLogoStack(providers: tab.logoProviders, size: 26, maxVisible: 5)
                    .accessibilityHidden(true)
            } else {
                SettingsIconTile(
                    icon: tab.icon,
                    iconTint: tab.accentColor,
                    customIcon: tab.customIcon,
                    symbolSize: 13
                )
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(tab.title)
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text(tab.subtitle)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }

    /// Build the deep-link destination for a programmatic push from the
    /// search router. Each branch instantiates the same detail view that the
    /// natural drill-down would.
    @ViewBuilder
    private func destination(for route: SettingsPageRoute) -> some View {
        switch route {
        case .operatorModel:
            OperatorModelDetailView(
                settingsManager: settingsManager,
                dataStore: dataStore,
                setupGuide: setupGuideSnapshot
            )
        case .appearance:
            AppearanceSettingsDetailView(settingsManager: settingsManager)
        case .defaultView:
            DefaultViewSettingsDetailView(settingsManager: settingsManager)
        case .dataRefresh:
            DataRefreshSettingsDetailView(settingsManager: settingsManager)
        case .indexing:
            IndexingOverviewDetailView(
                settingsManager: settingsManager,
                dataStore: dataStore,
                sharedFeaturesAvailable: accountManager.isSignedIn,
                runtimeContext: runtimeContext
            )
        case .sessionSummaries:
            SessionSummariesDetailView(settingsManager: settingsManager)
        case .aiInboxRoot:
            AIInboxSettingsRootView()
                .navigationTitle("AI Inbox")
        case .daemonLifecycle:
            DaemonLifecycleDetailView(daemonManager: .shared)
        case .httpGateway:
            HTTPGatewayDetailView(settingsManager: settingsManager)
        case .controllerRuntime:
            ControllerRuntimeDetailView(settingsManager: settingsManager)
        case .hermesChatEngines:
            ChatEnginesDetailView(settingsManager: settingsManager)
        case .hermesGateway:
            HermesGatewayDetailView(
                settingsManager: settingsManager,
                hermesRuntimeLauncher: hermesRuntimeLauncher
            )
        case .hermesPiAgent:
            PiAgentDetailView(
                settingsManager: settingsManager,
                piAgentRuntimeAdapter: piAgentRuntimeAdapter
            )
        case .hermesRelay:
            RemoteRelayDetailView(settingsManager: settingsManager)
        case .hermesPiRelay:
            RemoteRelayPiDetailView(settingsManager: settingsManager)
        case .agentsAccounts:
            AgentsAccountsView(
                settingsManager: settingsManager,
                daemonManager: .shared,
                dataStore: dataStore,
                accountManager: accountManager
            )
        case .agentsCLIs:
            AgentsCLIsView(
                settingsManager: settingsManager,
                daemonManager: .shared,
                dataStore: dataStore,
                accountManager: accountManager
            )
        case .agentsRuntimes:
            AgentsRuntimesView(
                settingsManager: settingsManager,
                dataStore: dataStore,
                cloudSyncService: cloudSyncService,
                iCloudSessionMirrorService: iCloudSessionMirrorService
            )
        case .agentsModels:
            AgentsModelsView(
                settingsManager: settingsManager,
                daemonManager: .shared
            )
        case .agentsAdvanced:
            AgentsAdvancedView(
                settingsManager: settingsManager,
                daemonManager: .shared,
                dataStore: dataStore,
                accountManager: accountManager,
                cloudSyncService: cloudSyncService,
                iCloudSessionMirrorService: iCloudSessionMirrorService
            )
        case .analysisConfigurator:
            ElderWandConfiguratorView(controller: chatController, settingsManager: settingsManager)
        case .fusionImpact:
            // The standing fusion-spend screen reads `token_usage` through the
            // injected store. The fusion-search quota ring is fed separately
            // from the `openburnbar_elder_wand_fusion` quota snapshot; until the
            // macOS quota-sync workstream threads that bucket in, the ring
            // self-hides (passing `nil`).
            FusionImpactView(dataStore: dataStore)
        case .homeRoot, .generalRoot, .updatesRoot, .daemonRoot, .accountRoot, .cloudRoot,
             .agentsRoot, .modelProxyRoot,
             .connectionsRoot, .providersRoot, .routingPoolsRoot,
             .switcherRoot, .hermesRoot,
             .alertsRoot, .notificationsRoot, .devicesAndSyncRoot, .mediaRoot,
             .dataControlCenterRoot,
             .textExpansionRoot, .computerUseRoot, .petsRoot:
             // `.aiInboxRoot` is handled above so Indexing can drill into it.
            // Roots are reachable via the sidebar tab selection — the path
            // stays empty for these. Legacy roots (`connectionsRoot`,
            // `providersRoot`, `routingPoolsRoot`, `switcherRoot`,
            // `hermesRoot`) forward into the unified Agents tab via the
            // tab resolver.
            detailContent
        }
    }

    private var setupGuideSnapshot: OpenBurnBarSetupGuideSnapshot {
        OpenBurnBarSetupGuideBuilder.build(
            detection: settingsManager.detectAvailableProviders(),
            indexingEnabled: settingsManager.conversationIndexingEnabled,
            isSignedIn: accountManager.isSignedIn,
            conversationCloudEnabled: settingsManager.conversationCloudBackupEnabled,
            iCloudMirrorEnabled: settingsManager.iCloudSessionMirrorEnabled
        )
    }

    private func setupCopilot() {
        guard actionRegistry == nil else { return }
        let registry = SettingsActionRegistry(settingsManager: settingsManager, router: router)
        actionRegistry = registry
        copilotController = SettingsCopilotController(registry: registry, cliBridge: cliBridge)
    }

    private func consumePendingSettingsDestination() {
        if let itemID = UserDefaults.standard.string(forKey: SettingsDeepLinkRouting.pendingItemKey),
           routeToSettingsItem(id: itemID) {
            return
        }

        // Consume a deep-link tab parked in UserDefaults by callers like the
        // menu-bar popover whisper. Legacy raw values resolve into the unified
        // Agents tab so old links still land somewhere useful.
        if let raw = UserDefaults.standard.string(forKey: SettingsDeepLinkRouting.pendingTabKey),
           let tab = SettingsTab.resolving(legacyRawValue: raw) {
            router.selectedTab = tab
            router.path.removeAll()
            UserDefaults.standard.removeObject(forKey: SettingsDeepLinkRouting.pendingTabKey)
        }
    }

    @discardableResult
    private func routeToSettingsItem(id itemID: String?) -> Bool {
        guard itemID != nil else {
            return false
        }
        guard let item = SettingsDeepLinkRouting.item(matching: itemID) else {
            UserDefaults.standard.removeObject(forKey: SettingsDeepLinkRouting.pendingItemKey)
            return false
        }
        router.navigate(to: item)
        UserDefaults.standard.removeObject(forKey: SettingsDeepLinkRouting.pendingItemKey)
        UserDefaults.standard.removeObject(forKey: SettingsDeepLinkRouting.pendingTabKey)
        return true
    }

    @ViewBuilder
    private var detailContent: some View {
        switch router.selectedTab ?? .home {
        case .home:
            SettingsHomeView(
                settingsManager: settingsManager,
                accountManager: accountManager,
                dataStore: dataStore,
                daemonManager: .shared,
                cloudSyncService: cloudSyncService,
                runtimeContext: runtimeContext,
                router: router
            )
            .navigationTitle("Home")
        case .general:
            GeneralSettingsView(
                settingsManager: settingsManager,
                dataStore: dataStore,
                sharedFeaturesAvailable: accountManager.isSignedIn,
                cloudSyncService: cloudSyncService,
                iCloudSessionMirrorService: iCloudSessionMirrorService,
                runtimeContext: runtimeContext
            )
                .navigationTitle("General")
        case .aiInbox:
            AIInboxSettingsRootView()
                .navigationTitle("AI Inbox")
        case .updates:
            #if DISTRIBUTION_MAS
            Text("Updates are delivered through the Mac App Store.")
                .foregroundStyle(.secondary)
                .navigationTitle("Updates")
            #else
            UpdatesSettingsView()
                .navigationTitle("Updates")
            #endif
        case .daemon:
            DaemonSettingsView(settingsManager: settingsManager, dataStore: dataStore)
                .navigationTitle("Daemon")
        case .account:
            AccountSettingsView(
                currentUser: accountManager.currentUser,
                isAnonymous: accountManager.isAnonymousUser,
                isFirebaseAvailable: accountManager.isFirebaseAvailable,
                onLinkGoogle: {
                    try await accountManager.signInWithGoogle(presentingWindow: authPresentationWindow())
                },
                onEmailSignIn: { email, password in
                    try await accountManager.signInWithEmail(email: email, password: password)
                },
                onEmailSignUp: { email, password in
                    try await accountManager.signUpWithEmail(email: email, password: password)
                },
                onLinkApple: {
                    try await accountManager.signInWithApple(presentingWindow: authPresentationWindow())
                },
                onLinkGitHub: {
                    try await accountManager.signInWithGitHub(presentingWindow: authPresentationWindow())
                },
                onUpgradeToPremium: {
                    router.selectedTab = .cloud
                    router.path.removeAll()
                },
                onDeleteAccount: {
                    try await accountManager.deleteCurrentUser()
                },
                onSignOut: {
                    try accountManager.signOut()
                }
            )
            .navigationTitle("Account")
        case .cloud:
            CloudStoreSettingsView(
                settingsManager: settingsManager,
                accountManager: accountManager,
                dataStore: dataStore
            )
            .navigationTitle("OpenBurnBar Cloud")
        case .agents:
            AgentsSettingsView(
                settingsManager: settingsManager,
                daemonManager: .shared,
                dataStore: dataStore,
                accountManager: accountManager,
                cloudSyncService: cloudSyncService,
                iCloudSessionMirrorService: iCloudSessionMirrorService
            )
                .navigationTitle("Agents")
        case .modelProxy:
            ModelProxySettingsView(
                settingsManager: settingsManager,
                daemonManager: .shared,
                dataStore: dataStore,
                accountManager: accountManager
            )
            .navigationTitle("Model Proxy")
        case .alerts:
            AlertsSettingsView(settingsManager: settingsManager)
                .navigationTitle("Alerts")
        case .notifications:
            NotificationsSettingsView(settingsManager: settingsManager)
                .navigationTitle("Notifications")
        case .devicesAndSync:
            DevicesAndSyncSettingsView(
                settingsManager: settingsManager,
                runtimeContext: runtimeContext
            )
                .navigationTitle(MacCopy.devicesAndSyncTitle)
        case .textExpansion:
            TextExpansionSettingsView(
                settingsManager: settingsManager,
                dataStore: dataStore
            )
                .navigationTitle("Text Expansion")
        case .media:
            MediaPermissionsView()
                .navigationTitle("Media & Sharing")
        case .dataPrivacy:
            DataControlCenterSettingsLanding {
                isShowingDataControlCenter = true
            }
            .navigationTitle("Data & Privacy")
        case .computerUse:
            #if DISTRIBUTION_MAS
            MediaPermissionsView()
                .navigationTitle("Media & Sharing")
            #else
            ComputerUseSettingsView(runtimeController: runtimeContext?.computerUseRuntimeController)
                .navigationTitle("Computer Use")
            #endif
        case .pets:
            PetCompanionSettingsView(settingsManager: settingsManager)
                .navigationTitle("Pets")
        }
    }

    private func authPresentationWindow() throws -> NSWindow {
        let candidates = [presentationWindow, NSApp.keyWindow, NSApp.mainWindow]
            + NSApp.windows.filter { $0.title == "Settings" || $0.isVisible }
        guard let window = candidates.compactMap({ $0 }).first(where: { $0.isVisible && !$0.isMiniaturized }) else {
            throw AccountActionError.missingPresentationWindow
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        return window
    }
}

private struct PetCompanionSettingsView: View {
    @Bindable var settingsManager: SettingsManager
    @AppStorage(PetCompanionFeature.DefaultsKey.enabled)
    private var petEnabled = false
    @AppStorage(PetCompanionFeature.DefaultsKey.activePetID)
    private var activePetID = "claudecode"
    @AppStorage(PetCompanionFeature.DefaultsKey.activeAgent)
    private var activeAgentRaw = ChatBackendID.codex.rawValue

    private var bundledPets: [PetDefinition] {
        PetCatalog.bundledDefinitions()
    }

    private var activeAgentName: String {
        activeAgent.displayName
    }

    private var availableBackends: [ChatBackendID] {
        PetChatController.resolveAvailableBackends(enabled: settingsManager.enabledChatBackends)
    }

    private var activeAgent: ChatBackendID {
        let persisted = ChatBackendID(rawValue: activeAgentRaw) ?? .codex
        return availableBackends.contains(persisted) ? persisted : availableBackends.first ?? persisted
    }

    var body: some View {
        SettingsDeepLinkScrollContainer(route: .petsRoot) { _ in
            ScrollView {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xl) {
                    enableSection
                    petPickerSection
                    agentSection
                    summonSection
                }
                .padding(DesignSystem.Spacing.xl)
                .frame(maxWidth: 820, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var enableSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            SettingsSectionHeader(title: "DESKTOP COMPANION")
            SettingsToggle(
                title: "Show Desktop Pet",
                subtitle: "Keeps the floating companion available from launch and the summon hotkey.",
                icon: "pawprint.fill",
                isOn: Binding(
                    get: { petEnabled },
                    set: { enabled in
                        petEnabled = enabled
                        if enabled {
                            PetCompanionFeature.showCompanion()
                        } else {
                            PetCompanionFeature.runtime.controller.closeBubble()
                            PetCompanionFeature.hideCompanion()
                        }
                    }
                )
            )
            .padding(DesignSystem.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                    .fill(DesignSystem.Colors.surface.opacity(0.45))
            )
            .settingsAnchor(SettingsAnchor.petsCompanion)
        }
    }

    private var petPickerSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            SettingsSectionHeader(title: "PET")
            if bundledPets.isEmpty {
                unavailableRow(
                    icon: "pawprint",
                    title: "No bundled pets found",
                    detail: "The companion will fall back to the default pet when resources are available."
                )
            } else {
                PetFormPickerView(definitions: bundledPets, selectedPetID: $activePetID) { id, form in
                    PetCompanionFeature.selectPet(id: id, form: form)
                    if petEnabled {
                        PetCompanionFeature.showCompanion()
                    }
                }
                .frame(minHeight: 280, idealHeight: 420, maxHeight: 640)
                .padding(DesignSystem.Spacing.md)
                .background(
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                        .fill(DesignSystem.Colors.surface.opacity(0.35))
                )
            }
        }
    }

    private var agentSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            SettingsSectionHeader(title: "AGENT")
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    Image(systemName: "brain.head.profile")
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                    Text("Answering Agent")
                        .font(DesignSystem.Typography.body)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                        .layoutPriority(1)
                    Spacer()
                    Text(activeAgentName)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                PetAgentSwitcher(backends: availableBackends) { backend in
                    activeAgentRaw = backend.rawValue
                    PetCompanionFeature.runtime.controller.chat?.switchBackend(to: backend)
                }
            }
            .padding(DesignSystem.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                    .fill(DesignSystem.Colors.surface.opacity(0.45))
            )
        }
    }

    private var summonSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            SettingsSectionHeader(title: "CONTROLS")
            ViewThatFits(in: .horizontal) {
                HStack(spacing: DesignSystem.Spacing.md) {
                    summonButton
                    hideButton
                    hotkeyChip
                }
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                    HStack(spacing: DesignSystem.Spacing.md) {
                        summonButton
                        hideButton
                    }
                    hotkeyChip
                }
            }
        }
    }

    private var summonButton: some View {
        Button {
            petEnabled = true
            PetCompanionFeature.showCompanion()
            PetCompanionFeature.runtime.controller.openBubble()
        } label: {
            Label("Summon", systemImage: "sparkles")
        }
        .buttonStyle(.borderedProminent)
    }

    private var hideButton: some View {
        Button {
            petEnabled = false
            PetCompanionFeature.runtime.controller.closeBubble()
            PetCompanionFeature.hideCompanion()
        } label: {
            Label("Hide", systemImage: "eye.slash")
        }
        .buttonStyle(.bordered)
    }

    private var hotkeyChip: some View {
        Text(PetCompanionFeature.runtime.hotkey.combo.displayString)
            .font(DesignSystem.Typography.monoSmall)
            .foregroundStyle(DesignSystem.Colors.textSecondary)
            .padding(.horizontal, DesignSystem.Spacing.sm)
            .padding(.vertical, DesignSystem.Spacing.xs)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .fill(DesignSystem.Colors.surface.opacity(0.55))
            )
    }

    private func unavailableRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
            Image(systemName: icon)
                .foregroundStyle(DesignSystem.Colors.textMuted)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xxs) {
                Text(title)
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text(detail)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
        }
        .padding(DesignSystem.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                .fill(DesignSystem.Colors.surface.opacity(0.45))
        )
    }
}

private struct SettingsWindowReader: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            window = view.window
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            if window !== view.window {
                window = view.window
            }
        }
    }
}
private enum AccountActionError: LocalizedError {
    case missingPresentationWindow

    var errorDescription: String? {
        switch self {
        case .missingPresentationWindow:
            return "OpenBurnBar could not find a window to present the sign-in flow."
        }
    }
}

#Preview {
    let store = (try? DataStore()) ?? {
        preconditionFailure("Preview requires a valid DataStore - ensure app support directory is writable")
    }()
    SettingsView(settingsManager: SettingsManager(), dataStore: store)
}

private struct DataControlCenterSettingsLanding: View {
    let onOpen: () -> Void

    @StateObject private var entitlement = MacCloudEntitlementStore.shared

    /// The Data Vault / agent-memory workbench requires Cloud Pro. When the
    /// member doesn't yet hold it, the landing wears the evocative unlock veil
    /// over a blurred teaser of the workbench affordance instead of opening.
    private var isUnlocked: Bool {
        entitlement.cloudTier.satisfies(GatedFeature.gatedFeature(.dataVault).requiredTier)
    }

    var body: some View {
        Group {
            if isUnlocked {
                landingCard
            } else {
                FeatureLockedVeil(feature: GatedFeature.gatedFeature(.dataVault)) {
                    landingCard
                }
            }
        }
        .onAppear { entitlement.start() }
    }

    private var landingCard: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 0)
            VStack(spacing: 14) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 46, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.teal)
                Text("Data & Privacy Control Center")
                    .font(DesignSystem.Typography.title)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text("Open the dedicated Pensieve workbench for vault inventory, export, deletion, recovery setup, audit verification, and panic revoke. It runs outside the Settings split view so its own columns stay intact.")
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 560)
                Button(action: onOpen) {
                    Label("Open Data Control Center", systemImage: "arrow.up.right.square.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(DesignSystem.Colors.teal)
                .disabled(!isUnlocked)
                .settingsAnchor(SettingsAnchor.dataControlCenterInventory)
                Button {
                    _ = SettingsDeepLinkRouting.route(to: "cloud.memoryTour")
                    // Also open Settings to Cloud so the tour sheet is reachable
                    // even when the user taps this from an already-open Data &
                    // Privacy landing without going through search.
                    NotificationCenter.default.post(
                        name: Notification.Name("openburnbar.openSettingsItem"),
                        object: "cloud.memoryTour"
                    )
                } label: {
                    Label("How Memory works — one-minute tour", systemImage: "brain.head.profile")
                }
                .buttonStyle(.bordered)
                .tint(PensieveTheme.brassCore)
                .help("Take the Pensieve tour: what memory is, where to connect, how to recall, where to govern it")
            }
            .padding(32)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(DesignSystem.Colors.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .stroke(DesignSystem.Colors.borderSubtle, lineWidth: 1)
                    )
            )
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}
