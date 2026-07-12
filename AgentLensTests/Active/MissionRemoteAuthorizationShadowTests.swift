import XCTest
import OpenBurnBarCore
@testable import OpenBurnBar

/// Split-brain Phase M3: unit coverage for the SHADOW-mode comparator that
/// pits the GUI's own mission-authorization decision against the daemon's
/// authoritative `daemon.mission.authorizeRemote` verdict.
///
/// These tests pin the exact divergence classification (agree / GUI-stricter /
/// daemon-stricter / daemon-unreachable-fail-safe) plus the GUI-decision
/// reducer and the request builder, so parity can be reasoned about from
/// telemetry BEFORE any enforcement migration.
final class MissionRemoteAuthorizationShadowTests: XCTestCase {

    private func daemon(
        _ verdict: BurnBarRemoteMissionAuthorizationVerdict,
        reason: BurnBarRemoteMissionDenialReason? = nil
    ) -> BurnBarRemoteMissionAuthorizeResponse {
        BurnBarRemoteMissionAuthorizeResponse(verdict: verdict, deniedReason: reason)
    }

    // MARK: - Comparator table

    func testComparatorAgreementAndDivergenceTable() {
        struct Case {
            let name: String
            let gui: GUIMissionAuthorizationDecision
            let daemon: BurnBarRemoteMissionAuthorizeResponse?
            let expected: MissionAuthorizationDivergenceKind
            let expectDivergent: Bool
        }

        let cases: [Case] = [
            // --- agree (both authorities reach the same verdict) ---
            .init(name: "allow == authorized", gui: .allow, daemon: daemon(.authorized), expected: .agree, expectDivergent: false),
            .init(name: "requiresApproval == requires_approval", gui: .requiresApproval, daemon: daemon(.requiresApproval), expected: .agree, expectDivergent: false),
            .init(name: "deny == denied", gui: .deny, daemon: daemon(.denied, reason: .untrustedDevice), expected: .agree, expectDivergent: false),

            // --- daemon stricter (daemon permits LESS than the GUI) ---
            .init(name: "GUI allow, daemon requiresApproval", gui: .allow, daemon: daemon(.requiresApproval), expected: .daemonStricter, expectDivergent: true),
            .init(name: "GUI allow, daemon denied", gui: .allow, daemon: daemon(.denied, reason: .fanOutCapExceeded), expected: .daemonStricter, expectDivergent: true),
            .init(name: "GUI requiresApproval, daemon denied", gui: .requiresApproval, daemon: daemon(.denied, reason: .unknownTrustState), expected: .daemonStricter, expectDivergent: true),

            // --- GUI stricter (GUI permits LESS than the daemon) ---
            .init(name: "GUI deny, daemon authorized", gui: .deny, daemon: daemon(.authorized), expected: .guiStricter, expectDivergent: true),
            .init(name: "GUI deny, daemon requiresApproval", gui: .deny, daemon: daemon(.requiresApproval), expected: .guiStricter, expectDivergent: true),
            .init(name: "GUI requiresApproval, daemon authorized", gui: .requiresApproval, daemon: daemon(.authorized), expected: .guiStricter, expectDivergent: true),

            // --- daemon unreachable (fail-safe, GUI decision governs) ---
            .init(name: "allow + unreachable", gui: .allow, daemon: nil, expected: .daemonUnreachable, expectDivergent: false),
            .init(name: "deny + unreachable", gui: .deny, daemon: nil, expected: .daemonUnreachable, expectDivergent: false),
            .init(name: "requiresApproval + unreachable", gui: .requiresApproval, daemon: nil, expected: .daemonUnreachable, expectDivergent: false)
        ]

        for testCase in cases {
            let signal = MissionRemoteAuthorizationShadow.compare(
                missionID: "mission-\(testCase.name)",
                gui: testCase.gui,
                daemon: testCase.daemon,
                promptSHA256: "abc123"
            )
            XCTAssertEqual(signal.kind, testCase.expected, "kind mismatch: \(testCase.name)")
            XCTAssertEqual(signal.isDivergent, testCase.expectDivergent, "divergence flag mismatch: \(testCase.name)")
            XCTAssertEqual(signal.guiDecision, testCase.gui, "gui preserved: \(testCase.name)")
            XCTAssertEqual(signal.promptSHA256, "abc123", "sha preserved: \(testCase.name)")
        }
    }

