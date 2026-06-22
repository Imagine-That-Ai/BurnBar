import AppKit
import SwiftUI

// MARK: - PetCatalog

/// Resolves the pets bundled with the app for the form picker (PLAN C8 "lists
/// every pet in the bundle with its 2D preview, and its 3D preview if a GLB
/// exists"). Reuses ``PetDefinition/loadBundled(id:in:)``; it only adds the
/// *enumeration* the picker needs.
@MainActor
enum PetCatalog {
    struct PetGroup: Identifiable {
        var id: String { name }
        let name: String
        let definitions: [PetDefinition]
    }

    static let groupOrder = ["Founders", "Legends", "Kawaii Animals"]

    /// The pet ids shipped in `PetCompanion/Resources/Pets/`. Discovered from the
    /// bundle so adding a pet folder needs no code change; falls back to the known
    /// roster when the bundle layout can't be enumerated (e.g. in tests).
    static func bundledPetIDs(in bundle: Bundle = .main) -> [String] {
        if let petsRoot = bundle.url(forResource: "Pets", withExtension: nil),
           let entries = try? FileManager.default.contentsOfDirectory(
                at: petsRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
           ) {
            let ids = entries
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
                .map { $0.lastPathComponent }
                .sorted()
            if !ids.isEmpty { return ids }
        }
        return knownRoster
    }

    /// The synced model pet ids shipped in `PetCompanion/Resources/Models/<id>/`.
    static func bundledModelPetIDs(in bundle: Bundle = .main) -> [String] {
        guard let modelsRoot = bundle.url(forResource: "Models", withExtension: nil),
              let entries = try? FileManager.default.contentsOfDirectory(
                    at: modelsRoot,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
              ) else { return [] }
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("petdef.json").path) }
            .map { $0.lastPathComponent }
            .sorted()
    }

    /// Load every bundled 3D definition, skipping atlas-only pets and malformed files.
    static func bundledDefinitions(in bundle: Bundle = .main) -> [PetDefinition] {
        var seen = Set<String>()
        let synced = bundledModelPetIDs(in: bundle).compactMap { PetDefinition.loadBundled(id: $0, in: bundle) }
        let legacyModels = bundledPetIDs(in: bundle).compactMap { PetDefinition.loadBundled(id: $0, in: bundle) }

        return (synced + legacyModels)
            .filter { $0.model3d != nil }
            .filter { seen.insert($0.id).inserted }
    }

    /// The roster shipped today (kept as a deterministic fallback).
    static let knownRoster = ["claudecode", "founder-jobs", "go-gopher", "goose", "huggingface"]

    /// The image resource name for a pet's 2D atlas preview, if it has one.
    static func atlasPreviewName(for def: PetDefinition) -> String? {
        def.atlas2d?.image
    }

    static func preferredModelForm(for def: PetDefinition) -> PetForm? {
        guard let model = def.model3d else { return nil }
        return .model3d(glbName: model.glb)
    }

    static func groupedDefinitions(_ definitions: [PetDefinition]) -> [PetGroup] {
        let modelDefinitions = definitions.filter { $0.model3d != nil }
        let grouped = Dictionary(grouping: modelDefinitions, by: groupName(for:))
        return groupOrder.compactMap { name in
            guard let defs = grouped[name], !defs.isEmpty else { return nil }
            return PetGroup(
                name: name,
                definitions: defs.sorted {
                    ($0.displayName ?? $0.name).localizedCaseInsensitiveCompare($1.displayName ?? $1.name) == .orderedAscending
                }
            )
        }
    }

    static func groupName(for def: PetDefinition) -> String {
        if let group = def.group, groupOrder.contains(group) { return group }
        if def.id.hasPrefix("founder-") { return "Founders" }
        if def.id.hasPrefix("kawaii-") { return "Kawaii Animals" }
        return "Legends"
    }
}

// MARK: - PetFormPickerView

