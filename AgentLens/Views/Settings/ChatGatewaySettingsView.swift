import SwiftUI

// MARK: - Hermes & Chat Settings (iOS-style landing)

/// Drill-down landing for the Hermes tab. Splits the previously-stacked
/// Hermes/Pi/OpenClaw/Inventory cards into focused subscreens so each row in
/// the landing reads like an iOS Settings entry: title + subtitle + status.
struct ChatGatewaySettingsView: View {
    @Bindable var settingsManager: SettingsManager
    private let dataStore: DataStore
    private let cloudSyncService: CloudSyncService?
    private let iCloudSessionMirrorService: ICloudSessionMirrorService?
    @State private var inventoryImportService: HermesInventoryImportService
    @State private var hermesRuntimeLauncher: HermesRuntimeLauncher
    @State private var piAgentRuntimeAdapter: PiAgentRuntimeAdapter

    init(
        settingsManager: SettingsManager,
        dataStore: DataStore,
        cloudSyncService: CloudSyncService? = nil,
        iCloudSessionMirrorService: ICloudSessionMirrorService? = nil
    ) {
        self._settingsManager = Bindable(settingsManager)
        self.dataStore = dataStore
        self.cloudSyncService = cloudSyncService
        self.iCloudSessionMirrorService = iCloudSessionMirrorService
        self._hermesRuntimeLauncher = State(initialValue: HermesRuntimeLauncher())
        let preferredInstance: String? = {
            let trimmed = settingsManager.piAgentSelectedInstanceID.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }()
        let redisURL: URL? = {
            let trimmed = settingsManager.piAgentRedisURL.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : URL(string: trimmed)
        }()
        self._piAgentRuntimeAdapter = State(initialValue: PiAgentRuntimeAdapter(
            preferredInstanceID: preferredInstance,
            redisURL: redisURL
        ))
        self._inventoryImportService = State(initialValue: HermesInventoryImportService(
            dataStore: dataStore,
            settingsManager: settingsManager,
            cloudSyncService: cloudSyncService,
            iCloudMirrorService: iCloudSessionMirrorService
        ))
    }

