import Foundation
import OpenBurnBarComputerUseCore
import OpenBurnBarCore
@testable import OpenBurnBarDaemon
import XCTest

final class DaemonComputerUseApprovalAuthorityVerifierTests: XCTestCase {
    func testAcceptsExactFreshSignedPendingApprovalAndRejectsReplay() async throws {
        let fixture = try makeFixture(counter: 7)
        let verifier = DaemonComputerUseApprovalAuthorityVerifier(resolvePinnedKey: { peerNodeID in
            peerNodeID == fixture.peerNodeID ? .ed25519(fixture.key.publicKey) : nil
        })

        try await verifier.verify(
            response: fixture.response,
            pendingRequest: fixture.request,
            sessionID: fixture.request.sessionId,
            now: fixture.now
        )
        do {
            try await verifier.verify(
                response: fixture.response,
                pendingRequest: fixture.request,
                sessionID: fixture.request.sessionId,
                now: fixture.now
            )
            XCTFail("expected replay rejection")
        } catch let failure as DaemonComputerUseApprovalAuthorityVerifier.VerificationFailure {
            XCTAssertEqual(failure, .counterReplay(lastSeen: 7, attempted: 7))
        }
    }

    func testRejectsWrongSessionAndPendingRequestHash() async throws {
        let fixture = try makeFixture(counter: 1)
        let verifier = DaemonComputerUseApprovalAuthorityVerifier(resolvePinnedKey: { _ in
            .ed25519(fixture.key.publicKey)
        })

        do {
            try await verifier.verify(
                response: fixture.response,
                pendingRequest: fixture.request,
                sessionID: "other-session",
                now: fixture.now
            )
            XCTFail("expected session rejection")
        } catch let failure as DaemonComputerUseApprovalAuthorityVerifier.VerificationFailure {
            XCTAssertEqual(
                failure,
                .wrongSession(expected: fixture.request.sessionId, observed: "other-session")
            )
        }

        var tampered = fixture.response
        tampered.requestHashBlake3 = String(repeating: "f", count: 64)
        do {
            try await verifier.verify(
                response: tampered,
                pendingRequest: fixture.request,
                sessionID: fixture.request.sessionId,
                now: fixture.now
            )
            XCTFail("expected request hash rejection")
        } catch let failure as DaemonComputerUseApprovalAuthorityVerifier.VerificationFailure {
            XCTAssertEqual(failure, .wrongRequestHash)
        }
    }

    func testRejectsForgedResponderAndStaleAuthority() async throws {
        let fixture = try makeFixture(counter: 2)
        let verifier = DaemonComputerUseApprovalAuthorityVerifier(resolvePinnedKey: { _ in
            .ed25519(fixture.key.publicKey)
        })

        var forged = fixture.response
        forged.respondedBy = "attacker"
        do {
            try await verifier.verify(
                response: forged,
                pendingRequest: fixture.request,
                sessionID: fixture.request.sessionId,
                now: fixture.now
            )
            XCTFail("expected responder rejection")
        } catch let failure as DaemonComputerUseApprovalAuthorityVerifier.VerificationFailure {
            XCTAssertEqual(
                failure,
                .wrongResponder(expected: fixture.peerNodeID, observed: "attacker")
            )
        }

        do {
            try await verifier.verify(
                response: fixture.response,
                pendingRequest: fixture.request,
                sessionID: fixture.request.sessionId,
                now: fixture.now.addingTimeInterval(31)
            )
            XCTFail("expected stale timestamp rejection")
        } catch let failure as DaemonComputerUseApprovalAuthorityVerifier.VerificationFailure {
            XCTAssertEqual(failure, .staleTimestamp)
        }
    }

