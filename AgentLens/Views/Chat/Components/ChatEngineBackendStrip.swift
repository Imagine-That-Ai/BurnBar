import SwiftUI

struct ChatEngineBackendStrip: View {
    @Bindable var controller: ChatSessionController
    var settingsManager: SettingsManager
    @State private var hermesRuntimeLauncher = HermesRuntimeLauncher()
    @State private var piAgentRuntimeAdapter = PiAgentRuntimeAdapter()

    private var enabledChatBackendsForHeader: [ChatBackendID] {
        settingsManager.enabledChatBackends
    }

    var body: some View {
        Group {
            if enabledChatBackendsForHeader.isEmpty {
                Text("Settings → Chat: enable engines")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            } else if enabledChatBackendsForHeader.count == 1, let only = enabledChatBackendsForHeader.first {
                Text(only.shortLabel)
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
            } else {
                HStack(spacing: 2) {
                    ForEach(enabledChatBackendsForHeader) { backend in
                        Button {
                            handleBackendTap(backend)
                        } label: {
                            HStack(spacing: 3) {
                                if shouldShowPlayAffordance(for: backend) {
                                    Image(systemName: "play.fill")
                                        .font(.system(size: 7, weight: .bold))
                                }
                                Text(backend.shortLabel)
                            }
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background {
                                if controller.chatBackend == backend {
                                    Capsule(style: .continuous)
                                        .fill(backendCapsuleFill(for: backend))
                                }
                            }
                            .foregroundStyle(
                                controller.chatBackend == backend
                                    ? backendForegroundColor(for: backend)
                                    : DesignSystem.Colors.textMuted
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(isBackendUnavailable(backend))
                        .opacity(isBackendUnavailable(backend) ? 0.4 : 1)
                    }
                }
                .padding(2)
                .background(DesignSystem.Colors.background.opacity(0.6))
                .clipShape(Capsule(style: .continuous))
            }
        }
        .animation(DesignSystem.Animation.snappy, value: controller.chatBackend)
        .animation(DesignSystem.Animation.snappy, value: enabledChatBackendsForHeader)
    }

    private func shouldShowPlayAffordance(for backend: ChatBackendID) -> Bool {
        switch backend {
        case .hermes:
            return controller.hermesAvailable == false && settingsManager.hermesSetupWizardCompleted
        case .piAgent:
            return controller.piAgentAvailable == false
        case .codex, .claude, .openclaw:
            return false
        }
    }

    private func backendCapsuleFill(for backend: ChatBackendID) -> AnyShapeStyle {
        switch backend {
        case .hermes:
            return AnyShapeStyle(DesignSystem.Colors.mercuryGradient)
        case .piAgent:
            return AnyShapeStyle(LinearGradient(
                colors: [DesignSystem.Colors.purple, DesignSystem.Colors.purple.opacity(0.7)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ))
        case .codex, .claude, .openclaw:
            return AnyShapeStyle(DesignSystem.Colors.accentGradient)
        }
    }

    private func backendForegroundColor(for backend: ChatBackendID) -> Color {
        switch backend {
        case .hermes:
            return Color(hex: "151210")
        case .codex, .claude, .openclaw, .piAgent:
            return .white
        }
    }

    private func handleBackendTap(_ backend: ChatBackendID) {
        if backend == .hermes && !settingsManager.hermesSetupWizardCompleted {
            WindowManager.shared.openHermesSetupWizard(
                settingsManager: settingsManager,
                chatController: controller
            )
            return
        }
        if backend == .hermes && controller.hermesAvailable == false {
            Task {
                await hermesRuntimeLauncher.openHermesAndGateway(
                    baseURL: resolvedHermesGatewayBaseURL,
                    bearerToken: resolvedHermesBearerToken
                )
                await controller.probeHermesAvailability()
                if controller.hermesAvailable {
                    controller.setChatBackend(.hermes)
                }
            }
            return
        }
        if backend == .piAgent && controller.piAgentAvailable == false {
            Task {
                syncPiAgentAdapterPreferences()
                _ = await piAgentRuntimeAdapter.openManagedRuntime(
                    baseURL: resolvedPiAgentGatewayBaseURL,
                    bearerToken: resolvedPiAgentBearerToken
                )
                await controller.probePiAgentAvailability()
                if controller.piAgentAvailable {
                    controller.setChatBackend(.piAgent)
                }
            }
            return
        }
        controller.setChatBackend(backend)
    }

    private func isBackendUnavailable(_ backend: ChatBackendID) -> Bool {
        switch backend {
        case .hermes:
            false
        case .openclaw:
            controller.openClawAvailable == false
        case .codex, .claude:
            false
        case .piAgent:
            false
        }
    }

    private func syncPiAgentAdapterPreferences() {
        let preferred = settingsManager.piAgentSelectedInstanceID.trimmingCharacters(in: .whitespacesAndNewlines)
        piAgentRuntimeAdapter.preferredInstanceID = preferred.isEmpty ? nil : preferred
        let redisRaw = settingsManager.piAgentRedisURL.trimmingCharacters(in: .whitespacesAndNewlines)
        piAgentRuntimeAdapter.redisURL = redisRaw.isEmpty ? nil : URL(string: redisRaw)
    }

    private var resolvedHermesGatewayBaseURL: URL {
        URL(string: settingsManager.hermesGatewayBaseURL.trimmingCharacters(in: .whitespacesAndNewlines))
            ?? URL(string: "http://127.0.0.1:8642")!
    }

    private var resolvedHermesBearerToken: String? {
        let token = settingsManager.hermesBearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    private var resolvedPiAgentGatewayBaseURL: URL {
        URL(string: settingsManager.piAgentGatewayBaseURL.trimmingCharacters(in: .whitespacesAndNewlines))
            ?? URL(string: "http://127.0.0.1:8765")!
    }

    private var resolvedPiAgentBearerToken: String? {
        let token = settingsManager.piAgentBearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }
}
