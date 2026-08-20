import XCTest
import OpenBurnBarEngine
@testable import OpenBurnBarDaemon

/// M2 (split-brain remediation Phase 2): table-driven coverage of
/// `BurnBarRemoteMissionAuthorizationPolicy` — every verdict branch, every
/// fail-closed default, and capability-ceiling attenuation. These verdicts
/// become the single mission authority once M3/M4 route the GUI listener
/// through `daemon.mission.authorizeRemote`; a row change here is a mission-
/// security policy change, not a test update.
final class BurnBarRemoteMissionAuthorizationTests: XCTestCase {

    // MARK: - Fixture

    private func makeRequest(
        executorTrustState: String = "trusted",
        commandsAllowed: Bool = false,
        fileEditsAllowed: Bool = false,
        additionalCapabilities: [String] = [],
        personaScope: PersonaScopeEnvelope? = nil,
        requestedRuntime: String? = "hermes",
        requestedModelID: String? = nil,
        approvalMode: String? = "existing_policy",
        approvalStatus: String? = nil,
        approverDeviceID: String? = "iphone-trusted-1",
        entitlementTier: String = "ultra",
        requestedFanOutCount: Int = 1,
        trustedFanOutCap: Int? = nil
    ) -> BurnBarRemoteMissionAuthorizeRequest {
        BurnBarRemoteMissionAuthorizeRequest(
            missionID: "mission-authz-1",
            originDeviceID: "phone-device-1",
            originPlatform: "ios",
            executorTrustState: executorTrustState,
            promptSummary: "Review the flaky test",
            promptSHA256: String(repeating: "ab", count: 32),
            requestedRuntime: requestedRuntime,
            requestedModelID: requestedModelID,
            requestedGrant: BurnBarRemoteMissionCapabilityGrantRequest(
                commandsAllowed: commandsAllowed,
                fileEditsAllowed: fileEditsAllowed,
                additionalCapabilities: additionalCapabilities
            ),
            personaScope: personaScope,
            approvalMode: approvalMode,
            approvalStatus: approvalStatus,
            approverDeviceID: approverDeviceID,
            entitlementTier: entitlementTier,
            requestedFanOutCount: requestedFanOutCount,
            trustedFanOutCap: trustedFanOutCap,
            workingDirectory: "/tmp/mission-workspace"
        )
    }

    // MARK: - (a) Trust: daemon's own fail-closed policy

    func testTrustVerdictTable() {
        struct Row {
            let state: String
            let expectedVerdict: BurnBarRemoteMissionAuthorizationVerdict
            let expectedReason: BurnBarRemoteMissionDenialReason?
        }
        let rows: [Row] = [
            Row(state: "trusted", expectedVerdict: .authorized, expectedReason: nil),
            Row(state: " Trusted \n", expectedVerdict: .authorized, expectedReason: nil),
            // Known not-trusted states → typed untrusted denial.
            Row(state: "pending", expectedVerdict: .denied, expectedReason: .untrustedDevice),
            Row(state: "untrusted", expectedVerdict: .denied, expectedReason: .untrustedDevice),
            Row(state: "revoked", expectedVerdict: .denied, expectedReason: .untrustedDevice),
            Row(state: "rejected", expectedVerdict: .denied, expectedReason: .untrustedDevice),
            Row(state: "denied", expectedVerdict: .denied, expectedReason: .untrustedDevice),
            // Unrecognized states fail CLOSED with the unknown-state reason.
            Row(state: "", expectedVerdict: .denied, expectedReason: .unknownTrustState),
            Row(state: "   ", expectedVerdict: .denied, expectedReason: .unknownTrustState),
            Row(state: "trusted-ish", expectedVerdict: .denied, expectedReason: .unknownTrustState),
            Row(state: "TRUSTED_DEVICE", expectedVerdict: .denied, expectedReason: .unknownTrustState),
            Row(state: "banana", expectedVerdict: .denied, expectedReason: .unknownTrustState)
        ]
        for row in rows {
            let response = BurnBarRemoteMissionAuthorizationPolicy.evaluate(
                makeRequest(executorTrustState: row.state)
            )
            XCTAssertEqual(response.verdict, row.expectedVerdict, "trust state '\(row.state)'")
            XCTAssertEqual(response.deniedReason, row.expectedReason, "trust state '\(row.state)'")
            if response.verdict == .denied {
                XCTAssertNil(response.grantCeiling, "denied verdicts must not carry a grant ceiling")
                XCTAssertNil(response.backendDecision, "denied verdicts must not carry a backend decision")
            }
        }
    }

