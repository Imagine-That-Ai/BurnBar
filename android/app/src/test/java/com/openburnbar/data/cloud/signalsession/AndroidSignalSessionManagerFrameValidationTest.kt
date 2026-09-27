package com.openburnbar.data.cloud.signalsession

import com.openburnbar.irohrelay.HermesRealtimeRelayFrame
import com.openburnbar.irohrelay.HermesRealtimeRelayFrameType
import com.openburnbar.irohrelay.IrohRelayStream
import io.mockk.coEvery
import io.mockk.mockk
import java.util.Base64
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test
import org.signal.libsignal.protocol.IdentityKeyPair
import org.signal.libsignal.protocol.SignalProtocolAddress

/**
 * Malformed inbound frames fail closed with user-safe copy (no "Signal" jargon)
 * before any ratchet state is touched.
 */
class AndroidSignalSessionManagerFrameValidationTest {
    private val remoteAddress = SignalProtocolAddress("remote-device", 1)
    private val manager =
        AndroidSignalSessionManager(
            store = AndroidSignalProtocolStore.testingTOFU(IdentityKeyPair.generate(), 0x3f01, InMemorySignalRecordVault()),
            localAddress = SignalProtocolAddress("local-device", 1),
        )

    private fun frame(ciphertextB64: String? = "AAAA", messageType: Int? = 2) = HermesRealtimeRelayFrame(
        type = HermesRealtimeRelayFrameType.SIGNAL_SESSION_MESSAGE,
        uid = "uid",
        connectionId = "conn",
        signalSessionCiphertextB64 = ciphertextB64,
        signalMessageType = messageType,
    )

    @Test
    fun receiveFailsWhenTheStreamClosesBeforeAFrame() = runTest {
        val stream = mockk<IrohRelayStream>()
        coEvery { stream.receive() } returns null

        val error = runCatching { manager.receive(stream = stream, remoteAddress = remoteAddress) }.exceptionOrNull()

        assertEquals("Secure session stream closed before a message frame arrived.", error?.message)
    }

    @Test
    fun decryptRejectsAFrameWithoutCiphertext() {
        val error = assertThrows(IllegalArgumentException::class.java) {
            manager.decrypt(frame = frame(ciphertextB64 = null), remoteAddress = remoteAddress)
        }
        assertEquals("Secure session frame is missing ciphertext.", error.message)
    }

    @Test
    fun decryptRejectsAFrameWithoutMessageType() {
        val error = assertThrows(IllegalArgumentException::class.java) {
            manager.decrypt(frame = frame(messageType = null), remoteAddress = remoteAddress)
        }
        assertEquals("Secure session frame is missing message type.", error.message)
    }

    @Test
    fun decryptRejectsAnUnsupportedMessageType() {
        val error = assertThrows(IllegalStateException::class.java) {
            manager.decrypt(
                frame = frame(ciphertextB64 = Base64.getEncoder().encodeToString(byteArrayOf(1, 2, 3)), messageType = 99),
                remoteAddress = remoteAddress,
            )
        }
        assertEquals("Unsupported secure session message type 99.", error.message)
    }
}
