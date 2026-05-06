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
        GlassCard {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                Text("Chat engines")
                    .font(DesignSystem.Typography.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)

                Text("Only the engines you enable here appear in the dashboard and menu bar chat header. Turn on each one you actually use so OpenBurnBar does not list every provider.")
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
                                .font(DesignSystem.Typography.caption)
                                .foregroundStyle(DesignSystem.Colors.textPrimary)
                        }
                    }
                }

                Divider().background(DesignSystem.Colors.border)

                Text("HTTP gateways")
                    .font(DesignSystem.Typography.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)

                Text("OpenClaw (OpenAI-compatible gateway, default 127.0.0.1:18789).")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)

                TextField("OpenClaw base URL", text: $settingsManager.openClawGatewayBaseURL)
                    .textFieldStyle(.roundedBorder)

                SecureField("OpenClaw bearer token (optional)", text: $settingsManager.openClawBearerToken)
                    .textFieldStyle(.roundedBorder)

                Divider().background(DesignSystem.Colors.border)

                Text("Hermes (local gateway on port 8642). In ~/.hermes/.env set API_SERVER_ENABLED=true, then run hermes gateway run in Terminal.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)

                Text("When you're signed in, this Mac also advertises a Remote Relay connection so your iPhone/iPad can chat with this local Hermes over cell signal. The API_SERVER_KEY stays on this Mac; BurnBar relays only your chat requests and streamed responses through your private Firestore namespace.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("Allow iPhone/iPad Remote Relay through this Mac", isOn: $settingsManager.hermesRemoteRelayEnabled)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)

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

                hermesInventoryImportCard

                Toggle("Hermes setup completed", isOn: $settingsManager.hermesSetupWizardCompleted)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)

                Text("Leave the field below empty unless you set API_SERVER_KEY in ~/.hermes/.env — then paste the same value here so OpenBurnBar can connect.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)

                TextField("Hermes base URL", text: $settingsManager.hermesGatewayBaseURL)
                    .textFieldStyle(.roundedBorder)

                SecureField("Same token as API_SERVER_KEY (leave empty if you didn't set one)", text: $settingsManager.hermesBearerToken)
                    .textFieldStyle(.roundedBorder)

                Text("Optional chat model id for the gateway (same as the JSON `model` field). Leave empty to let OpenBurnBar choose: if the gateway lists MiniMax but you use Codex with a ChatGPT account, OpenBurnBar sends a Codex-supported model instead (e.g. gpt-5.5). Set only if you need a specific id.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                TextField("Hermes chat model (optional)", text: $settingsManager.hermesChatModelOverride)
                    .textFieldStyle(.roundedBorder)

                Divider().background(DesignSystem.Colors.border)

                Text("After you finish the in-app chat backend setup, you can hide the first-run prompt.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)

                Toggle("Chat setup completed", isOn: $settingsManager.chatBackendOnboardingCompleted)
            }
            .padding(DesignSystem.Spacing.lg)
        }
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
