import Foundation
import OpenBurnBarComputerUseCore
import OpenBurnBarCore
@testable import OpenBurnBarDaemon
import XCTest

final class DaemonComputerUseSessionGrantAuthorityVerifierTests: XCTestCase {
    func testAcceptsExactFreshGrantWithoutConsumingLocalAuthProofAndRejectsReplay() async throws {
        let fixture = try makeFixture(counter: 7)
        let proofConsumptions = Locked(0)
        let verifier = makeVerifier(fixture: fixture, proofConsumptions: proofConsumptions)

        try await verifier.verify(
            fixture.request,
            expectedAuthorityPeerNodeID: fixture.peerNodeID,
            now: fixture.now
        )
        XCTAssertEqual(proofConsumptions.withLock { $0 }, 0)

        do {
            try await verifier.verify(
                fixture.request,
                expectedAuthorityPeerNodeID: fixture.peerNodeID,
                now: fixture.now
            )
            XCTFail("expected replay rejection")
        } catch let failure as DaemonComputerUseSessionGrantAuthorityVerifier.VerificationFailure {
            XCTAssertEqual(failure, .counterReplay(lastSeen: 7, attempted: 7))
        }
    }

    func testRejectsWrongAuthorityIntentAndMissingLocalAuthentication() async throws {
        let fixture = try makeFixture(counter: 1)
        let verifier = makeVerifier(fixture: fixture)

        do {
            try await verifier.verify(
                fixture.request,
                expectedAuthorityPeerNodeID: "different-authority",
                now: fixture.now
            )
            XCTFail("expected authority rejection")
        } catch let failure as DaemonComputerUseSessionGrantAuthorityVerifier.VerificationFailure {
            XCTAssertEqual(failure, .malformedAuthority)
        }

        var wrongIntent = fixture.request
        wrongIntent.authority.intentHashBlake3 = String(repeating: "f", count: 64)
        do {
            try await verifier.verify(
                wrongIntent,
                expectedAuthorityPeerNodeID: fixture.peerNodeID,
                now: fixture.now
            )
            XCTFail("expected intent rejection")
        } catch let failure as DaemonComputerUseSessionGrantAuthorityVerifier.VerificationFailure {
            XCTAssertEqual(failure, .wrongIntentHash)
        }

        var noLocalAuth = fixture.request
        noLocalAuth.localAuthenticationSatisfied = false
        noLocalAuth.localAuthProof = nil
        do {
            try await verifier.verify(
                noLocalAuth,
                expectedAuthorityPeerNodeID: fixture.peerNodeID,
                now: fixture.now
            )
            XCTFail("expected local-auth rejection")
        } catch let failure as DaemonComputerUseSessionGrantAuthorityVerifier.VerificationFailure {
            XCTAssertEqual(failure, .localAuthenticationRequired)
        }
    }

    func testPersistedCounterRejectsReplayAfterRestartAndCorruptStoreFailsClosed() async throws {
        let fixture = try makeFixture(counter: 9)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-cu-session-grant-replay-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("counters.json")

        let first = makeVerifier(
            fixture: fixture,
            replayCounterStore: DaemonComputerUseApprovalReplayCounterStore(fileURL: fileURL)
        )
        try await first.verify(
            fixture.request,
            expectedAuthorityPeerNodeID: fixture.peerNodeID,
            now: fixture.now
        )

        let restarted = makeVerifier(
            fixture: fixture,
            replayCounterStore: DaemonComputerUseApprovalReplayCounterStore(fileURL: fileURL)
        )
        do {
            try await restarted.verify(
                fixture.request,
                expectedAuthorityPeerNodeID: fixture.peerNodeID,
                now: fixture.now
            )
            XCTFail("expected persisted replay rejection")
        } catch let failure as DaemonComputerUseSessionGrantAuthorityVerifier.VerificationFailure {
            XCTAssertEqual(failure, .counterReplay(lastSeen: 9, attempted: 9))
        }

        try Data("{".utf8).write(to: fileURL, options: .atomic)
        let corrupt = makeVerifier(
            fixture: fixture,
            replayCounterStore: DaemonComputerUseApprovalReplayCounterStore(fileURL: fileURL)
        )
        do {
            try await corrupt.verify(
                fixture.request,
                expectedAuthorityPeerNodeID: fixture.peerNodeID,
                now: fixture.now
            )
            XCTFail("expected corrupt-store rejection")
        } catch let failure as DaemonComputerUseSessionGrantAuthorityVerifier.VerificationFailure {
            XCTAssertEqual(failure, .replayStoreUnavailable)
        }
    }

