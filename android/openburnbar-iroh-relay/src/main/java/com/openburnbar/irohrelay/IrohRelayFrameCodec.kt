package com.openburnbar.irohrelay

import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Length-prefixed JSON codec for `HermesRealtimeRelayFrame`. The Rust
 * crate writes `[u32 big-endian length][JSON payload]` onto the iroh
 * QUIC stream; this class reads/writes the same byte layout so the wire
 * format is byte-identical across iOS, Mac, and Android.
 */
class IrohRelayFrameCodec(
    private val maxFrameBytes: Int = IrohRelayProtocol.MAX_FRAME_BYTES,
) {
    /**
     * Encode a frame into the wire envelope. Throws if the encoded
     * payload would exceed `maxFrameBytes`.
     */
    fun encode(frame: HermesRealtimeRelayFrame): ByteArray {
        val payload = HermesRealtimeRelayJson
            .encodeToString(HermesRealtimeRelayFrame.serializer(), frame)
            .toByteArray(Charsets.UTF_8)
        if (payload.size > maxFrameBytes) {
            throw IrohRelayTransportError.StreamRejected(
                "iroh relay frame is ${payload.size} bytes, exceeds $maxFrameBytes."
            )
        }
        val envelope = ByteArray(payload.size + IrohRelayProtocol.WireFormat.LENGTH_PREFIX_BYTES)
        ByteBuffer.wrap(envelope, 0, IrohRelayProtocol.WireFormat.LENGTH_PREFIX_BYTES)
            .order(ByteOrder.BIG_ENDIAN)
            .putInt(payload.size)
        System.arraycopy(payload, 0, envelope, IrohRelayProtocol.WireFormat.LENGTH_PREFIX_BYTES, payload.size)
        return envelope
    }

    /**
     * Decode an inbound envelope. Returns the parsed frame and the number
     * of bytes consumed from the input.
     */
    fun decode(envelope: ByteArray): DecodedFrame {
        val prefix = IrohRelayProtocol.WireFormat.LENGTH_PREFIX_BYTES
        if (envelope.size < prefix) {
            throw IrohRelayTransportError.DecodeFailed("iroh frame envelope is shorter than length prefix.")
        }
        val length = ByteBuffer.wrap(envelope, 0, prefix).order(ByteOrder.BIG_ENDIAN).int
        if (length < 0 || length > maxFrameBytes) {
            throw IrohRelayTransportError.StreamRejected(
                "iroh relay inbound frame is $length bytes, exceeds $maxFrameBytes."
            )
        }
        val totalBytes = prefix + length
        if (envelope.size < totalBytes) {
            throw IrohRelayTransportError.DecodeFailed("iroh relay envelope is truncated.")
        }
        val payload = envelope.copyOfRange(prefix, totalBytes)
        return try {
            val frame = HermesRealtimeRelayJson.decodeFromString(
                HermesRealtimeRelayFrame.serializer(),
                payload.toString(Charsets.UTF_8),
            )
            DecodedFrame(frame, totalBytes)
        } catch (t: Throwable) {
            throw IrohRelayTransportError.DecodeFailed(t.message ?: t.javaClass.simpleName)
        }
    }

    data class DecodedFrame(val frame: HermesRealtimeRelayFrame, val consumed: Int)
}
