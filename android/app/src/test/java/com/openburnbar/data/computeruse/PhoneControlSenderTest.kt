package com.openburnbar.data.computeruse

import com.openburnbar.data.media.MediaStreamClass
import com.openburnbar.irohrelay.HermesRealtimeRelayFrame
import com.openburnbar.irohrelay.HermesRealtimeRelayFrameType
import com.openburnbar.irohrelay.HermesRealtimeRelayInputIntentKind
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertThrows
import org.junit.Test

class PhoneControlSenderTest {
    private val privateSeed = ByteArray(32) { index -> (index + 1).toByte() }

    @Test
    fun sendWritesSignedControlInputFrame() = runBlocking {
        val frames = mutableListOf<HermesRealtimeRelayFrame>()
        val sender = PhoneControlSender(
            uid = "uid-1",
            connectionId = "conn-1",
            peerNodeId = "android-phone-1",
            privateKeySeedProvider = { privateSeed },
            counterStore = InMemoryPhoneControlCounterStore(),
            nowMillis = { 1_700_000_000_123L },
            frameSink = { frames += it },
        )

        val authority = sender.send(
            PhoneControlIntent(
                kind = PhoneControlIntentKind.SCROLL,
                normalizedX = 0.4,
                normalizedY = 0.5,
                normalizedX2 = 0.4,
                normalizedY2 = 0.2,
            )
        )

        assertEquals(1, frames.size)
        val frame = frames.single()
        assertEquals(HermesRealtimeRelayFrameType.CONTROL_INPUT_INTENT, frame.type)
        assertEquals("uid-1", frame.uid)
        assertEquals("conn-1", frame.connectionId)
        assertEquals(MediaStreamClass.CONTROL_INPUT.raw, frame.control?.streamClass)
        val input = frame.control?.inputIntent
        assertNotNull(input)
        assertEquals(HermesRealtimeRelayInputIntentKind.SCROLL, input?.kind)
        assertEquals(0.4, input?.normalizedX ?: -1.0, 0.0)
        assertEquals(0.2, input?.normalizedY2 ?: -1.0, 0.0)
        assertNotNull(input?.clientIntentId)
        assertEquals("android-phone-1", input?.authority?.peerNodeId)
        assertEquals(1L, input?.authority?.counter)
        assertEquals(721_692_800.123, input?.authority?.timestamp ?: -1.0, 0.000_001)
        assertEquals(authority.intentHashBlake3, input?.authority?.intentHashBlake3)

        PhoneControlSigner.verify(
            intent = PhoneControlIntent(
                kind = PhoneControlIntentKind.SCROLL,
                normalizedX = 0.4,
                normalizedY = 0.5,
                normalizedX2 = 0.4,
                normalizedY2 = 0.2,
                clientIntentId = input?.clientIntentId,
            ),
            authority = authority,
            publicKey = PhoneControlSigner.publicKey(privateSeed),
            lastSeenCounter = 0,
            nowMillis = 1_700_000_000_123L,
        )
    }

    @Test
    fun sendIncrementsCounterPerPeer() = runBlocking {
        val frames = mutableListOf<HermesRealtimeRelayFrame>()
        val sender = PhoneControlSender(
            uid = "uid-1",
            connectionId = "conn-1",
            peerNodeId = "android-phone-1",
            privateKeySeedProvider = { privateSeed },
            counterStore = InMemoryPhoneControlCounterStore(mapOf("android-phone-1" to 41L)),
            nowMillis = { 1_700_000_000_000L },
            frameSink = { frames += it },
        )

        val first = sender.send(PhoneControlIntent(kind = PhoneControlIntentKind.PANIC))
        val second = sender.send(PhoneControlIntent(kind = PhoneControlIntentKind.PANIC))

        assertEquals(42L, first.counter)
        assertEquals(43L, second.counter)
        assertEquals(42L, frames[0].control?.inputIntent?.authority?.counter)
        assertEquals(43L, frames[1].control?.inputIntent?.authority?.counter)
    }

    @Test
    fun sendFailsWhenSigningKeyMissing() {
        val sender = PhoneControlSender(
            uid = "uid-1",
            connectionId = "conn-1",
            peerNodeId = "android-phone-1",
            privateKeySeedProvider = { null },
            counterStore = InMemoryPhoneControlCounterStore(),
            frameSink = {},
        )

        assertThrows(PhoneControlSender.SendError.SigningKeyMissing::class.java) {
            runBlocking {
                sender.send(PhoneControlIntent(kind = PhoneControlIntentKind.PANIC))
            }
        }
    }
}
