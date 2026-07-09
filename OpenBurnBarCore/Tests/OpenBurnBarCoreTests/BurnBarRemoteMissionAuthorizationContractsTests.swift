import XCTest
@testable import OpenBurnBarCore

/// Contract tests for the M2 `daemon.mission.authorizeRemote` wire types in
/// `OpenBurnBarMissionControlMissionsContracts.swift`. Mirrors the
/// `OpenBurnBarMissionControlMissionsContractsTests` pattern: symmetric
/// round trips PLUS hand-authored raw wire JSON so a CodingKeys rename cannot
/// slip through, absent-optional tolerance, and fail-closed decode defaults
/// for the capability grant.
final class BurnBarRemoteMissionAuthorizationContractsTests: XCTestCase {

    // MARK: - Builders

    private func makeRequest(
        commandsAllowed: Bool = true,
        fileEditsAllowed: Bool = false,
        additionalCapabilities: [String] = ["future_capability"]
    ) -> BurnBarRemoteMissionAuthorizeRequest {
        BurnBarRemoteMissionAuthorizeRequest(
            missionID: "mission-wire-authz-1",
            originDeviceID: "phone-wire-1",
            originPlatform: "ios",
            executorTrustState: "trusted",
            promptSummary: "Fix the flaky daemon lane",
            promptSHA256: String(repeating: "0f", count: 32),
            requestedRuntime: "codex",
            requestedModelID: "glm-5",
            requestedGrant: BurnBarRemoteMissionCapabilityGrantRequest(
                commandsAllowed: commandsAllowed,
                fileEditsAllowed: fileEditsAllowed,
                additionalCapabilities: additionalCapabilities
            ),
            personaScope: PersonaScopeEnvelope(
                agentURI: "agent://burnbar/codex",
                personaID: "tech-reviewer",
                permittedTools: ["read_file", "grep"],
                permittedFileGlobs: ["src/**"],
                permittedShellPrefixes: [],
                permitShell: false,
                permitFileEdits: false,
                appliedAt: Date(timeIntervalSinceReferenceDate: 2000)
            ),
            approvalMode: "manual_all",
            approvalStatus: "approved",
            approverDeviceID: "phone-wire-1",
            entitlementTier: "ultra",
            requestedFanOutCount: 3,
            workingDirectory: "/Users/operator/project"
        )
    }

    // MARK: - Verdict + reason enums: pinned wire values

    func testVerdictAndDenialReasonWireValuesAreStable() throws {
        // These strings are daemon socket protocol; a change is a protocol
        // break for every M3+ client, not a test update.
        XCTAssertEqual(BurnBarRemoteMissionAuthorizationVerdict.authorized.rawValue, "authorized")
        XCTAssertEqual(BurnBarRemoteMissionAuthorizationVerdict.requiresApproval.rawValue, "requires_approval")
        XCTAssertEqual(BurnBarRemoteMissionAuthorizationVerdict.denied.rawValue, "denied")

        let expectedReasons: [BurnBarRemoteMissionDenialReason: String] = [
            .untrustedDevice: "untrusted_device",
            .unknownTrustState: "unknown_trust_state",
            .approvalRejected: "approval_rejected",
            .fanOutCapExceeded: "fan_out_cap_exceeded",
            .invalidRequest: "invalid_request"
        ]
        XCTAssertEqual(
            expectedReasons.count,
            BurnBarRemoteMissionDenialReason.allCases.count,
            "A denial reason was added or removed without pinning its wire value here."
        )
        for reason in BurnBarRemoteMissionDenialReason.allCases {
            XCTAssertEqual(reason.rawValue, expectedReasons[reason])
        }

        // Unknown verdicts must fail decoding (older client vs newer daemon
        // surfaces loudly instead of silently misreading a verdict).
        let unknown = Data(#"["authorized_with_conditions"]"#.utf8)
        XCTAssertThrowsError(
            try JSONDecoder().decode([BurnBarRemoteMissionAuthorizationVerdict].self, from: unknown)
        )
    }

    // MARK: - Request round trip

    func testAuthorizeRequestRoundTripsFullyPopulated() throws {
        let request = makeRequest()
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(BurnBarRemoteMissionAuthorizeRequest.self, from: data)
        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.personaScope?.personaID, "tech-reviewer")
        XCTAssertEqual(decoded.requestedGrant.additionalCapabilities, ["future_capability"])
    }

    func testAuthorizeRequestDecodesFromRawWireJSONWithAbsentOptionals() throws {
        // Hand-authored minimal wire shape: every optional absent; the grant
        // carries only one capability key. Pins the exact wire key names.
        let wire = Data("""
        {
          "missionID": "mission-raw-1",
          "originDeviceID": "phone-raw-1",
          "originPlatform": "android",
          "executorTrustState": "pending",
          "promptSummary": "Audit the keystore bindings",
          "promptSHA256": "\(String(repeating: "aa", count: 32))",
          "requestedGrant": { "commandsAllowed": true },
          "entitlementTier": "cloud",
          "requestedFanOutCount": 2
        }
        """.utf8)
        let decoded = try JSONDecoder().decode(BurnBarRemoteMissionAuthorizeRequest.self, from: wire)
        XCTAssertEqual(decoded.missionID, "mission-raw-1")
        XCTAssertEqual(decoded.originPlatform, "android")
        XCTAssertEqual(decoded.executorTrustState, "pending")
        XCTAssertNil(decoded.requestedRuntime)
        XCTAssertNil(decoded.requestedModelID)
        XCTAssertNil(decoded.personaScope)
        XCTAssertNil(decoded.approvalMode)
        XCTAssertNil(decoded.approvalStatus)
        XCTAssertNil(decoded.approverDeviceID)
        XCTAssertNil(decoded.workingDirectory)
        XCTAssertEqual(decoded.entitlementTier, "cloud")
        XCTAssertEqual(decoded.requestedFanOutCount, 2)
        // Grant decode fails CLOSED: absent capability keys are non-grants.
        XCTAssertTrue(decoded.requestedGrant.commandsAllowed)
        XCTAssertFalse(decoded.requestedGrant.fileEditsAllowed)
        XCTAssertEqual(decoded.requestedGrant.additionalCapabilities, [])
    }

