import Foundation

// MARK: - Smart Display Kind
//
// Identifies which Smart Display card a user has configured. The order
// in which these are rendered in Settings → Devices & Sync → Smart
// Displays is persisted via `SmartDisplayOrder` so the user can drag
// their preferred display to the top.

public enum SmartDisplayKind: String, Codable, Sendable, CaseIterable, Identifiable, Hashable {
    case nestHub
    case pixelClock

    public var id: String { rawValue }

    /// Default order used when no persisted preference exists. Nest Hub
    /// goes first because it has been the canonical Smart Display for
    /// longest and the help text references it by name.
    public static let defaultOrder: [SmartDisplayKind] = [.nestHub, .pixelClock]

    public var displayName: String {
        switch self {
        case .nestHub:    return "Google Nest Hub"
        case .pixelClock: return "ULANZI TC001 Pixel Clock"
        }
    }

    /// SF Symbol used in drag handles and reorder affordances.
    public var symbolName: String {
        switch self {
        case .nestHub:    return "display"
        case .pixelClock: return "rectangle.grid.3x2.fill"
        }
    }
}

// MARK: - Smart Display Order

/// Persisted ordering of the Smart Display cards. Decoding skips
/// unknown raw values so future kinds (e.g. an e-ink panel) can ship
/// without breaking older clients. Missing canonical kinds are appended
/// in the canonical `defaultOrder` so a user with a stale doc still
/// sees every card.

public struct SmartDisplayOrder: Codable, Sendable, Equatable {
    public var kinds: [SmartDisplayKind]

    public init(kinds: [SmartDisplayKind]) {
        self.kinds = SmartDisplayOrder.normalize(kinds)
    }

    public static let `default` = SmartDisplayOrder(kinds: SmartDisplayKind.defaultOrder)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode([String].self)
        let decoded = raw.compactMap(SmartDisplayKind.init(rawValue:))
        self.kinds = SmartDisplayOrder.normalize(decoded)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(kinds.map(\.rawValue))
    }

    /// Moves a kind to a new index. Out-of-range indices are clamped so
    /// the operation is total — useful for swap-style buttons.
    public mutating func move(_ kind: SmartDisplayKind, to destination: Int) {
        guard let source = kinds.firstIndex(of: kind) else { return }
        let clamped = max(0, min(destination, kinds.count - 1))
        guard source != clamped else { return }
        kinds.remove(at: source)
        kinds.insert(kind, at: clamped)
    }

    /// SwiftUI `onMove` signature: takes an `IndexSet` of sources and a
    /// destination offset. Maintains list-style semantics (destination
    /// may be `count`, meaning "after the last item").
    public mutating func move(fromOffsets sources: IndexSet, toOffset destination: Int) {
        var copy = kinds
        copy.move(fromOffsets: sources, toOffset: destination)
        kinds = SmartDisplayOrder.normalize(copy)
    }

    /// Ensures we always render every canonical kind exactly once, in
    /// the user-specified order — missing kinds are appended in the
    /// default order so adding a new card is visible immediately.
    private static func normalize(_ input: [SmartDisplayKind]) -> [SmartDisplayKind] {
        var seen = Set<SmartDisplayKind>()
        var output: [SmartDisplayKind] = []
        for kind in input where !seen.contains(kind) {
            seen.insert(kind)
            output.append(kind)
        }
        for kind in SmartDisplayKind.defaultOrder where !seen.contains(kind) {
            output.append(kind)
            seen.insert(kind)
        }
        return output
    }
}