    var body: some View {
        List {
            Section {
                NavigationLink {
                    ChatEnginesDetailView(settingsManager: settingsManager)
                } label: {
                    SettingsDrillRow(
                        icon: "cpu",
                        iconTint: DesignSystem.Colors.whimsy,
                        title: "Chat Engines",
                        subtitle: "Which engines appear in the dashboard and menu-bar chat header",
                        value: "\(settingsManager.enabledChatBackends.count) on",
                        logoProviders: [.hermes, .piAgent, .openClaw, .claudeCode, .codex]
                    )
                }
            } header: {
                Text("Engines")
            } footer: {
                Text("Toggle the engines you want OpenBurnBar to surface. Configuration for each engine lives in its own row below.")
                    .font(DesignSystem.Typography.tiny)
            }

            Section {
                NavigationLink {
                    HermesGatewayDetailView(
                        settingsManager: settingsManager,
                        hermesRuntimeLauncher: hermesRuntimeLauncher
                    )
                } label: {
                    SettingsDrillRow(
                        icon: "antenna.radiowaves.left.and.right",
                        iconTint: DesignSystem.Colors.hermesAureate,
                        title: "Hermes Gateway",
                        subtitle: "Local webapi on :8642, auto-launch with OpenBurnBar",
                        value: settingsManager.launchHermesWithOpenBurnBar ? "Auto" : "Manual",
                        valueTint: settingsManager.launchHermesWithOpenBurnBar
                            ? DesignSystem.Colors.success
                            : DesignSystem.Colors.textMuted,
                        logoProvider: .hermes
                    )
                }

                NavigationLink {
                    PiAgentDetailView(
                        settingsManager: settingsManager,
                        piAgentRuntimeAdapter: piAgentRuntimeAdapter
                    )
                } label: {
                    SettingsDrillRow(
                        icon: "circle.hexagongrid.fill",
                        iconTint: DesignSystem.Colors.purple,
                        title: "Pi Agent Instances",
                        subtitle: "Pi gateway endpoint, optional Redis, instance selection",
                        value: settingsManager.launchPiAgentsWithOpenBurnBar ? "Auto" : "Manual",
                        valueTint: settingsManager.launchPiAgentsWithOpenBurnBar
                            ? DesignSystem.Colors.success
                            : DesignSystem.Colors.textMuted,
                        logoProvider: .piAgent
                    )
                }

                NavigationLink {
                    OpenClawGatewayDetailView(settingsManager: settingsManager)
                } label: {
                    SettingsDrillRow(
                        icon: "network.badge.shield.half.filled",
                        iconTint: DesignSystem.Colors.teal,
                        title: "OpenClaw Gateway",
                        subtitle: "OpenAI-compatible gateway (default 127.0.0.1:18789)",
                        value: openClawHostDisplay,
                        logoProvider: .openClaw
                    )
                }

                NavigationLink {
                    RemoteRelayDetailView(settingsManager: settingsManager)
                } label: {
                    SettingsDrillRow(
                        icon: "iphone.radiowaves.left.and.right",
                        iconTint: DesignSystem.Colors.coral,
                        title: "Hermes Remote Relay",
                        subtitle: "Let iPhone and iPad chat with this Mac's Hermes over the network",
                        value: settingsManager.hermesRemoteRelayEnabled ? "On" : "Off",
                        valueTint: settingsManager.hermesRemoteRelayEnabled
                            ? DesignSystem.Colors.success
                            : DesignSystem.Colors.textMuted,
                        logoProvider: .hermes
                    )
                }

                NavigationLink {
                    RemoteRelayPiDetailView(settingsManager: settingsManager)
                } label: {
                    SettingsDrillRow(
                        icon: "iphone.gen3.radiowaves.left.and.right",
                        iconTint: DesignSystem.Colors.purple,
                        title: "Pi Remote Relay",
                        subtitle: "Let iPhone and iPad chat with this Mac's Pi over the network",
                        value: settingsManager.piRemoteRelayEnabled ? "On" : "Off",
                        valueTint: settingsManager.piRemoteRelayEnabled
                            ? DesignSystem.Colors.success
                            : DesignSystem.Colors.textMuted,
                        logoProvider: .piAgent
                    )
                }
            } header: {
                Text("Gateways")
            }

            Section {
                NavigationLink {
                    HermesInventoryImportDetailView(
                        inventoryImportService: inventoryImportService
                    )
                } label: {
                    SettingsDrillRow(
                        icon: "tray.and.arrow.down.fill",
                        iconTint: DesignSystem.Colors.hermesAureate,
                        title: "Import Hermes Chats",
                        subtitle: "Bring pre-OpenBurnBar Hermes conversations into the local index",
                        value: inventoryStatusValue,
                        logoProvider: .hermes
                    )
                }

                NavigationLink {
                    HermesSetupDetailView(
                        settingsManager: settingsManager,
                        dataStore: dataStore,
                        cloudSyncService: cloudSyncService,
                        iCloudSessionMirrorService: iCloudSessionMirrorService
                    )
                } label: {
                    SettingsDrillRow(
                        icon: "wand.and.stars",
                        iconTint: DesignSystem.Colors.amber,
                        title: "Setup Assistant",
                        subtitle: "Guided Hermes setup, mark onboarding complete",
                        value: settingsManager.hermesSetupWizardCompleted ? "Done" : "Pending",
                        valueTint: settingsManager.hermesSetupWizardCompleted
                            ? DesignSystem.Colors.success
                            : DesignSystem.Colors.warning,
                        logoProvider: .hermes
                    )
                }
            } header: {
                Text("Import & setup")
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .background(DesignSystem.Colors.background)
        .navigationTitle("AI Environments")
    }

    private var openClawHostDisplay: String {
        let raw = settingsManager.openClawGatewayBaseURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, let url = URL(string: raw), let host = url.host else {
            return "Not set"
        }
        if let port = url.port { return "\(host):\(port)" }
        return host
    }

    private var inventoryStatusValue: String {
        switch inventoryImportService.phase {
        case .scanning: return "Scanning"
        case .importing: return "Importing"
        case .complete: return "Imported"
        case .failed: return "Error"
        case .ready: return "Ready"
        case .idle:
            return inventoryImportService.hasImportableInventory ? "Ready" : "—"
        }
    }
}

// MARK: - Chat Engines Detail

struct ChatEnginesDetailView: View {
    @Bindable var settingsManager: SettingsManager

    var body: some View {
        SettingsDetailContainer(
            title: "Chat Engines",
            subtitle: "Only the engines you enable here appear in the dashboard and menu bar chat header.",
            searchRoute: .hermesChatEngines
        ) {
            GlassCard {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                    ForEach(ChatBackendID.allCases) { backend in
                        Toggle(isOn: Binding(
                            get: { settingsManager.enabledChatBackends.contains(backend) },
                            set: { settingsManager.setChatBackendEnabled(backend, enabled: $0) }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(backend.displayName)
                                    .font(DesignSystem.Typography.body)
                                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                                Text(engineSubtitle(backend))
                                    .font(DesignSystem.Typography.tiny)
                                    .foregroundStyle(DesignSystem.Colors.textMuted)
                            }
                        }
                        if backend != ChatBackendID.allCases.last {
                            Divider().background(DesignSystem.Colors.border)
                        }
                    }
                }
                .padding(DesignSystem.Spacing.lg)
            }
            .settingsAnchor(SettingsAnchor.hermesConnections)

            // MARK: Hermes model picker — second-level row under Hermes.

            VStack(alignment: .leading, spacing: 4) {
                Text("Hermes models")
                    .font(DesignSystem.Typography.headline)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text("Shown in the secondary row beneath the strip when Hermes is the active surface.")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
            .padding(.top, DesignSystem.Spacing.lg)

            GlassCard {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                    ForEach(HermesModelID.allCases) { model in
                        Toggle(isOn: Binding(
                            get: { settingsManager.enabledHermesModels.contains(model) },
                            set: { settingsManager.setHermesModelEnabled(model, enabled: $0) }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.displayName)
                                    .font(DesignSystem.Typography.body)
                                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                                Text(hermesModelSubtitle(model))
                                    .font(DesignSystem.Typography.tiny)
                                    .foregroundStyle(DesignSystem.Colors.textMuted)
                            }
                        }
                        if model != HermesModelID.allCases.last {
                            Divider().background(DesignSystem.Colors.border)
                        }
                    }
                }
                .padding(DesignSystem.Spacing.lg)
            }
            .settingsAnchor(SettingsAnchor.hermesModels)
        }
    }

