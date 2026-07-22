import Foundation

/// Visual preset applied to an entire canvas.
///
/// Themes select different accent palettes from the existing
/// `UnifiedDesignSystem` rather than introducing new color primitives.
public enum InsightTheme: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    /// Default — full warm/whimsy gradient mix.
    case aurora
    /// Red/orange dominant — control-room feel.
    case ember
    /// Cool silver with Hermes shimmer — analytical feel.
    case mercury
    /// Purple/violet dominant — editorial feel.
    case whimsy
    /// High-contrast B&W with a single accent — archival feel.
    case mono
    /// Paper-tone — optimized for PDF export.
    case print

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .aurora: return "Aurora"
        case .ember: return "Ember"
        case .mercury: return "Mercury"
        case .whimsy: return "Whimsy"
        case .mono: return "Mono"
        case .print: return "Print"
        }
    }

    public var symbolName: String {
        switch self {
        case .aurora: return "sparkles"
        case .ember: return "flame.fill"
        case .mercury: return "circle.lefthalf.filled"
        case .whimsy: return "wand.and.stars"
        case .mono: return "circle.fill"
        case .print: return "doc.text.fill"
        }
    }
}
