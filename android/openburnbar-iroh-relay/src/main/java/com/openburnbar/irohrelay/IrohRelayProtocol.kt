package com.openburnbar.irohrelay

/**
 * Wire-version constants for the iroh transport. Mirrors
 * `IrohRelayProtocol` (Swift) — same ALPN, same protocol version, same
 * max-frame ceiling.
 */
object HermesRealtimeRelayProtocol {
    const val VERSION: Int = 1
    const val CAPABILITY: String = "realtime_relay"
    /** Required when binding a relay role on the legacy WSS path. */
    const val ROLE_HEADER_NAME: String = "X-OpenBurnBar-Relay-Role"
    const val HOST_ROLE_HEADER_VALUE: String = "host"
    const val CLIENT_ROLE_HEADER_VALUE: String = "client"
}

object IrohRelayProtocol {
    /** QUIC ALPN shared by Mac + iOS + Android. */
    const val ALPN: String = "openburnbar/1"

    /** Frame schema version. Same `HermesRealtimeRelayFrame` JSON shape across transports. */
    const val FRAME_PROTOCOL_VERSION: Int = HermesRealtimeRelayProtocol.VERSION

    /** Capability advertised by Mac in `host.register`. */
    const val CAPABILITY: String = "iroh_relay"

    /** Maximum length-prefix value on inbound frames: 512 KiB. */
    const val MAX_FRAME_BYTES: Int = 512 * 1024

    object WireFormat {
        /** Length prefix is a big-endian `UInt32` — same as Rust `to_be_bytes`. */
        const val LENGTH_PREFIX_BYTES: Int = 4
    }
}

enum class IrohRelayRole(val raw: String) {
    HOST("host"),
    CLIENT("client"),
}

/**
 * Lightweight error surface for the transport. Higher layers map these
 * into the existing `HermesServiceError.RelayUnavailable` envelope so
 * downstream code paths do not have to learn an iroh-specific taxonomy.
 */
sealed class IrohRelayTransportError(message: String) : RuntimeException(message) {
    object EndpointNotReady : IrohRelayTransportError("Iroh endpoint is not ready.")
    data class NodeIdUnreachable(val nodeId: String) : IrohRelayTransportError("Iroh node is unreachable: $nodeId.")
    data class StreamRejected(val detail: String) : IrohRelayTransportError(detail)
    object ProtocolMismatch : IrohRelayTransportError("Iroh protocol version mismatch.")
    data class DecodeFailed(val detail: String) : IrohRelayTransportError("Iroh frame decode failed: $detail")
    object TimedOut : IrohRelayTransportError("Iroh connection timed out.")
    object Shutdown : IrohRelayTransportError("Iroh endpoint is shut down.")
}
