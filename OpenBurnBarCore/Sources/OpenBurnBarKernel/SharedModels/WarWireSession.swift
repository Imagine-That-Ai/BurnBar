import Foundation

/// The Wire's handshake, as a pure state machine (§ The Wire of
/// `plans/2026-08-17-war-room-master-plan.md`).
///
/// Fail-closed is easy to state and easy to forget at a call site, so it is
/// encoded here instead: the session evaluates `WarWireGate` *before* it emits
/// a dial, refuses every frame that arrives out of order, and every terminal
/// path produces a `fallBackToFirestore` action carrying the reason. There is
/// no way to reach `.ready` without having been allowed by the gate and having
/// verified the peer answered as the machine we dialled.
///
/// Both Macs run this same type — the dialer via `open`, the answerer via
/// `accept` — so the two sides cannot hold different views of the rules.
public struct WarWireSession: Sendable, Equatable {

    public enum State: Sendable, Equatable {
        case idle
        /// Hello sent; nothing may flow until the peer answers.
        case awaitingAck
        case ready
        case closed(Closure)
    }

    /// Why a session ended. Every case routes work back to the Firestore relay;
    /// none of them is an error the user needs to see.
    public enum Closure: Sendable, Equatable {
        /// Our own gate refused before anything left the machine.
        case refusedLocally(WarWireDenialReason)
        /// The peer refused us.
        case refusedByPeer(WarWireDenialReason)
        /// The peer answered, but not as the machine we dialled.
        case peerIdentityMismatch
        /// A frame arrived that the current state does not permit.
        case protocolViolation
        case transportLost
        case closedByCaller

        public var denialReason: WarWireDenialReason? {
            switch self {
            case let .refusedLocally(reason), let .refusedByPeer(reason): return reason
            case .peerIdentityMismatch, .protocolViolation, .transportLost, .closedByCaller: return nil
            }
        }
    }

    public enum Action: Sendable, Equatable {
        case send(HermesRealtimeRelayFrame)
        /// Hand this event to the application. Only ever emitted from `.ready`.
        case deliver(WarWireEvent)
        /// Route this work over the Firestore relay instead. Always paired with
        /// a closure so the caller can log why the Wire was not used.
        case fallBackToFirestore(Closure)
    }

    public private(set) var state: State = .idle
    public let localBodyID: String
    public let remoteBodyID: String
    public let localDisplayName: String
    public let localCapabilities: [String]
    private let uid: String
    private let connectionID: String
    /// Highest chunk ordinal delivered per run. The wire contract makes the
    /// ordinal monotonic per run, so a chunk at or below the mark is a
    /// duplicate or stale reordering — dropped rather than spliced into the
    /// output out of order. Entries are released when the run completes.
    private var deliveredChunkHighWaterMarks: [String: Int] = [:]

    public init(
        localBodyID: String,
        remoteBodyID: String,
        localDisplayName: String,
        localCapabilities: [String] = [WarWireFrameCodec.capability],
        uid: String,
        connectionID: String
    ) {
        self.localBodyID = localBodyID
        self.remoteBodyID = remoteBodyID
        self.localDisplayName = localDisplayName
        self.localCapabilities = localCapabilities
        self.uid = uid
        self.connectionID = connectionID
    }

    public var isReady: Bool { state == .ready }

    public var pairID: String {
        WarWireGrant.pairID(localBodyID, remoteBodyID)
    }

    // MARK: - Dialing side

    /// Ask to open the Wire. Evaluates the gate first, so a refusal costs no
    /// network at all and the caller gets an immediate fallback instruction.
    public mutating func open(
        tier: CloudTier,
        killSwitchEngaged: Bool,
        grant: WarWireGrant?
    ) -> [Action] {
        guard state == .idle else { return [] }

        let decision = WarWireGate.evaluate(
            localBodyID: localBodyID,
            remoteBodyID: remoteBodyID,
            tier: tier,
            killSwitchEngaged: killSwitchEngaged,
            grant: grant
        )
        if let reason = decision.denialReason {
            return close(.refusedLocally(reason))
        }

        state = .awaitingAck
        return [.send(WarWireFrameCodec.hello(localHello, uid: uid, connectionID: connectionID))]
    }

    // MARK: - Answering side

