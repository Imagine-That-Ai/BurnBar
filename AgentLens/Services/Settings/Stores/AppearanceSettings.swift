import SwiftUI

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
        didSet { persistence.set(enableDesktopWallpaper, forKey: "enableDesktopWallpaper") }
    }

    var amoledDarkBackground: Bool = false {
        didSet { persistence.set(amoledDarkBackground, forKey: "amoledDarkBackground") }
    }

    var cycleShapesScreensaver: Bool = true {
        didSet { persistence.set(cycleShapesScreensaver, forKey: "cycleShapesScreensaver") }
    }

    var preferredSwiftUIColorScheme: ColorScheme? {
        appearanceMode.colorScheme
    }

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
        self.cycleShapesScreensaver = persistence.bool(forKey: "cycleShapesScreensaver", defaultValue: true)
    }
}
