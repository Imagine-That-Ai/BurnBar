import Foundation

// MARK: - Receipt Settings

@Observable
@MainActor
final class ReceiptSettings {
    private let persistence: SettingsPersistenceCoordinator

    var receiptFlyoutEnabled: Bool = true {
        didSet { persistence.set(receiptFlyoutEnabled, forKey: "receiptFlyoutEnabled") }
    }

    var receiptSystemNotificationsEnabled: Bool = false {
        didSet { persistence.set(receiptSystemNotificationsEnabled, forKey: "receiptSystemNotificationsEnabled") }
    }

    var receiptAutoQualityReviewEnabled: Bool = false {
        didSet { persistence.set(receiptAutoQualityReviewEnabled, forKey: "receiptAutoQualityReviewEnabled") }
    }

    var receiptSoundEnabled: Bool = true {
        didSet { persistence.set(receiptSoundEnabled, forKey: "receiptSoundEnabled") }
    }

    var receiptReviewModel: String = "anthropic/claude-3.5-haiku" {
        didSet { persistence.set(receiptReviewModel, forKey: "receiptReviewModel") }
    }

    init(persistence: SettingsPersistenceCoordinator) {
        self.persistence = persistence
        self.receiptFlyoutEnabled = persistence.bool(forKey: "receiptFlyoutEnabled", defaultValue: true)
        self.receiptSystemNotificationsEnabled = persistence.bool(forKey: "receiptSystemNotificationsEnabled", defaultValue: false)
        self.receiptAutoQualityReviewEnabled = persistence.bool(forKey: "receiptAutoQualityReviewEnabled", defaultValue: false)
        self.receiptSoundEnabled = persistence.bool(forKey: "receiptSoundEnabled", defaultValue: true)
        self.receiptReviewModel = persistence.string(forKey: "receiptReviewModel") ?? "anthropic/claude-3.5-haiku"
    }
}
