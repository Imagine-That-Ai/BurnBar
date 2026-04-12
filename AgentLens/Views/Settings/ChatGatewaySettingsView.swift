import SwiftUI

// MARK: - Chat Gateway Settings View

/// Settings view for configuring chat backends and HTTP gateways
struct ChatGatewaySettingsView: View {
    @Bindable var settingsManager: SettingsManager

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

                Button("Guided Hermes setup") {
                    WindowManager.shared.openHermesSetupWizard(
                        settingsManager: settingsManager,
                        chatController: nil
                    )
                }
                .buttonStyle(.bordered)
                .tint(DesignSystem.Colors.hermesAureate)
                .font(DesignSystem.Typography.caption)

                Text("Leave the field below empty unless you set API_SERVER_KEY in ~/.hermes/.env — then paste the same value here so OpenBurnBar can connect.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)

                SecureField("Same token as API_SERVER_KEY (leave empty if you didn't set one)", text: $settingsManager.hermesBearerToken)
                    .textFieldStyle(.roundedBorder)

                Text("Optional chat model id for the gateway (same as the JSON `model` field). Leave empty to let OpenBurnBar choose: if the gateway lists MiniMax but you use Codex with a ChatGPT account, OpenBurnBar sends a Codex-supported model instead (e.g. gpt-5.4-mini). Set only if you need a specific id.")
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
}
