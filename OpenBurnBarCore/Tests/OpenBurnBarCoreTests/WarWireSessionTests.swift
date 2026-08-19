import XCTest
@testable import OpenBurnBarKernel

/// The session is where "fail closed" stops being a slogan. These pin that no
/// path reaches `.ready` without the gate allowing it and the peer proving who
/// it is, and that every terminal path hands the caller a Firestore fallback.
final class WarWireSessionTests: XCTestCase {

    private let local = "mac-a"
    private let remote = "mac-b"

    private func session(localID: String = "mac-a", remoteID: String = "mac-b") -> WarWireSession {
        WarWireSession(
            localBodyID: localID,
            remoteBodyID: remoteID,
            localDisplayName: "Studio",
            uid: "uid-1",
            connectionID: "conn-1"
        )
    }

    private func grant(_ state: WarWireGrant.State = .active) -> WarWireGrant {
        WarWireGrant(bodyIDA: local, bodyIDB: remote, state: state)
    }

    private func peerHello(
        bodyID: String = "mac-b",
        pairID: String? = nil
    ) -> WarWireHello {
        WarWireHello(
            bodyID: bodyID,
            displayName: "Mini",
            capabilities: [WarWireFrameCodec.capability],
            pairID: pairID ?? WarWireGrant.pairID(local, remote)
        )
    }

    private func openAllowed(_ session: inout WarWireSession) -> [WarWireSession.Action] {
        session.open(tier: .pro, killSwitchEngaged: false, grant: grant())
    }

    // MARK: - The happy path

    func test_openSendsHelloAndWaits() {
        var session = session()
        let actions = openAllowed(&session)
        XCTAssertEqual(session.state, .awaitingAck)
        guard case let .send(frame) = actions.first else {
            XCTFail("expected a hello")
            return
        }
        XCTAssertEqual(frame.type, .warHello)
        XCTAssertEqual(frame.war?.pairId, WarWireGrant.pairID(local, remote))
    }

    func test_helloAckFromTheDialledMachineOpensTheWire() {
        var session = session()
        _ = openAllowed(&session)
        XCTAssertTrue(session.receive(.helloAck(peerHello())).isEmpty)
        XCTAssertEqual(session.state, .ready)
        XCTAssertTrue(session.isReady)
    }

    func test_readySessionDeliversWork() {
        var session = session()
        _ = openAllowed(&session)
        _ = session.receive(.helloAck(peerHello()))
        let event = WarWireEvent.streamChunk(runID: "run-1", sequence: 0, text: "hi")
        XCTAssertEqual(session.receive(event), [.deliver(event)])
    }

    /// The chunk ordinal is monotonic per run: a duplicate or reordered chunk
    /// is dropped rather than spliced into the output out of order.
    func test_staleAndDuplicateStreamChunksAreDropped() {
        var session = session()
        _ = openAllowed(&session)
        _ = session.receive(.helloAck(peerHello()))

        let first = WarWireEvent.streamChunk(runID: "run-1", sequence: 1, text: "a")
        let second = WarWireEvent.streamChunk(runID: "run-1", sequence: 2, text: "b")
        XCTAssertEqual(session.receive(first), [.deliver(first)])
        XCTAssertEqual(session.receive(second), [.deliver(second)])

        XCTAssertEqual(session.receive(.streamChunk(runID: "run-1", sequence: 2, text: "b")), [])
        XCTAssertEqual(session.receive(.streamChunk(runID: "run-1", sequence: 1, text: "a")), [])

        let next = WarWireEvent.streamChunk(runID: "run-1", sequence: 3, text: "c")
        XCTAssertEqual(session.receive(next), [.deliver(next)], "the lane recovers once order resumes")
    }

    /// Runs order independently — a slow run cannot hold back a fast one.
    func test_chunkOrderingIsTrackedPerRun() {
        var session = session()
        _ = openAllowed(&session)
        _ = session.receive(.helloAck(peerHello()))

        _ = session.receive(.streamChunk(runID: "run-1", sequence: 5, text: "late run"))
        let other = WarWireEvent.streamChunk(runID: "run-2", sequence: 0, text: "fresh run")
        XCTAssertEqual(session.receive(other), [.deliver(other)])
    }

