import SwiftUI

struct PetCompanionSettingsView: View {
    @Bindable var settingsManager: SettingsManager
    @AppStorage(PetCompanionFeature.DefaultsKey.enabled)
    private var petEnabled = false
    @AppStorage(PetCompanionFeature.DefaultsKey.activePetID)
    private var activePetID = "claudecode"
    @AppStorage(PetCompanionFeature.DefaultsKey.activeAgent)
    private var activeAgentRaw = ChatBackendID.codex.rawValue

    private var bundledPets: [PetDefinition] {
        PetCatalog.bundledDefinitions()
    }

    private var activeAgentName: String {
        activeAgent.displayName
    }

    private var availableBackends: [ChatBackendID] {
        PetChatController.resolveAvailableBackends(enabled: settingsManager.enabledChatBackends)
    }

    private var activeAgent: ChatBackendID {
        let persisted = ChatBackendID(rawValue: activeAgentRaw) ?? .codex
        return availableBackends.contains(persisted) ? persisted : availableBackends.first ?? persisted
    }

    var body: some View {
        SettingsDeepLinkScrollContainer(route: .petsRoot) { _ in
            ScrollView {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xl) {
                    enableSection
                    petPickerSection
                    agentSection
                    summonSection
                }
                .padding(DesignSystem.Spacing.xl)
                .frame(maxWidth: 820, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var enableSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            SettingsSectionHeader(title: "DESKTOP COMPANION")
            SettingsToggle(
                title: "Show Desktop Pet",
                subtitle: "Keeps the floating companion available from launch and the summon hotkey.",
                icon: "pawprint.fill",
                isOn: Binding(
                    get: { petEnabled },
                    set: { enabled in
                        petEnabled = enabled
                        if enabled {
                            PetCompanionFeature.showCompanion()
                        } else {
                            PetCompanionFeature.runtime.controller.closeBubble()
                            PetCompanionFeature.hideCompanion()
                        }
                    }
                )
            )
            .padding(DesignSystem.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                    .fill(DesignSystem.Colors.surface.opacity(0.45))
            )
            .settingsAnchor(SettingsAnchor.petsCompanion)
        }
    }

    private var petPickerSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            SettingsSectionHeader(title: "PET")
            if bundledPets.isEmpty {
                unavailableRow(
                    icon: "pawprint",
                    title: "No bundled pets found",
                    detail: "The companion will fall back to the default pet when resources are available."
                )
            } else {
                PetFormPickerView(definitions: bundledPets, selectedPetID: $activePetID) { id, form in
                    PetCompanionFeature.selectPet(id: id, form: form)
                    if petEnabled {
                        PetCompanionFeature.showCompanion()
                    }
                }
                .frame(minHeight: 420, maxHeight: 640)
                .padding(DesignSystem.Spacing.md)
                .background(
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                        .fill(DesignSystem.Colors.surface.opacity(0.35))
                )
            }
        }
    }

    private var agentSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            SettingsSectionHeader(title: "AGENT")
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    Image(systemName: "brain.head.profile")
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                    Text("Answering Agent")
                        .font(DesignSystem.Typography.body)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Spacer()
                    Text(activeAgentName)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                }
                PetAgentSwitcher(backends: availableBackends) { backend in
                    activeAgentRaw = backend.rawValue
                    PetCompanionFeature.runtime.controller.chat?.switchBackend(to: backend)
                }
            }
            .padding(DesignSystem.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                    .fill(DesignSystem.Colors.surface.opacity(0.45))
            )
        }
    }

    private var summonSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            SettingsSectionHeader(title: "CONTROLS")
            HStack(spacing: DesignSystem.Spacing.md) {
                Button {
                    petEnabled = true
                    PetCompanionFeature.showCompanion()
                    PetCompanionFeature.runtime.controller.openBubble()
                } label: {
                    Label("Summon", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    petEnabled = false
                    PetCompanionFeature.runtime.controller.closeBubble()
                    PetCompanionFeature.hideCompanion()
                } label: {
                    Label("Hide", systemImage: "eye.slash")
                }
                .buttonStyle(.bordered)

                Text(PetCompanionFeature.runtime.hotkey.combo.displayString)
                    .font(DesignSystem.Typography.monoSmall)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .padding(.horizontal, DesignSystem.Spacing.sm)
                    .padding(.vertical, DesignSystem.Spacing.xs)
                    .background(
                        RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                            .fill(DesignSystem.Colors.surface.opacity(0.55))
                    )
            }
        }
    }

    private func unavailableRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
            Image(systemName: icon)
                .foregroundStyle(DesignSystem.Colors.textMuted)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xxs) {
                Text(title)
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text(detail)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
        }
        .padding(DesignSystem.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                .fill(DesignSystem.Colors.surface.opacity(0.45))
        )
    }
}
