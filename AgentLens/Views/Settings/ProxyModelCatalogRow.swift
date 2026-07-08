import OpenBurnBarCore
import SwiftUI

struct ProxyModelCatalogRow: View {
    let model: ProxyAdvertisedModel
    let onToggleAdvertisement: ((ProxyAdvertisedModel, Bool) -> Void)?
    var existingVariantLevels: Set<BurnBarThinkingLevel> = []
    var onUpsertThinkingVariant: ((ProxyAdvertisedModel, BurnBarThinkingLevel) -> Void)?
    var onRemoveThinkingVariant: ((ProxyAdvertisedModel) -> Void)?
    var onUpsertModelAlias: ((ProxyAdvertisedModel, BurnBarModelAlias) async -> String?)?
    var onRemoveModelAlias: ((ProxyAdvertisedModel) -> Void)?
    var onSetDisplayName: ((ProxyAdvertisedModel, String) async -> String?)?
    var onClearDisplayName: ((ProxyAdvertisedModel) -> Void)?

    @State private var showsAliasEditor = false
    @State private var aliasDraft = ModelAliasEditorDraft.empty
    @State private var showsRenameSheet = false

    private var routeTint: Color {
        if model.routeEligible { return DesignSystem.Colors.success }
        return model.lastError == nil ? DesignSystem.Colors.warning : DesignSystem.Colors.error
    }

    private var quotaTint: Color {
        switch model.quotaState.lowercased() {
        case "healthy", "available", "ok":
            return DesignSystem.Colors.success
        case "exhausted", "auth_failed", "missing_credential", "disabled":
            return DesignSystem.Colors.error
        case "cooling_down", "limited", "unknown":
            return DesignSystem.Colors.warning
        default:
            return DesignSystem.Colors.textSecondary
        }
    }

    private var resolvedThinkingLevel: BurnBarThinkingLevel? {
        guard let raw = model.thinkingLevel else { return nil }
        return BurnBarThinkingLevel(rawValue: raw)
    }

    private var supportsThinkingVariants: Bool {
        guard model.isBaseCatalogRow else { return false }
        let id = model.modelID.lowercased()
        let provider = model.providerID.lowercased()
        if provider == "anthropic" {
            let isOpus4Plus = id.contains("opus") && id.contains("-4")
            let isSonnet4Plus = id.contains("sonnet") && id.contains("-4")
            return isOpus4Plus || isSonnet4Plus
        }
        if provider == "openai" {
            return id.hasPrefix("gpt-5") || id.contains("codex") || id.hasPrefix("o1") || id.hasPrefix("o3")
        }
        return false
    }