    private func hermesModelSubtitle(_ model: HermesModelID) -> String {
        switch model {
        case .codex:   return "Hermes routes through your local Codex CLI"
        case .claude:  return "Hermes routes through your local Claude Code CLI"
        case .zai:     return "Hermes routes through Z.ai (GLM)"
        case .kimi:    return "Hermes routes through Kimi (Moonshot)"
        case .minimax: return "Hermes routes through MiniMax Coding Plan"
        case .ollama:  return "Hermes routes through local Ollama"
        }
    }

    private func engineSubtitle(_ backend: ChatBackendID) -> String {
        switch backend {
        case .hermes: return "Local Hermes webapi (recommended)"
        case .piAgent: return "Pi agent via the Pi gateway"
        case .openclaw: return "OpenClaw OpenAI-compatible gateway"
        case .codex: return "Local Codex CLI session"
        case .claude: return "Local Claude Code CLI session"
        }
    }
}

// MARK: - Hermes Gateway Detail

struct HermesGatewayDetailView: View {
    @Bindable var settingsManager: SettingsManager
    @Bindable var hermesRuntimeLauncher: HermesRuntimeLauncher

    var body: some View {
        SettingsDetailContainer(
            title: "Hermes Gateway",
            subtitle: "OpenBurnBar can start the Hermes Dashboard and local API gateway for you. The gateway defaults to port 8642.",
            searchRoute: .hermesGateway
        ) {
            GlassCard {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                    HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                        ZStack {
                            Circle()
                                .fill(hermesRuntimeLauncher.status.gatewayRunning
                                    ? DesignSystem.Colors.success.opacity(0.16)
                                    : DesignSystem.Colors.surface)
                                .frame(width: 34, height: 34)
                            if hermesRuntimeLauncher.isBusy {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: hermesRuntimeLauncher.status.gatewayRunning ? "checkmark" : "power")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(hermesRuntimeLauncher.status.gatewayRunning
                                        ? DesignSystem.Colors.success
                                        : DesignSystem.Colors.hermesAureate)
                            }
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text(hermesRuntimeLauncher.status.message)
                                .font(DesignSystem.Typography.caption)
                                .foregroundStyle(hermesRuntimeLauncher.lastError == nil
                                    ? DesignSystem.Colors.textPrimary
                                    : DesignSystem.Colors.error)
                                .fixedSize(horizontal: false, vertical: true)

                            if let path = hermesRuntimeLauncher.status.hermesCLIPath {
                                Text(path)
                                    .font(DesignSystem.Typography.monoTiny)
                                    .foregroundStyle(DesignSystem.Colors.textMuted)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }

                        Spacer()
                    }

                    HStack(spacing: DesignSystem.Spacing.sm) {
                        Button {
                            Task { await openHermes() }
                        } label: {
                            Label("Open Hermes + Gateway", systemImage: "play.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(DesignSystem.Colors.hermesAureate)
                        .disabled(hermesRuntimeLauncher.isBusy)

                        Button {
                            Task { await refreshHermes() }
                        } label: {
                            Label("Check Health", systemImage: "waveform.path.ecg")
                        }
                        .buttonStyle(.bordered)
                        .disabled(hermesRuntimeLauncher.isBusy)
                    }
                    .controlSize(.small)
                    .font(DesignSystem.Typography.caption)

                    Toggle("Launch Hermes Dashboard and gateway when OpenBurnBar opens",
                           isOn: $settingsManager.launchHermesWithOpenBurnBar)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                }
                .padding(DesignSystem.Spacing.lg)
            }

            GlassCard {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                        fieldLabel("Base URL")
                        TextField("http://localhost:8642", text: $settingsManager.hermesGatewayBaseURL)
                            .textFieldStyle(.roundedBorder)
                    }
                    .settingsAnchor(SettingsAnchor.hermesGatewayURL)

                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                        fieldLabel("Bearer Token")
                        SecureField("Same as API_SERVER_KEY (leave empty if unset)",
                                    text: $settingsManager.hermesBearerToken)
                            .textFieldStyle(.roundedBorder)
                    }
                    .settingsAnchor(SettingsAnchor.hermesGatewayToken)

                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                        fieldLabel("Model Override")
                        TextField("Leave empty for auto (e.g. gpt-5.5)",
                                  text: $settingsManager.hermesChatModelOverride)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                    .padding(DesignSystem.Spacing.lg)
            }
        }
        .task { await refreshHermes() }
    }

    private func refreshHermes() async {
        _ = await hermesRuntimeLauncher.refreshStatus(
            baseURL: resolvedBaseURL,
            bearerToken: resolvedBearer
        )
    }

    private func openHermes() async {
        _ = await hermesRuntimeLauncher.openHermesAndGateway(
            baseURL: resolvedBaseURL,
            bearerToken: resolvedBearer
        )
    }

    private var resolvedBaseURL: URL {
        URL(string: settingsManager.hermesGatewayBaseURL.trimmingCharacters(in: .whitespacesAndNewlines))
            ?? URL(string: "http://127.0.0.1:8642")!
    }

    private var resolvedBearer: String? {
        let token = settingsManager.hermesBearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }
}

