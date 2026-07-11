import Foundation
import OpenBurnBarComputerUseCore
import OpenBurnBarCore
@testable import OpenBurnBarDaemon
import XCTest

final class ComputerUseLocalAuthGrantEnforcementTests: XCTestCase {
    private let deviceID = "linux-phone-1"
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func testValidExactSignedGrantIsAccepted() async throws {
        let request = makeSessionRequest()
        let binding = try makeGrantBinding(for: request)
        let proof = try makeProof(for: binding)
        let server = try makeServer()

        let denial = await enforce(
            server: server,
            proof: proof,
            binding: binding,
            request: request
        )

        XCTAssertNil(denial)
    }

    func testUnderScopedCapabilityIsDenied() async throws {
        let request = makeSessionRequest()
        let binding = try makeGrantBinding(
            for: request,
            capabilities: [AgentDesktopCapability.desktopScreenshot.rawValue]
        )
        let proof = try makeProof(for: binding)
        let server = try makeServer()

        let denial = await enforce(
            server: server,
            proof: proof,
            binding: binding,
            request: request
        )

        try assertUnauthorized(denial)
    }

    func testTrustEscalationIsDenied() async throws {
        let trustedRequest = makeSessionRequest(trustMode: .trusted)
        let manualBinding = try makeGrantBinding(
            for: trustedRequest,
            trustMode: .manual
        )
        let proof = try makeProof(for: manualBinding)
        let server = try makeServer()

        let denial = await enforce(
            server: server,
            proof: proof,
            binding: manualBinding,
            request: trustedRequest
        )

        try assertUnauthorized(denial)
    }

    func testExpiredAndOverlongSignedGrantsAreDenied() async throws {
        let request = makeSessionRequest()
        let server = try makeServer()
        let cases: [(name: String, requestedAt: Date, expiresAt: Date, duration: TimeInterval)] = [
            (
                name: "expired",
                requestedAt: now.addingTimeInterval(-600),
                expiresAt: now.addingTimeInterval(-1),
                duration: AgentCapabilityGrantRequest.defaultGrantDuration
            ),
            (
                name: "overlong",
                requestedAt: now.addingTimeInterval(-10),
                expiresAt: now.addingTimeInterval(300),
                duration: AgentCapabilityGrantRequest.defaultGrantDuration + 1
            )
        ]

        for testCase in cases {
            let binding = try makeGrantBinding(
                for: request,
                requestID: "grant-\(testCase.name)-\(UUID().uuidString)",
                requestedAt: testCase.requestedAt,
                expiresAt: testCase.expiresAt,
                grantDurationSeconds: testCase.duration
            )
            let proof = try makeProof(for: binding)
            let denial = await enforce(
                server: server,
                proof: proof,
                binding: binding,
                request: request
            )

            try assertUnauthorized(denial, context: testCase.name)
        }
    }

    func testExactSessionIntentRetargetingIsDenied() async throws {
        let authorizedRequest = makeSessionRequest()
        let binding = try makeGrantBinding(for: authorizedRequest)
        let server = try makeServer()
        let retargetedRequests: [(name: String, request: ComputerUseSessionStartRequest)] = [
            (
                "run",
                makeSessionRequest(runID: BurnBarRunID(rawValue: "run-retargeted"))
            ),
            (
                "run-call",
                makeSessionRequest(runCallID: "call-retargeted")
            ),
            (
                "run-generation",
                makeSessionRequest(runGeneration: 8)
            ),
            (
                "scope",
                makeSessionRequest(scopeRuleIDs: ["https://retargeted.example/*"])
            ),
            (
                "action-cap",
                makeSessionRequest(actionCap: 51)
            ),
            (
                "timeout",
                makeSessionRequest(sessionTimeoutSeconds: 1_799)
            ),
            (
                "client",
                makeSessionRequest(clientID: BurnBarClientID(rawValue: "retargeted-client"))
            )
        ]

        for retarget in retargetedRequests {
            let proof = try makeProof(for: binding)
            let denial = await enforce(
                server: server,
                proof: proof,
                binding: binding,
                request: retarget.request
            )

            try assertUnauthorized(denial, context: retarget.name)
        }
    }

    #if os(Linux)
    func testLinuxFilePinBackingCommitsAliasesTogetherAndRejectsPartialConflict() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-linux-pin-aliases-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DaemonPhoneKeyPinStore(
            backing: DaemonPhoneKeyFilePinBacking(fileURL: root.appendingPathComponent("pins.json"))
        )
        let originalKey = PlatformCrypto.ed25519PrivateKey()
        let originalVerifier = PhoneControlVerifyingKey.ed25519(originalKey.publicKey)
        guard case .pinned = store.pinAliases(
            deviceIds: [deviceID, "linux-peer-node"],
            key: originalVerifier
        ) else {
            return XCTFail("expected atomic Linux alias commit")
        }

