import Foundation

// MARK: - Alert Settings

@Observable
@MainActor
final class AlertSettings {
    private let persistence: SettingsPersistenceCoordinator

    var costAlertThreshold: Double? = nil {
        didSet {
            if let threshold = costAlertThreshold {
                persistence.set(true, forKey: "hasCostAlertThreshold")
                persistence.set(threshold, forKey: "costAlertThreshold")
            } else {
                persistence.set(false, forKey: "hasCostAlertThreshold")
            }
        }
    }

    var dailyDigestEnabled: Bool = false {
        didSet { persistence.set(dailyDigestEnabled, forKey: "dailyDigestEnabled") }
    }

    var dailyDigestHour: Int = 18 {
        didSet { persistence.set(dailyDigestHour, forKey: "dailyDigestHour") }
    }

    init(persistence: SettingsPersistenceCoordinator) {
        self.persistence = persistence
        if persistence.objectExists(forKey: "hasCostAlertThreshold") {
            self.costAlertThreshold = persistence.double(forKey: "costAlertThreshold")
        } else {
            self.costAlertThreshold = nil
        }
        self.dailyDigestEnabled = persistence.bool(forKey: "dailyDigestEnabled")
        if persistence.objectExists(forKey: "dailyDigestHour") {
            let hour = persistence.integer(forKey: "dailyDigestHour")
            self.dailyDigestHour = (hour >= 0 && hour < 24) ? hour : 18
        } else {
            self.dailyDigestHour = 18
        }
    }
}
