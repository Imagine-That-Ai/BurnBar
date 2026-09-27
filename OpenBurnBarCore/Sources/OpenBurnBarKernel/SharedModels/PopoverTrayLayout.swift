import Foundation

// MARK: - Popover tray sections

/// Every user-customizable block in the macOS menu-bar popover body.
///
/// Header chrome, the action bar, the update banner, and the cloud whisper
/// strip stay pinned. Everything else — including quotas — participates in
/// one layout: order, relative weight, min/max, collapse, hide.
public enum PopoverTraySectionID: String, CaseIterable, Codable, Sendable, Identifiable {
    case quotas
    case insights
    case summary
    case providers
    case mercury
    case chat
    case quickSwitch

    public var id: String { rawValue }

    /// Historical tray order before quotas joined the layout model. Used when
    /// migrating a stored `popoverTraySectionOrder` that never named quotas:
    /// quotas stay first (where the pinned bar lived), other missing IDs append.
    public static let legacyTrayOrder: [PopoverTraySectionID] = [
        .insights, .summary, .providers, .mercury, .chat, .quickSwitch
    ]

    public static let defaultOrder: [PopoverTraySectionID] = [.quotas] + legacyTrayOrder

    public var accessibilityLabel: String {
        switch self {
        case .quotas: return "Quotas"
        case .insights: return "Insights"
        case .summary: return "Summary"
        case .providers: return "Providers"
        case .mercury: return "Mercury"
        case .chat: return "Chat"
        case .quickSwitch: return "Quick Switch"
        }
    }

    public var settingsSubtitle: String {
        switch self {
        case .quotas: return "Provider quota bars"
        case .insights: return "Workflow insight cards"
        case .summary: return "Today's burn and 7-day trend"
        case .providers: return "Top providers by spend"
        case .mercury: return "Call and file transfer"
        case .chat: return "Assistants strip"
        case .quickSwitch: return "Switch the active account"
        }
    }

    public var symbolName: String {
        switch self {
        case .quotas: return "gauge.with.dots.needle.67percent"
        case .insights: return "sparkles"
        case .summary: return "chart.xyaxis.line"
        case .providers: return "square.stack.3d.up"
        case .mercury: return "phone.fill"
        case .chat: return "bubble.left.and.bubble.right"
        case .quickSwitch: return "arrow.left.arrow.right"
        }
    }
}

// MARK: - Per-section spec

public struct PopoverTraySectionSpec: Codable, Equatable, Sendable, Identifiable {
    public var id: PopoverTraySectionID
    public var isHidden: Bool
    public var isCollapsed: Bool
    /// Relative share of leftover body height among expanded, unpinned sections.
    public var weight: Double
    public var minHeight: Double
    public var maxHeight: Double
    /// Absolute height from a drag-resize. `nil` means “use weight”.
    public var pinnedHeight: Double?

    public init(
        id: PopoverTraySectionID,
        isHidden: Bool = false,
        isCollapsed: Bool = false,
        weight: Double = PopoverTrayLayoutMath.defaultWeight,
        minHeight: Double = PopoverTrayLayoutMath.defaultMinHeight,
        maxHeight: Double? = nil,
        pinnedHeight: Double? = nil
    ) {
        self.id = id
        self.isHidden = isHidden
        self.isCollapsed = isCollapsed
        self.weight = PopoverTrayLayoutMath.clampWeight(weight)
        self.minHeight = PopoverTrayLayoutMath.clampMinHeight(minHeight)
        let resolvedMax = maxHeight ?? PopoverTrayLayoutMath.defaultMaxHeight(for: id)
        self.maxHeight = PopoverTrayLayoutMath.clampMaxHeight(resolvedMax, minHeight: self.minHeight)
        self.pinnedHeight = pinnedHeight.map { PopoverTrayLayoutMath.clamp($0, min: self.minHeight, max: self.maxHeight) }
    }

    public var effectiveMinHeight: Double {
        PopoverTrayLayoutMath.clampMinHeight(minHeight)
    }

    public var effectiveMaxHeight: Double {
        PopoverTrayLayoutMath.clampMaxHeight(maxHeight, minHeight: effectiveMinHeight)
    }

    public var effectiveWeight: Double {
        PopoverTrayLayoutMath.clampWeight(weight)
    }