    func testPersistedCounterRejectsReplayAfterVerifierRestart() async throws {
        let fixture = try makeFixture(counter: 9)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-cu-approval-replay-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("counters.json")
        let resolver: DaemonComputerUseApprovalAuthorityVerifier.PinnedKeyResolver = { peerNodeID in
            peerNodeID == fixture.peerNodeID ? .ed25519(fixture.key.publicKey) : nil
        }
        let first = DaemonComputerUseApprovalAuthorityVerifier(
            resolvePinnedKey: resolver,
            replayCounterStore: DaemonComputerUseApprovalReplayCounterStore(fileURL: fileURL)
        )
        try await first.verify(
            response: fixture.response,
            pendingRequest: fixture.request,
            sessionID: fixture.request.sessionId,
            now: fixture.now
        )

        let restarted = DaemonComputerUseApprovalAuthorityVerifier(
            resolvePinnedKey: resolver,
            replayCounterStore: DaemonComputerUseApprovalReplayCounterStore(fileURL: fileURL)
        )
        do {
            try await restarted.verify(
                response: fixture.response,
                pendingRequest: fixture.request,
                sessionID: fixture.request.sessionId,
                now: fixture.now
            )
            XCTFail("expected restart replay rejection")
        } catch let failure as DaemonComputerUseApprovalAuthorityVerifier.VerificationFailure {
            XCTAssertEqual(failure, .counterReplay(lastSeen: 9, attempted: 9))
        }
    }

    func testCorruptPersistedCounterStoreFailsClosed() async throws {
        let fixture = try makeFixture(counter: 1)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-cu-approval-corrupt-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fileURL = root.appendingPathComponent("counters.json")
        try Data("{".utf8).write(to: fileURL)
        let verifier = DaemonComputerUseApprovalAuthorityVerifier(
            resolvePinnedKey: { _ in .ed25519(fixture.key.publicKey) },
            replayCounterStore: DaemonComputerUseApprovalReplayCounterStore(fileURL: fileURL)
        )

        do {
            try await verifier.verify(
                response: fixture.response,
                pendingRequest: fixture.request,
                sessionID: fixture.request.sessionId,
                now: fixture.now
            )
            XCTFail("expected corrupt replay store rejection")
        } catch let failure as DaemonComputerUseApprovalAuthorityVerifier.VerificationFailure {
            XCTAssertEqual(failure, .replayStoreUnavailable)
        }
    }

    func testLinuxApprovalRPCRequiresExactSignedAuthorityAndResolvesContinuationOnce() async throws {
        let fixture = try makeFixture(counter: 11, now: Date())
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-cu-approval-rpc-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pinStore = DaemonPhoneKeyPinStore(backing: DaemonPhoneKeyInMemoryPinBacking())
        let pinnedKey = PhoneControlVerifyingKey.ed25519(fixture.key.publicKey)
        guard case .pinned = pinStore.pinAliases(
            deviceIds: ["source-device", fixture.peerNodeID],
            key: pinnedKey
        ) else {
            XCTFail("expected source-device and transport-peer aliases to pin atomically")
            return
        }
        let approvalVerifier = DaemonComputerUseApprovalAuthorityVerifier(
            resolvePinnedKey: { peerNodeID in
                guard case .pinned(let key) = pinStore.pinnedKey(deviceId: peerNodeID) else {
                    return nil
                }
                return key
            },
            replayCounterStore: DaemonComputerUseApprovalReplayCounterStore(
                fileURL: root.appendingPathComponent("approval-counters.json")
            )
        )
        let proofVerifier = DaemonLocalAuthProofVerifier(
            resolvePinnedKey: { _ in pinnedKey },
            consumeProof: { _, _ in true }
        )
        let service = ComputerUseService(
            auditBaseDirectory: root.appendingPathComponent("audit", isDirectory: true),
            privilegedInputKillSwitchActivator: { _ in },
            playwrightDriverFactory: { _ in nil }
        )
        let server = BurnBarDaemonServer(
            configuration: BurnBarDaemonConfiguration(
                socketPath: root.appendingPathComponent("daemon.sock").path,
                socketAuthToken: "test-token",
                startsMissionControlBackgroundLoops: false
            ),
            logger: BurnBarDaemonLogger(category: "cu-approval-rpc-integration-tests"),
            computerUseService: service,
            localAuthProofVerifier: proofVerifier,
            phoneControlPinStore: pinStore,
            computerUseApprovalAuthorityVerifier: approvalVerifier
        )
        let awaitingResponse = Task {
            try await service.awaitApprovalResponse(fixture.request)
        }
        while await service.pendingApprovals(
            ComputerUseApprovalPendingRequest(sessionId: fixture.request.sessionId)
        ).requests.isEmpty {
            await Task.yield()
        }

        var unsigned = fixture.response
        unsigned.authority = nil
        let unsignedReply: BurnBarRPCResponseEnvelope<ComputerUseApprovalRespondResponse> = try await sendApprovalResponse(
            unsigned,
            sessionID: fixture.request.sessionId,
            requestID: "unsigned",
            server: server
        )
        XCTAssertEqual(unsignedReply.error?.code, BurnBarRPCErrorCode.unauthorized)

        let wrongSessionReply: BurnBarRPCResponseEnvelope<ComputerUseApprovalRespondResponse> = try await sendApprovalResponse(
            fixture.response,
            sessionID: "wrong-session",
            requestID: "wrong-session",
            server: server
        )
        XCTAssertEqual(wrongSessionReply.error?.code, BurnBarRPCErrorCode.unauthorized)

        let acceptedReply: BurnBarRPCResponseEnvelope<ComputerUseApprovalRespondResponse> = try await sendApprovalResponse(
            fixture.response,
            sessionID: fixture.request.sessionId,
            requestID: "signed-exact",
            server: server
        )
        XCTAssertEqual(acceptedReply.result?.accepted, true)
        XCTAssertNil(acceptedReply.error)
        let resolved = try await awaitingResponse.value
        XCTAssertEqual(resolved, fixture.response)
        let pendingAfterResolution = await service.pendingApprovals(
            ComputerUseApprovalPendingRequest(sessionId: fixture.request.sessionId)
        )
        XCTAssertTrue(pendingAfterResolution.requests.isEmpty)

        let replayReply: BurnBarRPCResponseEnvelope<ComputerUseApprovalRespondResponse> = try await sendApprovalResponse(
            fixture.response,
            sessionID: fixture.request.sessionId,
            requestID: "replay",
            server: server
        )
        XCTAssertEqual(replayReply.error?.code, BurnBarRPCErrorCode.unauthorized)
    }

