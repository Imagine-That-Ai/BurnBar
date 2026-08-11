import Foundation

// MARK: - Control Deck Layout
//
// The `ChartsPageLayout` contract, verbatim in shape and forward-compatibility
// semantics, with one deliberate difference: **reorder is within a group only.**
// The six bands are the information architecture; a free-for-all reorder would
// let a user dissolve the map into the same undifferentiated wall of switches
// the deck exists to replace.

/// One tile's persisted state: which control, whether shown, and how wide.
struct ControlTileConfig: Codable, Equatable, Identifiable, Sendable {
    var kind: ControlKind
    var isVisible: Bool
    var span: Int

    var id: String { kind.rawValue }

    init(kind: ControlKind, isVisible: Bool? = nil, span: Int? = nil) {
        self.kind = kind
        self.isVisible = isVisible ?? kind.defaultVisible
        self.span = min(ControlDeckLayout.maxSpan, max(1, span ?? kind.defaultSpan))
    }
}

/// The full deck layout: an ordered list of tile configs, persisted as JSON
/// under `ControlDeckLayout.storageKey`.
///
/// Decoding is forward-compatible — unknown kinds (from a newer build, or a
/// tile that was removed) are dropped, and kinds missing from the stored
/// payload (added since the layout was saved) are appended with their defaults.
/// That is what lets PR2 and PR3 add tiles without clobbering an arrangement
/// somebody already tuned.
struct ControlDeckLayout: Equatable, Sendable {
    static let storageKey = "controlDeck.layout.v1"

    /// Widest a tile may be. Matches the deck's 4-column grid at full width;
    /// a tile is clamped to the live column count at render time.
    static let maxSpan = 2

    private(set) var configs: [ControlTileConfig]

    static var `default`: ControlDeckLayout {
        ControlDeckLayout(configs: ControlKind.visibleKinds.map { ControlTileConfig(kind: $0) })
    }

    init(configs: [ControlTileConfig]) {
        self.configs = Self.reconciled(configs)
    }

    /// Tiles the deck actually renders, in order.
    var visibleConfigs: [ControlTileConfig] {
        configs.filter(\.isVisible)
    }

    var hiddenConfigs: [ControlTileConfig] {
        configs.filter { !$0.isVisible }
    }

    /// Visible tiles for one band, in the user's order. Groups with no visible
    /// tile render nothing at all — no empty header, no ghost band.
    func visibleConfigs(in group: ControlGroup) -> [ControlTileConfig] {
        visibleConfigs.filter { $0.kind.group == group }
    }

    /// Groups that have at least one visible tile, in fixed render order.
    var populatedGroups: [ControlGroup] {
        ControlGroup.allCases.filter { !visibleConfigs(in: $0).isEmpty }
    }

    // MARK: Mutations

    /// Moves `kind` so it occupies the position currently held by `target` —
    /// drag-to-reorder lands on a specific tile, not an abstract index.
    ///
    /// **Cross-group moves are refused.** The bands are the IA; a tile that
    /// could leave its band would take the band's meaning with it.
    mutating func move(_ kind: ControlKind, toPositionOf target: ControlKind) {
        guard kind != target,
              kind.group == target.group,
              let from = configs.firstIndex(where: { $0.kind == kind }),
              let to = configs.firstIndex(where: { $0.kind == target }) else { return }
        let config = configs.remove(at: from)
        configs.insert(config, at: to)
    }

    mutating func setVisible(_ kind: ControlKind, _ visible: Bool) {
        guard let index = configs.firstIndex(where: { $0.kind == kind }) else { return }
        configs[index].isVisible = visible
    }

    mutating func setSpan(_ kind: ControlKind, _ span: Int) {
        guard let index = configs.firstIndex(where: { $0.kind == kind }) else { return }
        configs[index].span = min(Self.maxSpan, max(1, span))
    }

    mutating func reset() {
        self = .default
    }

    // MARK: Persistence

    /// JSON round-trip tolerant of unknown kinds. See type comment.
    static func decode(from data: Data) -> ControlDeckLayout {
        struct RawConfig: Codable {
            let kind: String
            let isVisible: Bool?
            let span: Int?
        }
        guard let raw = try? JSONDecoder().decode([RawConfig].self, from: data) else {
            return .default
        }
        let known = raw.compactMap { entry -> ControlTileConfig? in
            guard let kind = ControlKind(rawValue: entry.kind) else { return nil }
            return ControlTileConfig(kind: kind, isVisible: entry.isVisible, span: entry.span)
        }
        return ControlDeckLayout(configs: known)
    }

    func encoded() -> Data? {
        try? JSONEncoder().encode(configs)
    }

    /// Deduplicates, drops kinds this build does not ship, and appends any
    /// missing kinds so every registered control always has exactly one slot.
    private static func reconciled(_ configs: [ControlTileConfig]) -> [ControlTileConfig] {
        let shipped = Set(ControlKind.visibleKinds)
        var seen = Set<ControlKind>()
        var result: [ControlTileConfig] = []
        for config in configs where shipped.contains(config.kind) && !seen.contains(config.kind) {
            seen.insert(config.kind)
            result.append(config)
        }
        for kind in ControlKind.visibleKinds where !seen.contains(kind) {
            result.append(ControlTileConfig(kind: kind))
        }
        return result
    }
}