    func testRejectsTimestampExpiryKeySignatureAndLocalProofFailures() async throws {
        let fixture = try makeFixture(counter: 3)

        try await assertRejected(
            fixture.request,
            fixture: fixture,
            verifier: makeVerifier(fixture: fixture),
            now: fixture.now.addingTimeInterval(31),
            expected: .staleTimestamp
        )
        try await assertRejected(
            fixture.request,
            fixture: fixture,
            verifier: makeVerifier(fixture: fixture),
            now: fixture.now.addingTimeInterval(-31),
            expected: .staleTimestamp
        )

        var expired = fixture.request
        expired.expiresAt = fixture.now.addingTimeInterval(-1)
        try await assertRejected(
            expired,
            fixture: fixture,
            verifier: makeVerifier(fixture: fixture),
            expected: .expiredGrant
        )

        var wrongKind = fixture.request
        wrongKind.authority.keyKind = .secureEnclaveP256
        try await assertRejected(
            wrongKind,
            fixture: fixture,
            verifier: makeVerifier(fixture: fixture),
            expected: .wrongKeyKind
        )

        var badSignature = fixture.request
        badSignature.authority.signatureEd25519 = Data(repeating: 0, count: 64).base64EncodedString()
        try await assertRejected(
            badSignature,
            fixture: fixture,
            verifier: makeVerifier(fixture: fixture),
            expected: .signatureInvalid
        )

        var badProof = fixture.request
        badProof.localAuthProof?.signatureEd25519 = Data(repeating: 0, count: 64).base64EncodedString()
        try await assertRejected(
            badProof,
            fixture: fixture,
            verifier: makeVerifier(fixture: fixture),
            expected: .localAuthProofRejected
        )
    }

    func testPersistenceFailurePoisonsVerifierFailClosed() async throws {
        let fixture = try makeFixture(counter: 5)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-cu-session-grant-write-failure-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("not-a-directory".utf8).write(to: root)
        let store = DaemonComputerUseApprovalReplayCounterStore(
            fileURL: root.appendingPathComponent("counters.json")
        )
        let verifier = makeVerifier(fixture: fixture, replayCounterStore: store)

        try await assertRejected(
            fixture.request,
            fixture: fixture,
            verifier: verifier,
            expected: .replayCounterPersistenceFailed
        )
        try await assertRejected(
            fixture.request,
            fixture: fixture,
            verifier: verifier,
            expected: .replayStoreUnavailable
        )
    }

    private struct Fixture {
        let key: PlatformEd25519SigningMaterial
        let peerNodeID: String
        let now: Date
        let request: HermesRealtimeRelayAgentGrantRequest
    }