    func test_answeringSideAcceptsAndBecomesReady() {
        var session = session(localID: remote, remoteID: local)
        let actions = session.accept(
            peerHello(bodyID: local),
            tier: .ultra,
            killSwitchEngaged: false,
            grant: grant()
        )
        XCTAssertEqual(session.state, .ready)
        guard case let .send(frame) = actions.first else {
            XCTFail("expected a hello ack")
            return
        }
        XCTAssertEqual(frame.type, .warHelloAck)
    }

    // MARK: - Refusing before the network

    /// A refusal must cost nothing: no frame leaves the machine.
    func test_killSwitchRefusesWithoutDialing() {
        var session = session()
        let actions = session.open(tier: .ultra, killSwitchEngaged: true, grant: grant())
        XCTAssertEqual(actions, [.fallBackToFirestore(.refusedLocally(.killSwitch))])
        XCTAssertEqual(session.state, .closed(.refusedLocally(.killSwitch)))
    }

    func test_belowProRefusesWithoutDialing() {
        var session = session()
        let actions = session.open(tier: .cloud, killSwitchEngaged: false, grant: grant())
        XCTAssertEqual(actions, [.fallBackToFirestore(.refusedLocally(.entitlement))])
    }

    func test_missingGrantRefusesWithoutDialing() {
        var session = session()
        let actions = session.open(tier: .pro, killSwitchEngaged: false, grant: nil)
        XCTAssertEqual(actions, [.fallBackToFirestore(.refusedLocally(.noGrant))])
    }

    func test_revokedGrantRefusesWithoutDialing() {
        var session = session()
        let actions = session.open(tier: .pro, killSwitchEngaged: false, grant: grant(.revoked))
        XCTAssertEqual(actions, [.fallBackToFirestore(.refusedLocally(.grantRevoked))])
    }

    func test_selfDialRefuses() {
        var session = session(localID: local, remoteID: local)
        let actions = session.open(
            tier: .pro,
            killSwitchEngaged: false,
            grant: WarWireGrant(bodyIDA: local, bodyIDB: local, state: .active)
        )
        XCTAssertEqual(actions, [.fallBackToFirestore(.refusedLocally(.selfDial))])
    }

    /// Consent revoked on the answering machine must refuse the session even
    /// when the dialer still believes it holds a grant.
    func test_answererRefusesWhenItsOwnGrantIsRevoked() {
        var session = session(localID: remote, remoteID: local)
        let actions = session.accept(
            peerHello(bodyID: local),
            tier: .pro,
            killSwitchEngaged: false,
            grant: grant(.revoked)
        )
        XCTAssertEqual(session.state, .closed(.refusedLocally(.grantRevoked)))
        guard case let .send(frame) = actions.first else {
            XCTFail("expected a denial frame")
            return
        }
        XCTAssertEqual(frame.type, .warDenied)
        XCTAssertEqual(frame.war?.denialReason, .grantRevoked)
        XCTAssertEqual(actions.last, .fallBackToFirestore(.refusedLocally(.grantRevoked)))
    }

    // MARK: - Identity

    func test_ackFromAnotherMachineIsRejected() {
        var session = session()
        _ = openAllowed(&session)
        let actions = session.receive(.helloAck(peerHello(bodyID: "mac-intruder")))
        XCTAssertEqual(actions, [.fallBackToFirestore(.peerIdentityMismatch)])
        XCTAssertFalse(session.isReady)
    }

    /// The pair id is re-derived, never trusted, so a forged one is refused
    /// even when the body id matches.
    func test_ackWithAForgedPairIDIsRejected() {
        var session = session()
        _ = openAllowed(&session)
        let actions = session.receive(.helloAck(peerHello(pairID: "mac-a__mac-zzz")))
        XCTAssertEqual(actions, [.fallBackToFirestore(.peerIdentityMismatch)])
    }

