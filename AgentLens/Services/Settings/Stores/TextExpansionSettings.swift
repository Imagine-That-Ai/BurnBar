import Foundation

extension Notification.Name {
    static let textExpansionMacGlobalExpansionEnabledDidChange = Notification.Name("textExpansion.macGlobalExpansionEnabled.didChange")
}

@Observable
@MainActor
final class TextExpansionSettings {
    private let persistence: SettingsPersistenceCoordinator

    var inAppExpansionEnabled: Bool = true {
        didSet { persistence.set(inAppExpansionEnabled, forKey: "textExpansion.inAppExpansionEnabled") }
    }

    var macGlobalExpansionEnabled: Bool = false {
        didSet {
            persistence.set(macGlobalExpansionEnabled, forKey: "textExpansion.macGlobalExpansionEnabled")
            guard oldValue != macGlobalExpansionEnabled else { return }
            NotificationCenter.default.post(
                name: .textExpansionMacGlobalExpansionEnabledDidChange,
                object: self,
                userInfo: ["enabled": macGlobalExpansionEnabled]
            )
        }
    }

    var llmRewritePreviewEnabled: Bool = true {
        didSet { persistence.set(llmRewritePreviewEnabled, forKey: "textExpansion.llmRewritePreviewEnabled") }
    }

    var exportKeyboardSnapshotEnabled: Bool = true {
        didSet { persistence.set(exportKeyboardSnapshotEnabled, forKey: "textExpansion.exportKeyboardSnapshotEnabled") }
    }

    var cloudSyncEnabled: Bool = true {
        didSet { persistence.set(cloudSyncEnabled, forKey: "textExpansion.cloudSyncEnabled") }
    }

    init(persistence: SettingsPersistenceCoordinator) {
        self.persistence = persistence
        self.inAppExpansionEnabled = persistence.bool(forKey: "textExpansion.inAppExpansionEnabled", defaultValue: true)
        self.macGlobalExpansionEnabled = persistence.bool(forKey: "textExpansion.macGlobalExpansionEnabled", defaultValue: false)
        self.llmRewritePreviewEnabled = persistence.bool(forKey: "textExpansion.llmRewritePreviewEnabled", defaultValue: true)
        self.exportKeyboardSnapshotEnabled = persistence.bool(forKey: "textExpansion.exportKeyboardSnapshotEnabled", defaultValue: true)
        self.cloudSyncEnabled = persistence.bool(forKey: "textExpansion.cloudSyncEnabled", defaultValue: true)
    }
}
