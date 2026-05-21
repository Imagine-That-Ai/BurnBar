import SwiftUI

enum DesktopWallpaperBackground: String, CaseIterable, Codable, Hashable, Identifiable {
    case macOSDesktop
    case midnight
    case amoledBlack
    case graphite
    case warmEmber
    case deepIndigo

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .macOSDesktop: return "macOS Desktop"
        case .midnight: return "Midnight"
        case .amoledBlack: return "AMOLED Black"
        case .graphite: return "Graphite"
        case .warmEmber: return "Warm Ember"
        case .deepIndigo: return "Deep Indigo"
        }
    }

    var detailText: String {
        switch self {
        case .macOSDesktop: return "Let your current macOS desktop show behind the swarm."
        case .midnight: return "A quiet near-black surface with a soft blue cast."
        case .amoledBlack: return "Pitch black for OLED and maximum particle contrast."
        case .graphite: return "Neutral dark gray for less contrast than black."
        case .warmEmber: return "Dark warm brown tuned for BurnBar embers."
        case .deepIndigo: return "A deep violet-blue stage for provider colors."
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
        }
    }

    var swatchColor: Color {
        switch self {
        case .macOSDesktop: return Color.clear
        case .midnight: return Color(red: 0.020, green: 0.024, blue: 0.040)
        case .amoledBlack: return Color.black
        case .graphite: return Color(red: 0.110, green: 0.115, blue: 0.125)
        case .warmEmber: return Color(red: 0.115, green: 0.065, blue: 0.045)
        case .deepIndigo: return Color(red: 0.050, green: 0.045, blue: 0.115)
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
        }
    }

    var isTransparent: Bool {
        self == .macOSDesktop
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
        didSet { persistence.set(useWebsiteBackground, forKey: "useWebsiteBackground") }
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
        didSet { persistence.set(cycleShapesScreensaver, forKey: "cycleShapesScreensaver") }
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
        let hasLaunched = persistence.bool(forKey: "hasLaunchedBefore")
        self.showInMenuBar = hasLaunched ? persistence.bool(forKey: "showInMenuBar") : true
        self.colorfulMenuBarIcon = persistence.bool(forKey: "colorfulMenuBarIcon")
        self.usePremiumSOTAUX = persistence.bool(forKey: "usePremiumSOTAUX")
        self.useWebsiteBackground = persistence.bool(forKey: "useWebsiteBackground")
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
    static let enableDesktopWallpaperDidChange = Notification.Name("com.openburnbar.appearance.enableDesktopWallpaperDidChange")
    static let amoledDarkBackgroundDidChange = Notification.Name("com.openburnbar.appearance.amoledDarkBackgroundDidChange")
    static let desktopWallpaperBackgroundDidChange = Notification.Name("com.openburnbar.appearance.desktopWallpaperBackgroundDidChange")
}
