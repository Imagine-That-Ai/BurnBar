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

    func testInFlightHandleSkipsClaimAndEvaluate() async throws {
        let functions = FakeClaimCliAgentMission()
        var evaluate = 0
        let decision = CLIAgentMissionClaimDecision.make(
            thisDeviceId: "mac-1",
            claimedBy: "mac-1",
            status: "waiting_for_approval",
            hasLocalHandle: true,
            inFlight: true
        )
        XCTAssertEqual(decision, .skip)
        try await CLIAgentMissionClaimThenEvaluate.run(
            decision: decision,
            claim: { try functions.claim(deviceId: "mac-1") },
            evaluate: { evaluate += 1 },
            fail: { }
        )
        XCTAssertEqual(functions.claimCount, 0)
        XCTAssertEqual(evaluate, 0)
    }

    func testApprovedWithoutApproverFailsClosed() {
        let data: [String: Any] = [
            "requestedRuntime": "hermes",
            "approvalStatus": "approved",
        ]
        let ctx = MissionRemoteAuthorizationShadow.ShadowContext.fromMissionData(
            data,
            missionID: "m1",
            prompt: "hi",
            fanOutCount: 1
        )
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
}

final class FakeClaimCliAgentMission {
    var status = "pending"
    var claimedBy: String?
    var claimCount = 0

    func claim(deviceId: String) throws -> String {
        claimCount += 1
        guard status == "pending", claimedBy == nil else {
            throw CLIAgentMissionClaimThenEvaluate.Failure.failedPrecondition
        }
        claimedBy = deviceId
        status = "accepted"
        return "nonce-winner"
    }
}
