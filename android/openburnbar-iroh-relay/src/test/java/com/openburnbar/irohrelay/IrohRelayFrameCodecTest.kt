package com.openburnbar.irohrelay

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class IrohRelayFrameCodecTest {
    private val codec = IrohRelayFrameCodec()

    @Test
    fun encode_emits_length_prefix_then_payload() {
        val frame = HermesRealtimeRelayFrame(
            type = HermesRealtimeRelayFrameType.PING,
            uid = "u1",
            connectionId = "c1",
        )
        val envelope = codec.encode(frame)
        // First 4 bytes are big-endian length.
        val length = ((envelope[0].toInt() and 0xff) shl 24) or
            ((envelope[1].toInt() and 0xff) shl 16) or
            ((envelope[2].toInt() and 0xff) shl 8) or
            (envelope[3].toInt() and 0xff)
        assertEquals(envelope.size - 4, length)
    }

    @Test
    fun encode_and_decode_round_trip() {
        val frame = HermesRealtimeRelayFrame(
            type = HermesRealtimeRelayFrameType.REQUEST_START,
            uid = "user-1",
            connectionId = "conn-1",
            requestId = "req-1",
            payload = HermesRealtimeRelayPayload(
                method = "hermes.chat",
                wrappedKey = "AAA=",
                payloadCiphertext = "BBB=",
            ),
        )
        val envelope = codec.encode(frame)
        val decoded = codec.decode(envelope)
        assertEquals(frame.copy(protocolVersion = IrohRelayProtocol.FRAME_PROTOCOL_VERSION), decoded.frame)
        assertEquals(envelope.size, decoded.consumed)
    }

    @Test
    fun request_start_wire_json_uses_swift_codable_keys() {
        val frame = HermesRealtimeRelayFrame(
            type = HermesRealtimeRelayFrameType.REQUEST_START,
            uid = "user-1",
            connectionId = "conn-1",
            requestId = "req-1",
            payload = HermesRealtimeRelayPayload(
                operation = "chatCompletions",
                method = "POST",
                payloadCiphertext = "BBB=",
                wrappedKey = "AAA=",
                relayEncryption = "p256-hkdf-sha256-aesgcm",
                relayKeyVersion = 1,
            ),
        )
        val envelope = codec.encode(frame)
        val length = ((envelope[0].toInt() and 0xff) shl 24) or
            ((envelope[1].toInt() and 0xff) shl 16) or
            ((envelope[2].toInt() and 0xff) shl 8) or
            (envelope[3].toInt() and 0xff)
        val json = String(envelope.copyOfRange(4, 4 + length), Charsets.UTF_8)
        assertEquals(
            """{"type":"request.start","uid":"user-1","connectionId":"conn-1","requestId":"req-1","protocolVersion":1,"payload":{"operation":"chatCompletions","method":"POST","payloadCiphertext":"BBB=","wrappedKey":"AAA=","relayEncryption":"p256-hkdf-sha256-aesgcm","relayKeyVersion":1}}""",
            json,
        )
    }

    @Test
    fun decode_rejects_oversize_length_prefix() {
        val codec = IrohRelayFrameCodec(maxFrameBytes = 16)
        val envelope = ByteArray(4 + 32) { 0 }
        envelope[3] = 32.toByte() // length prefix = 32 bytes > 16 cap.
        assertThrows(IrohRelayTransportError.StreamRejected::class.java) { codec.decode(envelope) }
    }

    @Test
    fun decode_rejects_short_prefix() {
        assertThrows(IrohRelayTransportError.DecodeFailed::class.java) {
            codec.decode(ByteArray(2))
        }
    }

    @Test
    fun decode_rejects_truncated_payload() {
        val envelope = ByteArray(4 + 10) { 0 }
        envelope[3] = 10.toByte() // declared length 10 but payload only has 0 bytes after prefix? wrong.
        // Actually buffer size matches; let's truncate:
        val truncated = envelope.copyOfRange(0, 4 + 5)
        assertThrows(IrohRelayTransportError.DecodeFailed::class.java) {
            codec.decode(truncated)
        }
    }

    @Test
    fun encode_then_decode_consumes_full_envelope() {
        val frame = HermesRealtimeRelayFrame(
            type = HermesRealtimeRelayFrameType.PONG,
            uid = "u",
            connectionId = "c",
        )
        val a = codec.encode(frame)
        val b = codec.encode(frame)
        val concatenated = a + b
        val first = codec.decode(concatenated)
        assertEquals(a.size, first.consumed)
        val rest = concatenated.copyOfRange(first.consumed, concatenated.size)
        val second = codec.decode(rest)
        assertEquals(b.size, second.consumed)
        assertArrayEquals(a, codec.encode(first.frame))
    }
}
