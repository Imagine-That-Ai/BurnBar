import Foundation

// MARK: - AuroraNavItem
//
// One user-configured slot in the bottom navigation tray. The tray used to be
// hardwired to `AuroraNavDestination.allCases`; it now renders an ordered list
// of these items, so users can add, remove, reorder, and configure tabs — and
// keep more than one AI Inbox tab, each pinned to a different filter preset.
//
// Identity is the instance `id`, not the kind: two inbox items are distinct
// tabs with distinct selection state. Canonical (single-instance) kinds use a
// stable `kind.<rawValue>` id so defaults and migrations produce byte-identical
// items across launches instead of fresh UUIDs that would defeat persistence.

struct AuroraNavItem: Identifiable, Hashable, Codable {
    let id: String
    var kind: AuroraNavDestination
    /// `AIInboxStore.Filter` raw value applied when this tab activates.
    /// Only meaningful for `.inbox`; nil keeps whatever filter the shared
    /// inbox store is already showing.
    var inboxFilter: String?

    init(id: String = UUID().uuidString, kind: AuroraNavDestination, inboxFilter: String? = nil) {
        self.id = id
        self.kind = kind
        self.inboxFilter = inboxFilter
    }

    /// The stable single-instance item for a kind.
    static func canonical(_ kind: AuroraNavDestination) -> AuroraNavItem {
        AuroraNavItem(id: "kind.\(kind.rawValue)", kind: kind)
    }

    /// The preset as a typed filter, when one is set and still valid.
    var inboxFilterPreset: AIInboxStore.Filter? {
        guard kind == .inbox, let raw = inboxFilter else { return nil }
        return AIInboxStore.Filter(rawValue: raw)
    }

    /// Tray caption. Preset-pinned inbox instances surface their preset so two
    /// inbox tabs are tellable apart at a glance.
    var trayLabel: String {
        if let preset = inboxFilterPreset { return preset.title }
        return kind.trayLabel
    }

    /// Full label for editors and accessibility.
    var displayLabel: String {
        if let preset = inboxFilterPreset { return "\(kind.label) — \(preset.title)" }
        return kind.label
    }
}

// MARK: - Layout rules

extension AuroraNavItem {
    /// Tray capacity. Eight 40 pt tabs are the narrowest layout that stays
    /// tappable on the smallest supported iPhone width.
    static let maxItems = 8
    static let minItems = 2

    /// The factory layout — the six legacy tabs in their legacy order.
    static var defaultItems: [AuroraNavItem] {
        AuroraNavDestination.defaultTrayOrder.map(canonical)
    }

    /// Whether the editor may offer another instance of this kind.
    /// Only the AI Inbox is multi-instance (per-filter presets make duplicates
    /// meaningful); every other kind is one tab or none.
    static func allowsMultipleInstances(_ kind: AuroraNavDestination) -> Bool {
        kind == .inbox
    }

    /// `.you` hosts Settings (including the tab-bar editor itself), so
    /// removing it would strand the user with no way back.
    static func isRemovable(_ item: AuroraNavItem, in items: [AuroraNavItem]) -> Bool {
        guard item.kind != .you else { return false }
        return items.count > minItems
    }

    /// Normalizes a persisted or user-edited list into something the tray can
    /// always render: duplicate ids and duplicate single-instance kinds are
    /// dropped (first occurrence wins), `.you` is guaranteed present, and the
    /// count is clamped to `maxItems` (never dropping `.you`). A list that
    /// cannot be salvaged falls back to the defaults.
    static func sanitized(_ items: [AuroraNavItem]) -> [AuroraNavItem] {
        var seenIDs = Set<String>()
        var seenSingleKinds = Set<AuroraNavDestination>()
        var result: [AuroraNavItem] = []
        for item in items {
            guard seenIDs.insert(item.id).inserted else { continue }
            if !allowsMultipleInstances(item.kind) {
                guard seenSingleKinds.insert(item.kind).inserted else { continue }
            }
            result.append(item)
        }
        if result.contains(where: { $0.kind == .you }) == false {
            result.append(.canonical(.you))
        }
        while result.count > maxItems {
            // Trim from the trailing edge, skipping `.you`.
            if let index = result.lastIndex(where: { $0.kind != .you }) {
                result.remove(at: index)
            } else {
                break
            }
        }
        guard result.count >= minItems else { return defaultItems }
        return result
    }
}
