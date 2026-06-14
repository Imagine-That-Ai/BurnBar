import FirebaseAuth
import Foundation
import UIKit

extension Notification.Name {
    /// Posted after a successful local escrow-device trust revocation so survivor
    /// rotation pickup can run immediately (mirrors Mac `AppDelegate` post-revoke trigger).
    static let openBurnBarDidRevokeDeviceTrust = Notification.Name("openBurnBarDidRevokeDeviceTrust")
}

/// RR-5 / T-PTR-02: survivor-side Cloud Vault rotation pickup on iOS launch,
/// foreground, and post-revoke. Mirrors Android `CloudVaultRotationPickupLifecycle`
/// and Mac `AppDelegate` pickup triggers.
enum CloudVaultRotationPickupLifecycle {
    private static let debounceInterval: TimeInterval = 30
    private static var installed = false
    private static var lastPickupAt: TimeInterval = 0
    private static var foregroundObserver: NSObjectProtocol?
    private static var postRevokeObserver: NSObjectProtocol?

    static func install() {
        guard !isRunningTests else { return }
        guard !installed else { return }
        installed = true

        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            schedulePickup(force: false)
        }

        postRevokeObserver = NotificationCenter.default.addObserver(
            forName: .openBurnBarDidRevokeDeviceTrust,
            object: nil,
            queue: .main
        ) { _ in
            schedulePickup(force: true)
        }

        schedulePickup(force: true)
    }

    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    private static func schedulePickup(force: Bool) {
        let now = Date().timeIntervalSinceReferenceDate
        if !force, now - lastPickupAt < debounceInterval {
            return
        }
        lastPickupAt = now

        guard let user = Auth.auth().currentUser, user.isAnonymous == false else { return }

        let rotatingDeviceId = MobileDeviceIdentity.loadOrCreateDeviceId()
        Task {
            do {
                _ = try await MobileCloudVaultRevocationRotation.pickUpPendingCloudVaultRotations(
                    rotatingDeviceId: rotatingDeviceId
                )
            } catch {
                #if DEBUG
                print("Cloud Vault rotation pickup failed: \(error.localizedDescription)")
                #endif
            }
        }
    }
}