    func testUnreachablePreservesGUIDecisionAndDetail() {
        let signal = MissionRemoteAuthorizationShadow.compare(
            missionID: "m1",
            gui: .allow,
            daemon: nil,
            promptSHA256: "deadbeef",
            unreachableDetail: "socket closed"
        )
        XCTAssertEqual(signal.kind, .daemonUnreachable)
        XCTAssertNil(signal.daemonVerdict)
        XCTAssertNil(signal.daemonDeniedReason)
        XCTAssertFalse(signal.isDivergent, "unreachable must be fail-safe, never a divergence")
        XCTAssertEqual(signal.unreachableDetail, "socket closed")
    }

    func testUnreachableDefaultDetailWhenNoneProvided() {
        let signal = MissionRemoteAuthorizationShadow.compare(
            missionID: "m2", gui: .deny, daemon: nil, promptSHA256: "00"
        )
        XCTAssertEqual(signal.kind, .daemonUnreachable)
        XCTAssertEqual(signal.unreachableDetail, "daemon verdict unavailable")
    }

    func testDaemonDeniedReasonCarriedIntoSignal() {
        let signal = MissionRemoteAuthorizationShadow.compare(
            missionID: "m3",
            gui: .allow,
            daemon: daemon(.denied, reason: .approvalRejected),
            promptSHA256: "ff"
        )
        XCTAssertEqual(signal.kind, .daemonStricter)
        XCTAssertEqual(signal.daemonVerdict, .denied)
        XCTAssertEqual(signal.daemonDeniedReason, .approvalRejected)
    }

    // MARK: - GUI decision reducer

    func testReduceGUIDecisionRejectedApprovalIsDeny() {
        for status in ["rejected", "canceled", "cancelled", "REJECTED", " Cancelled "] {
            let decision = MissionRemoteAuthorizationShadow.reduceGUIDecision(
                approvalStatus: status,
                willPauseForApproval: false
            )
            XCTAssertEqual(decision, .deny, "status=\(status) must reduce to deny")
        }
    }

    func testReduceGUIDecisionPauseIsRequiresApproval() {
        let decision = MissionRemoteAuthorizationShadow.reduceGUIDecision(
            approvalStatus: "pending",
            willPauseForApproval: true
        )
        XCTAssertEqual(decision, .requiresApproval)
    }

    func testReduceGUIDecisionNoPauseIsAllow() {
        let decision = MissionRemoteAuthorizationShadow.reduceGUIDecision(
            approvalStatus: "approved",
            willPauseForApproval: false
        )
        XCTAssertEqual(decision, .allow)
    }

    func testReduceGUIDecisionMissingApprovalStatusNoPauseIsAllow() {
        let decision = MissionRemoteAuthorizationShadow.reduceGUIDecision(
            approvalStatus: "",
            willPauseForApproval: false
        )
        XCTAssertEqual(decision, .allow)
    }

    func testReduceGUIDecisionTerminalDenialIsDeny() {
        // When Mac CLI assistants are disabled, shouldPauseForApproval
        // returns true (the mission is already failed) but the shadow must
        // report `.deny`, not `.requiresApproval`, so the GUI-vs-daemon
        // divergence is visible in telemetry.
        let decision = MissionRemoteAuthorizationShadow.reduceGUIDecision(
            approvalStatus: "approved",
            willPauseForApproval: true,
            isTerminalDenial: true
        )
        XCTAssertEqual(decision, .deny)
    }

    func testReduceGUIDecisionTerminalDenialOverridesApprovalPause() {
        let decision = MissionRemoteAuthorizationShadow.reduceGUIDecision(
            approvalStatus: "",
            willPauseForApproval: true,
            isTerminalDenial: true
        )
        XCTAssertEqual(decision, .deny)
    }

