import SwiftUI

/// User-selected accent for the Mercury Live screen. `.autoFromWallpaper`
/// asks the personalization store to sample the dominant color of the
/// peer's blurred wallpaper at resolve time; the explicit palette cases
/// resolve to fixed `Color` values that stay legible on the glassmorphic
/// dark surface.
enum MercuryAccent: String, Codable, Hashable, Sendable, CaseIterable {
    case autoFromWallpaper
    case ember
    case amber
    case blaze
    case whimsy
    case blue
    case purple
    case green
    case teal
    case pink

    /// Display name used in pickers and accessibility labels.
    var displayName: String {
        switch self {
        case .autoFromWallpaper: return "Auto"
        case .ember:             return "Ember"
        case .amber:             return "Amber"
        case .blaze:             return "Blaze"
        case .whimsy:            return "Whimsy"
        case .blue:              return "Blue"
        case .purple:            return "Purple"
        case .green:             return "Green"
        case .teal:              return "Teal"
        case .pink:              return "Pink"
        }
    }

    /// Fixed `Color` for explicit palette cases. `.autoFromWallpaper`
    /// returns the original blue fallback — callers that have a sampled
    /// color should resolve via `MercuryPersonalizationStore.resolvedAccent`.
    var staticColor: Color {
        switch self {
        case .autoFromWallpaper: return Color.blue
        case .ember:             return Color(red: 0.95, green: 0.45, blue: 0.20)
        case .amber:             return Color(red: 1.00, green: 0.75, blue: 0.30)
        case .blaze:             return Color(red: 0.95, green: 0.30, blue: 0.30)
        case .whimsy:            return Color(red: 0.75, green: 0.50, blue: 0.95)
        case .blue:              return Color(red: 0.30, green: 0.62, blue: 0.95)
        case .purple:            return Color(red: 0.65, green: 0.45, blue: 0.95)
        case .green:             return Color(red: 0.30, green: 0.80, blue: 0.55)
        case .teal:              return Color(red: 0.25, green: 0.78, blue: 0.85)
        case .pink:              return Color(red: 0.98, green: 0.45, blue: 0.70)
        }
    }

    /// The full ordered swatch row used by `MercuryAccentPicker`.
    static var swatchOrder: [MercuryAccent] {
        [.ember, .amber, .blaze, .whimsy, .blue, .purple, .green, .teal, .pink]
    }
}
