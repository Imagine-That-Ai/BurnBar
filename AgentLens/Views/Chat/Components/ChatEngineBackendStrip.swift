import SwiftUI

struct ChatEngineBackendStrip: View {
    @Bindable var controller: ChatSessionController
    var settingsManager: SettingsManager
    @State private var quotaService = ProviderQuotaService.shared

    /// The one switch path, injected on the controller (see `AgentDeck.swift`).
    private var switcher: AgentDeckSwitcher { controller.agentDeck.switcher }

    private var enabledChatBackendsForHeader: [ChatBackendID] {
        settingsManager.enabledChatBackends
    }

    /// Builds the hover tooltip for a backend pill. When the backend has
    /// a quota signal, the tooltip reads "Codex — 5h: 47% left · Combined
    /// ..." so users can see each provider's remaining quota by hovering;
    /// otherwise it falls back to the display name.
    private func tooltipText(for backend: ChatBackendID) -> String {
        guard let provider = backend.agentProvider,
              let resolution = ProviderQuotaChip.resolve(
                provider: provider,
                style: .full,
                displayName: backend.displayName,
                service: quotaService,
                cumulative: settingsManager.cumulativeAcrossAccounts
              )
        else {
            return backend.displayName
        }
        return resolution.tooltip
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
                    .popoverTooltip(tooltipText(for: only))
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
                        .popoverTooltip(tooltipText(for: backend))
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
        case .codex, .claude, .openclaw, .droid, .forge, .antigravity, .cursorAgent, .openClaude, .omp, .junie, .fx, .muse, .grok, .kimi:
            return false
        }
    }

    /// Delegates to the one switching path the app has
    /// (`AgentDeckSwitcher`), so this strip and the Agent Deck's Sigil / ghost
    /// row can never drift on the Hermes-wizard, Hermes-launch and Pi-launch
    /// asymmetries.
    private func handleBackendTap(_ backend: ChatBackendID) {
        switcher.select(backend, controller: controller, settingsManager: settingsManager)
    }

    private func isBackendUnavailable(_ backend: ChatBackendID) -> Bool {
        switch backend {
        case .hermes:
            false
        case .openclaw:
            controller.openClawAvailable == false
        case .codex, .claude, .droid, .forge, .antigravity, .cursorAgent, .openClaude, .omp, .junie, .fx, .muse, .grok, .kimi:
            false
        case .piAgent:
            false
        }
    }

}