// MARK: - Pi Agent Detail

struct PiAgentDetailView: View {
    @Bindable var settingsManager: SettingsManager
    @Bindable var piAgentRuntimeAdapter: PiAgentRuntimeAdapter

    var body: some View {
        SettingsDetailContainer(
            title: "Pi Agent Instances",
            subtitle: "OpenBurnBar can start the Pi agent and its local API gateway. Redis is optional and only used for richer multi-instance discovery and control.",
            searchRoute: .hermesPiAgent
        ) {
            GlassCard {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                    HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                        ZStack {
                            Circle()
                                .fill(piAgentRuntimeAdapter.managedStatus.gatewayRunning
                                    ? DesignSystem.Colors.success.opacity(0.16)
                                    : DesignSystem.Colors.surface)
                                .frame(width: 34, height: 34)
                            if piAgentRuntimeAdapter.isBusy {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: piAgentRuntimeAdapter.managedStatus.gatewayRunning ? "checkmark" : "power")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(piAgentRuntimeAdapter.managedStatus.gatewayRunning
                                        ? DesignSystem.Colors.success
                                        : DesignSystem.Colors.purple)
                            }
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text(piAgentRuntimeAdapter.managedStatus.message)
                                .font(DesignSystem.Typography.caption)
                                .foregroundStyle(piAgentRuntimeAdapter.lastError == nil
                                    ? DesignSystem.Colors.textPrimary
                                    : DesignSystem.Colors.error)
                                .fixedSize(horizontal: false, vertical: true)

                            if let redis = piAgentRuntimeAdapter.managedStatus.redisStatus, !redis.isEmpty {
                                Text(redis)
                                    .font(DesignSystem.Typography.tiny)
                                    .foregroundStyle(DesignSystem.Colors.textMuted)
                            }

                            if let path = piAgentRuntimeAdapter.managedStatus.executablePath {
                                Text(path)
                                    .font(DesignSystem.Typography.monoTiny)
                                    .foregroundStyle(DesignSystem.Colors.textMuted)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }

                        Spacer()
                    }

                    HStack(spacing: DesignSystem.Spacing.sm) {
                        Button {
                            Task { await openPi() }
                        } label: {
                            Label("Open Pi + Gateway", systemImage: "play.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(DesignSystem.Colors.purple)
                        .disabled(piAgentRuntimeAdapter.isBusy)

                        Button {
                            Task { await refreshPi() }
                        } label: {
                            Label("Check Health", systemImage: "waveform.path.ecg")
                        }
                        .buttonStyle(.bordered)
                        .disabled(piAgentRuntimeAdapter.isBusy)
                    }
                    .controlSize(.small)
                    .font(DesignSystem.Typography.caption)

                    Toggle("Launch Pi agent and gateway when OpenBurnBar opens",
                           isOn: $settingsManager.launchPiAgentsWithOpenBurnBar)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                }
                .padding(DesignSystem.Spacing.lg)
            }

            GlassCard {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                        fieldLabel("Base URL")
                        TextField("http://127.0.0.1:8765", text: $settingsManager.piAgentGatewayBaseURL)
                            .textFieldStyle(.roundedBorder)
                    }
                    .settingsAnchor(SettingsAnchor.hermesPiHosts)

                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                        fieldLabel("Bearer Token")
                        SecureField("Optional bearer token", text: $settingsManager.piAgentBearerToken)
                            .textFieldStyle(.roundedBorder)

                        fieldLabel("Redis URL (optional)")
                        TextField("redis://127.0.0.1:6379/0", text: $settingsManager.piAgentRedisURL)
                            .textFieldStyle(.roundedBorder)

                        fieldLabel("Model Override")
                        TextField("Leave empty for gateway default",
                                  text: $settingsManager.piAgentChatModelOverride)
                            .textFieldStyle(.roundedBorder)

                        instancePicker
                    }
                }
                    .padding(DesignSystem.Spacing.lg)
            }
        }
        .task { await refreshPi() }
    }

    @ViewBuilder
    private var instancePicker: some View {
        let instances = piAgentRuntimeAdapter.managedStatus.instances
        if !instances.isEmpty {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                fieldLabel("Active Instance")
                Picker("Active instance", selection: Binding(
                    get: {
                        let stored = settingsManager.piAgentSelectedInstanceID
                        if instances.contains(where: { $0.id == stored }) { return stored }
                        return instances.first?.id ?? ""
                    },
                    set: { newValue in
                        settingsManager.piAgentSelectedInstanceID = newValue
                        piAgentRuntimeAdapter.preferredInstanceID = newValue.isEmpty ? nil : newValue
                    }
                )) {
                    ForEach(instances) { inst in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(inst.isOnline ? DesignSystem.Colors.success : DesignSystem.Colors.textMuted)
                                .frame(width: 6, height: 6)
                            Text(inst.displayName)
                            if let session = inst.activeSessionID {
                                Text("(\(session))")
                                    .foregroundStyle(DesignSystem.Colors.textMuted)
                            }
                        }
                        .tag(inst.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
        }
    }

    private func refreshPi() async {
        syncAdapter()
        _ = await piAgentRuntimeAdapter.refreshManagedStatus(
            baseURL: resolvedPiBaseURL,
            bearerToken: resolvedPiBearer
        )
    }

    private func openPi() async {
        syncAdapter()
        _ = await piAgentRuntimeAdapter.openManagedRuntime(
            baseURL: resolvedPiBaseURL,
            bearerToken: resolvedPiBearer
        )
    }

    private func syncAdapter() {
        let preferred = settingsManager.piAgentSelectedInstanceID.trimmingCharacters(in: .whitespacesAndNewlines)
        piAgentRuntimeAdapter.preferredInstanceID = preferred.isEmpty ? nil : preferred
        let redisRaw = settingsManager.piAgentRedisURL.trimmingCharacters(in: .whitespacesAndNewlines)
        piAgentRuntimeAdapter.redisURL = redisRaw.isEmpty ? nil : URL(string: redisRaw)
    }

    private var resolvedPiBaseURL: URL {
        URL(string: settingsManager.piAgentGatewayBaseURL.trimmingCharacters(in: .whitespacesAndNewlines))
            ?? URL(string: "http://127.0.0.1:8765")!
    }

    private var resolvedPiBearer: String? {
        let token = settingsManager.piAgentBearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }
}

// MARK: - OpenClaw Gateway Detail

struct OpenClawGatewayDetailView: View {
    @Bindable var settingsManager: SettingsManager

    var body: some View {
        SettingsDetailContainer(
            title: "OpenClaw Gateway",
            subtitle: "OpenAI-compatible gateway, default 127.0.0.1:18789."
        ) {
            GlassCard {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                    fieldLabel("Base URL")
                    TextField("http://127.0.0.1:18789", text: $settingsManager.openClawGatewayBaseURL)
                        .textFieldStyle(.roundedBorder)

                    fieldLabel("Bearer Token")
                    SecureField("Optional bearer token", text: $settingsManager.openClawBearerToken)
                        .textFieldStyle(.roundedBorder)
                }
                .padding(DesignSystem.Spacing.lg)
            }
        }
    }
}

