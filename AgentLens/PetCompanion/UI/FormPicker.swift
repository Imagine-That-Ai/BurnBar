import AppKit
import SwiftUI

// MARK: - PetCatalog

/// Resolves the pets bundled with the app for the form picker (PLAN C8 "lists
/// every pet in the bundle with its 2D preview, and its 3D preview if a GLB
/// exists"). Reuses ``PetDefinition/loadBundled(id:in:)``; it only adds the
/// *enumeration* the picker needs.
@MainActor
enum PetCatalog {
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

    /// Load every bundled definition, skipping any that fail to decode.
    static func bundledDefinitions(in bundle: Bundle = .main) -> [PetDefinition] {
        bundledPetIDs(in: bundle).compactMap { PetDefinition.loadBundled(id: $0, in: bundle) }
    }

    /// The roster shipped today (kept as a deterministic fallback).
    static let knownRoster = ["claudecode", "founder-jobs", "go-gopher", "goose", "huggingface"]

    /// The image resource name for a pet's 2D atlas preview, if it has one.
    static func atlasPreviewName(for def: PetDefinition) -> String? {
        def.atlas2d?.image
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
        definitions: [PetDefinition],
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
            LazyVGrid(columns: columns, spacing: DesignSystem.Spacing.md) {
                ForEach(definitions, id: \.id) { def in
                    cell(for: def)
                }
            }
            .padding(DesignSystem.Spacing.xs)
        }
    }

    private func cell(for def: PetDefinition) -> some View {
        let isSelected = def.id == selectedPetID
        let has3D = def.model3d != nil
        let has2D = def.atlas2d != nil
        return Button {
            selectedPetID = def.id
            if let form = def.defaultForm { onSelect(def.id, form) }
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
                    if has2D { formBadge("2D") }
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
           let image = NSImage(named: name) ?? bundledImage(named: name, petID: def.id) {
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
    private func bundledImage(named name: String, petID: String) -> NSImage? {
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension.isEmpty ? "png" : (name as NSString).pathExtension
        guard let url = Bundle.main.url(forResource: stem, withExtension: ext, subdirectory: "Pets/\(petID)")
            ?? Bundle.main.url(forResource: stem, withExtension: ext) else { return nil }
        return NSImage(contentsOf: url)
    }
}
