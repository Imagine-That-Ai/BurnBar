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
        Group {
            if models.isEmpty {
                fallbackPill(family)
            } else {
                HStack(spacing: 2) {
                    ForEach(models) { model in
                        advertisedPill(model)
                    }
                }
            }
        }
    }

    private func fallbackPill(_ model: HermesModelID) -> some View {
        let isSelected = selectedModel == model && (selectedOverride.isEmpty || selectedOverride == model.hermesModelOverride)
        return Button {
            handleModelTap(model)
        } label: {
            ProviderLogoView(provider: model.agentProvider, size: 13, useFallbackColor: false)
                .frame(width: 18, height: 18)
                .padding(.horizontal, 3)
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
        .accessibilityLabel(model.displayName)
        .help(model.displayName)
    }

    private func advertisedPill(_ model: HermesAdvertisedModel) -> some View {
        let isSelected = selectedOverride == model.id
        return Button {
            handleAdvertisedModelTap(model)
        } label: {
            ProviderLogoView(provider: model.family.agentProvider, size: 13, useFallbackColor: false)
                .frame(width: 18, height: 18)
                .padding(.horizontal, 3)
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
        .accessibilityLabel(model.displayName)
        .help(model.displayName)
    }

    // MARK: - Route rows for the Agent Sigil's model menu

    /// The same routing choices this strip renders as pills, shaped as menu
    /// rows so the Agent Deck can host them inside the Sigil's model menu
    /// (`docs/CHAT_AGENT_SWITCHER_REDESIGN.md` §3.4).
    ///
    /// Hermes is a router; a 12pt "Hermes" with no route was the app's least
    /// honest label. This is the first time the routing ladder is reachable on
    /// the full-canvas chat surface — with no second toolbar row, so the
    /// transcript never jumps 24pt when a Hermes tab is selected.
    @ViewBuilder
    static func routeMenuRows(
        controller: ChatSessionController,
        settingsManager: SettingsManager
    ) -> some View {
        if controller.chatBackend == .hermes {
            let families = settingsManager.enabledHermesModels
            Section("Route") {
                if families.isEmpty {
                    Button("Enable Hermes routes in Settings → Chat") {
                        AppCommandRouter.shared.openSettings?()
                    }
                } else {
                    Button(routeRowTitle("Automatic (gateway picks)", selected: settingsManager.selectedHermesModel == nil)) {
                        settingsManager.applyHermesModelSelection(nil)
                    }
                    ForEach(families) { family in
                        Button(routeRowTitle(family.displayName, selected: settingsManager.selectedHermesModel == family)) {
                            settingsManager.applyHermesModelSelection(family)
                        }
                    }
                }
            }
        }
    }

    /// macOS `Menu` renders plain `Button(title)` text, so the selection mark
    /// is part of the string (the same trick the model rows already use for
    /// their quota suffix).
    private static func routeRowTitle(_ title: String, selected: Bool) -> String {
        (selected ? "✓ " : "  ") + title
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
