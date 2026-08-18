import XCTest
@testable import OpenBurnBarIrohRelay
import OpenBurnBarKernel

/// Two Macs, one in-process iroh rendezvous. These drive the Wire end to end
/// over a real transport rather than a mock, so the handshake, the refusal
/// paths, and the fallback all get exercised as they will run in the field.
final class WarWireDialerTests: XCTestCase {

    private let dialerBody = "mac-studio"
    private let answererBody = "mac-mini"

    private func credentials(
        bodyID: String,
        tier: CloudTier = .pro,
        killSwitch: Bool = false
    ) -> WarWireCredentials {
        WarWireCredentials(
            localBodyID: bodyID,
            localDisplayName: bodyID == dialerBody ? "Studio" : "Mini",
            uid: "uid-1",
            connectionID: "conn-1",
            tier: tier,
            killSwitchEngaged: killSwitch
        )
    }

    private func activeGrant() -> WarWireGrant {
        WarWireGrant(bodyIDA: dialerBody, bodyIDB: answererBody, state: .active)
    }

    /// Stands up both endpoints and serves one inbound Wire dial.
    private func makePair(
        answererCredentials: WarWireCredentials,
        answererGrant: WarWireGrant?
    ) async throws -> (
        dialTransport: LoopbackIrohRelayTransport,
        target: IrohDialTarget,
        served: Task<WarWireDialOutcome, Error>
    ) {
        let rendezvous = LoopbackIrohRelayRendezvous()
        let answerTransport = LoopbackIrohRelayTransport(nodeId: "node-mini", rendezvous: rendezvous)
        let dialTransport = LoopbackIrohRelayTransport(nodeId: "node-studio", rendezvous: rendezvous)
        _ = try await answerTransport.start()
        _ = try await dialTransport.start()

        let served = Task<WarWireDialOutcome, Error> {
            let inbound = try await answerTransport.accept(timeout: 5)
            return await WarWireDialer.accept(
                on: inbound,
                credentials: answererCredentials,
                grantForPeer: { _ in answererGrant }
            )
        }

        return (dialTransport, IrohDialTarget(nodeId: "node-mini"), served)
    }

    // MARK: - The happy path

    func test_dialCompletesTheHandshakeAndBothSidesGoReady() async throws {
        let pair = try await makePair(
            answererCredentials: credentials(bodyID: answererBody),
            answererGrant: activeGrant()
        )

        let outcome = await WarWireDialer.dial(
            transport: pair.dialTransport,
            target: pair.target,
            remoteBodyID: answererBody,
            grant: activeGrant(),
            credentials: credentials(bodyID: dialerBody)
        )

        let link = try XCTUnwrap(outcome.link, "expected a live Wire")
        let ready = await link.isReady
        XCTAssertTrue(ready)
        let remote = await link.remoteBodyID
        XCTAssertEqual(remote, answererBody)

        let servedOutcome = try await pair.served.value
        let servedLink = try XCTUnwrap(servedOutcome.link)
        let servedReady = await servedLink.isReady
        XCTAssertTrue(servedReady)

        await link.close()
        await servedLink.close()
    }

    /// The relay host's request handler reads the first frame to classify the
    /// stream, so the answerer's Wire entry point takes the opening hello it
    /// already holds. Same handshake, same outcome — only the read is skipped.
    func test_acceptWithAPreReadOpeningFrameCompletesTheHandshake() async throws {
        let rendezvous = LoopbackIrohRelayRendezvous()
        let answerTransport = LoopbackIrohRelayTransport(nodeId: "node-mini", rendezvous: rendezvous)
        let dialTransport = LoopbackIrohRelayTransport(nodeId: "node-studio", rendezvous: rendezvous)
        _ = try await answerTransport.start()
        _ = try await dialTransport.start()

        let answererCredentials = credentials(bodyID: answererBody)
        let answererGrant = activeGrant()
        let served = Task<WarWireDialOutcome, Error> {
            let inbound = try await answerTransport.accept(timeout: 5)
            let firstFrame = try await inbound.receive()
            let opening = try XCTUnwrap(firstFrame, "expected the dialer's hello")
            XCTAssertEqual(opening.type, .warHello)
            return await WarWireDialer.accept(
                opening: opening,
                on: inbound,
                credentials: answererCredentials,
                grantForPeer: { _ in answererGrant }
            )
        }

        let outcome = await WarWireDialer.dial(
            transport: dialTransport,
            target: IrohDialTarget(nodeId: "node-mini"),
            remoteBodyID: answererBody,
            grant: activeGrant(),
            credentials: credentials(bodyID: dialerBody)
        )

        let link = try XCTUnwrap(outcome.link, "expected a live Wire")
        let servedOutcome = try await served.value
        let servedLink = try XCTUnwrap(servedOutcome.link)
        let ready = await link.isReady
        let servedReady = await servedLink.isReady
        XCTAssertTrue(ready)
        XCTAssertTrue(servedReady)
        await link.close()
        await servedLink.close()
    }