    /// Answer an inbound hello. Runs the identical gate the dialer ran, so
    /// consent that was revoked on this machine refuses the session even if the
    /// dialer still believed it held a grant.
    public mutating func accept(
        _ hello: WarWireHello,
        tier: CloudTier,
        killSwitchEngaged: Bool,
        grant: WarWireGrant?
    ) -> [Action] {
        guard state == .idle else { return [] }

        // The dialer's claimed pair id is re-derived rather than trusted.
        guard hello.bodyID == remoteBodyID, hello.pairID == pairID else {
            return [
                .send(WarWireFrameCodec.denied(.grantMismatch, uid: uid, connectionID: connectionID))
            ] + close(.peerIdentityMismatch)
        }

        let decision = WarWireGate.evaluate(
            localBodyID: localBodyID,
            remoteBodyID: hello.bodyID,
            tier: tier,
            killSwitchEngaged: killSwitchEngaged,
            grant: grant
        )
        if let reason = decision.denialReason {
            return [
                .send(WarWireFrameCodec.denied(reason, uid: uid, connectionID: connectionID))
            ] + close(.refusedLocally(reason))
        }

        state = .ready
        return [.send(WarWireFrameCodec.helloAck(localHello, uid: uid, connectionID: connectionID))]
    }

    // MARK: - Inbound

    public mutating func receive(_ event: WarWireEvent) -> [Action] {
        switch state {
        case .closed, .idle:
            return []

        case .awaitingAck:
            switch event {
            case let .helloAck(hello):
                guard hello.bodyID == remoteBodyID, hello.pairID == pairID else {
                    return close(.peerIdentityMismatch)
                }
                state = .ready
                return []
            case let .denied(reason, _):
                return close(.refusedByPeer(reason))
            default:
                // Nothing is allowed to flow before the handshake completes.
                return close(.protocolViolation)
            }

        case .ready:
            switch event {
            case .hello, .helloAck:
                // A second handshake on a live session is not a renegotiation
                // we support; treat it as the protocol error it is.
                return close(.protocolViolation)
            case let .denied(reason, _):
                return close(.refusedByPeer(reason))
            case let .streamChunk(runID, sequence, _):
                guard sequence > deliveredChunkHighWaterMarks[runID, default: Int.min] else {
                    return []
                }
                deliveredChunkHighWaterMarks[runID] = sequence
                return [.deliver(event)]
            case let .streamComplete(runID, _, _):
                deliveredChunkHighWaterMarks.removeValue(forKey: runID)
                return [.deliver(event)]
            default:
                return [.deliver(event)]
            }
        }
    }

    public mutating func transportFailed() -> [Action] {
        guard state != .closed(.transportLost) else { return [] }
        return close(.transportLost)
    }

    /// The peer sent something this side cannot interpret. Distinct from a
    /// denial: nobody refused anything, the lane is simply no longer
    /// trustworthy, so the session closes and the caller falls back.
    public mutating func protocolViolated() -> [Action] {
        guard !isClosed else { return [] }
        return close(.protocolViolation)
    }

    public mutating func closeByCaller() -> [Action] {
        guard !isClosed else { return [] }
        state = .closed(.closedByCaller)
        return []
    }

    // MARK: - Sending

    /// Frames the application may push once the handshake is done. Returns nil
    /// before `.ready` so work cannot leak onto an unverified session.
    public func fleetSnapshotFrame(_ bodies: [FleetBodySnapshot]) -> HermesRealtimeRelayFrame? {
        guard isReady else { return nil }
        return WarWireFrameCodec.fleetSnapshot(bodies, uid: uid, connectionID: connectionID)
    }

    public func dispatchFrame(
        _ request: HermesRealtimeRelayWarDispatchRequest
    ) -> HermesRealtimeRelayFrame? {
        guard isReady else { return nil }
        return WarWireFrameCodec.dispatch(request, uid: uid, connectionID: connectionID)
    }

    // MARK: - Private

    private var isClosed: Bool {
        if case .closed = state { return true }
        return false
    }

    private var localHello: WarWireHello {
        WarWireHello(
            bodyID: localBodyID,
            displayName: localDisplayName,
            capabilities: localCapabilities,
            pairID: pairID
        )
    }

    private mutating func close(_ closure: Closure) -> [Action] {
        state = .closed(closure)
        return [.fallBackToFirestore(closure)]
    }
}
