import Foundation
import OpenBurnBarUI

enum DesktopWallpaperBackground: String, CaseIterable, Codable, Hashable, Identifiable {
    case macOSDesktop
    case midnight
    case amoledBlack
    case graphite
    case warmEmber
    case deepIndigo
    case auroraTeal
    case sunsetCrimson
    case cyberpunkViolet
    case forestMoss
    case solarFlare

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .macOSDesktop: return "BurnBar Desktop"
        case .midnight: return "Midnight"
        case .amoledBlack: return "AMOLED Black"
        case .graphite: return "Graphite"
        case .warmEmber: return "Warm Ember"
        case .deepIndigo: return "Deep Indigo"
        case .auroraTeal: return "Aurora Teal"
        case .sunsetCrimson: return "Sunset Crimson"
        case .cyberpunkViolet: return "Cyberpunk Violet"
        case .forestMoss: return "Forest Moss"
        case .solarFlare: return "Solar Flare"
        }
    }

    var detailText: String {
        switch self {
        case .macOSDesktop: return "Use a BurnBar-owned macOS-style gradient under the live swarm."
        case .midnight: return "A quiet near-black surface with a soft blue cast."
        case .amoledBlack: return "Pitch black for OLED and maximum particle contrast."
        case .graphite: return "Neutral dark gray for less contrast than black."
        case .warmEmber: return "Dark warm brown tuned for BurnBar embers."
        case .deepIndigo: return "A deep violet-blue stage for provider colors."
        case .auroraTeal: return "An ethereal deep teal wash inspired by northern lights."
        case .sunsetCrimson: return "A premium dark velvet burgundy-red sunset mood."
        case .cyberpunkViolet: return "A futuristic dark indigo-magenta cybernetic grid backdrop."
        case .forestMoss: return "A quiet dark pine green inspired by ancient foggy forests."
        case .solarFlare: return "A stellar dark solar corona backdrop with rich golden accents."
        }
    }

    var iconName: String {
        switch self {
        case .macOSDesktop: return "desktopcomputer"
        case .midnight: return "moon.stars.fill"
        case .amoledBlack: return "circle.fill"
        case .graphite: return "square.fill"
        case .warmEmber: return "flame.fill"
        case .deepIndigo: return "sparkles"
        case .auroraTeal: return "leaf.fill"
        case .sunsetCrimson: return "sunset.fill"
        case .cyberpunkViolet: return "bolt.horizontal.fill"
        case .forestMoss: return "tree.fill"
        case .solarFlare: return "sun.max.fill"
        }
    }

    var isTransparent: Bool {
        false
    }

    var swarmPalette: SwarmColorPalette {
        switch self {
        case .macOSDesktop, .midnight, .amoledBlack, .graphite, .warmEmber, .deepIndigo:
            return .defaultEmber
        case .auroraTeal:
            return .auroraTeal
        case .sunsetCrimson:
            return .sunsetCrimson
        case .cyberpunkViolet:
            return .cyberpunkViolet
        case .forestMoss:
            return .forestMoss
        case .solarFlare:
            return .solarFlare
        }
    }
}
