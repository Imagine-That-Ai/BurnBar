import SwiftUI

struct OnboardingChatEngineView: View {
    @Binding var enabledBackends: Set<ChatBackendID>
    @Binding var defaultEngine: ChatBackendID
    var chatController: ChatSessionController?

    private var orderedSelection: [ChatBackendID] {
        ChatBackendID.allCases.filter { enabledBackends.contains($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                Text("Choose chat engines")
                    .font(DesignSystem.Typography.title)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)

                Text("OpenBurnBar attaches your local index as context to every query. Enable the backends you use \u{2014} add or remove anytime in Settings.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            GlassCard {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                    ForEach(ChatBackendID.allCases) { backend in
                        HStack(spacing: DesignSystem.Spacing.sm) {
                            backendLogo(for: backend)

                            Toggle(isOn: Binding(
                                get: { enabledBackends.contains(backend) },
                                set: { on in
                                    if on {
                                        enabledBackends.insert(backend)
                                    } else {
                                        enabledBackends.remove(backend)
                                    }
                                    let ordered = ChatBackendID.allCases.filter { enabledBackends.contains($0) }
                                    if !ordered.contains(defaultEngine) {
                                        defaultEngine = ordered.first ?? .codex
                                    }
                                }
                            )) {
                                Text(backend.displayName)
                                    .font(DesignSystem.Typography.body)
                                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                            }

                            if backend == .hermes {
                                Spacer()
                                Button("Setup wizard") {
                                    WindowManager.shared.openHermesSetupWizard(
                                        settingsManager: SettingsManager.shared,
                                        chatController: chatController
                                    )
                                }
                                .buttonStyle(.plain)
                                .font(DesignSystem.Typography.tiny)
                                .foregroundStyle(DesignSystem.Colors.hermesAureate)
                            }
                        }
                    }
                }
                .padding(DesignSystem.Spacing.sm)
            }

            if orderedSelection.count >= 2 {
                Picker("Default engine", selection: $defaultEngine) {
                    ForEach(orderedSelection, id: \.self) { backend in
                        Text(backend.displayName).tag(backend)
                    }
                }
                .pickerStyle(.menu)
                .font(DesignSystem.Typography.caption)
            }

            // Gateway health
            HStack(spacing: DesignSystem.Spacing.lg) {
                Button("Check gateway health") {
                    Task {
                        await chatController?.probeHermesAvailability()
                        await chatController?.probeOpenClawAvailability()
                    }
                }
                .buttonStyle(.bordered)
                .font(DesignSystem.Typography.caption)

                if let ctrl = chatController {
                    HStack(spacing: DesignSystem.Spacing.sm) {
                        gatewayDot(ok: ctrl.hermesAvailable)
                        Text("Hermes")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                    }
                    HStack(spacing: DesignSystem.Spacing.sm) {
                        gatewayDot(ok: ctrl.openClawAvailable)
                        Text("OpenClaw")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                    }
                }
            }
        }
    }

    private func gatewayDot(ok: Bool) -> some View {
        Circle()
            .fill(ok ? DesignSystem.Colors.success : DesignSystem.Colors.textMuted)
            .frame(width: 8, height: 8)
    }

    @ViewBuilder
    private func backendLogo(for backend: ChatBackendID) -> some View {
        if let provider = backend.agentProvider {
            ProviderLogoView(provider: provider, size: 22, useFallbackColor: true)
        }
    }
}
