import AppKit
import SceneKit
import SwiftUI

// MARK: - PetCatalog

/// Resolves the pets bundled with the app for the form picker (PLAN C8 "lists
/// every pet in the bundle with its 2D preview, and its 3D preview if a GLB
/// exists"). Reuses ``PetDefinition/loadBundled(id:in:)``; it only adds the
/// *enumeration*, *grouping*, and *filtering* the picker library needs.
@MainActor
enum PetCatalog {
    struct PetGroup: Identifiable {
        var id: String { name }
        let name: String
        let definitions: [PetDefinition]
    }

    static let groupOrder = ["Family", "Founders", "Legends", "Modern Icons", "Kawaii Animals", "Meshy"]

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

    /// Load every bundled definition, skipping only malformed files.
    static func bundledDefinitions(in bundle: Bundle = .main) -> [PetDefinition] {
        var seen = Set<String>()
        let synced = bundledModelPetIDs(in: bundle).compactMap { PetDefinition.loadBundled(id: $0, in: bundle) }
        let legacyModels = bundledPetIDs(in: bundle).compactMap { PetDefinition.loadBundled(id: $0, in: bundle) }

        return (synced + legacyModels)
            .filter { $0.defaultForm != nil }
            .filter { seen.insert($0.id).inserted }
    }

    /// The roster shipped today (kept as a deterministic fallback).
    static let knownRoster = ["claudecode", "founder-jobs", "go-gopher", "goose", "huggingface"]

    static func preferredForm(for def: PetDefinition) -> PetForm? {
        def.defaultForm
    }

    static func displayName(for def: PetDefinition) -> String {
        def.displayName ?? def.name
    }

    static func groupedDefinitions(_ definitions: [PetDefinition]) -> [PetGroup] {
        let selectableDefinitions = definitions.filter { $0.defaultForm != nil }
        let grouped = Dictionary(grouping: selectableDefinitions, by: groupName(for:))
        let orderedNames = groupOrder + grouped.keys
            .filter { !groupOrder.contains($0) }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

        return orderedNames.compactMap { name in
            guard let defs = grouped[name], !defs.isEmpty else { return nil }
            return PetGroup(name: name, definitions: sortedByName(defs))
        }
    }

    /// Ordered category chips (name + count) for the picker's quick-nav rail.
    static func categories(_ definitions: [PetDefinition]) -> [(name: String, count: Int)] {
        groupedDefinitions(definitions).map { ($0.name, $0.definitions.count) }
    }

    /// Pure filter used by the picker (and exercised by tests): keep selectable
    /// pets, optionally scoped to a category, matching a case-insensitive query
    /// against display name or category, sorted by display name.
    static func filtered(_ definitions: [PetDefinition], search: String, category: String?) -> [PetDefinition] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let result = definitions
            .filter { $0.defaultForm != nil }
            .filter { category == nil || groupName(for: $0) == category }
            .filter { def in
                guard !query.isEmpty else { return true }
                return displayName(for: def).lowercased().contains(query)
                    || groupName(for: def).lowercased().contains(query)
            }
        return sortedByName(result)
    }

    static func groupName(for def: PetDefinition) -> String {
        if let group = def.group?.trimmingCharacters(in: .whitespacesAndNewlines), !group.isEmpty { return group }
        if def.id.hasPrefix("founder-") { return "Founders" }
        if def.id.hasPrefix("kawaii-") { return "Kawaii Animals" }
        return "Legends"
    }

    private static func sortedByName(_ defs: [PetDefinition]) -> [PetDefinition] {
        defs.sorted { displayName(for: $0).localizedCaseInsensitiveCompare(displayName(for: $1)) == .orderedAscending }
    }
}

// MARK: - PetFormPickerView

/// The pet library (PLAN C8, redesigned): a searchable, category-filterable
/// gallery of every bundled pet. Each card shows a still thumbnail rendered
/// through the live companion's framing pipeline (see ``PetThumbnailStore``), so
/// the grid scrolls smoothly even with 100+ high-poly models. Selecting a pet
/// reports its id and preferred ``PetForm`` so the host swaps the skin live.
struct PetFormPickerView: View {
    var definitions: [PetDefinition]
    @Binding var selectedPetID: String
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

    // One cache per picker instance keeps thumbnail rendering stable without
    // adding a process-wide singleton. SwiftUI preserves this object while the
    // picker is mounted.
    @StateObject private var thumbnails = PetThumbnailStore()
    @State private var searchText = ""
    @State private var selectedCategory: String?
    @FocusState private var searchFocused: Bool

    private let columns = [GridItem(.adaptive(minimum: 132, maximum: 168), spacing: DesignSystem.Spacing.md)]

