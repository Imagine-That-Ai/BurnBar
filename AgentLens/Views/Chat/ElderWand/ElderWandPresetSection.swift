import OpenBurnBarCore
import SwiftUI

// MARK: - Elder Wand Preset Section
//
// Lists the user's saved Elder Wand presets and exposes the lifecycle actions:
// edit (load into the configurator), set-default, rename, delete, plus the
// save affordance for the in-flight edit. Operates directly on the injected
// `@Bindable` store — `@Bindable`, never `@State`, because the store is owned
// elsewhere (SettingsManager).

struct ElderWandPresetSection: View {
    @Bindable var settings: ElderWandSettings
    /// The live edit model, so "Save" can lower the current edit into a preset
    /// and "Edit" can load a saved preset back into the buffer.
    @Bindable var editor: ElderWandConfiguratorModel

    @State private var renameTarget: ElderWandPreset?
    @State private var renameText: String = ""
    @State private var deleteTarget: ElderWandPreset?

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            header
            saveBar

            if settings.presets.isEmpty {
                emptyState
            } else {
                VStack(spacing: DesignSystem.Spacing.sm) {
                    ForEach(settings.presets) { preset in
                        ElderWandPresetRow(
                            preset: preset,
                            isActive: settings.activePreset?.id == preset.id,
                            onEdit: { editor.load(from: preset) },
                            onSetDefault: { settings.setDefault(id: preset.id) },
                            onRename: { beginRename(preset) },
                            onDelete: { deleteTarget = preset }
                        )
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .alert("Rename Preset", isPresented: renameAlertBinding) {
            TextField("Preset name", text: $renameText)
            Button("Save") { commitRename() }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        } message: {
            Text("Choose a new name for this Elder Wand preset.")
        }
        .confirmationDialog(
            "Delete this preset?",
            isPresented: deleteConfirmBinding,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { commitDelete() }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: {
            if let deleteTarget {
                Text("\(deleteTarget.name) will be removed. This can't be undone.")
            }
        }
    }

    // MARK: - Header + save bar

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Presets")
                .font(DesignSystem.Typography.headline)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
            Text("The default preset runs when The Elder Wand is on.")
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
        }
        .accessibilityElement(children: .combine)
    }

    private var saveBar: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            TextField("Name this panel", text: $editor.name)
                .textFieldStyle(.plain)
                .font(DesignSystem.Typography.body)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .padding(.horizontal, DesignSystem.Spacing.md)
                .padding(.vertical, DesignSystem.Spacing.sm)
                .liquidGlassSurface(in: .rect(cornerRadius: DesignSystem.Radius.md))
                .accessibilityLabel("Preset name")

            GlassButton(
                title: editor.editingPresetID == nil ? "Save" : "Update",
                icon: "square.and.arrow.down",
                style: .prominent,
                action: save
            )
            .frame(maxWidth: 120)
            .disabled(!editor.isValid)
            .opacity(editor.isValid ? 1 : 0.5)
        }
        .animation(DesignSystem.Animation.snappy, value: editor.isValid)
        .animation(DesignSystem.Animation.snappy, value: editor.editingPresetID)
    }

    private var emptyState: some View {
        Text("No saved presets yet. Build a panel above, name it, and save.")
            .font(DesignSystem.Typography.caption)
            .foregroundStyle(DesignSystem.Colors.textMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DesignSystem.Spacing.md)
            .liquidGlassSurface(in: .rect(cornerRadius: DesignSystem.Radius.md))
    }

    // MARK: - Actions

    private func save() {
        guard let preset = editor.buildPreset() else { return }
        settings.save(preset)
        editor.reset()
    }

    private func beginRename(_ preset: ElderWandPreset) {
        renameTarget = preset
        renameText = preset.name
    }

    private func commitRename() {
        guard let target = renameTarget else { return }
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            settings.rename(id: target.id, to: trimmed)
        }
        renameTarget = nil
    }

    private func commitDelete() {
        guard let target = deleteTarget else { return }
        if editor.editingPresetID == target.id { editor.reset() }
        settings.delete(id: target.id)
        deleteTarget = nil
    }

    // MARK: - Presentation bindings

    private var renameAlertBinding: Binding<Bool> {
        Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )
    }

    private var deleteConfirmBinding: Binding<Bool> {
        Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        )
    }
}

// MARK: - Row

/// One saved preset: name + default badge + a summary of its panel size and
/// judge, with an action menu. Extracted so each row's hover/menu state stays
/// isolated and the list body stays a flat `ForEach`.
private struct ElderWandPresetRow: View {
    let preset: ElderWandPreset
    let isActive: Bool
    let onEdit: () -> Void
    let onSetDefault: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void

    private var summary: String {
        let panel = preset.analysisModelIDs.count
        let panelLabel = panel == 1 ? "1 model" : "\(panel) models"
        let judge = ChatSessionController.abbreviateChatModelName(preset.judgeModelID)
        return "\(panelLabel) · judge \(judge)"
    }

    var body: some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.primaryGradient)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(DesignSystem.Colors.ember.opacity(0.12))
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: DesignSystem.Spacing.xs) {
                    Text(preset.name)
                        .font(DesignSystem.Typography.body)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                        .lineLimit(1)

                    if isActive {
                        Text("Default")
                            .font(DesignSystem.Typography.tiny)
                            .fontWeight(.semibold)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(DesignSystem.Colors.ember.opacity(0.14))
                            .foregroundStyle(DesignSystem.Colors.ember)
                            .clipShape(Capsule())
                    }
                }

                Text(summary)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: DesignSystem.Spacing.sm)

            Menu {
                Button("Edit", systemImage: "slider.horizontal.3", action: onEdit)
                if !isActive {
                    Button("Set as Default", systemImage: "star", action: onSetDefault)
                }
                Button("Rename", systemImage: "pencil", action: onRename)
                Divider()
                Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Preset actions")
        }
        .padding(DesignSystem.Spacing.md)
        .liquidGlassSurface(in: .rect(cornerRadius: DesignSystem.Radius.md))
        .overlay {
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md)
                .strokeBorder(
                    DesignSystem.Colors.ember.opacity(isActive ? 0.45 : 0),
                    lineWidth: 1
                )
        }
        .animation(DesignSystem.Animation.snappy, value: isActive)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(preset.name)\(isActive ? ", default" : ""). \(summary)")
    }
}
