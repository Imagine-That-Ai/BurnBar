import Foundation
import OpenBurnBarCore

/// Wire-version constants for the iroh transport. Mirrors
/// `HermesRealtimeRelayProtocol` for the WebSocket relay — same protocol
/// version on the frame, new ALPN on the QUIC layer.
public enum IrohRelayProtocol {
    /// QUIC ALPN identifier shared by Mac + iOS. Bumping this string is the
    /// clean upgrade boundary across both platforms; old + new clients refuse
    /// to handshake until both ends agree on the ALPN.
    public static let alpn = "openburnbar/1"

    /// Frame schema version. Same `HermesRealtimeRelayFrame` JSON shape that
    /// the Cloud Run relay ships; iroh is purely a transport swap.
    public static let frameProtocolVersion = HermesRealtimeRelayProtocol.version

    /// Capability advertised by the Mac in its `host.register` frame. Lets
    /// iOS confirm the Mac is iroh-transport-aware before binding requests
    /// to the iroh stream instead of the WebSocket socket.
    public static let capability = "iroh_relay"

    /// Maximum length-prefix value accepted on inbound frames. Matches
    /// `DEFAULT_MAX_FRAME_BYTES` in the Cloud Run relay: 512 KiB.
    public static let maxFrameBytes: Int = 512 * 1024

    /// Length prefix is a big-endian `UInt32`, matching the Rust crate's
    /// `to_be_bytes` writer. Surface this here so test code never has to
    /// rederive the wire format.
    public enum WireFormat {
        public static let lengthPrefixBytes = 4
    }
}

/// Logical role on the iroh connection. Mac hosts; iOS clients open
/// per-request bidirectional streams. Same model as the WebSocket relay.
public enum IrohRelayRole: String, Sendable, Equatable {
    case host
    case client
}

/// Lightweight error surface for the transport. Higher layers map these into
/// the existing `HermesServiceError.relayUnavailable(...)` envelope so
/// downstream code paths do not have to learn an iroh-specific taxonomy.
public enum IrohRelayTransportError: Error, Equatable, Sendable {
    case endpointNotReady
    case nodeIdUnreachable(String)
    case streamRejected(String)
    case protocolMismatch
    case decodeFailed(String)
    case timedOut
    case shutdown
}