        let replacementKey = PlatformCrypto.ed25519PrivateKey()
        let replacementVerifier = PhoneControlVerifyingKey.ed25519(replacementKey.publicKey)
        guard case .conflict = store.pinAliases(
            deviceIds: ["rejected-new-device", "linux-peer-node"],
            key: replacementVerifier
        ) else {
            return XCTFail("expected existing peer alias conflict")
        }
        guard case .absent = store.pinnedKey(deviceId: "rejected-new-device") else {
            return XCTFail("conflicting alias transaction must not persist a new device")
        }
        for identifier in [deviceID, "linux-peer-node"] {
            guard case .pinned(let key) = store.pinnedKey(deviceId: identifier) else {
                XCTFail("expected persisted alias \(identifier)")
                continue
            }
            XCTAssertEqual(key.publicKeyRepresentation, originalKey.publicKey.rawRepresentation)
        }
    }
    #endif

    private func makeServer() throws -> BurnBarDaemonServer {
        let pinnedKey = try PlatformCrypto.ed25519PrivateKey(
            rawRepresentation: Data(repeating: 0x2A, count: 32)
        )
        let verifier = DaemonLocalAuthProofVerifier(
            resolvePinnedKey: { [deviceID] candidate in
                candidate == deviceID ? .ed25519(pinnedKey.publicKey) : nil
            },
            consumeProof: { _, _ in true }
        )
        return BurnBarDaemonServer(
            configuration: BurnBarDaemonConfiguration(
                socketPath: "/tmp/openburnbar-cu-grant-enforcement-\(UUID().uuidString).sock",
                socketAuthToken: "test-token",
                startsMissionControlBackgroundLoops: false
            ),
            logger: BurnBarDaemonLogger(category: "cu-grant-enforcement-tests"),
            localAuthProofVerifier: verifier
        )
    }

    private func makeSessionRequest(
        trustMode: ComputerUseTrustMode = .manual,
        scopeRuleIDs: [String] = ["https://example.com/*"],
        actionCap: Int = 50,
        sessionTimeoutSeconds: Int = 1_800,
        clientID: BurnBarClientID = BurnBarClientID(rawValue: "linux-shell"),
        runID: BurnBarRunID = BurnBarRunID(rawValue: "run-1"),
        runCallID: String = "call-1",
        runGeneration: UInt64 = 7
    ) -> ComputerUseSessionStartRequest {
        ComputerUseSessionStartRequest(
            mode: ComputerUseMode.browser.rawValue,
            trustMode: trustMode.rawValue,
            scopeRuleIds: scopeRuleIDs,
            phoneViewerNodeId: deviceID,
            actionCap: actionCap,
            sessionTimeoutSeconds: sessionTimeoutSeconds,
            clientID: clientID,
            runID: runID,
            runCallID: runCallID,
            runGeneration: runGeneration
        )
    }

    private func makeGrantBinding(
        for request: ComputerUseSessionStartRequest,
        requestID: String = "grant-request",
        capabilities: [String] = [
            AgentDesktopCapability.desktopBrowser.rawValue,
            AgentDesktopCapability.desktopScreenshot.rawValue
        ],
        trustMode: ComputerUseTrustMode = .manual,
        requestedAt: Date? = nil,
        expiresAt: Date? = nil,
        grantDurationSeconds: TimeInterval = AgentCapabilityGrantRequest.defaultGrantDuration
    ) throws -> ComputerUseLocalAuthGrantBinding {
        let clientIntentID = try ComputerUsePhoneControlSigner()
            .canonicalComputerUseSessionIntentID(request: request)
        return ComputerUseLocalAuthGrantBinding(
            requestId: "\(requestID)-\(UUID().uuidString)",
            runtime: "codex",
            threadId: "thread-linux-cu",
            preset: "desktop",
            capabilities: capabilities,
            trustMode: trustMode.rawValue,
            deliveryMode: AgentGrantDeliveryMode.liveThenQueued.rawValue,
            requestedAt: requestedAt ?? now.addingTimeInterval(-10),
            expiresAt: expiresAt ?? now.addingTimeInterval(300),
            grantDurationSeconds: grantDurationSeconds,
            sourceDeviceId: deviceID,
            clientIntentId: clientIntentID,
            localAuthenticationSatisfied: true
        )
    }

    private func makeProof(
        for binding: ComputerUseLocalAuthGrantBinding
    ) throws -> HermesRealtimeRelayAgentGrantLocalAuthProof {
        let pinnedKey = try PlatformCrypto.ed25519PrivateKey(
            rawRepresentation: Data(repeating: 0x2A, count: 32)
        )
        let intentHash = try ComputerUsePhoneControlSigner()
            .canonicalAgentGrantRequestHashHex(binding: binding)
        return try ComputerUsePhoneControlSigner().signLocalAuthProof(
            proofId: UUID().uuidString,
            deviceId: deviceID,
            signedIntentHash: intentHash,
            authenticatedAt: now.addingTimeInterval(-1),
            expiresAt: now.addingTimeInterval(120),
            privateKey: pinnedKey
        )
    }

    private func enforce(
        server: BurnBarDaemonServer,
        proof: HermesRealtimeRelayAgentGrantLocalAuthProof,
        binding: ComputerUseLocalAuthGrantBinding,
        request: ComputerUseSessionStartRequest
    ) async -> Data? {
        await server.enforceLocalAuthProof(
            requestId: UUID().uuidString,
            method: .computerUseSessionStart,
            proof: proof,
            sourceDeviceId: deviceID,
            intentHashHex: nil,
            grantBinding: binding,
            sessionRequest: request,
            now: now
        )
    }

    private func assertUnauthorized(
        _ data: Data?,
        context: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        guard let data else {
            XCTFail("expected unauthorized denial \(context)", file: file, line: line)
            return
        }
        let response = try JSONDecoder().decode(
            BurnBarRPCResponseEnvelope<BurnBarEmptyResult>.self,
            from: data
        )
        XCTAssertEqual(response.error?.code, -32_001, context, file: file, line: line)
        XCTAssertNil(response.result, context, file: file, line: line)
    }
}
