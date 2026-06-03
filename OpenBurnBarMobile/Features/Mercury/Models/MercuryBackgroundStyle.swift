import Foundation

/// How the screen's full-bleed background should render.
/// - `.wallpaper`: blur of the Mac's desktop wallpaper (default).
/// - `.aurora`: ambient glows on a charcoal gradient (original fallback).
/// - `.solid`: a single accent-tinted dark surface for users who want a
///   calm, clean look.
/// - `.website`: the active, reconverging token-ember "Logo Swarm".
/// - `.constellation`: a calm, slow ambient field where one crest/provider
///   logo at a time resolves into dots somewhere on screen, shimmers, then
///   scatters apart as a different logo resolves elsewhere.
enum MercuryBackgroundStyle: Codable, Hashable, Sendable, CaseIterable {
    case wallpaper
    case aurora
    case solid
    case website
    case constellation

    var displayName: String {
        switch self {
        case .wallpaper:     return "Wallpaper"
        case .aurora:        return "Aurora"
        case .solid:         return "Solid"
        case .website:       return "Logo Swarm"
        case .constellation: return "Constellation"
        }
    }

    var icon: String {
        switch self {
        case .wallpaper:     return "photo.fill"
        case .aurora:        return "sparkles"
        case .solid:         return "circle.fill"
        case .website:       return "point.3.filled.connected.trianglepath.dotted"
        case .constellation: return "circle.hexagongrid.fill"
        }
    }
}
