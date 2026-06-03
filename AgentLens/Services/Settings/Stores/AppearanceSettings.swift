import SwiftUI
import OpenBurnBarCore

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

    var swatchColor: Color {
        switch self {
        case .macOSDesktop: return Color(red: 0.180, green: 0.455, blue: 0.930)
        case .midnight: return Color(red: 0.020, green: 0.024, blue: 0.040)
        case .amoledBlack: return Color.black
        case .graphite: return Color(red: 0.110, green: 0.115, blue: 0.125)
        case .warmEmber: return Color(red: 0.115, green: 0.065, blue: 0.045)
        case .deepIndigo: return Color(red: 0.050, green: 0.045, blue: 0.115)
        case .auroraTeal: return Color(red: 0.020, green: 0.050, blue: 0.055)
        case .sunsetCrimson: return Color(red: 0.050, green: 0.020, blue: 0.024)
        case .cyberpunkViolet: return Color(red: 0.035, green: 0.020, blue: 0.050)
        case .forestMoss: return Color(red: 0.020, green: 0.040, blue: 0.025)
        case .solarFlare: return Color(red: 0.055, green: 0.040, blue: 0.020)
        }
    }

    var swatchPreviewColors: [Color] {
        switch self {
        case .macOSDesktop:
            return [
                Color(red: 0.180, green: 0.455, blue: 0.930),
                Color(red: 0.960, green: 0.385, blue: 0.455),
                Color(red: 0.980, green: 0.720, blue: 0.255)
            ]
        case .midnight:
            return [
                Color(red: 0.018, green: 0.026, blue: 0.070),
                Color(red: 0.055, green: 0.145, blue: 0.320),
                Color(red: 0.115, green: 0.260, blue: 0.520)
            ]
        case .amoledBlack:
            return [
                Color.black,
                Color(red: 0.010, green: 0.010, blue: 0.012),
                Color(red: 0.055, green: 0.055, blue: 0.060)
            ]
        case .graphite:
            return [
                Color(red: 0.105, green: 0.112, blue: 0.128),
                Color(red: 0.270, green: 0.295, blue: 0.330),
                Color(red: 0.475, green: 0.505, blue: 0.545)
            ]
        case .warmEmber:
            return [
                Color(red: 0.115, green: 0.052, blue: 0.030),
                Color(red: 0.470, green: 0.145, blue: 0.020),
                Color(red: 0.920, green: 0.355, blue: 0.055)
            ]
        case .deepIndigo:
            return [
                Color(red: 0.045, green: 0.035, blue: 0.120),
                Color(red: 0.180, green: 0.115, blue: 0.390),
                Color(red: 0.410, green: 0.300, blue: 0.880)
            ]
        case .auroraTeal:
            return [
                Color(red: 0.015, green: 0.045, blue: 0.050),
                Color(red: 0.050, green: 0.180, blue: 0.200),
                Color(red: 0.120, green: 0.380, blue: 0.400)
            ]
        case .sunsetCrimson:
            return [
                Color(red: 0.045, green: 0.018, blue: 0.020),
                Color(red: 0.180, green: 0.055, blue: 0.070),
                Color(red: 0.420, green: 0.115, blue: 0.145)
            ]
        case .cyberpunkViolet:
            return [
                Color(red: 0.030, green: 0.015, blue: 0.045),
                Color(red: 0.150, green: 0.055, blue: 0.220),
                Color(red: 0.380, green: 0.120, blue: 0.520)
            ]
        case .forestMoss:
            return [
                Color(red: 0.015, green: 0.035, blue: 0.020),
                Color(red: 0.055, green: 0.140, blue: 0.080),
                Color(red: 0.150, green: 0.320, blue: 0.180)
            ]
        case .solarFlare:
            return [
                Color(red: 0.050, green: 0.035, blue: 0.015),
                Color(red: 0.200, green: 0.140, blue: 0.055),
                Color(red: 0.480, green: 0.340, blue: 0.120)
            ]
        }
    }

    var swatchPreviewStrokeColor: Color {
        switch self {
        case .macOSDesktop:
            return Color(red: 0.180, green: 0.455, blue: 0.930)
        case .midnight:
            return Color(red: 0.170, green: 0.335, blue: 0.650)
        case .amoledBlack:
            return Color(red: 0.910, green: 0.355, blue: 0.405)
        case .graphite:
            return Color(red: 0.570, green: 0.600, blue: 0.640)
        case .warmEmber:
            return Color(red: 0.920, green: 0.355, blue: 0.055)
        case .deepIndigo:
            return Color(red: 0.500, green: 0.380, blue: 0.960)
        case .auroraTeal:
            return Color(red: 0.120, green: 0.380, blue: 0.400)
        case .sunsetCrimson:
            return Color(red: 0.420, green: 0.115, blue: 0.145)
        case .cyberpunkViolet:
            return Color(red: 0.380, green: 0.120, blue: 0.520)
        case .forestMoss:
            return Color(red: 0.150, green: 0.320, blue: 0.180)
        case .solarFlare:
            return Color(red: 0.480, green: 0.340, blue: 0.120)
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

// MARK: - Appearance Settings

@Observable
@MainActor
final class AppearanceSettings {
    private let persistence: SettingsPersistenceCoordinator

    var appearanceMode: AppearanceMode = .system {
        didSet { persistence.set(appearanceMode, forKey: "appearanceMode") }
    }

    /// The app *skin* (see `AppSkin`) — orthogonal to light/dark. `.editorial`
    /// re-points the design-system tokens to the light, paper-bright
    /// app.burnbar.ai console palette. Written straight to `UserDefaults.standard`
    /// (in addition to the debounced coordinator) so `AppSkin.current`, read from
    /// the dynamic color resolvers, sees the change immediately and after relaunch.
    var appearanceSkin: AppSkin = .aurora {
        didSet {
            UserDefaults.standard.set(appearanceSkin.rawValue, forKey: AppSkin.storageKey)
            persistence.set(appearanceSkin.rawValue, forKey: AppSkin.storageKey)
            NotificationCenter.default.post(name: .appearanceSkinDidChange, object: nil)
        }
    }

    var showInMenuBar: Bool = true {
        didSet { persistence.set(showInMenuBar, forKey: "showInMenuBar") }
    }

    /// When `true`, the menu bar icon renders in full color instead of the
    /// monochrome template style that adapts to system light/dark mode.
    var colorfulMenuBarIcon: Bool = false {
        didSet { persistence.set(colorfulMenuBarIcon, forKey: "colorfulMenuBarIcon") }
    }

    var usePremiumSOTAUX: Bool = false {
        didSet { persistence.set(usePremiumSOTAUX, forKey: "usePremiumSOTAUX") }
    }

    var useWebsiteBackground: Bool = false {
        didSet {
            persistence.set(useWebsiteBackground, forKey: "useWebsiteBackground")
            NotificationCenter.default.post(name: .useWebsiteBackgroundDidChange, object: nil)
        }
    }

    /// When `true` (and ``useWebsiteBackground`` is on), the dynamic background
    /// renders the calm "Constellation" style — one crest / provider logo at a
    /// time resolving, shimmering, and dissolving — instead of the energetic
    /// continuously-murmurating swarm. Additive: leaves the swarm behaviour
    /// untouched when off.
    var useConstellationBackground: Bool = false {
        didSet {
            persistence.set(useConstellationBackground, forKey: "useConstellationBackground")
            NotificationCenter.default.post(name: .useConstellationBackgroundDidChange, object: nil)
        }
    }

    var enableDesktopWallpaper: Bool = false {
        didSet {
            persistence.set(enableDesktopWallpaper, forKey: "enableDesktopWallpaper")
            NotificationCenter.default.post(name: .enableDesktopWallpaperDidChange, object: nil)
        }
    }

    var desktopWallpaperBackground: DesktopWallpaperBackground = .macOSDesktop {
        didSet {
            persistence.set(desktopWallpaperBackground.rawValue, forKey: "desktopWallpaperBackground")
            syncAMOLEDAliasFromDesktopBackground()
            NotificationCenter.default.post(name: .desktopWallpaperBackgroundDidChange, object: nil)
        }
    }

    var amoledDarkBackground: Bool = false {
        didSet {
            persistence.set(amoledDarkBackground, forKey: "amoledDarkBackground")
            syncDesktopBackgroundFromAMOLEDAlias()
            NotificationCenter.default.post(name: .amoledDarkBackgroundDidChange, object: nil)
        }
    }

    var cycleShapesScreensaver: Bool = true {
        didSet {
            persistence.set(cycleShapesScreensaver, forKey: "cycleShapesScreensaver")
            NotificationCenter.default.post(name: .cycleShapesScreensaverDidChange, object: nil)
        }
    }

    var enableSwarmSparkles: Bool = true {
        didSet {
            persistence.set(enableSwarmSparkles, forKey: "enableSwarmSparkles")
            NotificationCenter.default.post(name: .enableSwarmSparklesDidChange, object: nil)
        }
    }

    var excludeBrandShapesFromSwarm: Bool = false {
        didSet {
            persistence.set(excludeBrandShapesFromSwarm, forKey: "excludeBrandShapesFromSwarm")
            NotificationCenter.default.post(name: .excludeBrandShapesFromSwarmDidChange, object: nil)
        }
    }

    var clickDesktopToCycleSwarm: Bool = false {
        didSet {
            persistence.set(clickDesktopToCycleSwarm, forKey: "clickDesktopToCycleSwarm")
            NotificationCenter.default.post(name: .clickDesktopToCycleSwarmDidChange, object: nil)
        }
    }

    var desktopWallpaperSpeed: Double = 1.0 {
        didSet {
            let clamped = min(max(desktopWallpaperSpeed, 0.35), 2.5)
            guard desktopWallpaperSpeed == clamped else {
                desktopWallpaperSpeed = clamped
                return
            }
            persistence.set(desktopWallpaperSpeed, forKey: "desktopWallpaperSpeed")
            NotificationCenter.default.post(name: .desktopWallpaperSpeedDidChange, object: nil)
        }
    }

    var desktopWallpaperProviderGlyphs: [AgentProvider] = SwarmProviderGlyphSelection.allProviders {
        didSet {
            let normalized = SwarmProviderGlyphSelection.normalized(desktopWallpaperProviderGlyphs)
            guard desktopWallpaperProviderGlyphs == normalized else {
                desktopWallpaperProviderGlyphs = normalized
                return
            }
            persistence.set(
                SwarmProviderGlyphSelection.encode(normalized),
                forKey: "desktopWallpaperProviderGlyphs"
            )
            NotificationCenter.default.post(name: .desktopWallpaperProviderGlyphsDidChange, object: nil)
        }
    }

    var preferredSwiftUIColorScheme: ColorScheme? {
        appearanceMode.colorScheme
    }

    private var isSyncingDesktopWallpaperBackground = false

    init(persistence: SettingsPersistenceCoordinator) {
        self.persistence = persistence
        if let modeRaw = persistence.optionalString(forKey: "appearanceMode"),
           let mode = AppearanceMode(rawValue: modeRaw) {
            self.appearanceMode = mode
        } else if persistence.bool(forKey: "preferLightAppearance") {
            self.appearanceMode = .light
        } else {
            self.appearanceMode = .system
        }
        // Skin is canonically read from `UserDefaults.standard` (where the
        // dynamic color resolvers read `AppSkin.current`); mirror it back through
        // the coordinator so a fresh suite stays consistent.
        self.appearanceSkin = AppSkin.current
        let hasLaunched = persistence.bool(forKey: "hasLaunchedBefore")
        self.showInMenuBar = hasLaunched ? persistence.bool(forKey: "showInMenuBar") : true
        self.colorfulMenuBarIcon = persistence.bool(forKey: "colorfulMenuBarIcon")
        self.usePremiumSOTAUX = persistence.bool(forKey: "usePremiumSOTAUX")
        self.useWebsiteBackground = persistence.bool(forKey: "useWebsiteBackground")
        self.useConstellationBackground = persistence.bool(forKey: "useConstellationBackground", defaultValue: false)
        self.enableDesktopWallpaper = persistence.bool(forKey: "enableDesktopWallpaper", defaultValue: false)
        self.amoledDarkBackground = persistence.bool(forKey: "amoledDarkBackground", defaultValue: false)
        if let raw = persistence.optionalString(forKey: "desktopWallpaperBackground"),
           let background = DesktopWallpaperBackground(rawValue: raw) {
            self.desktopWallpaperBackground = background
        } else if self.amoledDarkBackground {
            self.desktopWallpaperBackground = .amoledBlack
        } else {
            self.desktopWallpaperBackground = .macOSDesktop
        }
        self.amoledDarkBackground = self.desktopWallpaperBackground == .amoledBlack
        persistence.set(self.desktopWallpaperBackground.rawValue, forKey: "desktopWallpaperBackground")
        persistence.set(self.amoledDarkBackground, forKey: "amoledDarkBackground")
        self.cycleShapesScreensaver = persistence.bool(forKey: "cycleShapesScreensaver", defaultValue: true)
        self.enableSwarmSparkles = persistence.bool(forKey: "enableSwarmSparkles", defaultValue: true)
        self.excludeBrandShapesFromSwarm = persistence.bool(forKey: "excludeBrandShapesFromSwarm", defaultValue: false)
        self.clickDesktopToCycleSwarm = persistence.bool(forKey: "clickDesktopToCycleSwarm", defaultValue: false)
        self.desktopWallpaperSpeed = min(max(persistence.double(forKey: "desktopWallpaperSpeed", defaultValue: 1.0), 0.35), 2.5)
        self.desktopWallpaperProviderGlyphs = SwarmProviderGlyphSelection.decode(
            persistence.optionalString(forKey: "desktopWallpaperProviderGlyphs")
        )
    }

    private func syncAMOLEDAliasFromDesktopBackground() {
        guard !isSyncingDesktopWallpaperBackground else { return }
        let shouldUseAMOLED = desktopWallpaperBackground == .amoledBlack
        guard amoledDarkBackground != shouldUseAMOLED else { return }
        isSyncingDesktopWallpaperBackground = true
        amoledDarkBackground = shouldUseAMOLED
        isSyncingDesktopWallpaperBackground = false
    }

    private func syncDesktopBackgroundFromAMOLEDAlias() {
        guard !isSyncingDesktopWallpaperBackground else { return }
        let nextBackground: DesktopWallpaperBackground
        if amoledDarkBackground {
            nextBackground = .amoledBlack
        } else if desktopWallpaperBackground == .amoledBlack {
            nextBackground = .macOSDesktop
        } else {
            return
        }
        guard desktopWallpaperBackground != nextBackground else { return }
        isSyncingDesktopWallpaperBackground = true
        desktopWallpaperBackground = nextBackground
        isSyncingDesktopWallpaperBackground = false
    }
}

extension Notification.Name {
    static let appearanceSkinDidChange = Notification.Name("com.openburnbar.appearance.appearanceSkinDidChange")
    static let useWebsiteBackgroundDidChange = Notification.Name("com.openburnbar.appearance.useWebsiteBackgroundDidChange")
    static let useConstellationBackgroundDidChange = Notification.Name("com.openburnbar.appearance.useConstellationBackgroundDidChange")
    static let enableDesktopWallpaperDidChange = Notification.Name("com.openburnbar.appearance.enableDesktopWallpaperDidChange")
    static let amoledDarkBackgroundDidChange = Notification.Name("com.openburnbar.appearance.amoledDarkBackgroundDidChange")
    static let desktopWallpaperBackgroundDidChange = Notification.Name("com.openburnbar.appearance.desktopWallpaperBackgroundDidChange")
    static let cycleShapesScreensaverDidChange = Notification.Name("com.openburnbar.appearance.cycleShapesScreensaverDidChange")
    static let enableSwarmSparklesDidChange = Notification.Name("com.openburnbar.appearance.enableSwarmSparklesDidChange")
    static let excludeBrandShapesFromSwarmDidChange = Notification.Name("com.openburnbar.appearance.excludeBrandShapesFromSwarmDidChange")
    static let clickDesktopToCycleSwarmDidChange = Notification.Name("com.openburnbar.appearance.clickDesktopToCycleSwarmDidChange")
    static let desktopWallpaperSpeedDidChange = Notification.Name("com.openburnbar.appearance.desktopWallpaperSpeedDidChange")
    static let desktopWallpaperProviderGlyphsDidChange = Notification.Name("com.openburnbar.appearance.desktopWallpaperProviderGlyphsDidChange")
}