    func test_answererRejectsAHelloClaimingTheWrongPair() {
        var session = session(localID: remote, remoteID: local)
        let actions = session.accept(
            peerHello(bodyID: local, pairID: "bogus__pair"),
            tier: .pro,
            killSwitchEngaged: false,
            grant: grant()
        )
        XCTAssertEqual(session.state, .closed(.peerIdentityMismatch))
        XCTAssertEqual(actions.last, .fallBackToFirestore(.peerIdentityMismatch))
    }

    // MARK: - Ordering

    /// Nothing may flow before the handshake completes.
    func test_workBeforeTheAckIsAProtocolViolation() {
        var session = session()
        _ = openAllowed(&session)
        let actions = session.receive(.streamChunk(runID: "run-1", sequence: 0, text: "early"))
        XCTAssertEqual(actions, [.fallBackToFirestore(.protocolViolation)])
    }

    func test_secondHandshakeOnALiveSessionIsAProtocolViolation() {
        var session = session()
        _ = openAllowed(&session)
        _ = session.receive(.helloAck(peerHello()))
        XCTAssertEqual(
            session.receive(.helloAck(peerHello())),
            [.fallBackToFirestore(.protocolViolation)]
        )
    }

    func test_peerDenialClosesAndFallsBack() {
        var session = session()
        _ = openAllowed(&session)
        let actions = session.receive(.denied(.grantRevoked, message: nil))
        XCTAssertEqual(actions, [.fallBackToFirestore(.refusedByPeer(.grantRevoked))])
        XCTAssertEqual(session.state, .closed(.refusedByPeer(.grantRevoked)))
    }

    func test_peerDenialMidSessionAlsoFallsBack() {
        var session = session()
        _ = openAllowed(&session)
        _ = session.receive(.helloAck(peerHello()))
        XCTAssertEqual(
            session.receive(.denied(.killSwitch, message: nil)),
            [.fallBackToFirestore(.refusedByPeer(.killSwitch))]
        )
    }

    func test_transportLossFallsBack() {
        var session = session()
        _ = openAllowed(&session)
        XCTAssertEqual(session.transportFailed(), [.fallBackToFirestore(.transportLost)])
    }

    func test_closedSessionIgnoresFurtherFrames() {
        var session = session()
        _ = openAllowed(&session)
        _ = session.transportFailed()
        XCTAssertTrue(session.receive(.helloAck(peerHello())).isEmpty)
    }

    func test_openIsIgnoredOnceTheSessionHasMoved() {
        var session = session()
        _ = openAllowed(&session)
        XCTAssertTrue(openAllowed(&session).isEmpty, "a second open must not re-dial")
    }

    // MARK: - Outbound gating

    /// Work must not leak onto a session that has not been verified.
    func test_noWorkFramesBeforeReady() {
        var session = session()
        XCTAssertNil(session.fleetSnapshotFrame([]))
        _ = openAllowed(&session)
        XCTAssertNil(session.fleetSnapshotFrame([]), "still unverified while awaiting the ack")
        XCTAssertNil(session.dispatchFrame(
            HermesRealtimeRelayWarDispatchRequest(dispatchId: "d", instruction: "go")
        ))
    }

    func test_workFramesAreAvailableOnceReady() {
        var session = session()
        _ = openAllowed(&session)
        _ = session.receive(.helloAck(peerHello()))
        XCTAssertEqual(session.fleetSnapshotFrame([])?.type, .warFleetSnapshot)
        XCTAssertEqual(
            session.dispatchFrame(
                HermesRealtimeRelayWarDispatchRequest(dispatchId: "d", instruction: "go")
            )?.type,
            .warDispatch
        )
    }

    func test_closureExposesTheDenialReasonForLogging() {
        XCTAssertEqual(WarWireSession.Closure.refusedLocally(.killSwitch).denialReason, .killSwitch)
        XCTAssertEqual(WarWireSession.Closure.refusedByPeer(.noGrant).denialReason, .noGrant)
        XCTAssertNil(WarWireSession.Closure.transportLost.denialReason)
        XCTAssertNil(WarWireSession.Closure.peerIdentityMismatch.denialReason)
    }

    func test_pairIDIsOrderIndependent() {
        XCTAssertEqual(
            session(localID: "mac-a", remoteID: "mac-b").pairID,
            session(localID: "mac-b", remoteID: "mac-a").pairID
        )
    }
}
