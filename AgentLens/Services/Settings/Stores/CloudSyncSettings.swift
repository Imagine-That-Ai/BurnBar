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

    var chatThreadContentCloudBackupEnabled: Bool = false {
        didSet { persistence.set(chatThreadContentCloudBackupEnabled, forKey: "chatThreadContentCloudBackupEnabled") }
    }

    var chatThreadContentCloudBackupConsentShown: Bool = false {
        didSet { persistence.set(chatThreadContentCloudBackupConsentShown, forKey: "chatThreadContentCloudBackupConsentShown") }
    }

    init(persistence: SettingsPersistenceCoordinator) {
        self.persistence = persistence
        self.conversationCloudBackupEnabled = persistence.bool(forKey: "conversationCloudBackupEnabled")
        self.iCloudSessionMirrorEnabled = persistence.bool(forKey: "iCloudSessionMirrorEnabled")
        self.sessionLogCloudBackupEnabled = persistence.bool(forKey: "sessionLogCloudBackupEnabled")
        self.sessionLogCloudBackupConsentShown = persistence.bool(forKey: "sessionLogCloudBackupConsentShown")
        self.chatThreadContentCloudBackupEnabled = persistence.bool(forKey: "chatThreadContentCloudBackupEnabled")
        self.chatThreadContentCloudBackupConsentShown = persistence.bool(forKey: "chatThreadContentCloudBackupConsentShown")
    }
}
