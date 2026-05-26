import SwiftUI
import OpenBurnBarCore

struct InsightsComposerBar: View {

    @Bindable var environment: InsightsMacEnvironment
    @State private var localPrompt: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(alignment: .center, spacing: UnifiedDesignSystem.Spacing.sm) {
            modelChip
            TextField("Ask the model anything…", text: $localPrompt, axis: .horizontal)
                .focused($isFocused)
                .textFieldStyle(.plain)
                .font(UnifiedDesignSystem.Typography.body)
                .padding(.vertical, 6)
                .padding(.horizontal, UnifiedDesignSystem.Spacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.md, style: .continuous)
                        .fill(UnifiedDesignSystem.Colors.surface)
                )
                .onSubmit { sendPrompt() }
            Button(action: sendPrompt) {
                if environment.isComposing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 13, weight: .semibold))
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(UnifiedDesignSystem.Colors.ember)
            .disabled(localPrompt.isEmpty || environment.isComposing)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, UnifiedDesignSystem.Spacing.md)
        .padding(.vertical, UnifiedDesignSystem.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.lg, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.lg, style: .continuous)
                        .stroke(UnifiedDesignSystem.Colors.borderSubtle, lineWidth: 0.5)
                )
        )
    }

    private func sendPrompt() {
        guard !localPrompt.isEmpty, !environment.isComposing else { return }
        let prompt = localPrompt
        localPrompt = ""
        Task { await environment.compose(prompt: prompt) }
    }

    private func resolveProvider(for providerKey: String) -> AgentProvider? {
        AgentProvider.fromCatalogProviderID(providerKey) ?? AgentProvider.fromPersistedToken(providerKey)
    }

    private var modelChip: some View {
        Menu {
            ForEach(environment.modelCatalog) { model in
                Button {
                    environment.selectedModelTag = .init(
                        providerKey: model.providerKey,
                        modelID: model.id,
                        displayName: model.displayName,
                        egressTier: model.egressTier
                    )
                } label: {
                    Label {
                        VStack(alignment: .leading) {
                            Text(model.displayName)
                            Text(model.egressTier.displayLabel)
                                .font(.caption)
                        }
                    } icon: {
                        if let provider = resolveProvider(for: model.providerKey) {
                            UnifiedProviderLogoView(provider: provider, size: 16)
                        } else {
                            Image(systemName: model.egressTier.symbolName)
                        }
                    }
                }
            }
            Divider()
            Toggle("Privacy mode (local models only)", isOn: $environment.privacyMode)
        } label: {
            HStack(spacing: 4) {
                if let provider = resolveProvider(for: environment.selectedModelTag.providerKey) {
                    UnifiedProviderLogoView(provider: provider, size: 12)
                } else {
                    Image(systemName: environment.selectedModelTag.egressTier.symbolName)
                        .font(.system(size: 11, weight: .semibold))
                }
                Text(environment.selectedModelTag.displayName)
                    .font(UnifiedDesignSystem.Typography.caption)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
            }
            .padding(.horizontal, UnifiedDesignSystem.Spacing.sm)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(UnifiedDesignSystem.Colors.surface)
            )
            .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
    }
}
