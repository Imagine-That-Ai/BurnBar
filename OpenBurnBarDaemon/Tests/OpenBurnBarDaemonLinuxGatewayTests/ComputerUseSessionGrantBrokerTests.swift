import Foundation
import OpenBurnBarComputerUseCore
import OpenBurnBarEngine
import XCTest
@testable import OpenBurnBarDaemon

final class ComputerUseSessionGrantBrokerTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_100_000)

    func testPublishesExactChallengeAndConsumesVerifiedGrantOnce() async throws {
        let published = PublishedFrames()
        let validations = SynchronousBox<Int>(0)
        let broker = makeBroker(
            published: published,
            prevalidate: { request, peer, now in
                XCTAssertEqual(peer, "phone-authority-1")
                XCTAssertEqual(request.authority.peerNodeId, peer)
                XCTAssertEqual(now, self.now)
                validations.withValue { $0 += 1 }
            }
        )
        let request = sessionRequest()

        let acquired = try await broker.acquire(metadata: metadata(), request: request, now: now)
        XCTAssertEqual(acquired.state, .awaitingPhone)
        let firstPublication = await published.first()
        let publication = try XCTUnwrap(firstPublication)
        XCTAssertEqual(publication.peerNodeID, "phone-transport-1")
        XCTAssertEqual(publication.frame.type, .controlSessionGrantChallenge)
        XCTAssertEqual(publication.frame.requestId, acquired.challengeID)
        let challenge = try XCTUnwrap(publication.frame.control?.sessionGrantChallenge)
        XCTAssertEqual(challenge.sessionIntentId, acquired.sessionIntentID)
        XCTAssertEqual(challenge.capabilities, ["desktop_browser", "desktop_screenshot"])
        XCTAssertEqual(challenge.trustMode, ComputerUseTrustMode.step.rawValue)
        XCTAssertEqual(try nonceBytes(challenge.nonce).count, 32)

        let proof = localAuthProof(intentHash: "signed-grant-intent")
        let wire = try signedGrant(challenge: challenge, proof: proof)
        try await broker.ingest(wire, authenticatedTransportPeerNodeID: "phone-transport-1", now: now)
        let readyStatus = await broker.status(challengeID: acquired.challengeID, now: now)
        XCTAssertEqual(readyStatus?.state, .ready)

        let consumableRequest = sessionRequest(grantChallengeID: acquired.challengeID)
        let preview = try await broker.prepare(
            challengeID: acquired.challengeID,
            request: consumableRequest,
            now: now
        )
        XCTAssertEqual(preview.request.localAuthProof, proof)
        let stillReadyStatus = await broker.status(challengeID: acquired.challengeID, now: now)
        XCTAssertEqual(stillReadyStatus?.state, .ready)

        let prepared = try await broker.prepareAndConsume(
            challengeID: acquired.challengeID,
            request: consumableRequest,
            now: now
        )
        XCTAssertEqual(prepared.request.localAuthProof, proof)
        XCTAssertEqual(prepared.request.sourceDeviceId, "phone-device-1")
        XCTAssertEqual(prepared.request.intentHashHex, "signed-grant-intent")
        XCTAssertEqual(prepared.request.localAuthGrantBinding?.clientIntentId, acquired.sessionIntentID)
        XCTAssertEqual(prepared.request.localAuthGrantBinding?.capabilities, challenge.capabilities)
        XCTAssertEqual(validations.value, 1)
        let consumedStatus = await broker.status(challengeID: acquired.challengeID, now: now)
        XCTAssertEqual(consumedStatus?.state, .consumed)

        await assertBrokerError(.alreadyConsumed) {
            _ = try await broker.prepareAndConsume(
                challengeID: acquired.challengeID,
                request: self.sessionRequest(grantChallengeID: acquired.challengeID),
                now: self.now
            )
        }
    }

    func testRejectsWrongPeerWithoutBurningChallenge() async throws {
        let published = PublishedFrames()
        let broker = makeBroker(published: published)
        let acquired = try await broker.acquire(metadata: metadata(), request: sessionRequest(), now: now)
        let firstPublication = await published.first()
        let challenge = try XCTUnwrap(firstPublication?.frame.control?.sessionGrantChallenge)
        let wire = try signedGrant(challenge: challenge)

        await assertBrokerError(.wrongAuthenticatedPeer) {
            try await broker.ingest(wire, authenticatedTransportPeerNodeID: "attacker-peer", now: self.now)
        }
        var wrongAuthority = wire
        wrongAuthority.authority.peerNodeId = "attacker-authority"
        await assertBrokerError(.wrongAuthenticatedPeer) {
            try await broker.ingest(
                wrongAuthority,
                authenticatedTransportPeerNodeID: "phone-transport-1",
                now: self.now
            )
        }
        try await broker.ingest(wire, authenticatedTransportPeerNodeID: "phone-transport-1", now: now)
        let status = await broker.status(challengeID: acquired.challengeID, now: now)
        XCTAssertEqual(status?.state, .ready)
    }

    func testRejectsFieldMismatchWithoutCallingProofValidator() async throws {
        let published = PublishedFrames()
        let validations = SynchronousBox<Int>(0)
        let broker = makeBroker(published: published, prevalidate: { _, _, _ in
            validations.withValue { $0 += 1 }
        })
        _ = try await broker.acquire(metadata: metadata(), request: sessionRequest(), now: now)
        let firstPublication = await published.first()
        let challenge = try XCTUnwrap(firstPublication?.frame.control?.sessionGrantChallenge)
        var mismatched = try signedGrant(challenge: challenge)
        mismatched.capabilities.append("workspace_read")

        await assertBrokerError(.grantMismatch(field: "capabilities")) {
            try await broker.ingest(mismatched, authenticatedTransportPeerNodeID: "phone-transport-1", now: self.now)
        }
        XCTAssertEqual(validations.value, 0)
    }

    func testForgedProofFailsClosedAndLegitimateRetryCanSucceed() async throws {
        let published = PublishedFrames()
        let broker = makeBroker(published: published, prevalidate: { request, _, _ in
            if request.authority.signatureEd25519 == "forged" { throw TestFailure.forged }
        })
        let acquired = try await broker.acquire(metadata: metadata(), request: sessionRequest(), now: now)
        let firstPublication = await published.first()
        let challenge = try XCTUnwrap(firstPublication?.frame.control?.sessionGrantChallenge)
        var forged = try signedGrant(challenge: challenge)
        forged.authority.signatureEd25519 = "forged"

        await assertBrokerError(.proofRejected) {
            try await broker.ingest(forged, authenticatedTransportPeerNodeID: "phone-transport-1", now: self.now)
        }
        let status = await broker.status(challengeID: acquired.challengeID, now: now)
        XCTAssertEqual(status?.state, .awaitingPhone)
        try await broker.ingest(
            signedGrant(challenge: challenge),
            authenticatedTransportPeerNodeID: "phone-transport-1",
            now: now
        )
    }

    func testSuspendedPrevalidationCannotResurrectExpiredChallenge() async throws {
        let published = PublishedFrames()
        let validationGate = SuspendedGrantPrevalidator()
        let clock = SynchronousBox(now)
        let broker = ComputerUseSessionGrantBroker(
            publisher: { peer, frame in await published.append(peerNodeID: peer, frame: frame) },
            prevalidatePinnedPhoneGrant: { _, _, _ in await validationGate.validate() },
            randomBytes: { count in Data(repeating: 8, count: count) },
            challengeIDGenerator: { "challenge-suspended-validation" },
            clock: { clock.value },
            challengeLifetime: 1,
            terminalRetention: 0
        )
        let acquired = try await broker.acquire(metadata: metadata(), request: sessionRequest(), now: now)
        let firstPublication = await published.first()
        let publication = try XCTUnwrap(firstPublication)
        let challenge = try XCTUnwrap(publication.frame.control?.sessionGrantChallenge)
        let wire = try signedGrant(challenge: challenge)
        let ingestTask = Task {
            try await broker.ingest(
                wire,
                authenticatedTransportPeerNodeID: "phone-transport-1",
                now: self.now
            )
        }
        for _ in 0..<100 where await validationGate.hasRequest() == false {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let validationStarted = await validationGate.hasRequest()
        XCTAssertTrue(validationStarted)

        let expiredNow = now.addingTimeInterval(2)
        clock.withValue { $0 = expiredNow }
        let removed = await broker.status(challengeID: acquired.challengeID, now: expiredNow)
        XCTAssertNil(removed)
        await validationGate.release()
        do {
            try await ingestTask.value
            XCTFail("Expired challenge must not be restored after suspended validation")
        } catch {
            XCTAssertEqual(error as? ComputerUseSessionGrantBroker.BrokerError, .challengeNotFound)
        }
        let status = await broker.status(challengeID: acquired.challengeID, now: expiredNow)
        XCTAssertNil(status)
    }

    func testReplayIsRejectedBeforeAndAfterConsume() async throws {
        let published = PublishedFrames()
        let broker = makeBroker(published: published)
        let request = sessionRequest()
        let acquired = try await broker.acquire(metadata: metadata(), request: request, now: now)
        let firstPublication = await published.first()
        let challenge = try XCTUnwrap(firstPublication?.frame.control?.sessionGrantChallenge)
        let wire = try signedGrant(challenge: challenge)
        try await broker.ingest(wire, authenticatedTransportPeerNodeID: "phone-transport-1", now: now)

        await assertBrokerError(.grantNotReady) {
            try await broker.ingest(wire, authenticatedTransportPeerNodeID: "phone-transport-1", now: self.now)
        }
        _ = try await broker.prepareAndConsume(
            challengeID: acquired.challengeID,
            request: sessionRequest(grantChallengeID: acquired.challengeID),
            now: now
        )
        await assertBrokerError(.alreadyConsumed) {
            try await broker.ingest(wire, authenticatedTransportPeerNodeID: "phone-transport-1", now: self.now)
        }
    }

    func testExpiryWipesReadyGrantAndPreventsConsume() async throws {
        let published = PublishedFrames()
        let broker = makeBroker(published: published)
        let request = sessionRequest()
        let acquired = try await broker.acquire(metadata: metadata(), request: request, now: now)
        let firstPublication = await published.first()
        let challenge = try XCTUnwrap(firstPublication?.frame.control?.sessionGrantChallenge)
        try await broker.ingest(
            signedGrant(challenge: challenge),
            authenticatedTransportPeerNodeID: "phone-transport-1",
            now: now
        )
        let expiredNow = now.addingTimeInterval(301)

        let status = await broker.status(challengeID: acquired.challengeID, now: expiredNow)
        XCTAssertEqual(status?.state, .expired)
        await assertBrokerError(.challengeExpired) {
            _ = try await broker.prepareAndConsume(
                challengeID: acquired.challengeID,
                request: self.sessionRequest(grantChallengeID: acquired.challengeID),
                now: expiredNow
            )
        }
    }

    func testUnavailableTransportAndProofValidatorFailClosed() async throws {
        let unavailable = ComputerUseSessionGrantBroker(
            randomBytes: { _ in Data(repeating: 7, count: 32) },
            challengeIDGenerator: { "challenge-unavailable" }
        )
        await assertBrokerError(.transportUnavailable) {
            _ = try await unavailable.acquire(
                metadata: self.metadata(),
                request: self.sessionRequest(),
                now: self.now
            )
        }

        let published = PublishedFrames()
        let noValidator = makeBroker(published: published, prevalidate: nil)
        _ = try await noValidator.acquire(metadata: metadata(), request: sessionRequest(), now: now)
        let firstPublication = await published.first()
        let challenge = try XCTUnwrap(firstPublication?.frame.control?.sessionGrantChallenge)
        await assertBrokerError(.proofValidatorUnavailable) {
            try await noValidator.ingest(
                self.signedGrant(challenge: challenge),
                authenticatedTransportPeerNodeID: "phone-transport-1",
                now: self.now
            )
        }
    }

    func testRendererProofFieldsAndChangedConsumeRequestAreRejected() async throws {
        let published = PublishedFrames()
        let broker = makeBroker(published: published)
        let injected = sessionRequest(localAuthProof: localAuthProof(intentHash: "renderer"))
        await assertBrokerError(.rendererProofFieldsRejected) {
            _ = try await broker.acquire(metadata: self.metadata(), request: injected, now: self.now)
        }
        await assertBrokerError(.sessionRequestMismatch) {
            _ = try await broker.acquire(
                metadata: self.metadata(),
                request: self.sessionRequest(grantChallengeID: "renderer-challenge"),
                now: self.now
            )
        }

        let original = sessionRequest()
        let acquired = try await broker.acquire(metadata: metadata(), request: original, now: now)
        let firstPublication = await published.first()
        let challenge = try XCTUnwrap(firstPublication?.frame.control?.sessionGrantChallenge)
        try await broker.ingest(
            signedGrant(challenge: challenge),
            authenticatedTransportPeerNodeID: "phone-transport-1",
            now: now
        )
        let changed = sessionRequest(actionCap: 51, grantChallengeID: acquired.challengeID)
        await assertBrokerError(.sessionRequestMismatch) {
            _ = try await broker.prepareAndConsume(
                challengeID: acquired.challengeID,
                request: changed,
                now: self.now
            )
        }
        _ = try await broker.prepareAndConsume(
            challengeID: acquired.challengeID,
            request: sessionRequest(grantChallengeID: acquired.challengeID),
            now: now
        )
    }

    func testRecordBoundFailsClosedAndExpiryCleanupReleasesCapacity() async throws {
        let published = PublishedFrames()
        let challengeSequence = SynchronousBox<Int>(0)
        let broker = ComputerUseSessionGrantBroker(
            publisher: { peer, frame in await published.append(peerNodeID: peer, frame: frame) },
            prevalidatePinnedPhoneGrant: { _, _, _ in },
            randomBytes: { count in Data(repeating: 9, count: count) },
            challengeIDGenerator: {
                challengeSequence.withValue { $0 += 1 }
                return "challenge-capacity-\(challengeSequence.value)"
            },
            terminalRetention: 0,
            maximumRecords: 1
        )
        let first = try await broker.acquire(metadata: metadata(), request: sessionRequest(), now: now)

        await assertBrokerError(.capacityExceeded) {
            _ = try await broker.acquire(
                metadata: self.metadata(),
                request: self.sessionRequest(actionCap: 51),
                now: self.now
            )
        }
        let removed = await broker.status(
            challengeID: first.challengeID,
            now: now.addingTimeInterval(301)
        )
        XCTAssertNil(removed)
        let second = try await broker.acquire(
            metadata: metadata(),
            request: sessionRequest(actionCap: 51),
            now: now.addingTimeInterval(301)
        )
        XCTAssertNotEqual(first.challengeID, second.challengeID)
    }

    func testConcurrentStartReservationIsTokenBoundAndNonReusable() async throws {
        let published = PublishedFrames()
        let broker = makeBroker(published: published)
        let acquired = try await broker.acquire(metadata: metadata(), request: sessionRequest(), now: now)
        let pendingPublication = await published.first()
        let publication = try XCTUnwrap(pendingPublication)
        let challenge = try XCTUnwrap(publication.frame.control?.sessionGrantChallenge)
        try await broker.ingest(
            signedGrant(challenge: challenge),
            authenticatedTransportPeerNodeID: "phone-transport-1",
            now: now
        )
        let request = sessionRequest(grantChallengeID: acquired.challengeID)
        let first = try await broker.reserveForStart(
            challengeID: acquired.challengeID,
            request: request,
            now: now
        )
        let starting = await broker.status(challengeID: acquired.challengeID, now: now)
        XCTAssertEqual(starting?.state, .starting)

        await assertBrokerError(.grantNotReady) {
            _ = try await broker.reserveForStart(
                challengeID: acquired.challengeID,
                request: request,
                now: self.now
            )
        }
        let consumedAmbiguousStart = await broker.consumeAfterAmbiguousStart(first, now: now)
        XCTAssertTrue(consumedAmbiguousStart)
        let restoredConsumedReservation = await broker.restoreAfterDefiniteStartFailure(first, now: now)
        XCTAssertFalse(restoredConsumedReservation)
        let consumed = await broker.status(challengeID: acquired.challengeID, now: now)
        XCTAssertEqual(consumed?.state, .consumed)
    }

    func testDefiniteStartFailureRestoresReadyForOneFreshRetry() async throws {
        let published = PublishedFrames()
        let broker = makeBroker(published: published)
        let acquired = try await broker.acquire(metadata: metadata(), request: sessionRequest(), now: now)
        let pendingPublication = await published.first()
        let publication = try XCTUnwrap(pendingPublication)
        let challenge = try XCTUnwrap(publication.frame.control?.sessionGrantChallenge)
        try await broker.ingest(
            signedGrant(challenge: challenge),
            authenticatedTransportPeerNodeID: "phone-transport-1",
            now: now
        )
        let request = sessionRequest(grantChallengeID: acquired.challengeID)
        let failedAttempt = try await broker.reserveForStart(
            challengeID: acquired.challengeID,
            request: request,
            now: now
        )
        let restoredFailedAttempt = await broker.restoreAfterDefiniteStartFailure(failedAttempt, now: now)
        XCTAssertTrue(restoredFailedAttempt)
        let ready = await broker.status(challengeID: acquired.challengeID, now: now)
        XCTAssertEqual(ready?.state, .ready)

        let retry = try await broker.reserveForStart(
            challengeID: acquired.challengeID,
            request: request,
            now: now
        )
        let consumedStaleReservation = await broker.consumeAfterAmbiguousStart(failedAttempt, now: now)
        XCTAssertFalse(consumedStaleReservation)
        try await broker.commitStartedSession(retry, now: now)
        let consumed = await broker.status(challengeID: acquired.challengeID, now: now)
        XCTAssertEqual(consumed?.state, .consumed)
    }

    func testStartingExpiryBecomesConsumedBeforeTerminalCleanup() async throws {
        let published = PublishedFrames()
        let broker = ComputerUseSessionGrantBroker(
            publisher: { peer, frame in await published.append(peerNodeID: peer, frame: frame) },
            prevalidatePinnedPhoneGrant: { _, _, _ in },
            randomBytes: { count in Data(repeating: 4, count: count) },
            challengeIDGenerator: { "challenge-starting-expiry" },
            clock: { self.now },
            terminalRetention: 10
        )
        let acquired = try await broker.acquire(metadata: metadata(), request: sessionRequest(), now: now)
        let pendingPublication = await published.first()
        let publication = try XCTUnwrap(pendingPublication)
        let challenge = try XCTUnwrap(publication.frame.control?.sessionGrantChallenge)
        try await broker.ingest(
            signedGrant(challenge: challenge),
            authenticatedTransportPeerNodeID: "phone-transport-1",
            now: now
        )
        let reservation = try await broker.reserveForStart(
            challengeID: acquired.challengeID,
            request: sessionRequest(grantChallengeID: acquired.challengeID),
            now: now
        )

        let terminalNow = now.addingTimeInterval(301)
        let terminal = await broker.status(challengeID: acquired.challengeID, now: terminalNow)
        XCTAssertEqual(terminal?.state, .consumed)
        let restoredExpiredReservation = await broker.restoreAfterDefiniteStartFailure(
            reservation,
            now: terminalNow
        )
        XCTAssertFalse(restoredExpiredReservation)
        await assertBrokerError(.challengeExpired) {
            _ = try await broker.prepare(
                challengeID: acquired.challengeID,
                request: self.sessionRequest(grantChallengeID: acquired.challengeID),
                now: terminalNow
            )
        }
        let removed = await broker.status(
            challengeID: acquired.challengeID,
            now: terminalNow.addingTimeInterval(10)
        )
        XCTAssertNil(removed)
    }

    private func makeBroker(
        published: PublishedFrames,
        prevalidate: ComputerUseSessionGrantBroker.PinnedPhoneGrantPrevalidator? = { _, _, _ in }
    ) -> ComputerUseSessionGrantBroker {
        ComputerUseSessionGrantBroker(
            publisher: { peer, frame in await published.append(peerNodeID: peer, frame: frame) },
            prevalidatePinnedPhoneGrant: prevalidate,
            randomBytes: { count in Data((0..<count).map { UInt8($0) }) },
            challengeIDGenerator: { "challenge-broker-0001" },
            clock: { self.now }
        )
    }

    private func metadata() -> ComputerUseSessionGrantBroker.AcquisitionMetadata {
        .init(
            uid: "user-1",
            connectionID: "connection-1",
            transportPeerNodeID: "phone-transport-1",
            authorityPeerNodeID: "phone-authority-1",
            sourceDeviceID: "phone-device-1",
            runtimeID: .codex,
            threadID: "thread-1",
            preset: .desktop,
            capabilities: [.desktopBrowser, .desktopScreenshot]
        )
    }

    private func sessionRequest(
        actionCap: Int = 50,
        grantChallengeID: String? = nil,
        localAuthProof: HermesRealtimeRelayAgentGrantLocalAuthProof? = nil
    ) -> ComputerUseSessionStartRequest {
        ComputerUseSessionStartRequest(
            mode: ComputerUseMode.browser.rawValue,
            trustMode: ComputerUseTrustMode.step.rawValue,
            scopeRuleIds: ["workspace-only"],
            phoneViewerNodeId: "phone-transport-1",
            macHostNodeId: "linux-host-1",
            actionCap: actionCap,
            sessionTimeoutSeconds: 1_800,
            clientID: BurnBarClientID(rawValue: "linux-desktop"),
            runID: BurnBarRunID(rawValue: "run-1"),
            runCallID: "call-1",
            runGeneration: 3,
            grantChallengeId: grantChallengeID,
            desktopOwnerAuthorizationRequest: .init(method: .linuxDesktopOwner),
            localAuthProof: localAuthProof,
            sourceDeviceId: localAuthProof?.deviceId,
            intentHashHex: localAuthProof?.signedIntentHash
        )
    }

    private func signedGrant(
        challenge: HermesRealtimeRelaySessionGrantChallenge,
        proof: HermesRealtimeRelayAgentGrantLocalAuthProof? = nil
    ) throws -> HermesRealtimeRelayAgentGrantRequest {
        var request = try AgentCapabilityGrantRequest(
            validatedSessionChallenge: challenge,
            sourceDeviceID: "phone-device-1",
            localAuthenticationSatisfied: proof != nil,
            now: now
        )
        request.localAuthProof = proof
        return request.wire(authority: HermesRealtimeRelayAuthorityEnvelope(
            peerNodeId: "phone-authority-1",
            counter: 1,
            timestamp: now,
            intentHashBlake3: proof?.signedIntentHash ?? "signed-grant-intent",
            signatureEd25519: "valid-signature"
        ))
    }

    private func localAuthProof(intentHash: String) -> HermesRealtimeRelayAgentGrantLocalAuthProof {
        HermesRealtimeRelayAgentGrantLocalAuthProof(
            proofId: "proof-1",
            deviceId: "phone-device-1",
            signedIntentHash: intentHash,
            authenticatedAt: now,
            expiresAt: now.addingTimeInterval(300),
            signatureEd25519: "proof-signature"
        )
    }

    private func nonceBytes(_ nonce: String) throws -> Data {
        var base64 = nonce.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return try XCTUnwrap(Data(base64Encoded: base64))
    }

    private func assertBrokerError(
        _ expected: ComputerUseSessionGrantBroker.BrokerError,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected broker error \(expected)")
        } catch {
            XCTAssertEqual(error as? ComputerUseSessionGrantBroker.BrokerError, expected)
        }
    }
}

private enum TestFailure: Error {
    case forged
}

private actor SuspendedGrantPrevalidator {
    private var requested = false
    private var continuation: CheckedContinuation<Void, Never>?

    func validate() async {
        requested = true
        await withCheckedContinuation { continuation = $0 }
    }

    func hasRequest() -> Bool { requested }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor PublishedFrames {
    struct Publication: Sendable {
        let peerNodeID: String
        let frame: HermesRealtimeRelayFrame
    }

    private var values: [Publication] = []

    func append(peerNodeID: String, frame: HermesRealtimeRelayFrame) {
        values.append(Publication(peerNodeID: peerNodeID, frame: frame))
    }

    func first() -> Publication? {
        values.first
    }
}

private final class SynchronousBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        self.stored = value
    }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func withValue(_ body: (inout Value) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body(&stored)
    }
}