// MARK: - Remote Relay Detail

struct RemoteRelayDetailView: View {
    @Bindable var settingsManager: SettingsManager

    var body: some View {
        SettingsDetailContainer(
            title: "Remote Relay",
            subtitle: "Premium accounts can use this Mac as a private Remote Relay host so iPhone and iPad can chat with local Hermes over cell signal. The API_SERVER_KEY stays on this Mac; OpenBurnBar relays only encrypted request and response frames.",
            searchRoute: .hermesRelay
        ) {
            GlassCard {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                    SettingsToggle(
                        title: "Allow iPhone/iPad Remote Relay",
                        subtitle: "Enables relaying Hermes chat through this Mac to mobile clients.",
                        icon: "iphone.radiowaves.left.and.right",
                        isOn: $settingsManager.hermesRemoteRelayEnabled
                    )

                    DisclosureGroup("Advanced relay endpoint") {
                        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                            Text("OpenBurnBar uses the hosted relay automatically for premium accounts. Change this only for development or self-hosted staging.")
                                .font(DesignSystem.Typography.caption)
                                .foregroundStyle(DesignSystem.Colors.textMuted)
                                .fixedSize(horizontal: false, vertical: true)

                            TextField("Hosted relay URL", text: $settingsManager.hermesRealtimeRelayURL)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                    .font(DesignSystem.Typography.caption)
                }
                .padding(DesignSystem.Spacing.lg)
            }
            .settingsAnchor(SettingsAnchor.hermesRelay)
        }
    }
}