    var body: some View {
        HStack(alignment: .center, spacing: DesignSystem.Spacing.sm) {
            Circle()
                .fill(routeTint)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 3) {
                if model.isUserModelAlias {
                    Text(model.modelID)
                        .font(DesignSystem.Typography.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                } else {
                    Text(model.displayName)
                        .font(DesignSystem.Typography.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                        .lineLimit(1)
                }
                HStack(spacing: 5) {
                    if model.isUserModelAlias {
                        if model.displayName != model.modelID {
                            Text(model.displayName)
                                .font(DesignSystem.Typography.monoTiny)
                                .foregroundStyle(DesignSystem.Colors.textMuted)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Text("•")
                                .font(DesignSystem.Typography.tiny)
                                .foregroundStyle(DesignSystem.Colors.textMuted.opacity(0.7))
                        }
                        if let baseModelID = model.baseModelID {
                            Text("→ \(baseModelID)")
                                .font(DesignSystem.Typography.monoTiny)
                                .foregroundStyle(DesignSystem.Colors.textMuted)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                    } else {
                        Text(model.modelID)
                            .font(DesignSystem.Typography.monoTiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    Text("•")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted.opacity(0.7))
                    Text(model.accountLabel)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text("•")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted.opacity(0.7))
                    Text(model.sourceKind.replacingOccurrences(of: "_", with: " "))
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: DesignSystem.Spacing.sm)
            if model.isUserModelAlias {
                tag("custom alias", tint: DesignSystem.Colors.ember)
            }
            if model.isBaseCatalogRow && model.displayNameIsCustom {
                tag("renamed", tint: DesignSystem.Colors.purple)
            }
            if let level = resolvedThinkingLevel {
                tag("think · \(level.displayLabel.lowercased())", tint: DesignSystem.Colors.purple)
            }
            tag(model.quotaState.replacingOccurrences(of: "_", with: " "), tint: quotaTint)
            tag(model.routeEligible ? "route ready" : "blocked", tint: routeTint)
            tag(advertisementLabel, tint: advertisementTint)
            if model.isUserModelAlias, let onRemoveModelAlias {
                Button {
                    onRemoveModelAlias(model)
                } label: {
                    Image(systemName: "minus.circle")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(DesignSystem.Colors.textMuted)
                .help("Remove the custom alias \(model.modelID).")
            } else if model.isUserModelAlias, onUpsertModelAlias != nil {
                Button {
                    aliasDraft = ModelAliasEditorDraft(model: model)
                    showsAliasEditor = true
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(DesignSystem.Colors.ember)
                .help("Edit alias \(model.modelID).")
            } else if model.isThinkingLevelVariant, let onRemoveThinkingVariant {
                Button {
                    onRemoveThinkingVariant(model)
                } label: {
                    Image(systemName: "minus.circle")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(DesignSystem.Colors.textMuted)
                .help("Remove the \(resolvedThinkingLevel?.displayLabel ?? "") thinking variant.")
            } else if supportsThinkingVariants, let onUpsertThinkingVariant {
                Menu {
                    ForEach(BurnBarThinkingLevel.allCases, id: \.self) { level in
                        Button("Add \(level.displayLabel) variant") {
                            onUpsertThinkingVariant(model, level)
                        }
                        .disabled(existingVariantLevels.contains(level))
                    }
                } label: {
                    Image(systemName: "brain")
                        .font(.system(size: 13, weight: .medium))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(DesignSystem.Colors.purple)
                .help("Add a thinking-level variant for \(model.modelID).")
            } else if model.isBaseCatalogRow, onSetDisplayName != nil || onUpsertModelAlias != nil {
                Button {
                    showsRenameSheet = true
                } label: {
                    Label("Rename…", systemImage: "character.cursor.ibeam")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(DesignSystem.Colors.ember)
                .help("Rename \(model.modelID) — change the name shown in Hermes, PI, Droid, and other clients.")
            }
            if let onToggleAdvertisement {
                Toggle(
                    "Advertise \(model.displayName)",
                    isOn: Binding(
                        get: { model.advertisementEnabled },
                        set: { onToggleAdvertisement(model, $0) }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .help(advertisementHelp)
                .accessibilityHint(advertisementHelp)
            }
        }
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .help(model.lastError ?? "\(model.modelID) via \(model.providerName) source \(model.sourceID)")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
        .sheet(isPresented: $showsAliasEditor) {
            ModelAliasEditorSheet(
                draft: $aliasDraft,
                onSave: { alias in
                    guard let onUpsertModelAlias else { return nil }
                    return await onUpsertModelAlias(model, alias)
                },
                onCancel: {
                    showsAliasEditor = false
                },
                onSaved: {
                    showsAliasEditor = false
                }
            )
        }
        .sheet(isPresented: $showsRenameSheet) {
            ModelRenameSheet(
                model: model,
                currentDisplayName: model.displayNameIsCustom ? model.displayName : "",
                canSetDisplayName: onSetDisplayName != nil,
                canCreateAlias: onUpsertModelAlias != nil,
                onSaveDisplayName: { name in
                    guard let onSetDisplayName else { return nil }
                    return await onSetDisplayName(model, name)
                },
                onResetDisplayName: {
                    onClearDisplayName?(model)
                    showsRenameSheet = false
                },
                onCreateAlias: { alias in
                    guard let onUpsertModelAlias else { return nil }
                    return await onUpsertModelAlias(model, alias)
                },
                onCancel: {
                    showsRenameSheet = false
                },
                onSaved: {
                    showsRenameSheet = false
                }
            )
        }
    }

    private func tag(_ label: String, tint: Color) -> some View {
        Text(label)
            .font(DesignSystem.Typography.tiny)
            .fontWeight(.semibold)
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tint.opacity(0.10))
            .clipShape(Capsule())
    }

    private var advertisementLabel: String {
        if model.advertised { return "advertised" }
        if model.advertisementEnabled { return "not live" }
        return "hidden"
    }

    private var advertisementTint: Color {
        if model.advertised { return DesignSystem.Colors.success }
        if model.advertisementEnabled { return DesignSystem.Colors.warning }
        return DesignSystem.Colors.textMuted
    }

    private var advertisementHelp: String {
        if model.advertisementEnabled {
            return "Hide \(model.modelID) from /v1/models and future Droid syncs for this provider."
        }
        return "Advertise \(model.modelID) through /v1/models and future Droid syncs for this provider."
    }

    private var accessibilitySummary: String {
        let route = model.routeEligible ? "route ready" : "blocked"
        let quota = model.quotaState.replacingOccurrences(of: "_", with: " ")
        return "\(model.displayName), \(model.providerName), \(model.accountLabel), \(quota), \(route), \(advertisementLabel)"
    }
}

private struct ModelAliasEditorDraft: Equatable {
    var baseModelID: String
    var aliasID: String
    var displayName: String
    var hidesBaseModel: Bool
    var createdAt: Date

    static var empty: ModelAliasEditorDraft {
        ModelAliasEditorDraft(baseModelID: "", aliasID: "", displayName: "", hidesBaseModel: false, createdAt: Date())
    }

    init(baseModel: ProxyAdvertisedModel) {
        self.baseModelID = baseModel.modelID
        self.aliasID = ""
        self.displayName = ""
        self.hidesBaseModel = false
        self.createdAt = Date()
    }

    init(model: ProxyAdvertisedModel) {
        self.baseModelID = model.baseModelID ?? model.modelID
        self.aliasID = model.modelID
        self.displayName = model.displayName == model.modelID ? "" : model.displayName
        self.hidesBaseModel = model.hidesBaseModel
        self.createdAt = Date()
    }

    init(
        baseModelID: String,
        aliasID: String,
        displayName: String,
        hidesBaseModel: Bool,
        createdAt: Date
    ) {
        self.baseModelID = baseModelID
        self.aliasID = aliasID
        self.displayName = displayName
        self.hidesBaseModel = hidesBaseModel
        self.createdAt = createdAt
    }

    var isValid: Bool {
        BurnBarModelAlias.isValidAliasID(aliasID)
            && !baseModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && aliasID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                != baseModelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func makeAlias() -> BurnBarModelAlias {
        let trimmedID = aliasID.trimmingCharacters(in: .whitespacesAndNewlines)
        return BurnBarModelAlias(
            aliasID: trimmedID,
            baseModelID: baseModelID.trimmingCharacters(in: .whitespacesAndNewlines),
            displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
            hidesBaseModel: hidesBaseModel,
            createdAt: createdAt,
            updatedAt: Date()
        )
    }
}

private struct ModelAliasEditorSheet: View {
    @Binding var draft: ModelAliasEditorDraft
    let onSave: (BurnBarModelAlias) async -> String?
    let onCancel: () -> Void
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var saveError: String?
    @State private var isSaving = false

    private var validationMessage: String? {
        let trimmedID = draft.aliasID.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedID.isEmpty { return "Enter a custom model id." }
        if !BurnBarModelAlias.isValidAliasID(trimmedID) {
            return "Use letters, numbers, and . _ - : / only (no spaces)."
        }
        if trimmedID.lowercased() == draft.baseModelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            return "The alias id must differ from the canonical model id."
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            Text("Custom model alias")
                .font(DesignSystem.Typography.headline)
                .fontWeight(.semibold)
            Text("Clients call the alias id in /v1/models and chat requests. BurnBar routes to \(draft.baseModelID).")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Custom model id", text: $draft.aliasID)
                .textFieldStyle(.roundedBorder)
                .font(DesignSystem.Typography.monoSmall)

            TextField("Display name (optional)", text: $draft.displayName)
                .textFieldStyle(.roundedBorder)

            Toggle("Hide original model in /v1/models", isOn: $draft.hidesBaseModel)
                .font(DesignSystem.Typography.caption)

            if let validationMessage {
                Text(validationMessage)
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
                Spacer()
                Button("Save alias") {
                    Task {
                        isSaving = true
                        defer { isSaving = false }
                        saveError = await onSave(draft.makeAlias())
                        if saveError == nil {
                            onSaved()
                            dismiss()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!draft.isValid || isSaving)
            }
        }
        .padding(DesignSystem.Spacing.lg)
        .frame(minWidth: 420)
    }
}
