#if canImport(ActivityKit)
@preconcurrency import ActivityKit
import Foundation
import OpenBurnBarCore

@available(iOS 16.1, *)
@MainActor
final class AgentWatchLiveActivityManager {
    static let shared = AgentWatchLiveActivityManager()

    private let backend: any AgentWatchLiveActivityBackend
    var hasActiveActivity: Bool { backend.activeSessionId != nil }

    init(backend: any AgentWatchLiveActivityBackend = ActivityKitAgentWatchLiveActivityBackend()) {
        self.backend = backend
    }

    func start(sessionId: String, startedAt: Date) {
        if backend.activeSessionId == sessionId { return }
        do {
            try backend.request(
                sessionId: sessionId,
                startedAt: startedAt,
                initialState: AgentWatchLiveActivityAttributes.ContentState(
                    appName: "Agent Live",
                    lastAction: "Watching Mac",
                    actionsCount: 0,
                    approvalPending: false,
                    elapsed: 0
                )
            )
        } catch {
            backend.end()
        }
    }

    func update(
        appName: String,
        lastAction: String,
        actionsCount: Int,
        approvalPending: Bool,
        elapsed: TimeInterval
    ) {
        let state = AgentWatchLiveActivityAttributes.ContentState(
            appName: appName,
            lastAction: lastAction,
            actionsCount: actionsCount,
            approvalPending: approvalPending,
            elapsed: elapsed
        )
        backend.update(state)
    }

    func end() {
        backend.end()
    }
}

@available(iOS 16.1, *)
@MainActor
protocol AgentWatchLiveActivityBackend: AnyObject {
    var activeSessionId: String? { get }
    func request(
        sessionId: String,
        startedAt: Date,
        initialState: AgentWatchLiveActivityAttributes.ContentState
    ) throws
    func update(_ state: AgentWatchLiveActivityAttributes.ContentState)
    func end()
}

@available(iOS 16.1, *)
@MainActor
private final class ActivityKitAgentWatchLiveActivityBackend: AgentWatchLiveActivityBackend {
    private var activity: Activity<AgentWatchLiveActivityAttributes>?

    var activeSessionId: String? { activity?.attributes.sessionId }

    func request(
        sessionId: String,
        startedAt: Date,
        initialState: AgentWatchLiveActivityAttributes.ContentState
    ) throws {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        end()
        let attributes = AgentWatchLiveActivityAttributes(
            sessionId: sessionId,
            startedAt: startedAt
        )
        let content = ActivityContent(state: initialState, staleDate: nil)
        activity = try Activity.request(attributes: attributes, content: content, pushType: nil)
    }

    func update(_ state: AgentWatchLiveActivityAttributes.ContentState) {
        guard let activity else { return }
        Task.detached { [activity, state] in
            await activity.update(ActivityContent(state: state, staleDate: nil))
        }
    }

    func end() {
        guard let activity else { return }
        self.activity = nil
        Task {
            await activity.end(nil, dismissalPolicy: .default)
        }
    }
}

@MainActor
final class AgentWatchLiveActivityManagerStub {
    static let shared = AgentWatchLiveActivityManagerStub()

    var hasActiveActivity: Bool { false }
    func start(sessionId: String, startedAt: Date) {}
    func update(appName: String, lastAction: String, actionsCount: Int, approvalPending: Bool, elapsed: TimeInterval) {}
    func end() {}
}
#endif
