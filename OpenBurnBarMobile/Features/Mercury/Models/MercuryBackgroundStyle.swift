import Foundation

/// How the screen's full-bleed background should render.
/// - `.wallpaper`: blur of the Mac's desktop wallpaper (default).
/// - `.aurora`: ambient glows on a charcoal gradient (original fallback).
/// - `.solid`: a single accent-tinted dark surface for users who want a
///   calm, clean look.
enum MercuryBackgroundStyle: Codable, Hashable, Sendable, CaseIterable {
    case wallpaper
    case aurora
    case solid
    case website

    var displayName: String {
        switch self {
        case .wallpaper: return "Wallpaper"
        case .aurora:    return "Aurora"
        case .solid:     return "Solid"
        case .website:   return "Website"
        }
    }

    var icon: String {
        switch self {
        case .wallpaper: return "photo.fill"
        case .aurora:    return "sparkles"
        case .solid:     return "circle.fill"
        case .website:   return "globe"
        }
    }
}
