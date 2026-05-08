import SwiftUI

// MARK: - Chat Gateway Settings View

/// Settings view for configuring chat backends and HTTP gateways
struct ChatGatewaySettingsView: View {
    @Bindable var settingsManager: SettingsManager
    private let dataStore: DataStore
    private let cloudSyncService: CloudSyncService?
    private let iCloudSessionMirrorService: ICloudSessionMirrorService?
    @State private var inventoryImportService: HermesInventoryImportService

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
        self._inventoryImportService = State(initialValue: HermesInventoryImportService(
            dataStore: dataStore,
            settingsManager: settingsManager,
            cloudSyncService: cloudSyncService,
            iCloudMirrorService: iCloudSessionMirrorService
        ))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xl) {
                headerSection
                chatEnginesSection
                hermesGatewaySection
                openclawSection
                importSection
                onboardingSection
            }
            .padding(DesignSystem.Spacing.lg)
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        GlassCard {
            HStack(spacing: DesignSystem.Spacing.lg) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [DesignSystem.Colors.hermesMercury.opacity(0.3),
                                         DesignSystem.Colors.hermesAureate.opacity(0.2)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 56, height: 56)
                    Text("☿")
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [DesignSystem.Colors.hermesMercury,
                                         DesignSystem.Colors.hermesAureate],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Hermes")
                        .font(DesignSystem.Typography.title)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Text("Messenger AI configuration")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }

                Spacer()
            }
            .padding(DesignSystem.Spacing.lg)
        }
    }

    // MARK: - Chat Engines

    private var chatEnginesSection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                sectionTitle("Chat Engines", icon: "cpu", color: DesignSystem.Colors.whimsy)

                Text("Only the engines you enable here appear in the dashboard and menu bar chat header.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                    ForEach(ChatBackendID.allCases) { backend in
                        Toggle(isOn: Binding(
                            get: { settingsManager.enabledChatBackends.contains(backend) },
                            set: { settingsManager.setChatBackendEnabled(backend, enabled: $0) }
                        )) {
                            Text(backend.displayName)
                                .font(DesignSystem.Typography.body)
                                .foregroundStyle(DesignSystem.Colors.textPrimary)
                        }
                    }
                }
            }
            .padding(DesignSystem.Spacing.lg)
        }
    }

    // MARK: - Hermes Gateway

    private var hermesGatewaySection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                sectionTitle("Hermes Gateway", icon: "network", color: DesignSystem.Colors.hermesAureate)

                Text("Local gateway on port 8642. In ~/.hermes/.env set API_SERVER_ENABLED=true, then run hermes gateway run in Terminal.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                    fieldLabel("Base URL")
                    TextField("http://localhost:8642", text: $settingsManager.hermesGatewayBaseURL)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                    fieldLabel("Bearer Token")
                    SecureField("Same as API_SERVER_KEY (leave empty if unset)", text: $settingsManager.hermesBearerToken)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                    fieldLabel("Model Override")
                    TextField("Leave empty for auto (e.g. gpt-5.5)", text: $settingsManager.hermesChatModelOverride)
                        .textFieldStyle(.roundedBorder)
                }

                Toggle("Allow iPhone/iPad Remote Relay through this Mac", isOn: $settingsManager.hermesRemoteRelayEnabled)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)

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

                Text("Premium accounts can use this Mac as a private Remote Relay host so iPhone and iPad can chat with local Hermes over cell signal. The API_SERVER_KEY stays on this Mac; OpenBurnBar relays only encrypted request and response frames.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(DesignSystem.Spacing.lg)
        }
    }

    // MARK: - OpenClaw Gateway

    private var openclawSection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                sectionTitle("OpenClaw Gateway", icon: "network.badge.shield.half.filled", color: DesignSystem.Colors.teal)

                Text("OpenAI-compatible gateway, default 127.0.0.1:18789.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)

                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                    fieldLabel("Base URL")
                    TextField("http://127.0.0.1:18789", text: $settingsManager.openClawGatewayBaseURL)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                    fieldLabel("Bearer Token")
                    SecureField("Optional bearer token", text: $settingsManager.openClawBearerToken)
                        .textFieldStyle(.roundedBorder)
                }
            }
            .padding(DesignSystem.Spacing.lg)
        }
    }

    // MARK: - Import

    private var importSection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                sectionTitle("Import", icon: "tray.and.arrow.down.fill", color: DesignSystem.Colors.hermesAureate)

                hermesInventoryImportCard
            }
            .padding(DesignSystem.Spacing.lg)
        }
    }

    // MARK: - Onboarding

    private var onboardingSection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                sectionTitle("Setup", icon: "wand.and.stars", color: DesignSystem.Colors.amber)

                HStack(spacing: DesignSystem.Spacing.md) {
                    Button("Guided Hermes setup") {
                        WindowManager.shared.openHermesSetupWizard(
                            settingsManager: settingsManager,
                            chatController: nil,
                            dataStore: dataStore,
                            cloudSyncService: cloudSyncService,
                            iCloudSessionMirrorService: iCloudSessionMirrorService
                        )
                    }
                    .buttonStyle(.bordered)
                    .tint(DesignSystem.Colors.hermesAureate)
                    .font(DesignSystem.Typography.caption)

                    Spacer()
                }

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

    // MARK: - Helpers

    private func sectionTitle(_ title: String, icon: String, color: Color) -> some View {
        Label {
            Text(title)
                .font(DesignSystem.Typography.headline)
                .fontWeight(.semibold)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
        } icon: {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(color.opacity(0.18))
                    .frame(width: 28, height: 28)
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(color)
            }
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(DesignSystem.Typography.caption)
            .fontWeight(.semibold)
            .foregroundStyle(DesignSystem.Colors.textSecondary)
            .textCase(.uppercase)
            .tracking(0.8)
    }

    private var hermesInventoryImportCard: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
                Image(systemName: "tray.and.arrow.down.fill")
                    .foregroundStyle(DesignSystem.Colors.hermesAureate)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Import existing Hermes chats")
                        .font(DesignSystem.Typography.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Text("Bring your pre-OpenBurnBar Hermes conversations into the local index, then optionally back them up so iPhone and iPad can read them.")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Text(inventoryImportService.primaryStatusText)
                .font(DesignSystem.Typography.tiny)
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
                .disabled(inventoryImportServiceIsBusy)

                Button {
                    Task { await inventoryImportService.importInventory() }
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .disabled(inventoryImportServiceIsBusy || !inventoryImportService.hasImportableInventory)
            }
            .controlSize(.small)
            .font(DesignSystem.Typography.caption)
        }
        .padding(DesignSystem.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(DesignSystem.Colors.surfaceElevated.opacity(0.7))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(DesignSystem.Colors.border.opacity(0.8), lineWidth: 1)
        )
    }

    private var inventoryImportServiceIsBusy: Bool {
        switch inventoryImportService.phase {
        case .scanning, .importing:
            return true
        default:
            return false
        }
    }

    private var statusColor: Color {
        switch inventoryImportService.phase {
        case .failed:
            return DesignSystem.Colors.error
        case .complete:
            return DesignSystem.Colors.success
        default:
            return DesignSystem.Colors.textSecondary
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