    enum CodingKeys: String, CodingKey {
        case id, isHidden, isCollapsed, weight, minHeight, maxHeight, pinnedHeight
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(PopoverTraySectionID.self, forKey: .id)
        isHidden = try container.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false
        isCollapsed = try container.decodeIfPresent(Bool.self, forKey: .isCollapsed) ?? false
        weight = PopoverTrayLayoutMath.clampWeight(
            try container.decodeIfPresent(Double.self, forKey: .weight) ?? PopoverTrayLayoutMath.defaultWeight
        )
        minHeight = PopoverTrayLayoutMath.clampMinHeight(
            try container.decodeIfPresent(Double.self, forKey: .minHeight) ?? PopoverTrayLayoutMath.defaultMinHeight
        )
        let decodedMax = try container.decodeIfPresent(Double.self, forKey: .maxHeight)
            ?? PopoverTrayLayoutMath.defaultMaxHeight(for: id)
        maxHeight = PopoverTrayLayoutMath.clampMaxHeight(decodedMax, minHeight: minHeight)
        if let pinned = try container.decodeIfPresent(Double.self, forKey: .pinnedHeight) {
            pinnedHeight = PopoverTrayLayoutMath.clamp(pinned, min: minHeight, max: maxHeight)
        } else {
            pinnedHeight = nil
        }
    }
}

// MARK: - Layout document

public struct PopoverTrayLayout: Codable, Equatable, Sendable {
    public static let storageKey = "popoverTrayLayoutJSON"
    public static let legacyOrderKey = "popoverTraySectionOrder"
    public static let legacyHeightsKey = "popoverTraySectionHeights"

    public var sections: [PopoverTraySectionSpec]

    public init(sections: [PopoverTraySectionSpec] = PopoverTrayLayout.defaultSections()) {
        self.sections = PopoverTrayLayout.normalize(sections)
    }

    public static func `default`() -> PopoverTrayLayout {
        PopoverTrayLayout(sections: defaultSections())
    }

    public static func defaultSections() -> [PopoverTraySectionSpec] {
        PopoverTraySectionID.defaultOrder.map { PopoverTraySectionSpec(id: $0) }
    }

    public var order: [PopoverTraySectionID] {
        sections.map(\.id)
    }

    public func spec(for id: PopoverTraySectionID) -> PopoverTraySectionSpec? {
        sections.first { $0.id == id }
    }

    public func isHidden(_ id: PopoverTraySectionID) -> Bool {
        spec(for: id)?.isHidden ?? false
    }

    public func isCollapsed(_ id: PopoverTraySectionID) -> Bool {
        spec(for: id)?.isCollapsed ?? false
    }

    /// Sections that should occupy layout slots: not hidden, and present in `available`.
    public func visibleSections(available: Set<PopoverTraySectionID>) -> [PopoverTraySectionSpec] {
        sections.filter { available.contains($0.id) && !$0.isHidden }
    }

    public mutating func update(_ id: PopoverTraySectionID, _ mutate: (inout PopoverTraySectionSpec) -> Void) {
        guard let index = sections.firstIndex(where: { $0.id == id }) else { return }
        mutate(&sections[index])
        sections[index].weight = PopoverTrayLayoutMath.clampWeight(sections[index].weight)
        sections[index].minHeight = PopoverTrayLayoutMath.clampMinHeight(sections[index].minHeight)
        sections[index].maxHeight = PopoverTrayLayoutMath.clampMaxHeight(
            sections[index].maxHeight,
            minHeight: sections[index].minHeight
        )
        if let pinned = sections[index].pinnedHeight {
            sections[index].pinnedHeight = PopoverTrayLayoutMath.clamp(
                pinned,
                min: sections[index].minHeight,
                max: sections[index].maxHeight
            )
        }
    }

    public mutating func setHidden(_ id: PopoverTraySectionID, hidden: Bool) {
        update(id) { spec in
            spec.isHidden = hidden
            if hidden {
                spec.isCollapsed = false
            }
        }
    }

    public mutating func setCollapsed(_ id: PopoverTraySectionID, collapsed: Bool) {
        update(id) { spec in
            spec.isCollapsed = collapsed
            if collapsed {
                spec.isHidden = false
            }
        }
    }

    public mutating func setWeight(_ id: PopoverTraySectionID, weight: Double) {
        update(id) { $0.weight = weight }
    }

    public mutating func setMinHeight(_ id: PopoverTraySectionID, minHeight: Double) {
        update(id) { $0.minHeight = minHeight }
    }

    public mutating func setMaxHeight(_ id: PopoverTraySectionID, maxHeight: Double) {
        update(id) { $0.maxHeight = maxHeight }
    }

    public mutating func setPinnedHeight(_ id: PopoverTraySectionID, height: Double?) {
        update(id) { $0.pinnedHeight = height }
    }

    public mutating func move(_ id: PopoverTraySectionID, offset: Int) {
        guard let current = sections.firstIndex(where: { $0.id == id }) else { return }
        let target = min(max(current + offset, 0), sections.count - 1)
        guard target != current else { return }
        let spec = sections.remove(at: current)
        sections.insert(spec, at: target)
    }

