package com.openburnbar.irohrelay

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Test

class HermesRealtimeRelayControlFrameTest {
    @Test
    fun codecRoundTripsControlInputIntentFrame() {
        val frame = HermesRealtimeRelayFrame(
            type = HermesRealtimeRelayFrameType.CONTROL_INPUT_INTENT,
            uid = "uid-1",
            connectionId = "conn-1",
            control = HermesRealtimeRelayControlPayload(
                streamClass = "control.input",
                inputIntent = HermesRealtimeRelayInputIntent(
                    kind = HermesRealtimeRelayInputIntentKind.SCROLL,
                    normalizedX = 0.4,
                    normalizedY = 0.5,
                    normalizedX2 = 0.4,
                    normalizedY2 = 0.2,
                    authority = HermesRealtimeRelayAuthorityEnvelope(
                        peerNodeId = "android-phone-1",
                        counter = 42,
                        timestamp = 721_692_800.123,
                        intentHashBlake3 = "f".repeat(64),
                        signatureEd25519 = "signature",
                    ),
                ),
            ),
        )

        val codec = IrohRelayFrameCodec()
        val decoded = codec.decode(codec.encode(frame)).frame

        assertEquals(HermesRealtimeRelayFrameType.CONTROL_INPUT_INTENT, decoded.type)
        assertEquals("control.input", decoded.control?.streamClass)
        assertNotNull(decoded.control?.inputIntent)
        assertEquals(HermesRealtimeRelayInputIntentKind.SCROLL, decoded.control?.inputIntent?.kind)
        assertEquals(0.2, decoded.control?.inputIntent?.normalizedY2 ?: -1.0, 0.0)
        assertEquals(42L, decoded.control?.inputIntent?.authority?.counter)
        assertEquals("f".repeat(64), decoded.control?.inputIntent?.authority?.intentHashBlake3)
    }
}
