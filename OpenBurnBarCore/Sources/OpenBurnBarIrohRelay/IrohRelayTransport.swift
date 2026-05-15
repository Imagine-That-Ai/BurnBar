import Foundation
import OpenBurnBarCore

/// One iroh bidirectional stream. Per spec, every `requestId` gets its own
/// stream; the long-lived `host.register` / `host.ready` exchange uses a
/// dedicated control stream. The transport never inspects frame contents —
/// it just moves length-prefixed JSON between endpoints.
public protocol IrohRelayStream: Sendable {
    /// Send a single frame. Length-prefixed JSON; the protocol encoder is
    /// responsible for the byte layout.
    func send(_ frame: HermesRealtimeRelayFrame) async throws

    /// Receive one frame, or `nil` if the remote closed the stream cleanly.
    func receive() async throws -> HermesRealtimeRelayFrame?

    /// Cleanly tear the stream down. Idempotent.
    func close() async
}

/// Identity of an iroh endpoint as seen by the publish/discover layer.
public struct IrohEndpointIdentity: Sendable, Equatable, Hashable {
    /// Base32 NodeId surface form (52 chars). What we publish to Firestore.
    public let nodeId: String

    /// Raw 32-byte public key. Equal to `Data(base32Decoded: nodeId)` for
    /// the iroh NodeId encoding; surfaced explicitly so signature verifiers
    /// can avoid re-decoding on every check.
    public let rawPublicKey: Data

    public init(nodeId: String, rawPublicKey: Data) {
        self.nodeId = nodeId
        self.rawPublicKey = rawPublicKey
    }
}

/// Transport-level capability surface. Mac calls `start()` once, then
/// `accept()` in a loop; iOS calls `start()` then `connect(to:)` per stream.
public protocol IrohRelayTransport: AnyObject, Sendable {
    /// Bring up the underlying iroh endpoint. Idempotent.
    /// - Returns: the local NodeId, to be published or matched against a
    ///   peer's signed record.
    func start() async throws -> IrohEndpointIdentity

    /// Dial a remote endpoint and open one bidirectional stream. iOS uses
    /// this both for the initial `host.register` exchange (one persistent
    /// stream) and per request stream.
    func connect(to peer: String, timeout: TimeInterval) async throws -> any IrohRelayStream

    /// Wait for the next inbound bidirectional stream. Mac uses this in a
    /// loop. Cancellation honored.
    func accept(timeout: TimeInterval) async throws -> any IrohRelayStream

    /// Tear the endpoint down. Pending streams are closed.
    func shutdown() async
}