// MARK: - Remote Relay (Pi) Detail
//
// Sibling of `RemoteRelayDetailView` for the Pi runtime. Mirrors Hermes copy
// and controls but writes to `piRemoteRelayEnabled` / `piRealtimeRelayURL`
// so users can enable Pi Remote Relay independently. Plan 2 §8 — the relay
// service multiplexes by `runtime` discriminator so a single Cloud Run host
// handles both runtimes.

struct RemoteRelayPiDetailView: View {
    @Bindable var settingsManager: SettingsManager

    var body: some View {
        SettingsDetailContainer(
            title: "Pi Remote Relay",
            subtitle: "Premium accounts can use this Mac as a private Remote Relay host so iPhone and iPad can chat with local Pi over cell signal. Bearer tokens stay on this Mac; OpenBurnBar relays only encrypted request and response frames.",
            searchRoute: .hermesPiRelay
        ) {
            GlassCard {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                    SettingsToggle(
                        title: "Allow iPhone/iPad Remote Relay for Pi",
                        subtitle: "Enables relaying Pi chat through this Mac to mobile clients.",
                        icon: "iphone.gen3.radiowaves.left.and.right",
                        isOn: $settingsManager.piRemoteRelayEnabled
                    )

                    DisclosureGroup("Advanced relay endpoint") {
                        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                            Text("OpenBurnBar uses the hosted relay automatically for premium accounts. Change this only for development or self-hosted staging.")
                                .font(DesignSystem.Typography.caption)
                                .foregroundStyle(DesignSystem.Colors.textMuted)
                                .fixedSize(horizontal: false, vertical: true)

                            TextField("Hosted relay URL", text: $settingsManager.piRealtimeRelayURL)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                    .font(DesignSystem.Typography.caption)
                }
                .padding(DesignSystem.Spacing.lg)
            }
            .settingsAnchor(SettingsAnchor.hermesPiRelay)
        }
    }
}