/// The form picker (PLAN C8): a grid of bundled pets, each showing a 2D preview
/// and a `3D` badge when a GLB form exists. Selecting a pet reports its id and
/// preferred ``PetForm`` so the host swaps the skin live (no restart). Styled
/// with ``DesignSystem`` tokens to read as native chrome.
struct PetFormPickerView: View {
    /// The pets to choose from (defaults to the bundled catalog).
    var definitions: [PetDefinition]
    /// The currently-selected pet id.
    @Binding var selectedPetID: String
    /// Called when the user picks a pet, with its id and preferred form.
    var onSelect: (String, PetForm) -> Void

    init(
        definitions: [PetDefinition] = PetCatalog.bundledDefinitions(),
        selectedPetID: Binding<String>,
        onSelect: @escaping (String, PetForm) -> Void
    ) {
        self.definitions = definitions
        self._selectedPetID = selectedPetID
        self.onSelect = onSelect
    }

    private let columns = [GridItem(.adaptive(minimum: 108), spacing: DesignSystem.Spacing.md)]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                ForEach(PetCatalog.groupedDefinitions(definitions)) { group in
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                        Text(group.name)
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                        LazyVGrid(columns: columns, spacing: DesignSystem.Spacing.md) {
                            ForEach(group.definitions, id: \.id) { def in
                                cell(for: def)
                            }
                        }
                    }
                }
            }
            .padding(DesignSystem.Spacing.xs)
        }
    }

    private func cell(for def: PetDefinition) -> some View {
        let isSelected = def.id == selectedPetID
        let has3D = def.model3d != nil
        return Button {
            selectedPetID = def.id
            if let form = PetCatalog.preferredModelForm(for: def) { onSelect(def.id, form) }
        } label: {
            VStack(spacing: DesignSystem.Spacing.xs) {
                preview(for: def)
                    .frame(width: 84, height: 84)
                    .background(DesignSystem.Colors.surface.opacity(0.5),
                                in: RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous))
                Text(def.displayName ?? def.name)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .lineLimit(1)
                HStack(spacing: DesignSystem.Spacing.xxs) {
                    if has3D { formBadge("3D") }
                }
            }
            .padding(DesignSystem.Spacing.sm)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                    .fill(isSelected ? DesignSystem.Colors.surface.opacity(0.9) : .clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                            .strokeBorder(isSelected ? AnyShapeStyle(DesignSystem.Colors.primaryGradient)
                                                     : AnyShapeStyle(DesignSystem.Colors.border.opacity(0.4)),
                                          lineWidth: isSelected ? 2 : 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(def.displayName ?? def.name)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// A 2D atlas preview (first frame of the default state) when an atlas image
    /// is bundled, else a glyph placeholder.
    @ViewBuilder
    private func preview(for def: PetDefinition) -> some View {
        if let name = PetCatalog.atlasPreviewName(for: def),
           let image = NSImage(named: name) ?? bundledImage(named: name) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: def.model3d != nil ? "cube.transparent" : "pawprint.fill")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(DesignSystem.Colors.textMuted)
        }
    }

    private func formBadge(_ text: String) -> some View {
        Text(text)
            .font(DesignSystem.Typography.tiny)
            .foregroundStyle(DesignSystem.Colors.textSecondary)
            .padding(.horizontal, DesignSystem.Spacing.xs)
            .padding(.vertical, 1)
            .background(DesignSystem.Colors.border.opacity(0.25), in: Capsule())
    }

    /// Look up an atlas master image inside the `Pets/<id>` resource subfolder
    /// when it isn't a top-level asset-catalog image.
    private func bundledImage(named name: String) -> NSImage? {
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension.isEmpty ? "png" : (name as NSString).pathExtension
        guard let url = Bundle.main.url(forResource: stem, withExtension: ext, subdirectory: "Pets")
            ?? Bundle.main.url(forResource: stem, withExtension: ext) else { return nil }
        return NSImage(contentsOf: url)
    }
}
