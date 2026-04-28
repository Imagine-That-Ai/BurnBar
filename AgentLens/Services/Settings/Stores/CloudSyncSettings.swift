import Foundation

// MARK: - Cloud Sync Settings

@Observable
@MainActor
final class CloudSyncSettings {
    private let persistence: SettingsPersistenceCoordinator

    var conversationCloudBackupEnabled: Bool = false {
        didSet { persistence.set(conversationCloudBackupEnabled, forKey: "conversationCloudBackupEnabled") }
    }

    var iCloudSessionMirrorEnabled: Bool = false {
        didSet { persistence.set(iCloudSessionMirrorEnabled, forKey: "iCloudSessionMirrorEnabled") }
    }

    var sessionLogCloudBackupEnabled: Bool = false {
        didSet { persistence.set(sessionLogCloudBackupEnabled, forKey: "sessionLogCloudBackupEnabled") }
    }

    var sessionLogCloudBackupConsentShown: Bool = false {
        didSet { persistence.set(sessionLogCloudBackupConsentShown, forKey: "sessionLogCloudBackupConsentShown") }
    }

    init(persistence: SettingsPersistenceCoordinator) {
        self.persistence = persistence
        self.conversationCloudBackupEnabled = persistence.bool(forKey: "conversationCloudBackupEnabled")
        self.iCloudSessionMirrorEnabled = persistence.bool(forKey: "iCloudSessionMirrorEnabled")
        self.sessionLogCloudBackupEnabled = persistence.bool(forKey: "sessionLogCloudBackupEnabled")
        self.sessionLogCloudBackupConsentShown = persistence.bool(forKey: "sessionLogCloudBackupConsentShown")
    }
}
