import Foundation
import OpenBurnBarCore

/// Surfaces App Check attestation bind failures to Settings UI (Mac).
@Observable @MainActor
final class AppCheckAttestationMonitor {
    static let shared = AppCheckAttestationMonitor()

    private(set) var lastWarningMessage: String?

    private init() {
        NotificationCenter.default.addObserver(
            forName: .openBurnBarAppCheckValidationFailed,
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
