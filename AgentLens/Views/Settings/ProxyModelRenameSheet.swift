import OpenBurnBarCore
import SwiftUI

// MARK: - Model Rename Sheet
//
// The display-name-first "Rename" experience for a base catalog model.
//
//   • The headline field sets a verbatim *display-name override*: the model
//     keeps its wire id and routing, but presents under the chosen name in
//     `/v1/models`, every wired CLI picker, and the BurnBar / Hermes / PI
//     apps. Free text — spaces and punctuation allowed. Empty + Save (or
//     "Reset to default") clears the override.
//
//   • The Advanced disclosure is the power-user escape hatch for clients that
//     display the raw model id rather than a display name (e.g. Forge, generic
//     OpenAI tools): it mints a custom wire id (an alias) those clients call
//     and show directly, while BurnBar still routes to the canonical model.
struct ModelRenameSheet: View {
    let model: ProxyAdvertisedModel
    let currentDisplayName: String
    let canSetDisplayName: Bool
    let canCreateAlias: Bool
    let onSaveDisplayName: (String) async -> String?
    let onResetDisplayName: () -> Void
    let onCreateAlias: (BurnBarModelAlias) async -> String?
    let onCancel: () -> Void
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var displayName: String
    @State private var showsAdvanced = false
    @State private var aliasID = ""
    @State private var hidesBaseModel = false
    @State private var saveError: String?
    @State private var isSaving = false

    init(
        model: ProxyAdvertisedModel,
        currentDisplayName: String,
        canSetDisplayName: Bool,
        canCreateAlias: Bool,
        onSaveDisplayName: @escaping (String) async -> String?,
        onResetDisplayName: @escaping () -> Void,
        onCreateAlias: @escaping (BurnBarModelAlias) async -> String?,
        onCancel: @escaping () -> Void,
        onSaved: @escaping () -> Void
    ) {
        self.model = model
        self.currentDisplayName = currentDisplayName
        self.canSetDisplayName = canSetDisplayName
        self.canCreateAlias = canCreateAlias
        self.onSaveDisplayName = onSaveDisplayName
        self.onResetDisplayName = onResetDisplayName
        self.onCreateAlias = onCreateAlias
        self.onCancel = onCancel
        self.onSaved = onSaved
        _displayName = State(initialValue: currentDisplayName)
    }

    private var trimmedDisplayName: String {
        displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedAliasID: String {
        aliasID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasExistingOverride: Bool {
        !currentDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var usingAliasPath: Bool {
        showsAdvanced && !trimmedAliasID.isEmpty
    }

    private var aliasValidationMessage: String? {
        guard usingAliasPath else { return nil }
        if !BurnBarModelAlias.isValidAliasID(trimmedAliasID) {
            return "Use letters, numbers, and . _ - : / only (no spaces)."
        }
        if trimmedAliasID.lowercased() == model.modelID.lowercased() {
            return "The custom id must differ from \(model.modelID)."
        }
        return nil
    }

    private var canSave: Bool {
        if usingAliasPath {
            return aliasValidationMessage == nil
        }
        return canSetDisplayName && (!trimmedDisplayName.isEmpty || hasExistingOverride)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            Text("Rename model")
                .font(DesignSystem.Typography.headline)
                .fontWeight(.semibold)
            Text("Give “\(model.modelID)” a friendlier name. Routing is unchanged — only the label clients show changes.")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Display name", text: $displayName)
                .textFieldStyle(.roundedBorder)
                .disabled(!canSetDisplayName)

            Text("Shown in Hermes, PI, and Droid. Clients that display the raw model id (e.g. Forge) keep showing “\(model.modelID)” — use Advanced to give those a custom id too.")
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
                .fixedSize(horizontal: false, vertical: true)

            if canCreateAlias {
                DisclosureGroup(isExpanded: $showsAdvanced) {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                        TextField("Custom wire id (e.g. my-fast-coder)", text: $aliasID)
                            .textFieldStyle(.roundedBorder)
                            .font(DesignSystem.Typography.monoSmall)
                        Toggle("Hide the original \(model.modelID)", isOn: $hidesBaseModel)
                            .font(DesignSystem.Typography.caption)
                        Text("Mints a new model id that id-only clients (Forge, generic OpenAI tools) call and display directly. BurnBar still routes it to \(model.modelID).")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 4)
                } label: {
                    Text("Advanced — custom wire id (for Forge & id-only clients)")
                        .font(DesignSystem.Typography.caption)
                        .fontWeight(.medium)
                }
            }

            if let aliasValidationMessage {
                Text(aliasValidationMessage)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.error)
            }
            if let saveError {
                Text(saveError)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.error)
            }

            HStack {
                Button("Cancel") {
                    onCancel()
                    dismiss()
                }
                if hasExistingOverride {
                    Button("Reset to default") {
                        onResetDisplayName()
                        dismiss()
                    }
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                }
                Spacer()
                Button(usingAliasPath ? "Create alias" : "Save") {
                    Task {
                        isSaving = true
                        defer { isSaving = false }
                        if usingAliasPath {
                            let alias = BurnBarModelAlias(
                                aliasID: trimmedAliasID,
                                baseModelID: model.baseModelID ?? model.modelID,
                                displayName: trimmedDisplayName,
                                hidesBaseModel: hidesBaseModel
                            )
                            saveError = await onCreateAlias(alias)
                        } else {
                            saveError = await onSaveDisplayName(trimmedDisplayName)
                        }
                        if saveError == nil {
                            onSaved()
                            dismiss()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSave || isSaving)
            }
        }
        .padding(DesignSystem.Spacing.lg)
        .frame(minWidth: 440)
    }
}
