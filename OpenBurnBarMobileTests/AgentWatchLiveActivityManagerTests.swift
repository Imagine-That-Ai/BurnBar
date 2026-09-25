#if canImport(ActivityKit) && canImport(AppIntents) && canImport(UIKit)
import AppIntents
import XCTest
@testable import OpenBurnBarMobile
import OpenBurnBarCore

@MainActor
final class AgentWatchLiveActivityManagerTests: XCTestCase {
    // Wave 4: one class-wide ActivityKit floor instead of a per-test guard in
    // every method. Tests needing newer OSes keep their own finer guards.
    override nonisolated func setUpWithError() throws {
        try super.setUpWithError()
        guard #available(iOS 16.1, *) else { try skipActivityKitUnavailable() }
    }

    /// Shared iOS 17 intents skip for the three intent tests below (was: an
    /// identical guard+skip in each). The `guard #available` stays at the call
    /// site so availability narrowing is preserved; only the throw moves here.
    private func skipLiveActivityIntentsUnavailable() throws -> Never {
        throw XCTSkip("Live Activity intents require iOS 17+") // env-guard: iOS 17+
    }

    func test_startUpdateEnd_routesThroughBackendAndSkipsDuplicateStart() throws {
        let backend = StubAgentWatchLiveActivityBackend()
        let manager = AgentWatchLiveActivityManager(
            backend: backend,
            pushCapability: AgentWatchLiveActivityPushCapability(canRequestTokenPush: false),
            tokenSink: nil
        )
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        manager.start(sessionId: "session-1", startedAt: startedAt)
        manager.start(sessionId: "session-1", startedAt: startedAt.addingTimeInterval(10))

        XCTAssertTrue(manager.hasActiveActivity)
        XCTAssertEqual(backend.starts.count, 1)
        XCTAssertEqual(backend.starts.first?.sessionId, "session-1")
        XCTAssertEqual(backend.starts.first?.startedAt, startedAt)
        XCTAssertEqual(backend.starts.first?.pushType, .none)
        XCTAssertEqual(manager.appliedPushType, .none)
        XCTAssertEqual(
            backend.starts.first?.initialState,
            AgentWatchLiveActivityAttributes.ContentState(
                appName: "Agent Live",
                lastAction: "Watching Mac",
                actionsCount: 0,
                approvalPending: false,
                elapsed: 0,
                remoteRefreshEnabled: false
            )
        )

        manager.update(
            appName: "Xcode",
            lastAction: "Edited RootTabView.swift",
            actionsCount: 7,
            approvalPending: true,
            elapsed: 42,
            pendingApprovalId: "approval-7"
        )

        XCTAssertEqual(
            backend.updates,
            [
                AgentWatchLiveActivityAttributes.ContentState(
                    appName: "Xcode",
                    lastAction: "Edited RootTabView.swift",
                    actionsCount: 7,
                    approvalPending: true,
                    elapsed: 42,
                    remoteRefreshEnabled: false,
                    pendingApprovalId: "approval-7"
                )
            ]
        )
        XCTAssertTrue(backend.updates[0].showsLocalOnlyRefreshCopy)

        manager.end()

        XCTAssertFalse(manager.hasActiveActivity)
        XCTAssertEqual(backend.endCount, 1)
        XCTAssertEqual(manager.appliedPushType, .none)
        XCTAssertFalse(manager.hasPushToken)
    }

    func test_apsProbeTreatsResolvedProfileAsTokenCapable() throws {
        let outcome = APSEnvironmentEntitlementProbe.inspect(
            profileData: try Self.mobileProvisionFixture(apsEnvironment: "development"),
            entitlementsPlistData: nil
        )
        XCTAssertEqual(outcome, .present("development"))
        XCTAssertTrue(outcome.canRequestTokenPush)
        XCTAssertTrue(
            AgentWatchLiveActivityPushCapability(canRequestTokenPush: outcome.canRequestTokenPush)
                .canRequestTokenPush
        )
    }

    func test_apsProbeTreatsMissingKeyAsAbsent() throws {
        let outcome = APSEnvironmentEntitlementProbe.inspect(
            profileData: try Self.mobileProvisionFixture(apsEnvironment: nil),
            entitlementsPlistData: nil
        )
        XCTAssertEqual(outcome, .absent)
        XCTAssertFalse(outcome.canRequestTokenPush)
    }

    func test_apsProbeNamesUnresolvedPlaceholderFallback() throws {
        let outcome = APSEnvironmentEntitlementProbe.inspect(
            profileData: nil,
            entitlementsPlistData: try Self.entitlementsPlist(apsEnvironment: "$(APS_ENVIRONMENT)")
        )
        XCTAssertEqual(outcome, .undetectable(.unresolvedBuildPlaceholder))
        XCTAssertFalse(outcome.canRequestTokenPush)
    }

