import SwiftUI

struct ChatEngineBackendStrip: View {
    @Bindable var controller: ChatSessionController
    var settingsManager: SettingsManager

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
                            if backend == .hermes && !settingsManager.hermesSetupWizardCompleted {
                                WindowManager.shared.openHermesSetupWizard(
                                    settingsManager: settingsManager,
                                    chatController: controller
                                )
                                return
                            }
                            controller.setChatBackend(backend)
                        } label: {
                            Text(backend.shortLabel)
                                .font(.system(size: 9, weight: .semibold, design: .rounded))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background {
                                    if controller.chatBackend == backend {
                                        Capsule(style: .continuous)
                                            .fill(backend == .hermes ? AnyShapeStyle(DesignSystem.Colors.mercuryGradient) : AnyShapeStyle(DesignSystem.Colors.accentGradient))
                                    }
                                }
                                .foregroundStyle(
                                    controller.chatBackend == backend
                                        ? (backend == .hermes ? Color(hex: "151210") : .white)
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

    private func isBackendUnavailable(_ backend: ChatBackendID) -> Bool {
        switch backend {
        case .hermes:
            controller.hermesAvailable == false && settingsManager.hermesSetupWizardCompleted
        case .openclaw:
            controller.openClawAvailable == false
        case .codex, .claude:
            false
        }
    }
}
