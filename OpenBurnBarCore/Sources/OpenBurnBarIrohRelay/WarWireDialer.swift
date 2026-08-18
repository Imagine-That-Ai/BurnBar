import Foundation
import OpenBurnBarKernel

/// The Wire's transport half — dials a peer Mac over iroh and runs
/// `WarWireSession` across the resulting stream (§ The Wire of
/// `plans/2026-08-17-war-room-master-plan.md`).
///
/// The policy lives in the Kernel and the bytes live in `IrohRelayTransport`;
/// this file is only the join between them. It adds exactly one behaviour of
/// its own: a refusal never touches the network. `dial` evaluates the gate
/// before it asks the transport for anything, so a revoked grant or an engaged
/// kill switch costs zero packets and returns a Firestore fallback immediately.

public struct WarWireCredentials: Sendable {
    public var localBodyID: String
    public var localDisplayName: String
    public var uid: String
    public var connectionID: String
    public var tier: CloudTier
    public var killSwitchEngaged: Bool
    public var capabilities: [String]

    public init(
        localBodyID: String,
        localDisplayName: String,
        uid: String,
        connectionID: String,
        tier: CloudTier,
        killSwitchEngaged: Bool,
        capabilities: [String] = [WarWireFrameCodec.capability]
    ) {
        self.localBodyID = localBodyID
        self.localDisplayName = localDisplayName
        self.uid = uid
        self.connectionID = connectionID
        self.tier = tier
        self.killSwitchEngaged = killSwitchEngaged
        self.capabilities = capabilities
    }
}

public enum WarWireDialOutcome: Sendable {
    case connected(WarWireLink)
    /// The Wire is unavailable; route this work over the Firestore relay. Not
    /// an error — just the other road.
    case fallBackToFirestore(WarWireSession.Closure)

    public var link: WarWireLink? {
        guard case let .connected(link) = self else { return nil }
        return link
    }

    public var closure: WarWireSession.Closure? {
        guard case let .fallBackToFirestore(closure) = self else { return nil }
        return closure
    }
}

/// A live, verified Wire between two Macs. Only reachable by completing the
/// handshake, so holding one is proof the gate allowed it and the peer proved
/// its identity.
public actor WarWireLink {
    public enum Inbound: Sendable, Equatable {
        case event(WarWireEvent)
        /// The session consumed the frame without producing anything for the
        /// caller — a handshake step, or a frame arriving on a lane that is not
        /// ready. Callers loop; they never see the frame.
        case handled
        case closed(WarWireSession.Closure)
        /// The peer hung up cleanly.
        case finished
    }

    public let remoteBodyID: String
    private let stream: any IrohRelayStream
    private var session: WarWireSession
    private var isReading = false

    init(stream: any IrohRelayStream, session: WarWireSession) {
        self.stream = stream
        self.session = session
        self.remoteBodyID = session.remoteBodyID
    }

    public var isReady: Bool { session.isReady }
    public var state: WarWireSession.State { session.state }
    public var remotePeerNodeID: String? { stream.remotePeerNodeId }

    /// Read one frame and fold it through the session. Returns `.finished` when
    /// the peer closed cleanly, `.closed` when the session terminated (and the
    /// caller should fall back), or the delivered event.
    public func next() async -> Inbound {
        // `next` suspends on the transport, so two concurrent readers would fold
        // frames through the session in completion order rather than arrival
        // order — and arrival order is the entire contract of a handshake.
        guard !isReading else { return .closed(.protocolViolation) }
        isReading = true
        defer { isReading = false }

        let frame: HermesRealtimeRelayFrame?
        do {
            frame = try await stream.receive()
        } catch {
            return await terminate(session.transportFailed())
        }

        guard let frame else {
            await stream.close()
            return .finished
        }

        let event: WarWireEvent
        do {
            event = try WarWireFrameCodec.event(from: frame)
        } catch {
            // A frame we cannot fully understand is a protocol violation, and
            // the session's own rule is that those close the Wire. Drive the
            // session through its own violation path rather than synthesizing a
            // denial that never arrived, so `state` and the returned closure
            // tell the same story.
            return await terminate(session.protocolViolated())
        }

        let actions = session.receive(event)
        if let closure = actions.compactMap(\.fallbackClosure).first {
            return await terminate([.fallBackToFirestore(closure)])
        }
        for case let .send(outbound) in actions {
            try? await stream.send(outbound)
        }
        for case let .deliver(delivered) in actions {
            return .event(delivered)
        }
        // The session produced no delivery. Handing the frame over anyway would
        // route around the one rule this type exists to enforce — that nothing
        // flows before the handshake completes, and nothing flows after close.
        return .handled
    }

    @discardableResult
    public func pushFleetSnapshot(_ bodies: [FleetBodySnapshot]) async throws -> Bool {
        guard let frame = session.fleetSnapshotFrame(bodies) else { return false }
        try await stream.send(frame)
        return true
    }

    @discardableResult
    public func dispatch(_ request: HermesRealtimeRelayWarDispatchRequest) async throws -> Bool {
        guard let frame = session.dispatchFrame(request) else { return false }
        try await stream.send(frame)
        return true
    }

    public func close() async {
        _ = session.closeByCaller()
        await stream.close()
    }

    private func terminate(_ actions: [WarWireSession.Action]) async -> Inbound {
        await stream.close()
        let closure = actions.compactMap(\.fallbackClosure).first ?? .transportLost
        return .closed(closure)
    }
}

