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
                backendIcon(for: only, size: 13)
                    .frame(width: 18, height: 18)
                    .accessibilityLabel(only.displayName)
                    .popoverTooltip(only.displayName)
                    .padding(.horizontal, 6)
                .padding(.vertical, 3)
            } else {
                HStack(spacing: 2) {
                    ForEach(enabledChatBackendsForHeader) { backend in
                        Button {
                            handleBackendTap(backend)
                        } label: {
                            HStack(spacing: 2) {
                                if shouldShowPlayAffordance(for: backend) {
                                    Image(systemName: "play.fill")
                                        .font(.system(size: 7, weight: .bold))
                                }
                                backendIcon(for: backend, size: 12)
                            }
                            .frame(width: shouldShowPlayAffordance(for: backend) ? 24 : 18, height: 18)
                            .padding(.horizontal, 3)
                            .padding(.vertical, 3)
                            .background {
                                if controller.chatBackend == backend {
                                    Capsule(style: .continuous)
                                        .fill(AnyShapeStyle(backend.gradient))
                                }
                            }
                            .foregroundStyle(
                                controller.chatBackend == backend
                                    ? backend.activeForeground
                                    : DesignSystem.Colors.textMuted
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(backend.displayName)
                        .popoverTooltip(backend.displayName)
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

    @ViewBuilder
    private func backendIcon(for backend: ChatBackendID, size: CGFloat) -> some View {
        if let provider = backend.agentProvider {
            ProviderLogoView(provider: provider, size: size, useFallbackColor: false)
        } else {
            Text(backend.glyph)
                .font(.system(size: size, weight: .semibold, design: .rounded))
        }
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

    private func handleBackendTap(_ backend: ChatBackendID) {
        if backend == .hermes && !settingsManager.hermesSetupWizardCompleted {
            WindowManager.shared.openHermesSetupWizard(
                settingsManager: settingsManager,
                chatController: controller
            )
            return
        }
        if backend == .hermes && controller.hermesAvailable == false {
            controller.setChatBackend(.hermes)
            Task {
                await hermesRuntimeLauncher.openHermesAndGateway(
                    baseURL: resolvedHermesGatewayBaseURL,
                    bearerToken: resolvedHermesBearerToken
                )
                await controller.probeHermesAvailability()
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