    func testTrustDenialDominatesApprovedStatus() {
        // Even a fully approved mission is refused from an untrusted executor.
        let response = BurnBarRemoteMissionAuthorizationPolicy.evaluate(
            makeRequest(executorTrustState: "pending", approvalStatus: "approved")
        )
        XCTAssertEqual(response.verdict, .denied)
        XCTAssertEqual(response.deniedReason, .untrustedDevice)
    }

    // MARK: - (b) Approval: daemon policy + backend consent, fail-closed

    func testApprovalVerdictTable() {
        struct Row {
            let mode: String?
            let status: String?
            let commands: Bool
            let fileEdits: Bool
            let expected: BurnBarRemoteMissionAuthorizationVerdict
            let expectedReason: BurnBarRemoteMissionDenialReason?
            let note: String
        }
        let rows: [Row] = [
            // Terminal approval decisions deny outright.
            Row(mode: "existing_policy", status: "rejected", commands: false, fileEdits: false,
                expected: .denied, expectedReason: .approvalRejected, note: "rejected handshake"),
            Row(mode: "existing_policy", status: "canceled", commands: false, fileEdits: false,
                expected: .denied, expectedReason: .approvalRejected, note: "canceled handshake"),
            Row(mode: "manual_all", status: " Cancelled ", commands: true, fileEdits: true,
                expected: .denied, expectedReason: .approvalRejected, note: "cancelled handshake dominates policy"),
            // Explicit approval satisfies every mode, including manual_all + risky.
            Row(mode: "manual_all", status: "approved", commands: true, fileEdits: true,
                expected: .authorized, expectedReason: nil, note: "approved satisfies manual_all risky"),
            Row(mode: "definitely_unknown", status: "APPROVED", commands: false, fileEdits: false,
                expected: .authorized, expectedReason: nil, note: "approved satisfies even unknown modes"),
            // No decision yet: daemon-local policy decides.
            Row(mode: "existing_policy", status: nil, commands: false, fileEdits: false,
                expected: .authorized, expectedReason: nil, note: "read-only existing_policy runs"),
            Row(mode: nil, status: nil, commands: false, fileEdits: false,
                expected: .authorized, expectedReason: nil, note: "absent mode read-only runs"),
            Row(mode: "manual_all", status: nil, commands: false, fileEdits: false,
                expected: .requiresApproval, expectedReason: nil, note: "manual_all pauses read-only"),
            Row(mode: "existing_policy", status: nil, commands: true, fileEdits: false,
                expected: .requiresApproval, expectedReason: nil, note: "commands pause"),
            Row(mode: nil, status: nil, commands: false, fileEdits: true,
                expected: .requiresApproval, expectedReason: nil, note: "file edits pause"),
            // Unknown approvalMode fails closed inside the daemon policy.
            Row(mode: "auto_yolo", status: nil, commands: false, fileEdits: false,
                expected: .requiresApproval, expectedReason: nil, note: "unknown mode fails closed"),
            // Unknown approvalStatus strings are treated as no-decision-yet.
            Row(mode: "existing_policy", status: "mystery_status", commands: false, fileEdits: false,
                expected: .authorized, expectedReason: nil, note: "unknown status + safe policy runs"),
            Row(mode: "manual_all", status: "mystery_status", commands: false, fileEdits: false,
                expected: .requiresApproval, expectedReason: nil, note: "unknown status + manual_all pauses")
        ]
        for row in rows {
            let approved = (row.status ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "approved"
            let response = BurnBarRemoteMissionAuthorizationPolicy.evaluate(
                makeRequest(
                    commandsAllowed: row.commands,
                    fileEditsAllowed: row.fileEdits,
                    approvalMode: row.mode,
                    approvalStatus: row.status,
                    approverDeviceID: approved ? "iphone-trusted-1" : nil
                )
            )
            XCTAssertEqual(response.verdict, row.expected, row.note)
            XCTAssertEqual(response.deniedReason, row.expectedReason, row.note)
            if response.verdict == .requiresApproval {
                XCTAssertNotNil(
                    response.grantCeiling,
                    "\(row.note): requiresApproval must carry the would-be ceiling"
                )
                XCTAssertNil(
                    response.backendDecision,
                    "\(row.note): only authorized verdicts carry a backend decision"
                )
            }
        }
    }

    func testApprovedWithoutApproverFailsClosed() {
        let response = BurnBarRemoteMissionAuthorizationPolicy.evaluate(
            makeRequest(
                approvalMode: "existing_policy",
                approvalStatus: "approved",
                approverDeviceID: nil
            )
        )
        XCTAssertEqual(response.verdict, .denied)
        XCTAssertEqual(response.deniedReason, .approvalRejected)
    }

    func testMacCLIAssistantBackendsRequireConsentBeforeAuthorization() {
        struct Row {
            let runtime: String?
            let expected: BurnBarRemoteMissionAuthorizationVerdict
            let note: String
        }
        let rows: [Row] = [
            Row(runtime: "hermes", expected: .authorized, note: "Hermes remains local-safe"),
            Row(runtime: "codex", expected: .requiresApproval, note: "Codex requires backend consent"),
            Row(runtime: " claude-code ", expected: .requiresApproval, note: "Claude Code alias requires consent"),
            Row(runtime: "opencode", expected: .requiresApproval, note: "OpenCode requires consent"),
            Row(runtime: "auto", expected: .requiresApproval, note: "auto may resolve to a CLI assistant"),
            Row(runtime: nil, expected: .requiresApproval, note: "absent runtime defaults to auto"),
            Row(runtime: "future-agent", expected: .requiresApproval, note: "unknown runtime fails closed")
        ]
        for row in rows {
            let response = BurnBarRemoteMissionAuthorizationPolicy.evaluate(
                makeRequest(
                    requestedRuntime: row.runtime,
                    approvalMode: "existing_policy",
                    approvalStatus: nil
                )
            )
            XCTAssertEqual(response.verdict, row.expected, row.note)
            if response.verdict == .requiresApproval {
                XCTAssertNotNil(response.grantCeiling, row.note)
                XCTAssertNil(response.backendDecision, row.note)
            }
        }
    }

    // MARK: - (c) Capability ceiling: never wider, deny-by-default

    func testGrantCeilingNeverWiderThanRequestedAndDropsUnknownCapabilities() throws {
        struct Row {
            let commands: Bool
            let fileEdits: Bool
            let additional: [String]
        }
        let rows: [Row] = [
            Row(commands: false, fileEdits: false, additional: []),
            Row(commands: true, fileEdits: false, additional: []),
            Row(commands: false, fileEdits: true, additional: ["desktop_system_input"]),
            Row(commands: true, fileEdits: true, additional: ["shell_unrestricted", "hid", "future_capability"])
        ]
        for row in rows {
            let response = BurnBarRemoteMissionAuthorizationPolicy.evaluate(
                makeRequest(
                    commandsAllowed: row.commands,
                    fileEditsAllowed: row.fileEdits,
                    additionalCapabilities: row.additional,
                    approvalStatus: "approved"
                )
            )
            XCTAssertEqual(response.verdict, .authorized)
            let ceiling = try XCTUnwrap(response.grantCeiling)
            // Never wider than requested.
            XCTAssertEqual(ceiling.commandsAllowed, row.commands)
            XCTAssertEqual(ceiling.fileEditsAllowed, row.fileEdits)
            // Deny-by-default: no unrecognized identifier survives into the
            // ceiling — today the daemon recognizes none, so the lane is empty.
            XCTAssertEqual(
                ceiling.additionalCapabilities, [],
                "unrecognized capability identifiers must be denied, got \(ceiling.additionalCapabilities)"
            )
        }
    }

    func testPersonaScopeAttenuatesGrantCeiling() throws {
        let personaScope = PersonaScopeEnvelope(
            agentURI: "agent://burnbar/codex",
            personaID: "read-only-reviewer",
            permitShell: false,
            permitFileEdits: false,
            appliedAt: Date(timeIntervalSinceReferenceDate: 42)
        )
        let response = BurnBarRemoteMissionAuthorizationPolicy.evaluate(
            makeRequest(
                commandsAllowed: true,
                fileEditsAllowed: true,
                additionalCapabilities: ["shell_unrestricted"],
                personaScope: personaScope,
                requestedRuntime: "hermes",
                approvalStatus: "approved"
            )
        )
        XCTAssertEqual(response.verdict, .authorized)
        let ceiling = try XCTUnwrap(response.grantCeiling)
        XCTAssertFalse(ceiling.commandsAllowed)
        XCTAssertFalse(ceiling.fileEditsAllowed)
        XCTAssertEqual(ceiling.additionalCapabilities, [])
    }

    func testGrokBotInputCapabilityIsRecognized() throws {
        XCTAssertTrue(
            BurnBarRemoteMissionAuthorizationPolicy.recognizedAdditionalCapabilities.contains("input.grok_bot")
        )
        let response = BurnBarRemoteMissionAuthorizationPolicy.evaluate(
            makeRequest(
                additionalCapabilities: ["input.grok_bot"],
                approvalStatus: "approved"
            )
        )
        XCTAssertEqual(response.verdict, .authorized)
        XCTAssertEqual(response.grantCeiling?.additionalCapabilities, ["input.grok_bot"])
    }

    // MARK: - (d) Daemon-trusted fan-out cap, fail-closed

    func testFanOutVerdictTable() {
        struct Row {
            let tier: String
            let requested: Int
            let expected: BurnBarRemoteMissionAuthorizationVerdict
            let expectedReason: BurnBarRemoteMissionDenialReason?
        }
        let rows: [Row] = [
            // M2 has no daemon-owned entitlement resolver yet, so caller-
            // supplied tier text cannot widen beyond the trusted free cap.
            Row(tier: "none", requested: 1, expected: .authorized, expectedReason: nil),
            Row(tier: "none", requested: 2, expected: .denied, expectedReason: .fanOutCapExceeded),
            Row(tier: "cloud", requested: 1, expected: .authorized, expectedReason: nil),
            Row(tier: "cloud", requested: 2, expected: .denied, expectedReason: .fanOutCapExceeded),
            Row(tier: "pro", requested: 1, expected: .authorized, expectedReason: nil),
            Row(tier: "pro", requested: 2, expected: .denied, expectedReason: .fanOutCapExceeded),
            Row(tier: "ultra", requested: 1, expected: .authorized, expectedReason: nil),
            Row(tier: "ultra", requested: 2, expected: .denied, expectedReason: .fanOutCapExceeded),
            Row(tier: " ULTRA ", requested: 2, expected: .denied, expectedReason: .fanOutCapExceeded),
            Row(tier: "enterprise-platinum", requested: 2, expected: .denied, expectedReason: .fanOutCapExceeded),
            Row(tier: "", requested: 2, expected: .denied, expectedReason: .fanOutCapExceeded),
            Row(tier: "enterprise-platinum", requested: 1, expected: .authorized, expectedReason: nil),
            // Malformed counts are invalid requests.
            Row(tier: "ultra", requested: 0, expected: .denied, expectedReason: .invalidRequest),
            Row(tier: "ultra", requested: -3, expected: .denied, expectedReason: .invalidRequest)
        ]
        for row in rows {
            let response = BurnBarRemoteMissionAuthorizationPolicy.evaluate(
                makeRequest(
                    approvalStatus: "approved",
                    entitlementTier: row.tier,
                    requestedFanOutCount: row.requested
                )
            )
            XCTAssertEqual(
                response.verdict, row.expected,
                "tier '\(row.tier)' fanOut \(row.requested)"
            )
            XCTAssertEqual(
                response.deniedReason, row.expectedReason,
                "tier '\(row.tier)' fanOut \(row.requested)"
            )
        }
    }

    // MARK: - (d) GUI-resolved trusted fan-out cap (split-brain M4)

    func testTrustedFanOutCapHonorsGUIResolvedCapClampedToCeiling() {
        struct Row {
            let reportedCap: Int?
            let requested: Int
            let expected: BurnBarRemoteMissionAuthorizationVerdict
            let note: String
        }
        // freeCap=1, ultraCap=16.
        let rows: [Row] = [
            // Absent cap fails closed to the free cap.
            Row(reportedCap: nil, requested: 1, expected: .authorized, note: "nil cap runs solo"),
            Row(reportedCap: nil, requested: 2, expected: .denied, note: "nil cap denies fan-out"),
            // The GUI-resolved paid caps are honored.
            Row(reportedCap: 3, requested: 3, expected: .authorized, note: "cloud cap 3 runs 3"),
            Row(reportedCap: 3, requested: 4, expected: .denied, note: "cloud cap 3 denies 4"),
            Row(reportedCap: 8, requested: 8, expected: .authorized, note: "pro cap 8 runs 8"),
            Row(reportedCap: 16, requested: 16, expected: .authorized, note: "ultra cap 16 runs 16"),
            // A cap above the ultra ceiling is clamped to 16 (never widened).
            Row(reportedCap: 999, requested: 17, expected: .denied, note: "over-ceiling cap clamped to 16, denies 17"),
            Row(reportedCap: 999, requested: 16, expected: .authorized, note: "over-ceiling cap clamped to 16, runs 16"),
            // A cap below the free cap is clamped UP to 1 (never drops the floor).
            Row(reportedCap: 0, requested: 1, expected: .authorized, note: "sub-floor cap clamped to 1, runs 1"),
            Row(reportedCap: -5, requested: 2, expected: .denied, note: "negative cap clamped to 1, denies 2")
        ]
        for row in rows {
            let response = BurnBarRemoteMissionAuthorizationPolicy.evaluate(
                makeRequest(
                    approvalStatus: "approved",
                    requestedFanOutCount: row.requested,
                    trustedFanOutCap: row.reportedCap
                )
            )
            XCTAssertEqual(response.verdict, row.expected, row.note)
            if response.verdict == .denied, row.requested >= 1 {
                XCTAssertEqual(response.deniedReason, .fanOutCapExceeded, row.note)
            }
        }
    }

    // MARK: - Backend decision

    func testBackendDecisionCarriesRequestedRuntimeAndDefaultsToAuto() throws {
        struct Row {
            let runtime: String?
            let model: String?
            let expectedRuntime: String
            let expectedModel: String?
            let expectedReason: String
        }
        let rows: [Row] = [
            Row(runtime: "codex", model: "glm-5", expectedRuntime: "codex",
                expectedModel: "glm-5", expectedReason: "requested_runtime_carried"),
            Row(runtime: " hermes \n", model: "  ", expectedRuntime: "hermes",
                expectedModel: nil, expectedReason: "requested_runtime_carried"),
            Row(runtime: nil, model: nil, expectedRuntime: "auto",
                expectedModel: nil, expectedReason: "defaulted_to_auto"),
            Row(runtime: "   ", model: "gpt-6", expectedRuntime: "auto",
                expectedModel: "gpt-6", expectedReason: "defaulted_to_auto")
        ]
        for row in rows {
            let response = BurnBarRemoteMissionAuthorizationPolicy.evaluate(
                makeRequest(
                    requestedRuntime: row.runtime,
                    requestedModelID: row.model,
                    approvalStatus: "approved"
                )
            )
            XCTAssertEqual(response.verdict, .authorized)
            let decision = try XCTUnwrap(response.backendDecision)
            XCTAssertEqual(decision.runtimeID, row.expectedRuntime)
            XCTAssertEqual(decision.modelID, row.expectedModel)
            XCTAssertEqual(decision.reason, row.expectedReason)
        }
    }

    // MARK: - Service surface

    func testMissionControlServiceExposesThePurePolicyVerdict() async throws {
        // The actor's protocol method must answer with EXACTLY the pure policy
        // evaluation — no store or transport state may perturb the verdict.
        let service = BurnBarMissionControlService(
            store: BurnBarMissionControlStore(
                eventsFileURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("authz-events-\(UUID().uuidString).jsonl"),
                projectionFileURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("authz-projection-\(UUID().uuidString).json"),
                logger: BurnBarDaemonLogger(category: "authz-tests"),
                notificationSecretStore: BurnBarInMemoryNotificationSecretStore()
            )
        )
        let requests = [
            makeRequest(approvalStatus: "approved"),
            makeRequest(executorTrustState: "banana"),
            makeRequest(approvalMode: "manual_all")
        ]
        for request in requests {
            let viaService = await service.missionAuthorizeRemote(request)
            let viaPolicy = BurnBarRemoteMissionAuthorizationPolicy.evaluate(request)
            XCTAssertEqual(viaService, viaPolicy)
        }
    }
}
