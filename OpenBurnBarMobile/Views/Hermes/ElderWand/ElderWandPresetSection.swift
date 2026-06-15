import SwiftUI
import OpenBurnBarCore

// MARK: - Elder Wand Preset Section (iOS)
//
// The named-preset manager: name the current draft, save it, set the default,
// and manage saved panels (set-default / edit / delete). Everything funnels
// through `ElderWandConfiguratorModel`, which writes to `ElderWandSettings.shared`
// (the store owns the one-default sanitiser + persistence). The active default
// is the preset the chat send-path uses.

struct ElderWandPresetSection: View {
    @Bindable var model: ElderWandConfiguratorModel

    @FocusState private var nameFocused: Bool
    @State private var pendingDeleteID: String?

    var body: some View {
        AuroraGlassCard(variant: .standard, cornerRadius: MobileTheme.Radius.lg) {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
                header
                nameField
                actionRow
                if !model.savedPresets.isEmpty {
                    Divider().overlay(MobileTheme.Colors.border.opacity(0.3))
                    savedList
                }
            }
        }
        .accessibilityElement(children: .contain)
        .confirmationDialog(
            "Delete this panel?",
            isPresented: deleteDialogPresented,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let id = pendingDeleteID {
                    model.delete(id: id)
                    HapticBus.destructive()
                }
                pendingDeleteID = nil
            }
            Button("Cancel", role: .cancel) { pendingDeleteID = nil }
        } message: {
            Text("This removes the saved panel. It can't be undone.")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(MobileTheme.Colors.hermesAureate)
            Text(model.isEditingExistingPreset ? "Edit panel" : "Save as panel")
                .font(MobileTheme.Typography.caption)
                .fontWeight(.semibold)
                .foregroundStyle(MobileTheme.Colors.textSecondary)
                .textCase(.uppercase)
                .tracking(0.5)
            Spacer(minLength: 0)
            if model.isEditingExistingPreset {
                Button {
                    model.resetToBlank()
                    HapticBus.toggle()
                } label: {
                    Label("New", systemImage: "plus")
                        .font(MobileTheme.Typography.caption)
                        .fontWeight(.semibold)
                }
                .buttonStyle(.plain)
                .foregroundStyle(MobileTheme.Colors.hermesAureate)
                .accessibilityLabel("Start a new panel")
            }
        }
    }

    // MARK: Name field

    private var nameField: some View {
        TextField("Panel name (e.g. Research bench)", text: $model.draftName)
            .textInputAutocapitalization(.words)
            .autocorrectionDisabled()
            .focused($nameFocused)
            .submitLabel(.done)
            .onSubmit { nameFocused = false }
            .font(MobileTheme.Typography.body)
            .foregroundStyle(MobileTheme.Colors.textPrimary)
            .padding(.horizontal, MobileTheme.Spacing.md)
            .padding(.vertical, MobileTheme.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: MobileTheme.Radius.md, style: .continuous)
                    .fill(MobileTheme.Colors.surface.opacity(0.55))
                    .overlay(
                        RoundedRectangle(cornerRadius: MobileTheme.Radius.md, style: .continuous)
                            .stroke(MobileTheme.Colors.border.opacity(0.45), lineWidth: 0.5)
                    )
            )
            .accessibilityLabel("Panel name")
    }

    // MARK: Action row

    private var actionRow: some View {
        HStack(spacing: MobileTheme.Spacing.sm) {
            Button {
                if model.save() != nil {
                    nameFocused = false
                    HapticBus.primaryAction()
                }
            } label: {
                Label(model.isEditingExistingPreset ? "Update" : "Save", systemImage: "checkmark")
                    .font(MobileTheme.Typography.body)
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, MobileTheme.Spacing.sm)
            }
            .buttonStyle(.plain)
            .foregroundStyle(model.canSave ? MobileTheme.Colors.textPrimary : MobileTheme.Colors.textMuted)
            .background(saveBackground)
            .disabled(!model.canSave)
            .accessibilityHint("Saves this panel")

            Button {
                model.setEditingAsDefault()
                nameFocused = false
                HapticBus.milestone()
            } label: {
                Label("Set default", systemImage: "star.fill")
                    .font(MobileTheme.Typography.body)
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, MobileTheme.Spacing.sm)
            }
            .buttonStyle(.plain)
            .foregroundStyle(model.canSave ? MobileTheme.amber : MobileTheme.Colors.textMuted)
            .background(
                RoundedRectangle(cornerRadius: MobileTheme.Radius.md, style: .continuous)
                    .fill(MobileTheme.amber.opacity(model.canSave ? 0.14 : 0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: MobileTheme.Radius.md, style: .continuous)
                            .stroke(MobileTheme.amber.opacity(model.canSave ? 0.4 : 0.12), lineWidth: 0.6)
                    )
            )
            .disabled(!model.canSave)
            .accessibilityHint("Saves and makes this the active panel")
        }
    }

    private var saveBackground: some View {
        RoundedRectangle(cornerRadius: MobileTheme.Radius.md, style: .continuous)
            .fill(MobileTheme.Colors.surfaceElevated.opacity(model.canSave ? 0.9 : 0.4))
            .overlay(
                RoundedRectangle(cornerRadius: MobileTheme.Radius.md, style: .continuous)
                    .stroke(MobileTheme.Colors.border.opacity(model.canSave ? 0.5 : 0.2), lineWidth: 0.6)
            )
    }

    // MARK: Saved list

    private var savedList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Saved panels")
                .font(MobileTheme.Typography.tiny)
                .fontWeight(.semibold)
                .foregroundStyle(MobileTheme.Colors.textMuted)
                .textCase(.uppercase)
                .tracking(0.5)
            ForEach(model.savedPresets) { preset in
                ElderWandPresetRow(
                    preset: preset,
                    isActive: preset.id == model.activePresetID,
                    isEditing: preset.id == model.activePresetID && model.isEditingExistingPreset,
                    onEdit: {
                        model.load(preset)
                        nameFocused = false
                        HapticBus.toggle()
                    },
                    onSetDefault: {
                        model.setDefault(id: preset.id)
                        HapticBus.milestone()
                    },
                    onDelete: { pendingDeleteID = preset.id }
                )
            }
        }
    }

    private var deleteDialogPresented: Binding<Bool> {
        Binding(
            get: { pendingDeleteID != nil },
            set: { if !$0 { pendingDeleteID = nil } }
        )
    }
}

