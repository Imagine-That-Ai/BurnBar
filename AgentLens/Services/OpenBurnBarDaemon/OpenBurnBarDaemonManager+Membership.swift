import FirebaseCore
import Foundation
import OpenBurnBarKernel

// MARK: - Memory Pro: daemon membership cache

extension OpenBurnBarDaemonManager {
    /// Two refreshes inside this window coalesce into one restore call.
    static let membershipRefreshMinimumInterval: TimeInterval = 60
    static let cadenceIDMembershipRefresh = "daemon-membership-refresh"

    /// Ask the daemon to re-pull its membership snapshot so Memory Pro gating
    /// (`BurnBarMembershipFreshness`, ≤ 7 days) sees a purchase, renewal, or
    /// lapse promptly. Called at launch, on entitlement changes (StoreKit or
    /// Firestore), and daily; rate-limited to once per minute.
    func refreshDaemonMembershipCache(reason: String, now: Date = Date()) async {
        if let last = lastMembershipRefreshAt, now.timeIntervalSince(last) < Self.membershipRefreshMinimumInterval {
            return
        }
        lastMembershipRefreshAt = now
        let socketURL = paths.socketURL
        let restore = dependencies.membershipRestore
        do {
            let response = try await daemonRPC {
                try restore(socketURL)
            }
            AppLogger.daemon.info(
                "memory_membership_cache_refreshed",
                metadata: [
                    "reason": reason,
                    "ok": response.ok ? "true" : "false",
                    "tier": response.membership?.tier ?? "unknown",
                    "updatedAt": response.membership?.updatedAt ?? "nil"
                ]
            )
        } catch {
            AppLogger.daemon.silentFailure(
                "OpenBurnBarDaemonManager: membership cache refresh failed (\(reason))",
                error: error
            )
        }
    }

    /// Daily refresh through the shared cadence coordinator (paused while the
    /// display sleeps; inert without Firebase).
    func registerMembershipRefreshCadence() {
        BackgroundCadenceCoordinator.shared.register(
            BackgroundCadenceCoordinator.Cadence(
                id: Self.cadenceIDMembershipRefresh,
                activeInterval: 86_400,
                backgroundInterval: 86_400,
                sleepInterval: nil,
                isEnabled: { FirebaseApp.app() != nil },
                fireImmediately: false,
                cancellableInFlight: true,
                work: { [weak self] in
                    await self?.refreshDaemonMembershipCache(reason: "daily")
                }
            )
        )
    }
}