    func test_apsProbeNamesMissingProfileFallback() {
        let outcome = APSEnvironmentEntitlementProbe.inspect(
            profileData: nil,
            entitlementsPlistData: nil
        )
        XCTAssertEqual(outcome, .undetectable(.missingEmbeddedProfile))
        XCTAssertFalse(outcome.canRequestTokenPush)
    }

    func test_startUsesTokenPushTypeWhenCapabilityExists() throws {
        let backend = StubAgentWatchLiveActivityBackend()
        let manager = AgentWatchLiveActivityManager(
            backend: backend,
            pushCapability: AgentWatchLiveActivityPushCapability(canRequestTokenPush: true),
            tokenSink: nil
        )

        manager.start(sessionId: "session-token", startedAt: Date())

        XCTAssertEqual(backend.starts.map(\.pushType), [.token])
        XCTAssertEqual(manager.appliedPushType, .token)
        XCTAssertFalse(manager.hasPushToken)
        XCTAssertEqual(backend.starts.first?.initialState.remoteRefreshEnabled, false)
    }

    func test_startFallsBackToLocalPushTypeWhenTokenRequestFails() throws {
        let backend = StubAgentWatchLiveActivityBackend()
        backend.requestErrorForPushType = .token
        let manager = AgentWatchLiveActivityManager(
            backend: backend,
            pushCapability: AgentWatchLiveActivityPushCapability(canRequestTokenPush: true),
            tokenSink: nil
        )

        manager.start(sessionId: "session-fallback", startedAt: Date())

        XCTAssertEqual(backend.starts.map(\.pushType), [.token, .none])
        XCTAssertEqual(manager.appliedPushType, .none)
        XCTAssertTrue(manager.hasActiveActivity)
        XCTAssertTrue(backend.starts.last?.initialState.showsLocalOnlyRefreshCopy ?? false)
    }

    func test_startFailureClearsBackendState() throws {
        let backend = StubAgentWatchLiveActivityBackend()
        backend.activeSessionId = "stale-session"
        backend.requestError = StubAgentWatchLiveActivityBackend.Error()
        let manager = AgentWatchLiveActivityManager(
            backend: backend,
            pushCapability: AgentWatchLiveActivityPushCapability(canRequestTokenPush: false),
            tokenSink: nil
        )

        manager.start(sessionId: "session-2", startedAt: Date())

        XCTAssertFalse(manager.hasActiveActivity)
        XCTAssertEqual(backend.endCount, 1)
        XCTAssertEqual(manager.appliedPushType, .none)
    }

    func test_pushTokenEnablesRemoteRefreshAndPersists() async throws {
        let backend = StubAgentWatchLiveActivityBackend()
        let sink = RecordingAgentWatchLiveActivityPushTokenSink()
        let manager = AgentWatchLiveActivityManager(
            backend: backend,
            pushCapability: AgentWatchLiveActivityPushCapability(canRequestTokenPush: true),
            tokenSink: sink
        )

        manager.start(sessionId: "session-token", startedAt: Date())
        let persisted = expectation(description: "Live Activity push token persisted")
        sink.onPersist = { persisted.fulfill() }
        backend.emitPushToken("aabbccdd")
        await fulfillment(of: [persisted], timeout: 1.0)

        XCTAssertTrue(manager.hasPushToken)
        XCTAssertEqual(backend.updates.last?.remoteRefreshEnabled, true)
        XCTAssertFalse(backend.updates.last?.showsLocalOnlyRefreshCopy ?? true)
        XCTAssertEqual(sink.persisted.map(\.sessionId), ["session-token"])
        XCTAssertEqual(sink.persisted.map(\.tokenHex), ["aabbccdd"])
    }

    func test_pushTokenIgnoredWhenActivityIsLocalOnly() throws {
        let backend = StubAgentWatchLiveActivityBackend()
        let sink = RecordingAgentWatchLiveActivityPushTokenSink()
        let manager = AgentWatchLiveActivityManager(
            backend: backend,
            pushCapability: AgentWatchLiveActivityPushCapability(canRequestTokenPush: false),
            tokenSink: sink
        )

        manager.start(sessionId: "session-local", startedAt: Date())
        backend.emitPushToken("deadbeef")

        XCTAssertFalse(manager.hasPushToken)
        XCTAssertTrue(sink.persisted.isEmpty)
        XCTAssertTrue(backend.updates.isEmpty)
    }