    func test_fleetSnapshotCrossesTheWireAndArrivesRoutable() async throws {
        let pair = try await makePair(
            answererCredentials: credentials(bodyID: answererBody),
            answererGrant: activeGrant()
        )
        let outcome = await WarWireDialer.dial(
            transport: pair.dialTransport,
            target: pair.target,
            remoteBodyID: answererBody,
            grant: activeGrant(),
            credentials: credentials(bodyID: dialerBody)
        )
        let link = try XCTUnwrap(outcome.link)
        let servedOutcome = try await pair.served.value
        let servedLink = try XCTUnwrap(servedOutcome.link)

        let body = FleetBodySnapshot(
            bodyID: dialerBody,
            displayName: "Studio",
            isLocal: true,
            hermesGatewayReachable: true,
            capabilities: ["hermes_chat"],
            activeRunCount: 1,
            performanceCores: 12
        )
        let sent = try await link.pushFleetSnapshot([body])
        XCTAssertTrue(sent)

        let inbound = await servedLink.next()
        guard case let .event(.fleetSnapshot(received)) = inbound else {
            XCTFail("expected a fleet snapshot, got \(inbound)")
            return
        }
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received[0].bodyID, dialerBody)
        XCTAssertTrue(received[0].wireReachable, "arrived over the Wire")
        XCTAssertFalse(received[0].isLocal, "a peer is never local to the receiver")

