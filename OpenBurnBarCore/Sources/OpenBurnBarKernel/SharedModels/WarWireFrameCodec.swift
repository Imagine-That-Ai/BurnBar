import Foundation

/// The Wire's frame layer — builds the eight `war.*` frames and parses inbound
/// ones into typed events (§ The Wire of `plans/2026-08-17-war-room-master-plan.md`).
///
/// Pure, so both Macs run identical encode/decode and a malformed peer is a
/// test case rather than a field incident. The transport (iroh stream, length
/// prefix, JSON) is somebody else's job; this file only decides what a war
/// frame *means*.

/// A war frame that has been validated and understood.
public enum WarWireEvent: Sendable, Equatable {
    case hello(WarWireHello)
    case helloAck(WarWireHello)
    case fleetSnapshot([FleetBodySnapshot])
    case dispatch(HermesRealtimeRelayWarDispatchRequest)
    case dispatchAck(dispatchID: String, runID: String)
    case streamChunk(runID: String, sequence: Int, text: String)
    case streamComplete(runID: String, status: HermesRealtimeRelayWarRunStatus, message: String?)
    case denied(WarWireDenialReason, message: String?)
}

public struct WarWireHello: Sendable, Equatable {
    public var bodyID: String
    public var displayName: String
    public var capabilities: [String]
    /// The grant the dialer claims covers this pair. The answering Mac
    /// re-derives it rather than trusting the dialer's arithmetic.
    public var pairID: String

    public init(bodyID: String, displayName: String, capabilities: [String], pairID: String) {
        self.bodyID = bodyID
        self.displayName = displayName
        self.capabilities = capabilities
        self.pairID = pairID
    }
}

public enum WarWireFrameError: Error, Equatable, Sendable {
    /// The frame's type is outside the `war` group entirely.
    case notAWarFrame(HermesRealtimeRelayFrameType)
    /// A war frame arrived with no war payload attached.
    case missingPayload(HermesRealtimeRelayFrameType)
    /// The envelope's frame type and the payload's own discriminator disagree.
    /// Refused rather than resolved: a peer that cannot label its own frame
    /// consistently does not get to pick which label wins.
    case kindMismatch(frame: HermesRealtimeRelayFrameType, payload: HermesRealtimeRelayWarPayload.Kind)
    case missingField(String)
}

public enum WarWireFrameCodec {

    /// Capability every War Room peer advertises; its absence in a hello means
    /// the peer predates the Wire and must be served over the Firestore relay.
    public static let capability = "war_wire_v1"

    // MARK: - Build

    public static func hello(
        _ hello: WarWireHello,
        uid: String,
        connectionID: String
    ) -> HermesRealtimeRelayFrame {
        frame(.warHello, uid: uid, connectionID: connectionID, payload: HermesRealtimeRelayWarPayload(
            kind: .hello,
            bodyId: hello.bodyID,
            displayName: hello.displayName,
            capabilities: hello.capabilities,
            pairId: hello.pairID
        ))
    }

    public static func helloAck(
        _ hello: WarWireHello,
        uid: String,
        connectionID: String
    ) -> HermesRealtimeRelayFrame {
        frame(.warHelloAck, uid: uid, connectionID: connectionID, payload: HermesRealtimeRelayWarPayload(
            kind: .helloAck,
            bodyId: hello.bodyID,
            displayName: hello.displayName,
            capabilities: hello.capabilities,
            pairId: hello.pairID
        ))
    }

    public static func fleetSnapshot(
        _ bodies: [FleetBodySnapshot],
        uid: String,
        connectionID: String
    ) -> HermesRealtimeRelayFrame {
        frame(.warFleetSnapshot, uid: uid, connectionID: connectionID, payload: HermesRealtimeRelayWarPayload(
            kind: .fleetSnapshot,
            fleet: bodies.map(wireState)
        ))
    }

    public static func dispatch(
        _ request: HermesRealtimeRelayWarDispatchRequest,
        uid: String,
        connectionID: String
    ) -> HermesRealtimeRelayFrame {
        frame(.warDispatch, uid: uid, connectionID: connectionID, payload: HermesRealtimeRelayWarPayload(
            kind: .dispatch,
            dispatch: request
        ))
    }

    public static func dispatchAck(
        dispatchID: String,
        runID: String,
        uid: String,
        connectionID: String
    ) -> HermesRealtimeRelayFrame {
        frame(.warDispatchAck, uid: uid, connectionID: connectionID, payload: HermesRealtimeRelayWarPayload(
            kind: .dispatchAck,
            runId: runID,
            status: .accepted,
            message: dispatchID
        ))
    }

    public static func streamChunk(
        runID: String,
        sequence: Int,
        text: String,
        uid: String,
        connectionID: String
    ) -> HermesRealtimeRelayFrame {
        frame(.warStreamChunk, uid: uid, connectionID: connectionID, payload: HermesRealtimeRelayWarPayload(
            kind: .streamChunk,
            runId: runID,
            sequence: sequence,
            chunk: text
        ))
    }

    public static func streamComplete(
        runID: String,
        status: HermesRealtimeRelayWarRunStatus,
        message: String? = nil,
        uid: String,
        connectionID: String
    ) -> HermesRealtimeRelayFrame {
        frame(.warStreamComplete, uid: uid, connectionID: connectionID, payload: HermesRealtimeRelayWarPayload(
            kind: .streamComplete,
            runId: runID,
            status: status,
            message: message
        ))
    }

