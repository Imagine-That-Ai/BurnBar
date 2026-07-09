import XCTest
import OpenBurnBarCore
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
        requestedRuntime: String? = "hermes",
        requestedModelID: String? = nil,
        approvalMode: String? = "existing_policy",
        approvalStatus: String? = nil,
        entitlementTier: String = "ultra",
        requestedFanOutCount: Int = 1
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
            approvalMode: approvalMode,
            approvalStatus: approvalStatus,
            approverDeviceID: nil,
            entitlementTier: entitlementTier,
            requestedFanOutCount: requestedFanOutCount,
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

    // MARK: - (b) Approval: shared policy semantics, fail-closed

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
            // No decision yet: shared policy decides.
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
            // Unknown approvalMode fails closed inside the SHARED policy.
            Row(mode: "auto_yolo", status: nil, commands: false, fileEdits: false,
                expected: .requiresApproval, expectedReason: nil, note: "unknown mode fails closed"),
            // Unknown approvalStatus strings are treated as no-decision-yet.
            Row(mode: "existing_policy", status: "mystery_status", commands: false, fileEdits: false,
                expected: .authorized, expectedReason: nil, note: "unknown status + safe policy runs"),
            Row(mode: "manual_all", status: "mystery_status", commands: false, fileEdits: false,
                expected: .requiresApproval, expectedReason: nil, note: "unknown status + manual_all pauses")
        ]
        for row in rows {
            let response = BurnBarRemoteMissionAuthorizationPolicy.evaluate(
                makeRequest(
                    commandsAllowed: row.commands,
                    fileEditsAllowed: row.fileEdits,
                    approvalMode: row.mode,
                    approvalStatus: row.status
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

    // MARK: - (d) Fan-out cap per entitlement tier, fail-closed

    func testFanOutVerdictTable() {
        struct Row {
            let tier: String
            let requested: Int
            let expected: BurnBarRemoteMissionAuthorizationVerdict
            let expectedReason: BurnBarRemoteMissionDenialReason?
        }
        let rows: [Row] = [
            // Caps mirror WandFanOut: free 1 · cloud 3 · pro 8 · ultra 16.
            Row(tier: "none", requested: 1, expected: .authorized, expectedReason: nil),
            Row(tier: "none", requested: 2, expected: .denied, expectedReason: .fanOutCapExceeded),
            Row(tier: "cloud", requested: 3, expected: .authorized, expectedReason: nil),
            Row(tier: "cloud", requested: 4, expected: .denied, expectedReason: .fanOutCapExceeded),
            Row(tier: "pro", requested: 8, expected: .authorized, expectedReason: nil),
            Row(tier: "pro", requested: 9, expected: .denied, expectedReason: .fanOutCapExceeded),
            Row(tier: "ultra", requested: 16, expected: .authorized, expectedReason: nil),
            Row(tier: "ultra", requested: 17, expected: .denied, expectedReason: .fanOutCapExceeded),
            Row(tier: " ULTRA ", requested: 16, expected: .authorized, expectedReason: nil),
            // Unknown tiers fail CLOSED to the free-tier cap of 1.
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