    private var results: [PetDefinition] {
        PetCatalog.filtered(definitions, search: searchText, category: selectedCategory)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            searchField
            categoryRail
            Divider().overlay(DesignSystem.Colors.borderSubtle)
            gallery
        }
    }

    // MARK: Search

    private var searchField: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.textMuted)
            TextField("Search pets", text: $searchText)
                .textFieldStyle(.plain)
                .font(DesignSystem.Typography.body)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .focused($searchFocused)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, DesignSystem.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .fill(DesignSystem.Colors.surfaceElevated)
                .overlay(
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                        .strokeBorder(
                            searchFocused
                                ? AnyShapeStyle(DesignSystem.Colors.primaryGradient)
                                : AnyShapeStyle(DesignSystem.Colors.border.opacity(0.5)),
                            lineWidth: searchFocused ? 1.5 : 1
                        )
                )
        )
    }

    // MARK: Category rail

    private var categoryRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                categoryPill(title: "All", count: definitions.count, isSelected: selectedCategory == nil) {
                    selectedCategory = nil
                }
                ForEach(PetCatalog.categories(definitions), id: \.name) { category in
                    categoryPill(
                        title: category.name,
                        count: category.count,
                        isSelected: selectedCategory == category.name
                    ) {
                        selectedCategory = (selectedCategory == category.name) ? nil : category.name
                    }
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
        }
    }

    private func categoryPill(title: String, count: Int, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: DesignSystem.Spacing.xs) {
                Text(title)
                    .font(DesignSystem.Typography.caption)
                Text("\(count)")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(isSelected ? Color.white.opacity(0.85) : DesignSystem.Colors.textMuted)
            }
            .foregroundStyle(isSelected ? Color.white : DesignSystem.Colors.textSecondary)
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.vertical, DesignSystem.Spacing.xs + 2)
            .background(
                Capsule(style: .continuous)
                    .fill(isSelected
                          ? AnyShapeStyle(DesignSystem.Colors.primaryGradient)
                          : AnyShapeStyle(DesignSystem.Colors.surface.opacity(0.7)))
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(DesignSystem.Colors.border.opacity(isSelected ? 0 : 0.4), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: isSelected)
        .accessibilityLabel("\(title), \(count) pets")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // MARK: Gallery

    @ViewBuilder
    private var gallery: some View {
        if results.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: DesignSystem.Spacing.md) {
                    ForEach(results, id: \.id) { def in
                        PetCard(
                            definition: def,
                            isSelected: def.id == selectedPetID,
                            thumbnail: thumbnails.thumbnail(for: def)
                        ) {
                            selectedPetID = def.id
                            if let form = PetCatalog.preferredForm(for: def) { onSelect(def.id, form) }
                        }
                        .id(def.id)
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, DesignSystem.Spacing.xs)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "pawprint")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(DesignSystem.Colors.textMuted)
            Text(searchText.isEmpty ? "No pets in this category" : "No pets match “\(searchText)”")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            if !searchText.isEmpty || selectedCategory != nil {
                Button("Clear filters") {
                    searchText = ""
                    selectedCategory = nil
                }
                .buttonStyle(.plain)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.ember)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DesignSystem.Spacing.xl)
    }
}

// MARK: - PetCard

/// A single pet in the library: a framed thumbnail, name, category, and a 3D
/// badge, with a gradient selection ring and a gentle hover lift.
private struct PetCard: View {
    let definition: PetDefinition
    let isSelected: Bool
    let thumbnail: NSImage?
    let action: () -> Void

    @State private var isHovering = false

    private var name: String { PetCatalog.displayName(for: definition) }
    private var category: String { PetCatalog.groupName(for: definition) }
    private var has3D: Bool { definition.model3d != nil }

    var body: some View {
        Button(action: action) {
            VStack(spacing: DesignSystem.Spacing.sm) {
                thumbnailView
                    .frame(height: 116)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                            .fill(DesignSystem.Colors.surfaceMuted.opacity(0.6))
                    )
                    .overlay(alignment: .topTrailing) {
                        if has3D { badge("3D") }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous))

                VStack(spacing: 1) {
                    Text(name)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                        .lineLimit(1)
                    Text(category)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .lineLimit(1)
                }
            }
            .padding(DesignSystem.Spacing.sm)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                    .fill(isSelected ? DesignSystem.Colors.surfaceElevated : DesignSystem.Colors.surface.opacity(isHovering ? 0.6 : 0.3))
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                            .strokeBorder(
                                isSelected
                                    ? AnyShapeStyle(DesignSystem.Colors.primaryGradient)
                                    : AnyShapeStyle(DesignSystem.Colors.border.opacity(isHovering ? 0.6 : 0.3)),
                                lineWidth: isSelected ? 2 : 1
                            )
                    )
                    .shadow(
                        color: isSelected ? DesignSystem.Colors.ember.opacity(0.28) : .black.opacity(isHovering ? 0.12 : 0),
                        radius: isSelected ? 12 : (isHovering ? 8 : 0),
                        x: 0, y: isSelected ? 4 : 2
                    )
            )
            .scaleEffect(isHovering && !isSelected ? 1.02 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.16)) { isHovering = hovering }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), \(category)\(has3D ? ", 3D model" : "")")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
    }

    @ViewBuilder
    private var thumbnailView: some View {
        if let thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .padding(DesignSystem.Spacing.xs)
                .transition(.opacity)
        } else {
            ThumbnailPlaceholder()
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(DesignSystem.Colors.whimsy.opacity(0.9)))
            .padding(DesignSystem.Spacing.xs)
    }
}

