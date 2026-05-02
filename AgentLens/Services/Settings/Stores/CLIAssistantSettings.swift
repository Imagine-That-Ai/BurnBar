import Foundation

// MARK: - CLI Assistant Settings

@Observable
@MainActor
final class CLIAssistantSettings {
    private let persistence: SettingsPersistenceCoordinator

    var cliAssistantAllowed: Bool = false {
        didSet {
            if cliAssistantAllowed { cliAssistantConsentShown = true }
            persistence.set(cliAssistantAllowed, forKey: "cliAssistantAllowed")
        }
    }

    var cliAssistantConsentShown: Bool = false {
        didSet { persistence.set(cliAssistantConsentShown, forKey: "cliAssistantConsentShown") }
    }

    init(persistence: SettingsPersistenceCoordinator) {
        self.persistence = persistence
        self.cliAssistantConsentShown = persistence.bool(forKey: "cliAssistantConsentShown")
        if persistence.objectExists(forKey: "cliAssistantAllowed") {
            self.cliAssistantAllowed = persistence.bool(forKey: "cliAssistantAllowed")
        } else {
            self.cliAssistantAllowed = false
        }
    }
}
