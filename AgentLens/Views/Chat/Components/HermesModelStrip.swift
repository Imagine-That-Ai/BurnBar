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

    private var selectedOverride: String {
        settingsManager.hermesChatModelOverride.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var advertisedModelsByFamily: [HermesModelID: [HermesAdvertisedModel]] {
        Dictionary(grouping: controller.hermesAdvertisedModels, by: \.family)
            .mapValues { models in
                models.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            }
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
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(enabledModels) { model in
                            familyGroup(for: model)
                        }
                    }
                    .padding(2)
                }
                .frame(maxWidth: 520, alignment: .leading)
                .background(DesignSystem.Colors.background.opacity(0.6))
                .clipShape(Capsule(style: .continuous))
            }
        }
        .animation(DesignSystem.Animation.snappy, value: selectedModel)
        .animation(DesignSystem.Animation.snappy, value: selectedOverride)
        .animation(DesignSystem.Animation.snappy, value: controller.hermesAdvertisedModels)
        .animation(DesignSystem.Animation.snappy, value: enabledModels)
        .animation(DesignSystem.Animation.snappy, value: controller.chatBackend)
    }

    @ViewBuilder
    private func familyGroup(for family: HermesModelID) -> some View {
        let models = advertisedModelsByFamily[family] ?? []
        HStack(spacing: 2) {
            familyTag(family)
            if models.isEmpty {
                fallbackPill(family)
            } else {
                ForEach(models) { model in
                    advertisedPill(model)
                }
            }
        }
    }

    private func familyTag(_ family: HermesModelID) -> some View {
        Text(family.shortLabel)
            .font(.system(size: 8, weight: .bold, design: .rounded))
            .foregroundStyle(DesignSystem.Colors.textMuted.opacity(0.8))
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(DesignSystem.Colors.surface.opacity(0.45), in: Capsule(style: .continuous))
            .help(family.displayName)
    }

    private func fallbackPill(_ model: HermesModelID) -> some View {
        let isSelected = selectedModel == model && (selectedOverride.isEmpty || selectedOverride == model.hermesModelOverride)
        return Button {
            handleModelTap(model)
        } label: {
            Text(model.shortLabel)
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background {
                    if isSelected {
                        Capsule(style: .continuous)
                            .fill(DesignSystem.Colors.mercuryGradient)
                    }
                }
                .foregroundStyle(
                    isSelected
                        ? Color(hex: "151210")
                        : DesignSystem.Colors.textMuted
                )
        }
        .buttonStyle(.plain)
        .help(model.displayName)
    }

    private func advertisedPill(_ model: HermesAdvertisedModel) -> some View {
        let isSelected = selectedOverride == model.id
        return Button {
            handleAdvertisedModelTap(model)
        } label: {
            Text(model.displayName)
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background {
                    if isSelected {
                        Capsule(style: .continuous)
                            .fill(DesignSystem.Colors.mercuryGradient)
                    }
                }
                .foregroundStyle(
                    isSelected
                        ? Color(hex: "151210")
                        : DesignSystem.Colors.textMuted
                )
        }
        .buttonStyle(.plain)
        .help(model.id)
    }

    private func handleModelTap(_ model: HermesModelID) {
        if settingsManager.selectedHermesModel == model {
            // Tap to clear → fall back to gateway-advertised default.
            settingsManager.applyHermesModelSelection(nil)
        } else {
            settingsManager.applyHermesModelSelection(model)
        }
    }

    private func handleAdvertisedModelTap(_ model: HermesAdvertisedModel) {
        if selectedOverride == model.id {
            settingsManager.applyHermesModelSelection(nil)
        } else {
            settingsManager.applyHermesModelSelection(model.family)
            settingsManager.hermesChatModelOverride = model.id
        }
    }
}
