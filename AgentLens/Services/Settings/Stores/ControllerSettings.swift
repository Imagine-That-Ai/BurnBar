import Foundation

// MARK: - Controller Settings

@Observable
@MainActor
final class ControllerSettings {
    private let persistence: SettingsPersistenceCoordinator
    private let secretPersistence: SettingsSecretPersistence

    var controllerRuntimeEnabled: Bool = true {
        didSet { persistence.set(controllerRuntimeEnabled, forKey: "controllerRuntimeEnabled") }
    }

    var controllerRuntimeRefreshMinutes: Int = 5 {
        didSet { persistence.set(controllerRuntimeRefreshMinutes, forKey: "controllerRuntimeRefreshMinutes") }
    }

    var controllerLocalNotificationsEnabled: Bool = true {
        didSet { persistence.set(controllerLocalNotificationsEnabled, forKey: "controllerLocalNotificationsEnabled") }
    }

    var controllerTelegramEnabled: Bool = false {
        didSet { persistence.set(controllerTelegramEnabled, forKey: "controllerTelegramEnabled") }
    }

    var controllerTelegramBotToken: String = "" {
        didSet {
            secretPersistence.persist(
                controllerTelegramBotToken,
                account: OpenBurnBarIdentity.controllerTelegramBotTokenAccount,
                legacyDefaultsKey: SettingsSecretDefaultsKey.controllerTelegramBotToken
            )
        }
    }

    var controllerTelegramChatID: String = "" {
        didSet { persistence.set(controllerTelegramChatID, forKey: "controllerTelegramChatID") }
    }

    var controllerCalendarIntegrationEnabled: Bool = true {
        didSet { persistence.set(controllerCalendarIntegrationEnabled, forKey: "controllerCalendarIntegrationEnabled") }
    }

    var controllerCalendarDefaultMinutes: Int = 30 {
        didSet { persistence.set(controllerCalendarDefaultMinutes, forKey: "controllerCalendarDefaultMinutes") }
    }

    var controllerDefaultSnoozeMinutes: Int = 180 {
        didSet { persistence.set(controllerDefaultSnoozeMinutes, forKey: "controllerDefaultSnoozeMinutes") }
    }

    var controllerSimulatorToolsEnabled: Bool = false {
        didSet { persistence.set(controllerSimulatorToolsEnabled, forKey: "controllerSimulatorToolsEnabled") }
    }

    init(persistence: SettingsPersistenceCoordinator, secretPersistence: SettingsSecretPersistence) {
        self.persistence = persistence
        self.secretPersistence = secretPersistence
        if persistence.objectExists(forKey: "controllerRuntimeEnabled") {
            self.controllerRuntimeEnabled = persistence.bool(forKey: "controllerRuntimeEnabled")
        } else {
            self.controllerRuntimeEnabled = true
        }
        if persistence.objectExists(forKey: "controllerRuntimeRefreshMinutes") {
            self.controllerRuntimeRefreshMinutes = max(persistence.integer(forKey: "controllerRuntimeRefreshMinutes"), 1)
        } else {
            self.controllerRuntimeRefreshMinutes = 5
        }
        if persistence.objectExists(forKey: "controllerLocalNotificationsEnabled") {
            self.controllerLocalNotificationsEnabled = persistence.bool(forKey: "controllerLocalNotificationsEnabled")
        } else {
            self.controllerLocalNotificationsEnabled = true
        }
        self.controllerTelegramEnabled = persistence.bool(forKey: "controllerTelegramEnabled")
        self.controllerTelegramBotToken = secretPersistence.load(
            account: OpenBurnBarIdentity.controllerTelegramBotTokenAccount,
            legacyDefaultsKey: SettingsSecretDefaultsKey.controllerTelegramBotToken
        )
        self.controllerTelegramChatID = persistence.string(forKey: "controllerTelegramChatID")
        if persistence.objectExists(forKey: "controllerCalendarIntegrationEnabled") {
            self.controllerCalendarIntegrationEnabled = persistence.bool(forKey: "controllerCalendarIntegrationEnabled")
        } else {
            self.controllerCalendarIntegrationEnabled = true
        }
        if persistence.objectExists(forKey: "controllerCalendarDefaultMinutes") {
            self.controllerCalendarDefaultMinutes = max(persistence.integer(forKey: "controllerCalendarDefaultMinutes"), 15)
        } else {
            self.controllerCalendarDefaultMinutes = 30
        }
        if persistence.objectExists(forKey: "controllerDefaultSnoozeMinutes") {
            self.controllerDefaultSnoozeMinutes = max(persistence.integer(forKey: "controllerDefaultSnoozeMinutes"), 15)
        } else {
            self.controllerDefaultSnoozeMinutes = 180
        }
        self.controllerSimulatorToolsEnabled = persistence.bool(forKey: "controllerSimulatorToolsEnabled")
    }
}
