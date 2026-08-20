import XCTest
@testable import OpenBurnBar
import OpenBurnBarKernel

final class CLIAgentMissionClaimCallableTests: XCTestCase {
    func testCatalogCoversWindowsParityTokens() {
        let catalog = MissionRuntimeCatalog.loadFixture()
        XCTAssertTrue(catalog.contains("junie"))
        XCTAssertTrue(catalog.contains("prime-agent"))
        XCTAssertTrue(catalog.contains("fx"))
        XCTAssertTrue(catalog.contains("kimi"))
        XCTAssertTrue(catalog.contains("gemini"))
    }

    func testUnknownKindDecodesWithoutThrowing() throws {
        let data = Data(#"{"kind":"futureKind"}"#.utf8)
        let event = try JSONDecoder().decode(CLIAgentRelayChatEvent.self, from: data)
        XCTAssertEqual(event.kind, .unknown)
    }

    func testUnknownThenCompletedKeepsDecoding() throws {
        let unknown = try JSONDecoder().decode(CLIAgentRelayChatEvent.self, from: Data(#"{"kind":"futureKind"}"#.utf8))
        let completed = try JSONDecoder().decode(CLIAgentRelayChatEvent.self, from: Data(#"{"kind":"completed"}"#.utf8))
        XCTAssertEqual(unknown.kind, .unknown)
        XCTAssertEqual(completed.kind, .completed)
    }

    func testWinnerClaimEvaluatesOnceLoserDoesNot() async throws {
        let functions = FakeClaimCliAgentMission()
        var evaluate = 0
        var failStatus = 0
        try await CLIAgentMissionClaimThenEvaluate.run(
            decision: .claim,
            claim: { try functions.claim(deviceId: "mac-winner") },
            evaluate: { evaluate += 1 },
            fail: { failStatus += 1 }
        )
        do {
            try await CLIAgentMissionClaimThenEvaluate.run(
                decision: .claim,
                claim: { try functions.claim(deviceId: "mac-loser") },
                evaluate: { evaluate += 1 },
                fail: { failStatus += 1 }
            )
        } catch CLIAgentMissionClaimThenEvaluate.Failure.failedPrecondition {
            XCTFail("failed-precondition must not evaluate or fail()")
        }
        XCTAssertEqual(functions.claimedBy, "mac-winner")
        XCTAssertEqual(evaluate, 1)
        XCTAssertEqual(failStatus, 0)
        XCTAssertTrue(MissionRuntimeCatalog.loadFixture().covers(ChatBackendID.allCases.map(\.rawValue)))
    }

    func testContinueAfterApproveSkipsSecondClaim() async throws {
        let functions = FakeClaimCliAgentMission()
        _ = try functions.claim(deviceId: "mac-1")
        var evaluate = 0
        var failStatus = 0
        let decision = CLIAgentMissionClaimDecision.make(
            thisDeviceId: "mac-1",
            claimedBy: "mac-1",
            status: "waiting_for_approval",
            hasLocalHandle: true,
            inFlight: false
        )
        XCTAssertEqual(decision, .continueWithoutClaim)
        try await CLIAgentMissionClaimThenEvaluate.run(
            decision: decision,
            claim: { try functions.claim(deviceId: "mac-1") },
            evaluate: { evaluate += 1 },
            fail: { failStatus += 1 }
        )
        XCTAssertEqual(functions.claimCount, 1)
        XCTAssertEqual(evaluate, 1)
        XCTAssertEqual(failStatus, 0)
    }

    func testInteractiveUnknownModeUsesLauncherDouble() async throws {
        let launcher = RecordingInteractiveLauncher()
        let backend = CLIAgentMissionBackend(rawValue: "codex", displayName: "Codex")
        let unknown = await CLIAgentDirectCLILaunchGate.run(
            presentationRaw: "not-a-mode",
            backend: backend,
            workingDirectoryURL: nil,
            launcher: launcher
        )
        XCTAssertEqual(unknown?.status, "failed")
        XCTAssertEqual(launcher.calls, 0)
        let interactive = await CLIAgentDirectCLILaunchGate.run(
            presentationRaw: "mac_interactive_cli",
            backend: backend,
            workingDirectoryURL: nil,
            launcher: launcher
        )
        XCTAssertEqual(interactive?.status, "running")
        XCTAssertEqual(launcher.calls, 1)
        XCTAssertEqual(CLIAgentDirectCLILaunchGate.decide(presentationRaw: "native_chat"), .proceed)
    }

    func testShadowContextCarriesApprovedByDeviceId() {
        let data: [String: Any] = [
            "requestedRuntime": "codex",
            "commandsAllowed": false,
            "fileEditsAllowed": false,
            "approvedByDeviceId": "iphone-trusted-1"
        ]
        let ctx = MissionRemoteAuthorizationShadow.ShadowContext.fromMissionData(
            data,
            missionID: "m1",
            prompt: "hi",
            fanOutCount: 1
        )
        XCTAssertEqual(ctx.approverDeviceID, "iphone-trusted-1")
    }

    func testApprovedWithoutApproverFailsClosed() {
        let data: [String: Any] = [
            "requestedRuntime": "hermes",
            "approvalStatus": "approved"
        ]
        let ctx = MissionRemoteAuthorizationShadow.ShadowContext.fromMissionData(
            data,
            missionID: "m1",
            prompt: "hi",
            fanOutCount: 1
        )
        XCTAssertEqual(ctx.approvalStatus.lowercased(), "approved")
        XCTAssertTrue(ctx.approverDeviceID?.isEmpty ?? true)
        XCTAssertEqual(
            MissionRemoteAuthorizationShadow.reduceGUIDecision(
                approvalStatus: ctx.approvalStatus,
                willPauseForApproval: false,
                approverDeviceID: ctx.approverDeviceID
            ),
            .deny
        )
    }

    func testTransportUnknownThenCompleted() throws {
        var events: [CLIAgentRelayChatEvent] = []
        try CLIAgentRelayChatEvent.consumeStream(
            rawEvents: [#"{"kind":"futureKind"}"#, #"{"kind":"completed"}"#]
        ) { events.append($0) }
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].kind, .unknown)
        XCTAssertEqual(events[1].kind, .completed)
    }

    func testTwoParksUseDistinctApprovalIds() {
        let first = CLIAgentApprovalRequestID.acpPark()
        let second = CLIAgentApprovalRequestID.acpPark()
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(first.hasPrefix("acp-"))
        XCTAssertTrue(second.hasPrefix("acp-"))
        XCTAssertNotEqual(CLIAgentApprovalRequestID.preDispatch(), first)
    }
}

final class FakeClaimCliAgentMission {
    var status = "pending"
    var claimedBy: String?
    var claimCount = 0

    func claim(deviceId: String) throws -> String {
        claimCount += 1
        // Mirrors claimCliAgentMission: only pending is claimable.
        guard status == "pending", claimedBy == nil else {
            throw CLIAgentMissionClaimThenEvaluate.Failure.failedPrecondition
        }
        claimedBy = deviceId
        status = "accepted"
        return "nonce-winner"
    }
}

final class RecordingInteractiveLauncher: InteractiveTerminalLaunching, @unchecked Sendable {
    var calls = 0
    func launchInteractive(runtimeId: String, workingDirectory: URL?) async throws {
        calls += 1
    }
}
