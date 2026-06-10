@file:Suppress("FunctionNaming", "MagicNumber")
// detekt: JUnit backtick BDD test names intentionally contain spaces.

package com.openburnbar

import com.openburnbar.data.computeruse.PhoneControlIntent
import com.openburnbar.data.computeruse.PhoneControlIntentKind
import com.openburnbar.data.computeruse.PhoneControlSigner
import com.openburnbar.data.computeruse.PhoneControlSignerVerify
import com.openburnbar.data.computeruse.PhoneControlSigningIdentity
import com.openburnbar.data.computeruse.PhoneControlSigningKeyStore
import com.openburnbar.irohrelay.HermesRealtimeRelayFrame
import com.openburnbar.irohrelay.HermesRealtimeRelayFrameType
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Wiring tests for [MainActivityE2EComputerUseStreamSetup], the E2E
 * proof-harness assembly: the control-classify preamble frame must carry the
 * published authority identity, and the tracking sender must sign real
 * verifiable envelopes with monotonic counters while mirroring every frame to
 * both the stream and the `lastSentFrame` probe.
 */
class MainActivityE2EComputerUseStreamSetupTest {
    private class RecordingStream : com.openburnbar.irohrelay.IrohRelayStream {
        val sent = mutableListOf<HermesRealtimeRelayFrame>()

        override suspend fun send(frame: HermesRealtimeRelayFrame) {
            sent += frame
        }

        override suspend fun receive(): HermesRealtimeRelayFrame? = null

        override suspend fun close() = Unit
    }

    private val seed = ByteArray(32) { (it + 31).toByte() }
    private val identity = PhoneControlSigningIdentity.Ed25519(seed)

    private fun keyStore(peerNodeId: String = "android-phone-e2e"): PhoneControlSigningKeyStore {
        val store = mockk<PhoneControlSigningKeyStore>()
        every { store.signingIdentity() } returns identity
        every { store.peerNodeId(identity) } returns peerNodeId
        return store
    }

    @Test
    fun `sendControlClassify emits one control input classify frame with the authority peer`() {
        val stream = RecordingStream()

        MainActivityE2EComputerUseStreamSetup.sendControlClassify(
            uid = "uid-1",
            connectionId = "conn-1",
            peerNodeId = "android-phone-e2e",
            stream = stream,
        )

        assertEquals(1, stream.sent.size)
        val frame = stream.sent.single()
        assertEquals(HermesRealtimeRelayFrameType.CONTROL_CLASSIFY, frame.type)
        assertEquals("uid-1", frame.uid)
        assertEquals("conn-1", frame.connectionId)
        val control = requireNotNull(frame.control)
        assertEquals("control.input", control.streamClass)
        assertEquals("android-phone-e2e", control.authorityPeerNodeId)
        assertNull(control.inputIntent)
    }

    @Test
    fun `tracking sender signs verifiable envelopes and mirrors the frame`() = runTest {
        val stream = RecordingStream()
        val sender = MainActivityE2EComputerUseStreamSetup.createPhoneControlSender(
            uid = "uid-1",
            connectionId = "conn-1",
            keyStore = keyStore(),
            stream = stream,
        )
        assertNull(sender.lastSentFrame)

        val intent = PhoneControlIntent(kind = PhoneControlIntentKind.TAP, normalizedX = 0.4, normalizedY = 0.6)
        val authority = sender.send(intent)

        // The probe sees exactly the frame the stream transported.
        assertEquals(1, stream.sent.size)
        assertSame(stream.sent.single(), sender.lastSentFrame)
        val frame = stream.sent.single()
        assertEquals(HermesRealtimeRelayFrameType.CONTROL_INPUT_INTENT, frame.type)
        val inputIntent = requireNotNull(requireNotNull(frame.control).inputIntent)
        assertEquals("TAP", inputIntent.kind.name)
        assertEquals(authority.intentHashBlake3, inputIntent.authority.intentHashBlake3)

        // The envelope is a real signature over the outbound intent.
        val outbound = intent.copy(clientIntentId = inputIntent.clientIntentId)
        PhoneControlSignerVerify.verify(
            intent = outbound,
            authority = authority,
            publicKey = PhoneControlSigner.publicKey(seed),
            lastSeenCounter = 0,
            nowMillis = authority.timestampMillis,
        )
    }

    @Test
    fun `counters are monotonic across sends so the mac replay gate holds`() = runTest {
        val stream = RecordingStream()
        val sender = MainActivityE2EComputerUseStreamSetup.createPhoneControlSender(
            uid = "uid-1",
            connectionId = "conn-1",
            keyStore = keyStore(),
            stream = stream,
        )

        val first = sender.send(PhoneControlIntent(kind = PhoneControlIntentKind.TAP, normalizedX = 0.1, normalizedY = 0.1))
        val second = sender.send(PhoneControlIntent(kind = PhoneControlIntentKind.TAP, normalizedX = 0.2, normalizedY = 0.2))

        assertTrue("counter must increase: ${first.counter} → ${second.counter}", second.counter > first.counter)
        assertEquals("android-phone-e2e", first.peerNodeId)
        assertEquals(2, stream.sent.size)
        assertNotEquals(stream.sent[0], stream.sent[1])
        assertSame(stream.sent[1], sender.lastSentFrame)
    }

    @Test
    fun `stream session exposes the transport and stream it was opened with`() {
        val transport = mockk<com.openburnbar.irohrelay.IrohRelayTransport>()
        val stream = RecordingStream()
        val session = MainActivityE2EComputerUseStreamSetup.StreamSession(transport, stream)
        assertSame(transport, session.transport)
        assertSame(stream, session.stream)
    }
}