    func test_liveActivityIntentRouterQueuesCommandUntilAppHandlerIsInstalled() async throws {
        guard #available(iOS 17.0, *) else { try skipLiveActivityIntentsUnavailable() }
        AgentWatchLiveActivityIntentRouter.resetForTesting()
        defer { AgentWatchLiveActivityIntentRouter.resetForTesting() }

        await AgentWatchLiveActivityIntentRouter.perform(.approve(approvalId: "approval-1"))

        let routed = expectation(description: "queued command routed")
        var received: [AgentWatchLiveActivityCommand] = []
        AgentWatchLiveActivityIntentRouter.install { command in
            received.append(command)
            routed.fulfill()
        }

        await fulfillment(of: [routed], timeout: 1.0)
        XCTAssertEqual(received, [.approve(approvalId: "approval-1")])
    }

    func test_liveActivityIntentRouterPreservesCommandsAddedWhileQueueDrains() async throws {
        guard #available(iOS 17.0, *) else { try skipLiveActivityIntentsUnavailable() }
        AgentWatchLiveActivityIntentRouter.resetForTesting()
        defer { AgentWatchLiveActivityIntentRouter.resetForTesting() }

        await AgentWatchLiveActivityIntentRouter.perform(.approve(approvalId: "approval-1"))

        let routed = expectation(description: "queued and reentrant commands routed")
        routed.expectedFulfillmentCount = 2
        var received: [AgentWatchLiveActivityCommand] = []
        AgentWatchLiveActivityIntentRouter.install { command in
            received.append(command)
            routed.fulfill()
            if command == .approve(approvalId: "approval-1") {
                await AgentWatchLiveActivityIntentRouter.perform(.halt)
            }
        }

        await fulfillment(of: [routed], timeout: 1.0)
        XCTAssertEqual(received, [.approve(approvalId: "approval-1"), .halt])
    }

    func test_liveActivityIntentAuthenticationPolicyRequiresUnlockForDecisionsOnly() throws {
        guard #available(iOS 17.0, *) else { try skipLiveActivityIntentsUnavailable() }

        XCTAssertEqual(
            AgentApproveIntent.authenticationPolicy,
            .requiresLocalDeviceAuthentication
        )
        XCTAssertEqual(
            AgentDenyIntent.authenticationPolicy,
            .requiresLocalDeviceAuthentication
        )
        XCTAssertEqual(
            AgentRejectIntent.authenticationPolicy,
            .requiresLocalDeviceAuthentication
        )
        XCTAssertEqual(
            AgentHaltIntent.authenticationPolicy,
            .alwaysAllowed
        )
        XCTAssertFalse(AgentApproveIntent.isDiscoverable)
        XCTAssertFalse(AgentDenyIntent.isDiscoverable)
        XCTAssertFalse(AgentHaltIntent.isDiscoverable)
    }

