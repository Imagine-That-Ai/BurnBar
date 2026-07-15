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

    private func context(
        missionID: String = "m1",
        prompt: String = "inspect the project",
        approvalStatus: String = "pending"
    ) -> MissionRemoteAuthorizationShadow.ShadowContext {
        MissionRemoteAuthorizationShadow.ShadowContext(
            missionID: missionID, prompt: prompt, runtime: "codex", modelID: "gpt-x",
            commandsAllowed: true, fileEditsAllowed: false,
            originDeviceID: "device-1", originPlatform: "macos",
            personaScopeJSON: nil, approvalMode: "manual_all", approvalStatus: approvalStatus,
            approverDeviceID: nil, entitlementTier: "pro", workingDirectory: nil, fanOutCount: 1
        )
    }

    @MainActor
    private func restoreMode(after body: () async -> Void) async {
        let previousMode = MissionRemoteAuthorizationShadow.mode
        defer { MissionRemoteAuthorizationShadow.mode = previousMode }
        await body()
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

    // MARK: - Listener field mapping and observation plumbing

    func testListenerShadowContextMapsFieldsAndFailsClosedForMissingValues() {
        let populated = CLIAgentMissionRequestListener.makeShadowContext(
            fields: .init(
                requestedRuntime: "ollama", requestedModelID: "  llama3  ",
                commandsAllowed: true, fileEditsAllowed: true,
                originDeviceID: "device-9", createdBy: nil,
                originPlatform: "ios", source: nil,
                personaScopeJSON: "{\"personaID\":\"reviewer\"}",
                approvalMode: "manual_all", approvalStatus: "pending",
                approverDeviceID: "approver-1", entitlementTier: "pro",
                workingDirectory: "/tmp/project"
            ),
            missionID: "mapped",
            prompt: "prompt",
            fanOutCount: 4
        )
        XCTAssertEqual(populated.missionID, "mapped")
        XCTAssertEqual(populated.runtime, "ollama")
        XCTAssertEqual(populated.modelID, "llama3")
        XCTAssertTrue(populated.commandsAllowed)
        XCTAssertTrue(populated.fileEditsAllowed)
        XCTAssertEqual(populated.originDeviceID, "device-9")
        XCTAssertEqual(populated.originPlatform, "ios")
        XCTAssertEqual(populated.approvalMode, "manual_all")
        XCTAssertEqual(populated.approverDeviceID, "approver-1")
        XCTAssertEqual(populated.entitlementTier, "pro")
        XCTAssertEqual(populated.workingDirectory, "/tmp/project")
        XCTAssertEqual(populated.fanOutCount, 4)

        let missing = CLIAgentMissionRequestListener.makeShadowContext(
            fields: .init(
                requestedRuntime: nil, requestedModelID: nil,
                commandsAllowed: nil, fileEditsAllowed: nil,
                originDeviceID: nil, createdBy: "creator-1",
                originPlatform: nil, source: "mobile",
                personaScopeJSON: nil, approvalMode: nil,
                approvalStatus: "", approverDeviceID: nil,
                entitlementTier: "  ", workingDirectory: nil
            ),
            missionID: "fallbacks",
            prompt: "",
            fanOutCount: 0
        )
        XCTAssertEqual(missing.runtime, "auto")
        XCTAssertNil(missing.modelID)
        XCTAssertFalse(missing.commandsAllowed)
        XCTAssertFalse(missing.fileEditsAllowed)
        XCTAssertEqual(missing.originDeviceID, "creator-1")
        XCTAssertEqual(missing.originPlatform, "mobile")
        XCTAssertNil(missing.personaScopeJSON)
        XCTAssertNil(missing.approvalMode)
        XCTAssertEqual(missing.approvalStatus, "")
        XCTAssertNil(missing.approverDeviceID)
        XCTAssertEqual(missing.entitlementTier, "none")
        XCTAssertNil(missing.workingDirectory)
    }

    func testEmitHandlesEverySignalKind() {
        MissionRemoteAuthorizationShadow.emit(MissionRemoteAuthorizationShadow.compare(
            missionID: "agree", gui: .allow, daemon: daemon(.authorized), promptSHA256: "a"
        ))
        MissionRemoteAuthorizationShadow.emit(MissionRemoteAuthorizationShadow.compare(
            missionID: "unreachable", gui: .deny, daemon: nil, promptSHA256: "b", unreachableDetail: "offline"
        ))
        MissionRemoteAuthorizationShadow.emit(MissionRemoteAuthorizationShadow.compare(
            missionID: "daemon-stricter", gui: .allow, daemon: daemon(.denied), promptSHA256: "c"
        ))
        MissionRemoteAuthorizationShadow.emit(MissionRemoteAuthorizationShadow.compare(
            missionID: "gui-stricter", gui: .deny, daemon: daemon(.authorized), promptSHA256: "d"
        ))
    }

    @MainActor
    func testObserveReturnsWithoutDaemonWhenShadowModeIsOff() async {
        await restoreMode { @MainActor in
            MissionRemoteAuthorizationShadow.mode = .off
            await MissionRemoteAuthorizationShadow.observe(
                ctx: context(), guiDecision: .allow, executorTrustState: "trusted"
            )
        }
    }

    @MainActor
    func testObserveClassifiesUnhealthyDaemonAsUnreachable() async {
        await restoreMode { @MainActor in
            MissionRemoteAuthorizationShadow.mode = .shadow
            let manager = OpenBurnBarDaemonManager()
            manager.status = .unhealthy("test daemon unavailable")
            await MissionRemoteAuthorizationShadow.observe(
                ctx: context(), guiDecision: .requiresApproval, executorTrustState: "trusted", manager: manager
            )
        }
    }

    @MainActor
    func testObserveClassifiesSocketFailureAsUnreachable() async {
        await restoreMode { @MainActor in
            MissionRemoteAuthorizationShadow.mode = .shadow
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("MissionRemoteAuthorizationShadowTests-\(UUID().uuidString)", isDirectory: true)
            let paths = OpenBurnBarDaemonRuntimePaths(
                supportDirectory: root,
                daemonDirectory: root.appendingPathComponent("daemon", isDirectory: true),
                frameworksDirectory: root.appendingPathComponent("Frameworks", isDirectory: true),
                installedBinaryURL: root.appendingPathComponent("daemon/OpenBurnBarDaemon"),
                socketURL: root.appendingPathComponent("missing.sock"),
                logURL: root.appendingPathComponent("daemon.log"),
                launchAgentPlistURL: root.appendingPathComponent("launch-agent.plist")
            )
            let manager = OpenBurnBarDaemonManager(paths: paths, dependencies: .live())
            let health = BurnBarHealthResponse(
                ok: true,
                daemonVersion: "test",
                protocolVersion: BurnBarProtocolVersion.current,
                socketPath: paths.socketURL.path
            )
            manager.status = .healthy(OpenBurnBarDaemonHealthSnapshot(response: health))
            await MissionRemoteAuthorizationShadow.observe(
                ctx: context(), guiDecision: .allow, executorTrustState: "trusted", manager: manager
            )
        }
    }

    @MainActor
    func testFireAndForgetHelpersScheduleShadowObservations() async {
        await restoreMode { @MainActor in
            MissionRemoteAuthorizationShadow.mode = .off
            let ctx = context(approvalStatus: "pending")
            MissionRemoteAuthorizationShadow.observeDeny(ctx: ctx, executorTrustState: "untrusted")
            MissionRemoteAuthorizationShadow.observeTrustedDecision(
                ctx: ctx,
                isTerminalDenial: false,
                personaScopeMalformed: false,
                willPauseForApproval: true
            )
            MissionRemoteAuthorizationShadow.observeTrustedDecision(
                ctx: ctx,
                isTerminalDenial: true,
                personaScopeMalformed: false,
                willPauseForApproval: true
            )
            MissionRemoteAuthorizationShadow.observeTrustedDecision(
                ctx: ctx,
                isTerminalDenial: false,
                personaScopeMalformed: true,
                willPauseForApproval: false
            )
            for _ in 0..<3 {
                await Task.yield()
            }
        }
    }

    // MARK: - P-ARCH-2: Enforce mode regression tests

    /// Verify the `.enforce` case exists on the Mode enum.
    @MainActor
    func testModeHasEnforceCase() async {
        await restoreMode { @MainActor in
            MissionRemoteAuthorizationShadow.mode = .enforce
            XCTAssertEqual(MissionRemoteAuthorizationShadow.mode, .enforce,
                           "Mode.enforce must exist and be settable")
        }
    }

    // MARK: - Pure enforce(signal:) — fail-closed invariant

    func testEnforceAgreeReturnsAllow() {
        let signal = MissionRemoteAuthorizationShadow.compare(
            missionID: "enforce-agree", gui: .allow, daemon: daemon(.authorized), promptSHA256: "a"
        )
        XCTAssertEqual(signal.kind, .agree)
        XCTAssertEqual(
            MissionRemoteAuthorizationShadow.enforce(signal: signal),
            .allow,
            "agree must allow in enforce mode"
        )
    }

    func testEnforceDaemonStricterReturnsDeny() {
        let signal = MissionRemoteAuthorizationShadow.compare(
            missionID: "enforce-daemon-stricter", gui: .allow, daemon: daemon(.denied, reason: .untrustedDevice), promptSHA256: "b"
        )
        XCTAssertEqual(signal.kind, .daemonStricter)
        XCTAssertEqual(
            MissionRemoteAuthorizationShadow.enforce(signal: signal),
            .deny,
            "daemon stricter must deny in enforce mode"
        )
    }

    func testEnforceGuiStricterReturnsAllow() {
        let signal = MissionRemoteAuthorizationShadow.compare(
            missionID: "enforce-gui-stricter", gui: .deny, daemon: daemon(.authorized), promptSHA256: "c"
        )
        XCTAssertEqual(signal.kind, .guiStricter)
        XCTAssertEqual(
            MissionRemoteAuthorizationShadow.enforce(signal: signal),
            .allow,
            "gui stricter must allow in enforce mode (daemon is more permissive)"
        )
    }

    func testEnforceDaemonUnreachableReturnsDeny() {
        // THE CRITICAL FAIL-CLOSED TEST: an unreachable daemon must NOT fall
        // back to GUI-allow in enforce mode.
        let signal = MissionRemoteAuthorizationShadow.compare(
            missionID: "enforce-unreachable", gui: .allow, daemon: nil, promptSHA256: "d",
            unreachableDetail: "socket closed"
        )
        XCTAssertEqual(signal.kind, .daemonUnreachable)
        XCTAssertEqual(signal.guiDecision, .allow)
        XCTAssertEqual(
            MissionRemoteAuthorizationShadow.enforce(signal: signal),
            .deny,
            "daemon unreachable must fail-closed to deny, even when GUI would allow"
        )
    }

    func testEnforceDaemonUnreachableReturnsDenyEvenWhenGUIDenies() {
        // Fail-closed is consistent regardless of the GUI decision.
        let signal = MissionRemoteAuthorizationShadow.compare(
            missionID: "enforce-unreachable-deny", gui: .deny, daemon: nil, promptSHA256: "e",
            unreachableDetail: "socket closed"
        )
        XCTAssertEqual(signal.kind, .daemonUnreachable)
        XCTAssertEqual(signal.guiDecision, .deny)
        XCTAssertEqual(
            MissionRemoteAuthorizationShadow.enforce(signal: signal),
            .deny,
            "daemon unreachable must deny in enforce mode even when GUI also denies"
        )
    }

    // MARK: - Enforce orchestration (async, @MainActor)

    @MainActor
    func testEnforceModeOffReturnsAllow() async {
        await restoreMode { @MainActor in
            MissionRemoteAuthorizationShadow.mode = .off
            let verdict = await MissionRemoteAuthorizationShadow.enforce(
                ctx: context(), guiDecision: .allow, executorTrustState: "trusted"
            )
            XCTAssertEqual(verdict, .allow, "off mode must always return allow")
        }
    }

    @MainActor
    func testEnforceModeShadowReturnsAllowAndDoesNotGovern() async {
        await restoreMode { @MainActor in
            MissionRemoteAuthorizationShadow.mode = .shadow
            let verdict = await MissionRemoteAuthorizationShadow.enforce(
                ctx: context(), guiDecision: .deny, executorTrustState: "untrusted"
            )
            XCTAssertEqual(verdict, .allow,
                           "shadow mode must return allow and never govern execution")
        }
    }

    @MainActor
    func testEnforceModeFailClosedOnUnhealthyDaemon() async {
        await restoreMode { @MainActor in
            MissionRemoteAuthorizationShadow.mode = .enforce
            let manager = OpenBurnBarDaemonManager()
            manager.status = .unhealthy("test daemon unavailable")
            let verdict = await MissionRemoteAuthorizationShadow.enforce(
                ctx: context(), guiDecision: .allow, executorTrustState: "trusted", manager: manager
            )
            XCTAssertEqual(verdict, .deny, "enforce mode must fail-closed to deny on unhealthy daemon")
        }
    }

    @MainActor
    func testEnforceModeFailClosedOnSocketFailure() async {
        await restoreMode { @MainActor in
            MissionRemoteAuthorizationShadow.mode = .enforce
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("MissionRemoteAuthorizationShadowTests-\(UUID().uuidString)", isDirectory: true)
            let paths = OpenBurnBarDaemonRuntimePaths(
                supportDirectory: root,
                daemonDirectory: root.appendingPathComponent("daemon", isDirectory: true),
                frameworksDirectory: root.appendingPathComponent("Frameworks", isDirectory: true),
                installedBinaryURL: root.appendingPathComponent("daemon/OpenBurnBarDaemon"),
                socketURL: root.appendingPathComponent("missing.sock"),
                logURL: root.appendingPathComponent("daemon.log"),
                launchAgentPlistURL: root.appendingPathComponent("launch-agent.plist")
            )
            let manager = OpenBurnBarDaemonManager(paths: paths, dependencies: .live())
            let health = BurnBarHealthResponse(
                ok: true,
                daemonVersion: "test",
                protocolVersion: BurnBarProtocolVersion.current,
                socketPath: paths.socketURL.path
            )
            manager.status = .healthy(OpenBurnBarDaemonHealthSnapshot(response: health))
            let verdict = await MissionRemoteAuthorizationShadow.enforce(
                ctx: context(), guiDecision: .allow, executorTrustState: "trusted", manager: manager
            )
            XCTAssertEqual(verdict, .deny, "enforce mode must fail-closed to deny on socket failure")
        }
    }

    // MARK: - Shadow mode preserved

    func testShadowModeDefaultIsShadow() {
        // Verify Mode has exactly three cases: .off, .shadow, .enforce.
        // The existence of these three values at compile time is the assertion;
        // the equality checks confirm they are distinct.
        let off: MissionRemoteAuthorizationShadow.Mode = .off
        let shadow: MissionRemoteAuthorizationShadow.Mode = .shadow
        let enforce: MissionRemoteAuthorizationShadow.Mode = .enforce
        XCTAssertNotEqual(off, shadow)
        XCTAssertNotEqual(shadow, enforce)
        XCTAssertNotEqual(off, enforce)
        // Exhaustive switch proves the enum has exactly three cases.
        let all: [MissionRemoteAuthorizationShadow.Mode] = [off, shadow, enforce]
        for mode in all {
            switch mode {
            case .off, .shadow, .enforce:
                break
            }
        }
        XCTAssertEqual(Set(all.map { $0.rawValue }), Set(["off", "shadow", "enforce"]))
    }
}