    public mutating func move(_ id: PopoverTraySectionID, toSlot slot: Int) {
        guard let current = sections.firstIndex(where: { $0.id == id }) else { return }
        let moved = sections.remove(at: current)
        let adjusted = slot > current ? slot - 1 : slot
        let clamped = min(max(adjusted, 0), sections.count)
        sections.insert(moved, at: clamped)
    }

    public mutating func restoreDefaults() {
        sections = Self.defaultSections()
    }

    public func encodeJSON() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    public func legacyOrderCSV() -> String {
        order.map(\.rawValue).joined(separator: ",")
    }

    public func legacyHeightsJSON() -> String {
        var heights: [String: Double] = [:]
        for spec in sections {
            if let pinned = spec.pinnedHeight {
                heights[spec.id.rawValue] = pinned
            }
        }
        guard let data = try? JSONEncoder().encode(heights),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    static func normalize(_ sections: [PopoverTraySectionSpec]) -> [PopoverTraySectionSpec] {
        var seen = Set<PopoverTraySectionID>()
        var result: [PopoverTraySectionSpec] = []
        for spec in sections where seen.insert(spec.id).inserted {
            result.append(spec)
        }
        for id in PopoverTraySectionID.defaultOrder where seen.insert(id).inserted {
            if id == .quotas {
                result.insert(PopoverTraySectionSpec(id: .quotas), at: 0)
            } else {
                result.append(PopoverTraySectionSpec(id: id))
            }
        }
        return result
    }
}

// MARK: - Load / migrate

public enum PopoverTrayLayoutStore {
    /// Canonical JSON wins. Otherwise rebuild from the older order CSV + heights
    /// JSON. Quotas were never in that CSV — they lived in a pinned bar above
    /// the tray — so a missing quotas id is inserted at the front, not the end.
    public static func load(
        json: String?,
        legacyOrder: String?,
        legacyHeightsJSON: String?
    ) -> PopoverTrayLayout {
        if let json, let parsed = decode(json) {
            return PopoverTrayLayout(sections: parsed.sections)
        }
        return migrate(legacyOrder: legacyOrder, legacyHeightsJSON: legacyHeightsJSON)
    }

    public static func decode(_ json: String) -> PopoverTrayLayout? {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "{}",
              let data = trimmed.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(PopoverTrayLayout.self, from: data) else {
            return nil
        }
        return PopoverTrayLayout(sections: decoded.sections)
    }

    public static func migrate(legacyOrder: String?, legacyHeightsJSON: String?) -> PopoverTrayLayout {
        let heights = decodeHeights(legacyHeightsJSON)
        let decodedIDs: [PopoverTraySectionID] = (legacyOrder ?? "")
            .split(separator: ",")
            .compactMap { PopoverTraySectionID(rawValue: String($0).trimmingCharacters(in: .whitespacesAndNewlines)) }

        var order: [PopoverTraySectionID] = []
        var seen = Set<PopoverTraySectionID>()
        for id in decodedIDs where seen.insert(id).inserted {
            order.append(id)
        }
        if seen.insert(.quotas).inserted {
            order.insert(.quotas, at: 0)
        }
        for id in PopoverTraySectionID.legacyTrayOrder where seen.insert(id).inserted {
            order.append(id)
        }

        let sections = order.map { id in
            PopoverTraySectionSpec(
                id: id,
                pinnedHeight: heights[id.rawValue]
            )
        }
        return PopoverTrayLayout(sections: sections)
    }

    private static func decodeHeights(_ json: String?) -> [String: Double] {
        guard let json, let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: Double].self, from: data) else {
            return [:]
        }
        return decoded
    }
}

// MARK: - Layout math

public enum PopoverTrayLayoutMath {
    public static let collapsedHeight: Double = 32
    public static let dividerHeight: Double = 8
    public static let defaultWeight: Double = 1
    public static let minWeight: Double = 0.25
    public static let maxWeight: Double = 4
    public static let defaultMinHeight: Double = 56
    public static let absoluteMinHeight: Double = 40
    public static let absoluteMaxHeight: Double = 720
    public static let defaultQuotaMaxHeight: Double = 360

    public static func defaultMaxHeight(for id: PopoverTraySectionID) -> Double {
        id == .quotas ? defaultQuotaMaxHeight : absoluteMaxHeight
    }

    public static func clampWeight(_ weight: Double) -> Double {
        clamp(weight, min: minWeight, max: maxWeight)
    }

    public static func clampMinHeight(_ height: Double) -> Double {
        clamp(height, min: absoluteMinHeight, max: absoluteMaxHeight)
    }

    public static func clampMaxHeight(_ height: Double, minHeight: Double) -> Double {
        clamp(height, min: max(minHeight, absoluteMinHeight), max: absoluteMaxHeight)
    }