/// A gentle pulsing placeholder shown while a thumbnail is rendered.
private struct ThumbnailPlaceholder: View {
    @State private var pulse = false

    var body: some View {
        Image(systemName: "pawprint.fill")
            .font(.system(size: 26, weight: .light))
            .foregroundStyle(DesignSystem.Colors.textMuted.opacity(pulse ? 0.45 : 0.2))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
            }
            .accessibilityHidden(true)
    }
}

// MARK: - PetThumbnailStore

/// Renders and caches one still thumbnail per pet so the picker library scrolls
/// smoothly no matter how large it grows.
///
/// A live `SCNView` per cell would decode each pet's GLB (often 100k+ vertices)
/// every time a cell scrolls into view — janky for a 100+ pet library. Instead
/// each pet is rendered **once**, offscreen, through the same framing pipeline
/// the live companion uses (so the thumbnail matches what lands on the desktop),
/// and the image is cached and published. 2D atlas pets reuse their first sprite
/// frame. Renders are serialized (one at a time) to bound GPU/CPU spikes and are
/// requested lazily as cells appear, so the grid stays responsive while
/// thumbnails fade in.
@MainActor
final class PetThumbnailStore: ObservableObject {
    @Published private(set) var images: [String: NSImage] = [:]

    private var inFlight: Set<String> = []
    private var queue: [PetDefinition] = []
    private var isRendering = false
    private let renderSize = CGSize(width: 264, height: 264)

    private init() {}

    /// Cached thumbnail, or `nil` while one is produced (enqueued on first miss).
    func thumbnail(for definition: PetDefinition) -> NSImage? {
        if let image = images[definition.id] { return image }
        enqueue(definition)
        return nil
    }

    private func enqueue(_ definition: PetDefinition) {
        guard images[definition.id] == nil, !inFlight.contains(definition.id) else { return }
        inFlight.insert(definition.id)
        queue.append(definition)
        pump()
    }

    private func pump() {
        // LIFO: the most recently requested (just-scrolled-into-view) pet renders
        // first, so what the user is looking at fills in soonest.
        guard !isRendering, let next = queue.popLast() else { return }
        isRendering = true
        Task { @MainActor in
            let image = await self.render(next)
            self.inFlight.remove(next.id)
            self.isRendering = false
            if let image {
                withAnimation(.easeOut(duration: 0.25)) { self.images[next.id] = image }
            }
            self.pump()
        }
    }

    private func render(_ definition: PetDefinition) async -> NSImage? {
        if let atlas = definition.atlas2d, let imageName = atlas.image,
           let base = Self.atlasImage(named: imageName, petID: definition.id) {
            return Self.firstFrame(of: base, atlas: atlas) ?? base
        }

        guard let form = definition.defaultForm, form.isModel else { return nil }

        let renderer = SceneKitPetRenderer(definition: definition, form: form)
        let container = NSView(frame: NSRect(origin: .zero, size: renderSize))
        let window = NSWindow(
            contentRect: container.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = container
        renderer.mount(in: container)
        renderer.play(state: "idle")
        defer { renderer.unmount() }

        guard let scnView = renderer.view as? SCNView else { return nil }
        scnView.frame = container.bounds
        container.layoutSubtreeIfNeeded()
        // First render evaluates the skinner and schedules the presentation-bounds
        // camera reframe; yield so it lands, then capture the framed pet.
        _ = scnView.snapshot()
        try? await Task.sleep(nanoseconds: 380_000_000)
        return scnView.snapshot()
    }

    private static func atlasImage(named name: String, petID: String) -> NSImage? {
        if let named = NSImage(named: name) { return named }
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension.isEmpty ? "png" : (name as NSString).pathExtension
        guard let url = Bundle.main.url(forResource: stem, withExtension: ext, subdirectory: "Pets/\(petID)")
            ?? Bundle.main.url(forResource: stem, withExtension: ext) else { return nil }
        return NSImage(contentsOf: url)
    }

    private static func firstFrame(of sheet: NSImage, atlas: PetDefinition.Atlas2D) -> NSImage? {
        guard let rect = atlas.frameRect(state: atlas.defaultState, frame: 0),
              let tiff = sheet.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let cg = bitmap.cgImage else { return nil }
        let crop = CGRect(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height)
        guard crop.maxX <= CGFloat(cg.width), crop.maxY <= CGFloat(cg.height),
              let cropped = cg.cropping(to: crop) else { return nil }
        return NSImage(cgImage: cropped, size: NSSize(width: rect.width, height: rect.height))
    }
}
