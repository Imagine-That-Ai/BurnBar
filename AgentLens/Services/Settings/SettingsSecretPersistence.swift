import Foundation

// MARK: - Settings Secret Defaults Key

enum SettingsSecretDefaultsKey {
    static let controllerTelegramBotToken = "controllerTelegramBotToken"
    static let openClawBearerToken = "openClawBearerToken"
    static let hermesBearerToken = "hermesBearerToken"
    static let gatewayAuthToken = "gatewayAuthToken"
}

// MARK: - Settings Secret Persistence

struct SettingsSecretPersistence {
    let defaults: UserDefaults
    let keychain: KeychainStore

    func load(account: String, legacyDefaultsKey: String) -> String {
        if let stored = try? keychain.string(for: account) {
            if defaults.object(forKey: legacyDefaultsKey) != nil {
                defaults.removeObject(forKey: legacyDefaultsKey)
            }
            return stored
        }

        guard let legacy = defaults.string(forKey: legacyDefaultsKey),
              !legacy.isEmpty else {
            if defaults.object(forKey: legacyDefaultsKey) != nil {
                defaults.removeObject(forKey: legacyDefaultsKey)
            }
            return ""
        }

        do {
            try keychain.set(legacy, for: account)
            defaults.removeObject(forKey: legacyDefaultsKey)
        } catch {
            defaults.removeObject(forKey: legacyDefaultsKey)
        }

        return legacy
    }

    func persist(_ value: String, account: String, legacyDefaultsKey: String) {
        do {
            if value.isEmpty {
                try keychain.delete(account: account)
            } else {
                try keychain.set(value, for: account)
            }
            defaults.removeObject(forKey: legacyDefaultsKey)
        } catch {
            defaults.removeObject(forKey: legacyDefaultsKey)
        }
    }
}