// MARK: - Inventory Import Detail

struct HermesInventoryImportDetailView: View {
    @Bindable var inventoryImportService: HermesInventoryImportService

    var body: some View {
        SettingsDetailContainer(
            title: "Import Hermes Chats",
            subtitle: "Bring your pre-OpenBurnBar Hermes conversations into the local index, then optionally back them up so iPhone and iPad can read them."
        ) {
            GlassCard {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                    Text(inventoryImportService.primaryStatusText)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(statusColor)

                    if inventoryImportService.hasImportableInventory {
                        HStack(spacing: DesignSystem.Spacing.md) {
                            metric("Chats", "\(inventoryImportService.summary.conversationCount)")
                            metric("Usage rows", "\(inventoryImportService.summary.usageEventCount)")
                            if let last = inventoryImportService.summary.lastActivityAt {
                                metric("Latest", last.formatted(date: .abbreviated, time: .omitted))
                            }
                        }

                        Toggle("Back up to OpenBurnBar Cloud for iPhone/iPad", isOn: Binding(
                            get: { inventoryImportService.decision.backupToOpenBurnBarCloud },
                            set: { inventoryImportService.decision.backupToOpenBurnBarCloud = $0 }
                        ))
                        .font(DesignSystem.Typography.caption)

                        Toggle("Mirror raw Hermes files to iCloud Drive", isOn: Binding(
                            get: { inventoryImportService.decision.mirrorToICloud },
                            set: { inventoryImportService.decision.mirrorToICloud = $0 }
                        ))
                        .font(DesignSystem.Typography.caption)
                    }

                    HStack(spacing: DesignSystem.Spacing.sm) {
                        Button {
                            Task { await inventoryImportService.scan() }
                        } label: {
                            Label("Scan", systemImage: "magnifyingglass")
                        }
                        .disabled(isBusy)

                        Button {
                            Task { await inventoryImportService.importInventory() }
                        } label: {
                            Label("Import", systemImage: "square.and.arrow.down")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isBusy || !inventoryImportService.hasImportableInventory)
                    }
                    .controlSize(.small)
                    .font(DesignSystem.Typography.caption)
                }
                .padding(DesignSystem.Spacing.lg)
            }
        }
    }

    private var isBusy: Bool {
        switch inventoryImportService.phase {
        case .scanning, .importing: return true
        default: return false
        }
    }

    private var statusColor: Color {
        switch inventoryImportService.phase {
        case .failed: return DesignSystem.Colors.error
        case .complete: return DesignSystem.Colors.success
        default: return DesignSystem.Colors.textSecondary
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(DesignSystem.Typography.caption)
                .fontWeight(.semibold)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
            Text(label)
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
        }
    }
}

// MARK: - Hermes Setup Detail

struct HermesSetupDetailView: View {
    @Bindable var settingsManager: SettingsManager
    let dataStore: DataStore
    let cloudSyncService: CloudSyncService?
    let iCloudSessionMirrorService: ICloudSessionMirrorService?

    var body: some View {
        SettingsDetailContainer(
            title: "Setup Assistant",
            subtitle: "Run the guided Hermes setup or manually mark onboarding flows as complete."
        ) {
            GlassCard {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                    Button("Guided Hermes setup") {
                        WindowManager.shared.openHermesSetupWizard(
                            settingsManager: settingsManager,
                            chatController: nil,
                            dataStore: dataStore,
                            cloudSyncService: cloudSyncService,
                            iCloudSessionMirrorService: iCloudSessionMirrorService
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(DesignSystem.Colors.hermesAureate)
                    .controlSize(.regular)

                    Divider().background(DesignSystem.Colors.border)

                    Toggle("Hermes setup completed", isOn: $settingsManager.hermesSetupWizardCompleted)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)

                    Toggle("Chat setup completed", isOn: $settingsManager.chatBackendOnboardingCompleted)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                }
                .padding(DesignSystem.Spacing.lg)
            }
        }
    }
}

// MARK: - Shared helpers

private func fieldLabel(_ text: String) -> some View {
    Text(text)
        .font(DesignSystem.Typography.caption)
        .fontWeight(.semibold)
        .foregroundStyle(DesignSystem.Colors.textSecondary)
        .textCase(.uppercase)
        .tracking(0.8)
}
