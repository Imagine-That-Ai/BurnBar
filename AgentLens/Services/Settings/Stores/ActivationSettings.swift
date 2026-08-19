import Foundation

// MARK: - Activation Settings

/// Persists the two — and only two — stored facts about the activation
/// checklist (T1.6): whether the user dismissed it by hand, and when every
/// step first read as complete. Everything else the checklist shows is
/// derived live from `SettingsManager` / `DataStoreCoordinator`, so the card
/// can never disagree with the switches it describes.
@Observable
@MainActor
final class ActivationSettings {
    private let persistence: SettingsPersistenceCoordinator

    /// The user closed the checklist by hand. Dismissal is forever — the card
    /// promised "never nagging", and a flag that quietly resets would break
    /// that promise.
    var checklistDismissed: Bool = false {
        didSet { persistence.set(checklistDismissed, forKey: "activationChecklistDismissed") }
    }

    /// The moment all five steps first read as done. Non-nil retires the card
    /// permanently; kept as a timestamp (not a Bool) so a future funnel can
    /// report time-to-activation without a schema change.
    var checklistCompletedAt: Date? {
        didSet {
            if let checklistCompletedAt {
                persistence.set(checklistCompletedAt, forKey: "activationChecklistCompletedAt")
            } else {
                persistence.removeObject(forKey: "activationChecklistCompletedAt")
            }
        }
    }

    init(persistence: SettingsPersistenceCoordinator) {
        self.persistence = persistence
        self.checklistDismissed = persistence.bool(forKey: "activationChecklistDismissed")
        self.checklistCompletedAt = persistence.optionalDate(forKey: "activationChecklistCompletedAt")
    }
}