    func testCapabilityGrantDecodeFailsClosedOnEmptyObject() throws {
        let decoded = try JSONDecoder().decode(
            BurnBarRemoteMissionCapabilityGrantRequest.self,
            from: Data("{}".utf8)
        )
        XCTAssertFalse(decoded.commandsAllowed)
        XCTAssertFalse(decoded.fileEditsAllowed)
        XCTAssertEqual(decoded.additionalCapabilities, [])
    }

    // MARK: - Response round trip

    func testAuthorizeResponseRoundTripsEveryVerdictShape() throws {
        let responses: [BurnBarRemoteMissionAuthorizeResponse] = [
            BurnBarRemoteMissionAuthorizeResponse(
                verdict: .authorized,
                grantCeiling: BurnBarRemoteMissionCapabilityGrantRequest(
                    commandsAllowed: true,
                    fileEditsAllowed: false
                ),
                backendDecision: BurnBarRemoteMissionBackendDecision(
                    runtimeID: "codex",
                    modelID: "glm-5",
                    reason: "requested_runtime_carried"
                )
            ),
            BurnBarRemoteMissionAuthorizeResponse(
                verdict: .requiresApproval,
                detail: "Pre-dispatch operator approval is required.",
                grantCeiling: BurnBarRemoteMissionCapabilityGrantRequest(
                    commandsAllowed: false,
                    fileEditsAllowed: true
                )
            ),
            BurnBarRemoteMissionAuthorizeResponse(
                verdict: .denied,
                deniedReason: .unknownTrustState,
                detail: "Executor trust state 'banana' does not permit remote mission execution."
            )
        ]
        for response in responses {
            let data = try JSONEncoder().encode(response)
            let decoded = try JSONDecoder().decode(BurnBarRemoteMissionAuthorizeResponse.self, from: data)
            XCTAssertEqual(decoded, response)
        }
    }

    func testAuthorizeResponseDecodesFromRawWireJSON() throws {
        let wire = Data("""
        {
          "verdict": "denied",
          "deniedReason": "fan_out_cap_exceeded",
          "detail": "Requested fan-out 4 exceeds the cap of 3 for tier 'cloud'."
        }
        """.utf8)
        let decoded = try JSONDecoder().decode(BurnBarRemoteMissionAuthorizeResponse.self, from: wire)
        XCTAssertEqual(decoded.verdict, .denied)
        XCTAssertEqual(decoded.deniedReason, .fanOutCapExceeded)
        XCTAssertNil(decoded.grantCeiling)
        XCTAssertNil(decoded.backendDecision)

        let authorizedWire = Data("""
        {
          "verdict": "authorized",
          "grantCeiling": { "commandsAllowed": false, "fileEditsAllowed": false, "additionalCapabilities": [] },
          "backendDecision": { "runtimeID": "auto", "reason": "defaulted_to_auto" }
        }
        """.utf8)
        let authorized = try JSONDecoder().decode(
            BurnBarRemoteMissionAuthorizeResponse.self,
            from: authorizedWire
        )
        XCTAssertEqual(authorized.verdict, .authorized)
        XCTAssertNil(authorized.deniedReason)
        XCTAssertEqual(authorized.backendDecision?.runtimeID, "auto")
        XCTAssertNil(authorized.backendDecision?.modelID)
    }

    // MARK: - Envelope integration

    func testAuthorizeRequestRidesTheRPCEnvelopeUnderTheNewMethod() throws {
        XCTAssertEqual(
            BurnBarRPCMethod.missionAuthorizeRemote.rawValue,
            "daemon.mission.authorizeRemote"
        )
        let envelope = BurnBarRPCRequestEnvelopeWithParams(
            id: "authorize-1",
            method: .missionAuthorizeRemote,
            authToken: "session-token",
            params: makeRequest()
        )
        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(
            BurnBarRPCRequestEnvelopeWithParams<BurnBarRemoteMissionAuthorizeRequest>.self,
            from: data
        )
        XCTAssertEqual(decoded.id, "authorize-1")
        XCTAssertEqual(decoded.method, .missionAuthorizeRemote)
        XCTAssertEqual(decoded.params, makeRequest())

        // An older daemon rejecting the new method answers on the error lane;
        // the client must read it and treat authorization as unavailable
        // (fail closed), mirroring the runtime-snapshot version-skew contract.
        let rejection = BurnBarRPCResponseEnvelope<BurnBarRemoteMissionAuthorizeResponse>(
            id: "authorize-1",
            error: BurnBarRPCError(code: -32601, message: "unsupported method: daemon.mission.authorizeRemote")
        )
        let rejectionData = try JSONEncoder().encode(rejection)
        let decodedRejection = try JSONDecoder().decode(
            BurnBarRPCResponseEnvelope<BurnBarRemoteMissionAuthorizeResponse>.self,
            from: rejectionData
        )
        XCTAssertNil(decodedRejection.result)
        XCTAssertEqual(decodedRejection.error?.code, -32601)
    }
}