// MARK: - Saved preset row

private struct ElderWandPresetRow: View {
    let preset: ElderWandPreset
    let isActive: Bool
    let isEditing: Bool
    let onEdit: () -> Void
    let onSetDefault: () -> Void
    let onDelete: () -> Void

    private var summary: String {
        let panel = preset.analysisModelIDs.count
        let panelWord = panel == 1 ? "model" : "models"
        let judge = FriendlyModelName.format(preset.judgeModelID)
        return "\(panel) \(panelWord) · judge \(judge)"
    }

    var body: some View {
        HStack(spacing: MobileTheme.Spacing.sm) {
            Button(action: onEdit) {
                HStack(spacing: MobileTheme.Spacing.sm) {
                    Image(systemName: isActive ? "star.fill" : "star")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(isActive ? MobileTheme.amber : MobileTheme.Colors.textMuted)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(preset.name)
                            .font(MobileTheme.Typography.body)
                            .fontWeight(.semibold)
                            .foregroundStyle(MobileTheme.Colors.textPrimary)
                            .lineLimit(1)
                        Text(summary)
                            .font(MobileTheme.Typography.tiny)
                            .foregroundStyle(MobileTheme.Colors.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if isEditing {
                        Text("Editing")
                            .font(.system(size: 11, weight: .heavy, design: .rounded))
                            .foregroundStyle(MobileTheme.Colors.hermesAureate)
                    }
                }
                .padding(MobileTheme.Spacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: MobileTheme.Radius.md, style: .continuous)
                        .fill(MobileTheme.Colors.surface.opacity(0.5))
                        .overlay(
                            RoundedRectangle(cornerRadius: MobileTheme.Radius.md, style: .continuous)
                                .stroke(
                                    isActive ? MobileTheme.amber.opacity(0.5) : MobileTheme.Colors.border.opacity(0.4),
                                    lineWidth: isActive ? 1.0 : 0.5
                                )
                        )
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(preset.name), \(summary)\(isActive ? ", default panel" : "")")
            .accessibilityHint("Loads this panel for editing")

            Menu {
                if !isActive {
                    Button {
                        onSetDefault()
                    } label: {
                        Label("Set as default", systemImage: "star.fill")
                    }
                }
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(MobileTheme.Colors.textMuted)
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel("More actions for \(preset.name)")
        }
    }
}