    public static func clamp(_ value: Double, min lower: Double, max upper: Double) -> Double {
        Swift.min(Swift.max(value, lower), upper)
    }

    /// Height of the laid-out stack including dividers between visible sections.
    public static func contentHeight(of heights: [PopoverTraySectionID: Double]) -> Double {
        let values = Array(heights.values)
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) + Double(values.count - 1) * dividerHeight
    }

    /// Share of leftover body height this section would receive among the
    /// currently expanded, unpinned, visible sections. Hidden/collapsed/pinned
    /// sections report `0`.
    public static func relativeShare(
        of id: PopoverTraySectionID,
        in layout: PopoverTrayLayout,
        available: Set<PopoverTraySectionID> = Set(PopoverTraySectionID.allCases)
    ) -> Double {
        let visible = layout.visibleSections(available: available)
        let flexible = visible.filter { !$0.isCollapsed && $0.pinnedHeight == nil }
        guard let spec = flexible.first(where: { $0.id == id }) else { return 0 }
        let weightSum = flexible.reduce(0.0) { $0 + $1.effectiveWeight }
        guard weightSum > 0 else { return 0 }
        return spec.effectiveWeight / weightSum
    }

    /// Allocate body height across visible sections.
    ///
    /// Hidden sections are omitted (no spacer). Collapsed sections get a labeled
    /// strip, not a blank hole. Pinned heights win over weight. Remaining space
    /// is split by weight, then clamped to each section’s min/max.
    public static func allocate(
        layout: PopoverTrayLayout,
        available: Set<PopoverTraySectionID>,
        bodyHeight: Double
    ) -> [PopoverTraySectionID: Double] {
        let visible = layout.visibleSections(available: available)
        guard !visible.isEmpty else { return [:] }

        let dividerTotal = Double(max(visible.count - 1, 0)) * dividerHeight
        var remaining = max(bodyHeight - dividerTotal, 0)
        var heights: [PopoverTraySectionID: Double] = [:]
        var flexible: [PopoverTraySectionSpec] = []

        for spec in visible {
            if spec.isCollapsed {
                heights[spec.id] = collapsedHeight
                remaining -= collapsedHeight
            } else if let pinned = spec.pinnedHeight {
                let height = clamp(pinned, min: spec.effectiveMinHeight, max: spec.effectiveMaxHeight)
                heights[spec.id] = height
                remaining -= height
            } else {
                flexible.append(spec)
            }
        }

        guard !flexible.isEmpty else { return heights }
        remaining = max(remaining, 0)

        let weightSum = flexible.reduce(0.0) { $0 + $1.effectiveWeight }
        var assigned: [PopoverTraySectionID: Double] = [:]
        if weightSum <= 0 {
            let even = remaining / Double(flexible.count)
            for spec in flexible {
                assigned[spec.id] = clamp(even, min: spec.effectiveMinHeight, max: spec.effectiveMaxHeight)
            }
        } else {
            for spec in flexible {
                let ideal = remaining * (spec.effectiveWeight / weightSum)
                assigned[spec.id] = clamp(ideal, min: spec.effectiveMinHeight, max: spec.effectiveMaxHeight)
            }
        }

        var iterations = 0
        while iterations < 12 {
            iterations += 1
            let currentSum = assigned.values.reduce(0, +)
            let delta = remaining - currentSum
            if abs(delta) <= 0.05 { break }
            if delta > 0 {
                let receivers = flexible.filter {
                    (assigned[$0.id] ?? 0) < $0.effectiveMaxHeight - 0.05
                }
                let receiverWeight = receivers.reduce(0.0) { $0 + $1.effectiveWeight }
                guard receiverWeight > 0 else { break }
                for spec in receivers {
                    let current = assigned[spec.id] ?? spec.effectiveMinHeight
                    let add = min(delta * (spec.effectiveWeight / receiverWeight), spec.effectiveMaxHeight - current)
                    assigned[spec.id] = current + add
                }
            } else {
                let donors = flexible.filter {
                    (assigned[$0.id] ?? 0) > $0.effectiveMinHeight + 0.05
                }
                let donorWeight = donors.reduce(0.0) { $0 + $1.effectiveWeight }
                guard donorWeight > 0 else { break }
                let need = -delta
                for spec in donors {
                    let current = assigned[spec.id] ?? spec.effectiveMinHeight
                    let take = min(need * (spec.effectiveWeight / donorWeight), current - spec.effectiveMinHeight)
                    assigned[spec.id] = current - take
                }
            }
        }

        for spec in flexible {
            heights[spec.id] = assigned[spec.id] ?? spec.effectiveMinHeight
        }
        return heights
    }
}