    func testReduceGUIDecisionNoTerminalDenialFallsBackToApprovalLogic() {
        let decision = MissionRemoteAuthorizationShadow.reduceGUIDecision(
            approvalStatus: "pending",
            willPauseForApproval: true,
            isTerminalDenial: false
        )
        XCTAssertEqual(decision, .requiresApproval)
    }

    func testReduceGUIDecisionDefaultsTerminalDenialToFalse() {
        // Backward compat: isTerminalDenial defaults to false
        let decision = MissionRemoteAuthorizationShadow.reduceGUIDecision(
            approvalStatus: "pending",
            willPauseForApproval: true
        )
        XCTAssertEqual(decision, .requiresApproval)
    }

    // MARK: - Request builder

    func testMakeRequestCarriesSummaryAndHashNotFullPrompt() {
        let longPrompt = String(repeating: "secret-payload ", count: 40)
        let request = MissionRemoteAuthorizationShadow.makeRequest(
            ctx: .init(
                missionID: "req-1", prompt: longPrompt, runtime: "codex", modelID: "gpt-x",
                commandsAllowed: true, fileEditsAllowed: false,
                originDeviceID: "unknown", originPlatform: "ios",
                personaScopeJSON: nil, approvalMode: "manual_all", approvalStatus: "pending",
                approverDeviceID: nil, entitlementTier: "pro", workingDirectory: nil, fanOutCount: 3
            ),
            executorTrustState: "trusted"
        )

        XCTAssertEqual(request.missionID, "req-1")
        XCTAssertEqual(request.executorTrustState, "trusted")
        XCTAssertEqual(request.requestedRuntime, "codex")
        XCTAssertEqual(request.requestedModelID, "gpt-x")
        XCTAssertTrue(request.requestedGrant.commandsAllowed)
        XCTAssertFalse(request.requestedGrant.fileEditsAllowed)
        XCTAssertEqual(request.approvalMode, "manual_all")
        XCTAssertEqual(request.approvalStatus, "pending")
        XCTAssertEqual(request.entitlementTier, "pro")
        XCTAssertEqual(request.originPlatform, "ios")
        XCTAssertEqual(request.requestedFanOutCount, 3)

        // The full prompt must NOT ride the socket; only a bounded summary + hash.
        XCTAssertLessThanOrEqual(request.promptSummary.count, 161)
        XCTAssertFalse(request.promptSummary.contains("\n"))
        XCTAssertEqual(request.promptSHA256, MissionRemoteAuthorizationShadow.sha256Hex(longPrompt))
        XCTAssertEqual(request.promptSHA256.count, 64)
    }

    func testMakeRequestFailsClosedOnMissingCapabilityFieldsAndDefaults() {
        let request = MissionRemoteAuthorizationShadow.makeRequest(
            ctx: .init(
                missionID: "req-2", prompt: "hi", runtime: nil, modelID: nil,
                commandsAllowed: false, fileEditsAllowed: false,
                originDeviceID: "unknown", originPlatform: "unknown",
                personaScopeJSON: nil, approvalMode: nil, approvalStatus: "",
                approverDeviceID: nil, entitlementTier: "none", workingDirectory: nil, fanOutCount: 0
            ),
            executorTrustState: "untrusted"
        )
        // Absent capability keys are a non-grant.
        XCTAssertFalse(request.requestedGrant.commandsAllowed)
        XCTAssertFalse(request.requestedGrant.fileEditsAllowed)
        // Missing entitlement tier fails closed to the free tier.
        XCTAssertEqual(request.entitlementTier, "none")
        // Fan-out is clamped to a positive count.
        XCTAssertEqual(request.requestedFanOutCount, 1)
        XCTAssertNil(request.requestedRuntime)
        XCTAssertEqual(request.originPlatform, "unknown")
        XCTAssertEqual(request.originDeviceID, "unknown")
    }

