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
    }
}