    private func makeFixture(counter: UInt64) throws -> Fixture {
        let signer = ComputerUsePhoneControlSigner()
        let key = PlatformCrypto.ed25519PrivateKey()
        let peerNodeID = "android-phone-session-grant"
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let sourceDeviceID = "android-device-1"
        let proofID = "proof-session-grant-1"

        var grant = AgentCapabilityGrantRequest(
            requestID: "challenge-session-grant-1",
            runtimeID: .codex,
            threadID: "thread-1",
            preset: .desktop,
            capabilities: [.desktopBrowser, .desktopScreenshot],
            trustMode: .step,
            deliveryMode: .live,
            requestedAt: now.addingTimeInterval(-1),
            expiresAt: now.addingTimeInterval(299),
            grantDurationSeconds: 300,
            sourceDeviceID: sourceDeviceID,
            clientIntentID: "session-intent-1",
            localAuthenticationSatisfied: true
        )
        let proofIntentHash = try signer.canonicalAgentGrantRequestHashHex(request: grant)
        let proofAuthenticatedAt = now.addingTimeInterval(-1)
        let proofExpiresAt = now.addingTimeInterval(299)
        let proofPayload = signer.localAuthProofSignablePayload(
            proofId: proofID,
            deviceId: sourceDeviceID,
            signedIntentHash: proofIntentHash,
            authenticatedAt: proofAuthenticatedAt,
            expiresAt: proofExpiresAt
        )
        grant.localAuthProof = HermesRealtimeRelayAgentGrantLocalAuthProof(
            proofId: proofID,
            deviceId: sourceDeviceID,
            signedIntentHash: proofIntentHash,
            authenticatedAt: proofAuthenticatedAt,
            expiresAt: proofExpiresAt,
            signatureEd25519: try PlatformCrypto.ed25519Signature(
                message: proofPayload,
                privateKey: key
            ).base64EncodedString()
        )
        var request = grant.wire(authority: HermesRealtimeRelayAuthorityEnvelope(
            peerNodeId: peerNodeID,
            counter: counter,
            timestamp: now,
            intentHashBlake3: "pending",
            signatureEd25519: "pending",
            keyKind: .ed25519
        ))
        let signed = try signer.sign(
            request: request,
            peerNodeId: peerNodeID,
            counter: counter,
            timestamp: now,
            privateKey: key
        )
        request.authority = HermesRealtimeRelayAuthorityEnvelope(
            peerNodeId: signed.peerNodeId,
            counter: signed.counter,
            timestamp: signed.timestamp,
            intentHashBlake3: signed.intentHashHex,
            signatureEd25519: signed.signatureBase64,
            keyKind: .ed25519
        )
        return Fixture(key: key, peerNodeID: peerNodeID, now: now, request: request)
    }

    private func makeVerifier(
        fixture: Fixture,
        proofConsumptions: Locked<Int> = Locked(0),
        replayCounterStore: DaemonComputerUseApprovalReplayCounterStore = DaemonComputerUseApprovalReplayCounterStore()
    ) -> DaemonComputerUseSessionGrantAuthorityVerifier {
        let pinnedKey = PhoneControlVerifyingKey.ed25519(fixture.key.publicKey)
        let localProofVerifier = DaemonLocalAuthProofVerifier(
            resolvePinnedKey: { deviceID in
                deviceID == "android-device-1" ? pinnedKey : nil
            },
            consumeProof: { _, _ in
                proofConsumptions.withLock { $0 += 1 }
                return true
            }
        )
        return DaemonComputerUseSessionGrantAuthorityVerifier(
            resolvePinnedKey: { peerNodeID in
                peerNodeID == fixture.peerNodeID ? pinnedKey : nil
            },
            localAuthProofVerifier: localProofVerifier,
            replayCounterStore: replayCounterStore
        )
    }

    private func assertRejected(
        _ request: HermesRealtimeRelayAgentGrantRequest,
        fixture: Fixture,
        verifier: DaemonComputerUseSessionGrantAuthorityVerifier,
        now: Date? = nil,
        expected: DaemonComputerUseSessionGrantAuthorityVerifier.VerificationFailure
    ) async throws {
        do {
            try await verifier.verify(
                request,
                expectedAuthorityPeerNodeID: fixture.peerNodeID,
                now: now ?? fixture.now
            )
            XCTFail("expected \(expected) rejection")
        } catch let failure as DaemonComputerUseSessionGrantAuthorityVerifier.VerificationFailure {
            XCTAssertEqual(failure, expected)
        }
    }
}