        await link.close()
        await servedLink.close()
    }

    func test_dispatchCrossesTheWire() async throws {
        let pair = try await makePair(
            answererCredentials: credentials(bodyID: answererBody),
            answererGrant: activeGrant()
        )
        let outcome = await WarWireDialer.dial(
            transport: pair.dialTransport,
            target: pair.target,
            remoteBodyID: answererBody,
            grant: activeGrant(),
            credentials: credentials(bodyID: dialerBody)
        )
        let link = try XCTUnwrap(outcome.link)
        let servedOutcome = try await pair.served.value
        let servedLink = try XCTUnwrap(servedOutcome.link)

        let request = HermesRealtimeRelayWarDispatchRequest(
            dispatchId: "disp-1",
            instruction: "run the suite",
            requiredCapabilities: ["hermes_chat"],
            originatorKind: "flame",
            originatorRef: "d-abc"
        )
        let dispatched = try await link.dispatch(request)
        XCTAssertTrue(dispatched)

        let inbound = await servedLink.next()
        guard case let .event(.dispatch(received)) = inbound else {
            XCTFail("expected a dispatch, got \(inbound)")
            return
        }
        XCTAssertEqual(received, request)

        await link.close()
        await servedLink.close()
    }

    // MARK: - Refusing before the socket

    /// The core promise of the fail-closed design: a refusal costs no network.
    /// The transport here is never started, so any attempt to reach it would
    /// throw and surface as `.transportLost` instead of the real reason.
    func test_killSwitchRefusesWithoutTouchingTheTransport() async {
        let unstarted = LoopbackIrohRelayTransport(
            nodeId: "node-studio",
            rendezvous: LoopbackIrohRelayRendezvous()
        )
        let outcome = await WarWireDialer.dial(
            transport: unstarted,
            target: IrohDialTarget(nodeId: "node-mini"),
            remoteBodyID: answererBody,
            grant: activeGrant(),
            credentials: credentials(bodyID: dialerBody, tier: .ultra, killSwitch: true)
        )
        XCTAssertEqual(outcome.closure, .refusedLocally(.killSwitch))
    }

    func test_belowProRefusesWithoutTouchingTheTransport() async {
        let unstarted = LoopbackIrohRelayTransport(
            nodeId: "node-studio",
            rendezvous: LoopbackIrohRelayRendezvous()
        )
        let outcome = await WarWireDialer.dial(
            transport: unstarted,
            target: IrohDialTarget(nodeId: "node-mini"),
            remoteBodyID: answererBody,
            grant: activeGrant(),
            credentials: credentials(bodyID: dialerBody, tier: .cloud)
        )
        XCTAssertEqual(outcome.closure, .refusedLocally(.entitlement))
    }

    func test_missingGrantRefusesWithoutTouchingTheTransport() async {
        let unstarted = LoopbackIrohRelayTransport(
            nodeId: "node-studio",
            rendezvous: LoopbackIrohRelayRendezvous()
        )
        let outcome = await WarWireDialer.dial(
            transport: unstarted,
            target: IrohDialTarget(nodeId: "node-mini"),
            remoteBodyID: answererBody,
            grant: nil,
            credentials: credentials(bodyID: dialerBody)
        )
        XCTAssertEqual(outcome.closure, .refusedLocally(.noGrant))
    }

    // MARK: - Refusing at the peer

    /// Consent revoked on the answering machine must refuse the dial, and the
    /// dialer must learn the actual reason rather than seeing a bare hangup.
    func test_peerWithARevokedGrantRefusesAndTellsTheDialerWhy() async throws {
        let pair = try await makePair(
            answererCredentials: credentials(bodyID: answererBody),
            answererGrant: WarWireGrant(bodyIDA: dialerBody, bodyIDB: answererBody, state: .revoked)
        )

        let outcome = await WarWireDialer.dial(
            transport: pair.dialTransport,
            target: pair.target,
            remoteBodyID: answererBody,
            grant: activeGrant(),
            credentials: credentials(bodyID: dialerBody)
        )
        XCTAssertEqual(outcome.closure, .refusedByPeer(.grantRevoked))
        XCTAssertNil(outcome.link)

        let served = try await pair.served.value
        XCTAssertEqual(served.closure, .refusedLocally(.grantRevoked))
    }

    func test_peerWithNoGrantRefuses() async throws {
        let pair = try await makePair(
            answererCredentials: credentials(bodyID: answererBody),
            answererGrant: nil
        )
        let outcome = await WarWireDialer.dial(
            transport: pair.dialTransport,
            target: pair.target,
            remoteBodyID: answererBody,
            grant: activeGrant(),
            credentials: credentials(bodyID: dialerBody)
        )
        XCTAssertEqual(outcome.closure, .refusedByPeer(.noGrant))
    }

    func test_peerBelowProRefuses() async throws {
        let pair = try await makePair(
            answererCredentials: credentials(bodyID: answererBody, tier: .none),
            answererGrant: activeGrant()
        )
        let outcome = await WarWireDialer.dial(
            transport: pair.dialTransport,
            target: pair.target,
            remoteBodyID: answererBody,
            grant: activeGrant(),
            credentials: credentials(bodyID: dialerBody)
        )
        XCTAssertEqual(outcome.closure, .refusedByPeer(.entitlement))
    }

    /// Dialing a machine that answers as somebody else must not produce a Wire.
    func test_dialingTheWrongMachineIsRefused() async throws {
        let pair = try await makePair(
            answererCredentials: credentials(bodyID: answererBody),
            answererGrant: activeGrant()
        )
        let outcome = await WarWireDialer.dial(
            transport: pair.dialTransport,
            target: pair.target,
            remoteBodyID: "mac-imposter",
            grant: WarWireGrant(bodyIDA: dialerBody, bodyIDB: "mac-imposter", state: .active),
            credentials: credentials(bodyID: dialerBody)
        )
        XCTAssertNil(outcome.link)
        XCTAssertEqual(outcome.closure, .refusedByPeer(.grantMismatch))
    }

    // MARK: - Transport failure

    func test_dialingAnUnreachableTargetFallsBack() async throws {
        let transport = LoopbackIrohRelayTransport(
            nodeId: "node-studio",
            rendezvous: LoopbackIrohRelayRendezvous()
        )
        _ = try await transport.start()
        let outcome = await WarWireDialer.dial(
            transport: transport,
            target: IrohDialTarget(nodeId: "node-nowhere"),
            remoteBodyID: answererBody,
            grant: activeGrant(),
            credentials: credentials(bodyID: dialerBody),
            timeout: 0.25
        )
        XCTAssertEqual(outcome.closure, .transportLost)
    }

    func test_peerHangupReadsAsFinished() async throws {
        let pair = try await makePair(
            answererCredentials: credentials(bodyID: answererBody),
            answererGrant: activeGrant()
        )
        let outcome = await WarWireDialer.dial(
            transport: pair.dialTransport,
            target: pair.target,
            remoteBodyID: answererBody,
            grant: activeGrant(),
            credentials: credentials(bodyID: dialerBody)
        )
        let link = try XCTUnwrap(outcome.link)
        let servedOutcome = try await pair.served.value
        let servedLink = try XCTUnwrap(servedOutcome.link)
        await servedLink.close()

        let inbound = await link.next()
        XCTAssertEqual(inbound, .finished)
    }

    // MARK: - Outbound gating

    func test_aRefusedDialYieldsNoLinkToPushWorkThrough() async throws {
        let pair = try await makePair(
            answererCredentials: credentials(bodyID: answererBody),
            answererGrant: nil
        )
        let outcome = await WarWireDialer.dial(
            transport: pair.dialTransport,
            target: pair.target,
            remoteBodyID: answererBody,
            grant: activeGrant(),
            credentials: credentials(bodyID: dialerBody)
        )
        XCTAssertNil(outcome.link, "work must have no Wire to leak onto")
        XCTAssertNotNil(outcome.closure)
    }
}