    /// The fail-closed refusal. Built from the same `WarWireDenialReason` the
    /// gate produced, so what the peer is told and what was decided cannot drift.
    public static func denied(
        _ reason: WarWireDenialReason,
        message: String? = nil,
        uid: String,
        connectionID: String
    ) -> HermesRealtimeRelayFrame {
        frame(.warDenied, uid: uid, connectionID: connectionID, payload: HermesRealtimeRelayWarPayload(
            kind: .denied,
            denialReason: HermesRealtimeRelayWarDenialReason(rawValue: reason.rawValue) ?? .unidentified,
            message: message
        ))
    }

    // MARK: - Parse

    /// Turn a received frame into a typed event, or throw.
    ///
    /// Every failure mode is explicit: not-a-war-frame, no payload, mismatched
    /// discriminators, or a missing field the frame's own kind requires. There
    /// is no lenient path — a frame that cannot be fully understood is refused,
    /// which is what keeps the fail-closed contract honest at the frame layer.
    public static func event(from frame: HermesRealtimeRelayFrame) throws -> WarWireEvent {
        guard frame.type.isWarFrame else {
            throw WarWireFrameError.notAWarFrame(frame.type)
        }
        guard let payload = frame.war else {
            throw WarWireFrameError.missingPayload(frame.type)
        }
        guard payload.kind == expectedKind(for: frame.type) else {
            throw WarWireFrameError.kindMismatch(frame: frame.type, payload: payload.kind)
        }

        switch payload.kind {
        case .hello, .helloAck:
            let hello = WarWireHello(
                bodyID: try require(payload.bodyId, "bodyId"),
                displayName: try require(payload.displayName, "displayName"),
                capabilities: payload.capabilities ?? [],
                pairID: try require(payload.pairId, "pairId")
            )
            return payload.kind == .hello ? .hello(hello) : .helloAck(hello)

        case .fleetSnapshot:
            let fleet = try require(payload.fleet, "fleet")
            return .fleetSnapshot(fleet.map(FleetBodySnapshot.init(receivedOverWire:)))

        case .dispatch:
            return .dispatch(try require(payload.dispatch, "dispatch"))

        case .dispatchAck:
            return .dispatchAck(
                dispatchID: try require(payload.message, "message"),
                runID: try require(payload.runId, "runId")
            )

        case .streamChunk:
            return .streamChunk(
                runID: try require(payload.runId, "runId"),
                sequence: try require(payload.sequence, "sequence"),
                text: try require(payload.chunk, "chunk")
            )

        case .streamComplete:
            return .streamComplete(
                runID: try require(payload.runId, "runId"),
                status: try require(payload.status, "status"),
                message: payload.message
            )

        case .denied:
            let wire = try require(payload.denialReason, "denialReason")
            // The two vocabularies are pinned equal by WarWireFrameCodecTests,
            // so this cannot silently degrade in practice.
            let reason = WarWireDenialReason(rawValue: wire.rawValue) ?? .unidentified
            return .denied(reason, message: payload.message)
        }
    }

    // MARK: - Helpers

    private static func frame(
        _ type: HermesRealtimeRelayFrameType,
        uid: String,
        connectionID: String,
        payload: HermesRealtimeRelayWarPayload
    ) -> HermesRealtimeRelayFrame {
        HermesRealtimeRelayFrame(type: type, uid: uid, connectionId: connectionID, war: payload)
    }

    private static func expectedKind(
        for type: HermesRealtimeRelayFrameType
    ) -> HermesRealtimeRelayWarPayload.Kind? {
        switch type {
        case .warHello: return .hello
        case .warHelloAck: return .helloAck
        case .warFleetSnapshot: return .fleetSnapshot
        case .warDispatch: return .dispatch
        case .warDispatchAck: return .dispatchAck
        case .warStreamChunk: return .streamChunk
        case .warStreamComplete: return .streamComplete
        case .warDenied: return .denied
        default: return nil
        }
    }

    private static func require<T>(_ value: T?, _ field: String) throws -> T {
        guard let value else { throw WarWireFrameError.missingField(field) }
        return value
    }

    private static func wireState(_ body: FleetBodySnapshot) -> HermesRealtimeRelayWarBodyState {
        HermesRealtimeRelayWarBodyState(
            bodyId: body.bodyID,
            displayName: body.displayName,
            hermesGatewayReachable: body.hermesGatewayReachable,
            capabilities: body.capabilities.sorted(),
            activeRunCount: body.activeRunCount,
            performanceCores: body.performanceCores
        )
    }
}

public extension HermesRealtimeRelayFrameType {
    var isWarFrame: Bool {
        switch self {
        case .warHello, .warHelloAck, .warFleetSnapshot, .warDispatch,
             .warDispatchAck, .warStreamChunk, .warStreamComplete, .warDenied:
            return true
        default:
            return false
        }
    }
}

public extension FleetBodySnapshot {
    /// Lift a body state that just arrived over the Wire into a routable snapshot.
    ///
    /// Three facts are supplied by the *receiver*, never by the sender: the peer
    /// is online (its frame just arrived), the Wire is reachable (that is how
    /// the frame got here), and it is not local. A machine does not get to
    /// assert its own liveness — presence stays the reader's verdict.
    init(receivedOverWire state: HermesRealtimeRelayWarBodyState) {
        self.init(
            bodyID: state.bodyId,
            displayName: state.displayName,
            isLocal: false,
            isOnline: true,
            hermesGatewayReachable: state.hermesGatewayReachable,
            wireReachable: true,
            capabilities: Set(state.capabilities),
            activeRunCount: state.activeRunCount,
            performanceCores: state.performanceCores
        )
    }
}