    private struct Fixture {
        let key: PlatformEd25519SigningMaterial
        let peerNodeID: String
        let now: Date
        let request: HermesRealtimeRelayApprovalRequest
        let response: HermesRealtimeRelayApprovalResponse
    }

    private func makeFixture(counter: UInt64, now: Date = Date(timeIntervalSinceReferenceDate: 800_000_000)) throws -> Fixture {
        let signer = ComputerUsePhoneControlSigner()
        let key = PlatformCrypto.ed25519PrivateKey()
        let peerNodeID = "android-phone-test"
        let request = HermesRealtimeRelayApprovalRequest(
            approvalId: "approval-1",
            runId: "run-1",
            sessionId: "session-1",
            toolKind: "browser_click",
            title: "Click",
            message: "Click the primary action",
            actionSummary: "Click the primary action",
            requestedAt: now.addingTimeInterval(-1),
            trustMode: "manual"
        )
        var response = HermesRealtimeRelayApprovalResponse(
            approvalId: request.approvalId,
            decision: .approve,
            respondedBy: peerNodeID,
            respondedAt: now,
            requestHashBlake3: try signer.canonicalApprovalRequestHashHex(request: request)
        )
        let signed = try signer.sign(
            approvalResponse: response,
            peerNodeId: peerNodeID,
            counter: counter,
            timestamp: now,
            privateKey: key
        )
        response.authority = HermesRealtimeRelayAuthorityEnvelope(
            peerNodeId: signed.peerNodeId,
            counter: signed.counter,
            timestamp: signed.timestamp,
            intentHashBlake3: signed.intentHashHex,
            signatureEd25519: signed.signatureBase64,
            keyKind: .ed25519
        )
        return Fixture(key: key, peerNodeID: peerNodeID, now: now, request: request, response: response)
    }

    private func sendApprovalResponse(
        _ response: HermesRealtimeRelayApprovalResponse,
        sessionID: String,
        requestID: String,
        server: BurnBarDaemonServer
    ) async throws -> BurnBarRPCResponseEnvelope<ComputerUseApprovalRespondResponse> {
        let envelope = BurnBarRPCRequestEnvelopeWithParams(
            id: requestID,
            method: BurnBarRPCMethod.computerUseApprovalRespond,
            authToken: "test-token",
            params: ComputerUseApprovalRespondRequest(sessionId: sessionID, response: response)
        )
        let responseData = try await server.handleComputerUseRPC(
            method: .computerUseApprovalRespond,
            decoder: JSONDecoder(),
            requestData: JSONEncoder().encode(envelope)
        )
        return try JSONDecoder().decode(
            BurnBarRPCResponseEnvelope<ComputerUseApprovalRespondResponse>.self,
            from: responseData
        )
    }
}