    func testMakeRequestDecodesPersonaScopeWhenPresent() throws {
        let envelope = PersonaScopeEnvelope(
            agentURI: "agent://burnbar/claude",
            personaID: "tech-reviewer",
            permitShell: false,
            permitFileEdits: false
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let json = String(data: try encoder.encode(envelope), encoding: .utf8)!

        let request = MissionRemoteAuthorizationShadow.makeRequest(
            ctx: .init(
                missionID: "req-3", prompt: "p", runtime: nil, modelID: nil,
                commandsAllowed: false, fileEditsAllowed: false,
                originDeviceID: "unknown", originPlatform: "unknown",
                personaScopeJSON: json, approvalMode: nil, approvalStatus: "",
                approverDeviceID: nil, entitlementTier: "none", workingDirectory: nil, fanOutCount: 1
            ),
            executorTrustState: "trusted"
        )
        XCTAssertEqual(request.personaScope?.permitShell, false)
        XCTAssertEqual(request.personaScope?.permitFileEdits, false)
        XCTAssertEqual(request.personaScope?.personaID, "tech-reviewer")
    }

    func testMakeRequestLeavesPersonaScopeNilOnMalformedJSON() {
        let request = MissionRemoteAuthorizationShadow.makeRequest(
            ctx: .init(
                missionID: "req-4", prompt: "p", runtime: nil, modelID: nil,
                commandsAllowed: false, fileEditsAllowed: false,
                originDeviceID: "unknown", originPlatform: "unknown",
                personaScopeJSON: "{not valid json", approvalMode: nil, approvalStatus: "",
                approverDeviceID: nil, entitlementTier: "none", workingDirectory: nil, fanOutCount: 1
            ),
            executorTrustState: "trusted"
        )
        XCTAssertNil(request.personaScope)
    }

    func testMakeRequestCarriesTrustedFanOutCap() {
        let request = MissionRemoteAuthorizationShadow.makeRequest(
            ctx: .init(
                missionID: "req-5", prompt: "p", runtime: nil, modelID: nil,
                commandsAllowed: false, fileEditsAllowed: false,
                originDeviceID: "unknown", originPlatform: "unknown",
                personaScopeJSON: nil, approvalMode: nil, approvalStatus: "",
                approverDeviceID: nil, entitlementTier: "none", workingDirectory: nil,
                fanOutCount: 8, trustedFanOutCap: 8
            ),
            executorTrustState: "trusted"
        )
        XCTAssertEqual(request.trustedFanOutCap, 8)
        XCTAssertEqual(request.requestedFanOutCount, 8)
    }

    // MARK: - Enforce mode (split-brain M4)

    func testDefaultModeIsEnforce() {
        // The default `MissionRemoteAuthorizationShadow.mode` resolves from the
        // environment at first access; in the test environment (no override) it
        // must default to `.enforce` — the daemon is the sole authority.
        XCTAssertEqual(MissionRemoteAuthorizationShadow.mode, .enforce)
    }

    func testModeEnumCarriesEnforceCase() {
        // Guard the rollback vocabulary the call site branches on.
        XCTAssertEqual(MissionRemoteAuthorizationShadow.Mode(rawValue: "enforce"), .enforce)
        XCTAssertEqual(MissionRemoteAuthorizationShadow.Mode(rawValue: "shadow"), .shadow)
        XCTAssertEqual(MissionRemoteAuthorizationShadow.Mode(rawValue: "off"), .off)
    }

    func testAuthorizationOutcomeUnreachableFlag() {
        XCTAssertTrue(
            MissionRemoteAuthorizationShadow.AuthorizationOutcome
                .daemonUnreachable(detail: "x").isDaemonUnreachable
        )
        XCTAssertFalse(
            MissionRemoteAuthorizationShadow.AuthorizationOutcome.authorized.isDaemonUnreachable
        )
        XCTAssertFalse(
            MissionRemoteAuthorizationShadow.AuthorizationOutcome
                .denied(reason: .untrustedDevice, detail: nil).isDaemonUnreachable
        )
    }
}