public enum WarWireDialer {

    /// Dial a peer Mac.
    ///
    /// Order matters and is the point: the gate runs first, so a refusal never
    /// opens a socket. Only an allowed dial reaches the transport, and only a
    /// verified ack produces a `WarWireLink`.
    public static func dial(
        transport: any IrohRelayTransport,
        target: IrohDialTarget,
        remoteBodyID: String,
        grant: WarWireGrant?,
        credentials: WarWireCredentials,
        timeout: TimeInterval = 10
    ) async -> WarWireDialOutcome {
        var session = WarWireSession(
            localBodyID: credentials.localBodyID,
            remoteBodyID: remoteBodyID,
            localDisplayName: credentials.localDisplayName,
            localCapabilities: credentials.capabilities,
            uid: credentials.uid,
            connectionID: credentials.connectionID
        )

        let opening = session.open(
            tier: credentials.tier,
            killSwitchEngaged: credentials.killSwitchEngaged,
            grant: grant
        )
        if let closure = opening.compactMap(\.fallbackClosure).first {
            return .fallBackToFirestore(closure)
        }
        guard let hello = opening.compactMap(\.frame).first else {
            return .fallBackToFirestore(.protocolViolation)
        }

        let stream: any IrohRelayStream
        do {
            stream = try await transport.connect(to: target, timeout: timeout)
        } catch {
            return .fallBackToFirestore(.transportLost)
        }

        do {
            try await stream.send(hello)
        } catch {
            await stream.close()
            return .fallBackToFirestore(.transportLost)
        }

        let answer: HermesRealtimeRelayFrame?
        do {
            answer = try await stream.receive()
        } catch {
            await stream.close()
            return .fallBackToFirestore(.transportLost)
        }
        guard let answer else {
            await stream.close()
            return .fallBackToFirestore(.transportLost)
        }

        let event: WarWireEvent
        do {
            event = try WarWireFrameCodec.event(from: answer)
        } catch {
            await stream.close()
            return .fallBackToFirestore(.protocolViolation)
        }

        let settled = session.receive(event)
        if let closure = settled.compactMap(\.fallbackClosure).first {
            await stream.close()
            return .fallBackToFirestore(closure)
        }
        guard session.isReady else {
            await stream.close()
            return .fallBackToFirestore(.protocolViolation)
        }

        return .connected(WarWireLink(stream: stream, session: session))
    }

    /// Answer an inbound Wire dial on an already-accepted stream.
    ///
    /// The answerer runs the same gate with its own grant, which is what makes
    /// revocation effective: consent pulled here refuses the session even while
    /// the dialer still believes it holds one.
    public static func accept(
        on stream: any IrohRelayStream,
        credentials: WarWireCredentials,
        grantForPeer: @Sendable (String) -> WarWireGrant?
    ) async -> WarWireDialOutcome {
        let opening: HermesRealtimeRelayFrame?
        do {
            opening = try await stream.receive()
        } catch {
            await stream.close()
            return .fallBackToFirestore(.transportLost)
        }
        guard let opening else {
            await stream.close()
            return .fallBackToFirestore(.transportLost)
        }
        return await accept(
            opening: opening,
            on: stream,
            credentials: credentials,
            grantForPeer: grantForPeer
        )
    }

    /// Answer an inbound Wire dial whose opening frame was already read.
    ///
    /// The relay host's request handler classifies each stream by its first
    /// frame, so by the time a `war.hello` reaches the Wire the frame is in
    /// hand. Same gate, same refusal semantics as `accept(on:)` — only the
    /// read is skipped.
    public static func accept(
        opening: HermesRealtimeRelayFrame,
        on stream: any IrohRelayStream,
        credentials: WarWireCredentials,
        grantForPeer: @Sendable (String) -> WarWireGrant?
    ) async -> WarWireDialOutcome {
        guard
            let event = try? WarWireFrameCodec.event(from: opening),
            case let .hello(hello) = event
        else {
            await stream.close()
            return .fallBackToFirestore(.protocolViolation)
        }

        var session = WarWireSession(
            localBodyID: credentials.localBodyID,
            remoteBodyID: hello.bodyID,
            localDisplayName: credentials.localDisplayName,
            localCapabilities: credentials.capabilities,
            uid: credentials.uid,
            connectionID: credentials.connectionID
        )

        let actions = session.accept(
            hello,
            tier: credentials.tier,
            killSwitchEngaged: credentials.killSwitchEngaged,
            grant: grantForPeer(hello.bodyID)
        )

        // The refusal frame is sent before closing so the dialer learns why
        // instead of seeing an unexplained hangup.
        for case let .send(frame) in actions {
            try? await stream.send(frame)
        }
        if let closure = actions.compactMap(\.fallbackClosure).first {
            await stream.close()
            return .fallBackToFirestore(closure)
        }

        return .connected(WarWireLink(stream: stream, session: session))
    }
}

private extension WarWireSession.Action {
    var fallbackClosure: WarWireSession.Closure? {
        guard case let .fallBackToFirestore(closure) = self else { return nil }
        return closure
    }

    var frame: HermesRealtimeRelayFrame? {
        guard case let .send(frame) = self else { return nil }
        return frame
    }
}
