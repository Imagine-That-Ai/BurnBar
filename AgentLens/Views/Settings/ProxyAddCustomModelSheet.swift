import OpenBurnBarCore
import SwiftUI

// MARK: - Add Custom Model Sheet
//
// The "easy, intuitive" path for advertising a provider model the bundled
// catalog doesn't know about yet (e.g. a model newer than the shipped catalog,
// or one a no-credential provider's live `/models` can't surface). Pick a
// provider, type the id the provider serves, and it joins the advertised
// `/v1/models` list — routed verbatim to that provider — once the provider has
// a working credential. The same sheet lists and removes existing custom models.
struct AddCustomModelSheet: View {
    struct ProviderOption: Identifiable, Hashable {
        let id: String   // providerID
        let name: String
    }

    let providers: [ProviderOption]
    let customModelsByProvider: [String: [BurnBarCustomModel]]
    let onAdd: (String, String, String) -> Void
    let onRemove: (String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedProviderID: String = ""
    @State private var modelID = ""
    @State private var displayName = ""

    private var selectedProvider: ProviderOption? {
        providers.first { $0.id == selectedProviderID } ?? providers.first
    }

    private var existingForProvider: [BurnBarCustomModel] {
        guard let providerID = selectedProvider?.id else { return [] }
        return customModelsByProvider[providerID] ?? []
    }

    private var validationMessage: String? {
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Enter the provider's model id." }
        if !BurnBarCustomModel.isValidModelID(trimmed) {
            return "Use letters, numbers, and . _ - : / only (no spaces)."
        }
        if existingForProvider.contains(where: { $0.modelID.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return "That model id is already added for this provider."
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            Text("Add a model")
                .font(DesignSystem.Typography.headline)
                .fontWeight(.semibold)
            Text("Advertise a provider model the bundled catalog doesn't list yet. BurnBar sends the id verbatim to the selected provider, so it must be a model that provider actually serves. It appears in /v1/models once the provider has a working credential.")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Provider", selection: $selectedProviderID) {
                ForEach(providers) { provider in
                    Text(provider.name).tag(provider.id)
                }
            }

            TextField("Model id (e.g. minimax-m3, glm-5.1, kimi-k2.6)", text: $modelID)
                .textFieldStyle(.roundedBorder)
                .font(DesignSystem.Typography.monoSmall)

            TextField("Display name (optional)", text: $displayName)
                .textFieldStyle(.roundedBorder)

            if let validationMessage {
                Text(validationMessage)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.error)
            }

            if !existingForProvider.isEmpty {
                Divider()
                Text("Your custom models for \(selectedProvider?.name ?? "")")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                ForEach(existingForProvider) { model in
                    HStack(spacing: DesignSystem.Spacing.sm) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.modelID)
                                .font(DesignSystem.Typography.monoSmall)
                            if !model.displayName.isEmpty,
                               model.displayName.caseInsensitiveCompare(model.modelID) != .orderedSame {
                                Text(model.displayName)
                                    .font(DesignSystem.Typography.tiny)
                                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                            }
                        }
                        Spacer()
                        Button(role: .destructive) {
                            if let providerID = selectedProvider?.id {
                                onRemove(providerID, model.modelID)
                            }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove this custom model")
                    }
                }
            }

            HStack {
                Button("Done") { dismiss() }
                Spacer()
                Button("Add model") {
                    guard let providerID = selectedProvider?.id else { return }
                    onAdd(
                        providerID,
                        modelID.trimmingCharacters(in: .whitespacesAndNewlines),
                        displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                    modelID = ""
                    displayName = ""
                }
                .buttonStyle(.borderedProminent)
                .disabled(validationMessage != nil || selectedProvider == nil)
            }
        }
        .padding(DesignSystem.Spacing.lg)
        .frame(minWidth: 460)
        .onAppear {
            if selectedProviderID.isEmpty {
                selectedProviderID = providers.first?.id ?? ""
            }
        }
    }
}