    func test_liveActivityIntentSupportedModesStayInBackgroundOnIOS26() throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("supportedModes requires iOS 26+") } // env-guard: iOS 26+

        XCTAssertEqual(AgentApproveIntent.supportedModes, .background)
        XCTAssertEqual(AgentDenyIntent.supportedModes, .background)
        XCTAssertEqual(AgentHaltIntent.supportedModes, .background)
        XCTAssertEqual(
            AgentWatchLiveActivityIntentSecurity.supportedModes,
            .background
        )
    }

    func test_liveActivityCommandRoutingUsesOverlayReceiverPaths() {
        XCTAssertEqual(
            AgentWatchLiveActivityCommandRouting.effect(
                for: .approve(approvalId: "approval-1"),
                hasReceiver: true,
                pendingApprovalId: "approval-1"
            ),
            .approve
        )
        XCTAssertEqual(
            AgentWatchLiveActivityCommandRouting.effect(
                for: .reject(approvalId: "approval-1"),
                hasReceiver: true,
                pendingApprovalId: "approval-1"
            ),
            .reject
        )
        XCTAssertEqual(
            AgentWatchLiveActivityCommandRouting.effect(
                for: .halt,
                hasReceiver: true,
                pendingApprovalId: nil
            ),
            .halt
        )
        XCTAssertEqual(
            AgentWatchLiveActivityCommandRouting.effect(
                for: .approve(approvalId: "approval-1"),
                hasReceiver: false,
                pendingApprovalId: "approval-1"
            ),
            .dropMissingReceiver
        )
        XCTAssertEqual(
            AgentWatchLiveActivityCommandRouting.effect(
                for: .reject(approvalId: "approval-1"),
                hasReceiver: true,
                pendingApprovalId: nil
            ),
            .waitingForApproval
        )
        XCTAssertEqual(
            AgentWatchLiveActivityCommandRouting.effect(
                for: .approve(approvalId: "approval-1"),
                hasReceiver: true,
                pendingApprovalId: "approval-2"
            ),
            .dropMismatchedApproval
        )
        XCTAssertEqual(
            AgentWatchLiveActivityCommandRouting.effect(
                for: .approve(approvalId: ""),
                hasReceiver: true,
                pendingApprovalId: "approval-1"
            ),
            .dropMissingApproval
        )
        XCTAssertEqual(
            AgentWatchLiveActivityCommandRouting.effect(
                for: .halt,
                hasReceiver: false,
                pendingApprovalId: nil
            ),
            .dropMissingReceiver
        )
        XCTAssertTrue(
            AgentWatchLiveActivityCommandRouting.retainsQueuedCommand(.dropMissingReceiver)
        )
        XCTAssertTrue(
            AgentWatchLiveActivityCommandRouting.retainsQueuedCommand(.waitingForApproval)
        )
        XCTAssertFalse(
            AgentWatchLiveActivityCommandRouting.retainsQueuedCommand(.dropMismatchedApproval)
        )
        XCTAssertFalse(
            AgentWatchLiveActivityCommandRouting.retainsQueuedCommand(.dropMissingApproval)
        )
        XCTAssertFalse(AgentWatchLiveActivityCommandRouting.retainsQueuedCommand(.approve))
        XCTAssertFalse(AgentWatchLiveActivityCommandRouting.retainsQueuedCommand(.reject))
        XCTAssertFalse(AgentWatchLiveActivityCommandRouting.retainsQueuedCommand(.halt))
    }

    private static func entitlementsPlist(apsEnvironment: String?) throws -> Data {
        var dict: [String: Any] = [
            "com.apple.security.application-groups": ["group.com.openburnbar.app"]
        ]
        if let apsEnvironment {
            dict["aps-environment"] = apsEnvironment
        }
        return try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
    }

    private static func mobileProvisionFixture(apsEnvironment: String?) throws -> Data {
        var entitlements: [String: Any] = [
            "application-identifier": "TEAM.com.openburnbar.app"
        ]
        if let apsEnvironment {
            entitlements["aps-environment"] = apsEnvironment
        }
        let profile: [String: Any] = [
            "Name": "fixture",
            "Entitlements": entitlements
        ]
        let plist = try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)
        var cms = Data("fake-cms-prefix".utf8)
        cms.append(plist)
        cms.append(Data("fake-cms-suffix".utf8))
        return cms
    }
}

@available(iOS 16.1, *)
@MainActor
private final class StubAgentWatchLiveActivityBackend: AgentWatchLiveActivityBackend {
    struct Error: Swift.Error {}

    struct Start: Equatable {
        var sessionId: String
        var startedAt: Date
        var initialState: AgentWatchLiveActivityAttributes.ContentState
        var pushType: AgentWatchLiveActivityPushType
    }

    var activeSessionId: String?
    var starts: [Start] = []
    var updates: [AgentWatchLiveActivityAttributes.ContentState] = []
    var endCount = 0
    var requestError: Swift.Error?
    var requestErrorForPushType: AgentWatchLiveActivityPushType?
    private var pushTokenHandler: (@MainActor (String) -> Void)?

    func setPushTokenHandler(_ handler: (@MainActor (String) -> Void)?) {
        pushTokenHandler = handler
    }

    func emitPushToken(_ hex: String) {
        pushTokenHandler?(hex)
    }

    func request(
        sessionId: String,
        startedAt: Date,
        initialState: AgentWatchLiveActivityAttributes.ContentState,
        pushType: AgentWatchLiveActivityPushType
    ) throws {
        starts.append(
            Start(
                sessionId: sessionId,
                startedAt: startedAt,
                initialState: initialState,
                pushType: pushType
            )
        )
        if let requestError { throw requestError }
        if requestErrorForPushType == pushType { throw Error() }
        activeSessionId = sessionId
    }

    func update(_ state: AgentWatchLiveActivityAttributes.ContentState) {
        guard activeSessionId != nil else { return }
        updates.append(state)
    }

    func end() {
        endCount += 1
        activeSessionId = nil
    }
}

@MainActor
private final class RecordingAgentWatchLiveActivityPushTokenSink: AgentWatchLiveActivityPushTokenSinking {
    struct Persist: Equatable {
        var sessionId: String
        var tokenHex: String
    }

    var persisted: [Persist] = []
    var onPersist: (() -> Void)?

    func persist(sessionId: String, tokenHex: String) async {
        persisted.append(Persist(sessionId: sessionId, tokenHex: tokenHex))
        onPersist?()
    }
}
#endif
