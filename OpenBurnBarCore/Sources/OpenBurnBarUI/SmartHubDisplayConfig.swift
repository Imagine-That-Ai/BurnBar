import Foundation

// MARK: - Smart Hub Display Config
//
// Per-display customization shared between macOS (Settings UI +
// `SmartHubBridgeServer`) and iOS (Smart Display section). Lives on
// `SmartHubConfig.displayConfig` so it travels through the same
// Firestore document the Mac already publishes.
//
// The Nest Hub bridge HTML reads these values from `/state.json` and
// applies them via CSS variables and JS runtime hooks, so existing Hub
// casts pick up the new behavior on their next poll cycle — no
// re-cast required.

public struct SmartHubDisplayConfig: Codable, Sendable, Equatable {

    public var layout: SmartHubDisplayLayout
    public var palette: SmartHubDisplayPalette
    public var theme: SmartHubDisplayTheme
    public var background: SmartHubDisplayBackground
    public var brightness: Double           // 0.0 – 1.0
    public var scrollSpeedSeconds: Int      // seconds per carousel page
    public var refreshCadenceSeconds: Int   // /state.json poll interval
    public var providerIDs: [String]        // empty = "all"
    public var audibleCue: Bool
    public var identifyOnRefresh: Bool      // pings /voice-refresh so the Hub speaks/blinks
    public var updatedAt: Date

    public init(
        layout: SmartHubDisplayLayout = .quotaCarousel,
        palette: SmartHubDisplayPalette = .emberWhimsy,
        theme: SmartHubDisplayTheme = .warmCharcoal,
        background: SmartHubDisplayBackground = .dashboard,
        brightness: Double = 0.85,
        scrollSpeedSeconds: Int = 8,
        refreshCadenceSeconds: Int = 5,
        providerIDs: [String] = [],
        audibleCue: Bool = false,
        identifyOnRefresh: Bool = false,
        updatedAt: Date = Date()
    ) {
        self.layout = layout
        self.palette = palette
        self.theme = theme
        self.background = background
        self.brightness = brightness
        self.scrollSpeedSeconds = scrollSpeedSeconds
        self.refreshCadenceSeconds = refreshCadenceSeconds
        self.providerIDs = providerIDs
        self.audibleCue = audibleCue
        self.identifyOnRefresh = identifyOnRefresh
        self.updatedAt = updatedAt
    }

    public static let `default` = SmartHubDisplayConfig()

    public var clampedBrightness: Double {
        min(max(brightness, 0.2), 1.0) // never fully dark — Nest Hub auto-blanks below 20%
    }

    public var clampedScrollSpeed: Int {
        min(max(scrollSpeedSeconds, 3), 30)
    }

    public var clampedRefreshCadence: Int {
        min(max(refreshCadenceSeconds, 3), 60)
    }
}

// MARK: - Layout

public enum SmartHubDisplayLayout: String, Codable, Sendable, CaseIterable {
    case quotaCarousel
    case bigTotal
    case providerGrid
    case singleProvider

    public var displayName: String {
        switch self {
        case .quotaCarousel:  return "Quota carousel"
        case .bigTotal:       return "Big total"
        case .providerGrid:   return "Provider grid"
        case .singleProvider: return "Single provider"
        }
    }

    public var iconName: String {
        switch self {
        case .quotaCarousel:  return "rectangle.stack"
        case .bigTotal:       return "dollarsign.square"
        case .providerGrid:   return "rectangle.grid.2x2"
        case .singleProvider: return "rectangle.portrait"
        }
    }
}

// MARK: - Palette

public enum SmartHubDisplayPalette: String, Codable, Sendable, CaseIterable {
    case emberWhimsy
    case mercury
    case forestSage
    case monochrome
    case rainbow

    /// 6-stripe Pride flag colors (red, orange, yellow, green, blue, violet).
    public static let rainbowFlag: [String] = [
        "#E40303", "#FF8C00", "#FFED00",
        "#008026", "#004CFF", "#732982"
    ]

    public var isRainbow: Bool { self == .rainbow }

    public var displayName: String {
        switch self {
        case .emberWhimsy: return "Ember & whimsy"
        case .mercury:     return "Mercury"
        case .forestSage:  return "Forest sage"
        case .monochrome:  return "Monochrome"
        case .rainbow:     return "Pride rainbow"
        }
    }

    public var primaryHex: String {
        switch self {
        case .emberWhimsy: return "#E07868"
        case .mercury:     return "#C8BFB5"
        case .forestSage:  return "#3A7835"
        case .monochrome:  return "#FFFFFF"
        case .rainbow:     return "#E40303"
        }
    }

    public var secondaryHex: String {
        switch self {
        case .emberWhimsy: return "#A294F0"
        case .mercury:     return "#9A9088"
        case .forestSage:  return "#7A8572"
        case .monochrome:  return "#B0B0B0"
        case .rainbow:     return "#732982"
        }
    }
}

// MARK: - Theme

public enum SmartHubDisplayTheme: String, Codable, Sendable, CaseIterable {
    case warmCharcoal
    case botanicalCream
    case oledBlack
    case matchSystem

    public var displayName: String {
        switch self {
        case .warmCharcoal:   return "Warm charcoal"
        case .botanicalCream: return "Botanical cream"
        case .oledBlack:      return "OLED black"
        case .matchSystem:    return "Match macOS appearance"
        }
    }

    /// Background hex pair (top, bottom) the bridge HTML applies as a
    /// radial gradient. Match-system is resolved to warmCharcoal on the
    /// Hub since the Hub itself has no light/dark switch — but it
    /// signals to the Mac that it should follow appearance in the
    /// settings preview.
    public var backgroundPair: (top: String, bottom: String) {
        switch self {
        case .warmCharcoal:   return ("#2A221A", "#0E0D0B")
        case .botanicalCream: return ("#EDF0E5", "#D8E2CA")
        case .oledBlack:      return ("#050505", "#000000")
        case .matchSystem:    return ("#2A221A", "#0E0D0B")
        }
    }

    public var textHex: String {
        switch self {
        case .warmCharcoal:   return "#F0EBE2"
        case .botanicalCream: return "#1C2014"
        case .oledBlack:      return "#FFFFFF"
        case .matchSystem:    return "#F0EBE2"
        }
    }
}

// MARK: - Background mode

public enum SmartHubDisplayBackground: String, Codable, Sendable, CaseIterable {
    case dashboard
    case ambient
    case photoBlend

    public var displayName: String {
        switch self {
        case .dashboard:  return "Dashboard"
        case .ambient:    return "Ambient"
        case .photoBlend: return "Photo blend"
        }
    }

    public var description: String {
        switch self {
        case .dashboard:  return "Full provider rows and totals."
        case .ambient:    return "Large total + clock."
        case .photoBlend: return "Gradient tinted by accent colors."
        }
    }

    public var iconName: String {
        switch self {
        case .dashboard:  return "rectangle.grid.2x2"
        case .ambient:    return "moon.stars"
        case .photoBlend: return "photo.on.rectangle.angled"
        }
    }
}
