import Foundation
import OpenBurnBarCore

extension Notification.Name {
    static let openBurnBarMobileAppCheckValidationFailed = Notification.Name("openBurnBarMobileAppCheckValidationFailed")
}

/// Surfaces App Check attestation bind failures to mobile Settings UI.
@Observable @MainActor
final class MobileAppCheckAttestationMonitor {
    static let shared = MobileAppCheckAttestationMonitor()

    private(set) var lastWarningMessage: String?

    private init() {
        NotificationCenter.default.addObserver(
            forName: .openBurnBarMobileAppCheckValidationFailed,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let message = notification.userInfo?["message"] as? String
            Task { @MainActor in
                self?.lastWarningMessage = message
            }
        }
    }

    func clearWarning() {
        lastWarningMessage = nil
    }
}
