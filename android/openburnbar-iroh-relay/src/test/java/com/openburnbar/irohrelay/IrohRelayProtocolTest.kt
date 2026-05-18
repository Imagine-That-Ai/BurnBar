package com.openburnbar.irohrelay

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.assertThrows
import org.junit.Test

/**
 * Wire-format constants must match the iOS / Mac copy of the
 * `IrohRelayProtocol` table byte-for-byte. These tests pin them so a
 * cross-platform drift is caught at PR time, not when a Mac and an
 * Android phone meet on the relay and silently disagree.
 */
class IrohRelayProtocolTest {

    @Test
    fun alpn_pins_to_openburnbar_v1() {
        assertEquals("openburnbar/1", IrohRelayProtocol.ALPN)
    }

    @Test
    fun max_frame_bytes_pins_to_512KiB() {
        assertEquals(512 * 1024, IrohRelayProtocol.MAX_FRAME_BYTES)
    }

    @Test
    fun length_prefix_is_four_bytes() {
        assertEquals(4, IrohRelayProtocol.WireFormat.LENGTH_PREFIX_BYTES)
    }

    @Test
    fun protocol_frame_version_is_one() {
        assertEquals(1, IrohRelayProtocol.FRAME_PROTOCOL_VERSION)
        assertEquals(HermesRealtimeRelayProtocol.VERSION, IrohRelayProtocol.FRAME_PROTOCOL_VERSION)
    }

    @Test
    fun role_header_values_match_swift_constants() {
        assertEquals("X-OpenBurnBar-Relay-Role", HermesRealtimeRelayProtocol.ROLE_HEADER_NAME)
        assertEquals("host", HermesRealtimeRelayProtocol.HOST_ROLE_HEADER_VALUE)
        assertEquals("client", HermesRealtimeRelayProtocol.CLIENT_ROLE_HEADER_VALUE)
    }

    @Test
    fun codec_enforces_max_bytes_on_outbound_frames() {
        // 600 KiB body > the 512 KiB ceiling — encode must reject it as
        // a `StreamRejected` to avoid letting an oversize frame land on
        // the relay where Mac will hang up the stream.
        val codec = IrohRelayFrameCodec(maxFrameBytes = IrohRelayProtocol.MAX_FRAME_BYTES)
        val oversize = HermesRealtimeRelayFrame(
            type = HermesRealtimeRelayFrameType.REQUEST_START,
            uid = "u",
            connectionId = "c",
            requestId = "r",
            payload = HermesRealtimeRelayPayload(
                payloadCiphertext = "A".repeat(600 * 1024),
            ),
        )
        val thrown = assertThrows(IrohRelayTransportError.StreamRejected::class.java) {
            codec.encode(oversize)
        }
        assertTrue(
            "expected oversize-message, got '${thrown.detail}'",
            thrown.detail.contains("exceeds"),
        )
    }

    @Test
    fun codec_rejects_malformed_length_prefix() {
        val codec = IrohRelayFrameCodec()
        val bytes = ByteArray(IrohRelayProtocol.WireFormat.LENGTH_PREFIX_BYTES - 1) { 0 }
        assertThrows(IrohRelayTransportError.DecodeFailed::class.java) {
            codec.decode(bytes)
        }
    }
}
