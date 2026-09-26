import Foundation
import Observation
import OpenBurnBarKernel

public extension Notification.Name {
    static let openBurnBarMobileAppCheckValidationFailed = Notification.Name("openBurnBarMobileAppCheckValidationFailed")
}

/// Wave 3.4 union of the macOS `AppCheckAttestationMonitor` and iOS
/// `MobileAppCheckAttestationMonitor` twins. Surfaces App Check attestation
/// bind failures to Settings UI. The two hosts post distinct notification
/// names (`.openBurnBarAppCheckValidationFailed` on macOS, defined in
/// OpenBurnBarKernel; `.openBurnBarMobileAppCheckValidationFailed` on iOS,
/// defined above), so `shared` observes the host-appropriate name while the
/// observation logic itself is shared.
@Observable @MainActor
public final class AppCheckAttestationMonitor {
    #if os(macOS)
    public static let shared = AppCheckAttestationMonitor(notificationName: .openBurnBarAppCheckValidationFailed)
    #else
    public static let shared = AppCheckAttestationMonitor(notificationName: .openBurnBarMobileAppCheckValidationFailed)
    #endif

    public private(set) var lastWarningMessage: String?

    init(notificationName: Notification.Name) {
        NotificationCenter.default.addObserver(
            forName: notificationName,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let message = notification.userInfo?["message"] as? String
            Task { @MainActor in
                self?.lastWarningMessage = message
            }
        }
    }

    public func clearWarning() {
        lastWarningMessage = nil
    }
}
