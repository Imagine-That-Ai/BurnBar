import ActivityKit
import Foundation
import OpenBurnBarCore

/// Manages the BurnBar Live Activity lifecycle.
/// Available on iOS 16.1+.
@available(iOS 16.1, *)
@Observable
@MainActor
final class LiveActivityManager {
    static let shared = LiveActivityManager()

    private var activity: Activity<BurnBarLiveActivityAttributes>?
    var hasActiveActivity: Bool { activity != nil }

    private init() {}

    /// Start a new Live Activity with current dashboard data.
    func startActivity(cost: Double, tokens: Int, provider: String, sessionActive: Bool) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        // End any existing activity first.
        endActivity()

        let attributes = BurnBarLiveActivityAttributes(heroTitle: "Today's Burn")
        let state = BurnBarLiveActivityAttributes.ContentState(
            heroCost: cost,
            heroTokens: tokens,
            topProvider: provider,
            sessionActive: sessionActive
        )

        do {
            activity = try Activity.request(
                attributes: attributes,
                contentState: state,
                pushType: nil
            )
        } catch {
            // Live Activity failures are non-critical; do not surface to user.
        }
    }

    /// Update the current Live Activity with new data.
    func updateActivity(cost: Double, tokens: Int, provider: String, sessionActive: Bool) {
        guard let activity else { return }

        let state = BurnBarLiveActivityAttributes.ContentState(
            heroCost: cost,
            heroTokens: tokens,
            topProvider: provider,
            sessionActive: sessionActive
        )

        Task {
            await activity.update(using: state)
        }
    }

    /// End the Live Activity.
    func endActivity() {
        guard let activity else { return }

        Task {
            await activity.end(dismissalPolicy: .default)
            self.activity = nil
        }
    }
}

// MARK: - No-op stub for iOS < 16.1

/// Non-ActivityKit fallback for compilation on older OS versions.
@MainActor
final class LiveActivityManagerStub {
    static let shared = LiveActivityManagerStub()
    var hasActiveActivity: Bool { false }
    func startActivity(cost: Double, tokens: Int, provider: String, sessionActive: Bool) {}
    func updateActivity(cost: Double, tokens: Int, provider: String, sessionActive: Bool) {}
    func endActivity() {}
}
