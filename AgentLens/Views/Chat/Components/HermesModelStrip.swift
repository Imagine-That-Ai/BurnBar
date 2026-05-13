import SwiftUI

// MARK: - Hermes Model Strip
//
// Second-level picker that appears under `ChatEngineBackendStrip` only
// when the active chat surface is Hermes. Mirrors the parent strip's
// visual language (small pills, animated selection) but renders the
// underlying model providers Hermes routes to: Codex, Claude, Z.ai,
// Kimi, MiniMax, Ollama.
//
// Selection writes through `SettingsManager.applyHermesModelSelection`,
// which mirrors into `hermesChatModelOverride` so the existing chat
// resolution path picks it up without a new routing branch.

struct HermesModelStrip: View {
    @Bindable var controller: ChatSessionController
    var settingsManager: SettingsManager

    private var enabledModels: [HermesModelID] {
        settingsManager.enabledHermesModels
    }

    private var selectedModel: HermesModelID? {
        settingsManager.selectedHermesModel
    }

    var body: some View {
        Group {
            if controller.chatBackend != .hermes {
                EmptyView()
            } else if enabledModels.isEmpty {
                Text("Settings → Chat: enable Hermes models")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            } else {
                HStack(spacing: 2) {
                    ForEach(enabledModels) { model in
                        Button {
                            handleModelTap(model)
                        } label: {
                            HStack(spacing: 3) {
                                Text(model.shortLabel)
                            }
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background {
                                if selectedModel == model {
                                    Capsule(style: .continuous)
                                        .fill(DesignSystem.Colors.mercuryGradient)
                                }
                            }
                            .foregroundStyle(
                                selectedModel == model
                                    ? Color(hex: "151210")
                                    : DesignSystem.Colors.textMuted
                            )
                        }
                        .buttonStyle(.plain)
                        .help(model.displayName)
                    }
                }
                .padding(2)
                .background(DesignSystem.Colors.background.opacity(0.6))
                .clipShape(Capsule(style: .continuous))
            }
        }
        .animation(DesignSystem.Animation.snappy, value: selectedModel)
        .animation(DesignSystem.Animation.snappy, value: enabledModels)
        .animation(DesignSystem.Animation.snappy, value: controller.chatBackend)
    }

    private func handleModelTap(_ model: HermesModelID) {
        if settingsManager.selectedHermesModel == model {
            // Tap to clear → fall back to gateway-advertised default.
            settingsManager.applyHermesModelSelection(nil)
        } else {
            settingsManager.applyHermesModelSelection(model)
        }
    }
}
