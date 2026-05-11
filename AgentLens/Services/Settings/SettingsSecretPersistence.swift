import Foundation

// MARK: - Settings Secret Defaults Key

enum SettingsSecretDefaultsKey {
    static let controllerTelegramBotToken = "controllerTelegramBotToken"
    static let openClawBearerToken = "openClawBearerToken"
    static let hermesBearerToken = "hermesBearerToken"
    static let piAgentBearerToken = "piAgentBearerToken"
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
            // Keychain migration failed — preserve the legacy UserDefaults
            // value so the next session can retry. Deleting it here would
            // permanently lose the user's secret if the keychain is locked
            // (e.g. CI without keychain provisioning, or app updates that
            // momentarily reject writes).
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
            // Same data-loss-protection rationale as `load(_:_:)`. Keep the
            // legacy value intact when keychain mutation fails so the user
            // can retry without re-entering credentials.
        }
    }
}
