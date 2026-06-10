@preconcurrency import ActivityKit
import Foundation
import OpenBurnBarCore

/// Manages the BurnBar Live Activity lifecycle.
/// Available on iOS 16.1+.
@available(iOS 16.1, *)
@Observable
@MainActor
final class LiveActivityManager {
    static let shared = LiveActivityManager()

    private let backend: any BurnBarLiveActivityBackend
    private var activity: (any BurnBarLiveActivityHandle)?
    var hasActiveActivity: Bool { activity != nil }

    init(backend: any BurnBarLiveActivityBackend = ActivityKitBurnBarLiveActivityBackend()) {
        self.backend = backend
    }

    /// Start a new Live Activity with current dashboard data.
    func startActivity(cost: Double, tokens: Int, provider: String, sessionActive: Bool) {
        guard backend.areActivitiesEnabled else { return }
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
            activity = try backend.request(attributes: attributes, state: state)
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
            await activity.update(state)
        }
    }

    /// End the Live Activity.
    func endActivity() {
        guard let activity else { return }
        // Clear the reference before awaiting the end so an in-flight end can
        // never nil out an activity requested after this call (mirrors
        // ActivityKitAgentWatchLiveActivityBackend.end()).
        self.activity = nil

        Task {
            await activity.end()
        }
    }
}

// MARK: - Backend abstraction

/// Requests platform Live Activities. Abstracted so unit tests can exercise
/// the manager's lifecycle ordering without ActivityKit.
@available(iOS 16.1, *)
@MainActor
protocol BurnBarLiveActivityBackend: AnyObject {
    var areActivitiesEnabled: Bool { get }
    func request(
        attributes: BurnBarLiveActivityAttributes,
        state: BurnBarLiveActivityAttributes.ContentState
    ) throws -> any BurnBarLiveActivityHandle
}

/// A single requested Live Activity.
@available(iOS 16.1, *)
@MainActor
protocol BurnBarLiveActivityHandle: AnyObject {
    func update(_ state: BurnBarLiveActivityAttributes.ContentState) async
    func end() async
}

@available(iOS 16.1, *)
@MainActor
private final class ActivityKitBurnBarLiveActivityBackend: BurnBarLiveActivityBackend {
    var areActivitiesEnabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    func request(
        attributes: BurnBarLiveActivityAttributes,
        state: BurnBarLiveActivityAttributes.ContentState
    ) throws -> any BurnBarLiveActivityHandle {
        let content = ActivityContent(state: state, staleDate: nil)
        return ActivityKitBurnBarLiveActivityHandle(
            activity: try Activity.request(attributes: attributes, content: content, pushType: nil)
        )
    }
}

@available(iOS 16.1, *)
@MainActor
private final class ActivityKitBurnBarLiveActivityHandle: BurnBarLiveActivityHandle {
    private let activity: Activity<BurnBarLiveActivityAttributes>

    init(activity: Activity<BurnBarLiveActivityAttributes>) {
        self.activity = activity
    }

    func update(_ state: BurnBarLiveActivityAttributes.ContentState) async {
        await activity.update(ActivityContent(state: state, staleDate: nil))
    }

    func end() async {
        await activity.end(nil, dismissalPolicy: .default)
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
