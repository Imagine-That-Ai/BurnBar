package com.openburnbar.data.cloud.signalsession

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.signal.libsignal.protocol.IdentityKey
import org.signal.libsignal.protocol.IdentityKeyPair
import org.signal.libsignal.protocol.SessionBuilder
import org.signal.libsignal.protocol.SessionCipher
import org.signal.libsignal.protocol.SignalProtocolAddress
import org.signal.libsignal.protocol.ecc.ECKeyPair
import org.signal.libsignal.protocol.message.CiphertextMessage
import org.signal.libsignal.protocol.message.PreKeySignalMessage
import org.signal.libsignal.protocol.message.SignalMessage

/**
 * Proves a full X3DH + PQXDH (Kyber) Double Ratchet session establishes and round-trips
 * between two [AndroidSignalProtocolStore] instances — the Android peer of the Swift
 * `OBBSignalProtocolStoreSessionTests`. Runs headlessly under `./gradlew :app:testDebugUnitTest`
 * against the desktop libsignal JNI (org.signal:libsignal-client on the test classpath) with NO
 * device/emulator. Constructor-order gotcha exercised: SessionBuilder(store, REMOTE, LOCAL) vs
 * SessionCipher(store, LOCAL, REMOTE).
 */
class AndroidSignalSessionRoundTripTest {

    private val aliceAddress = SignalProtocolAddress("alice", 1)
    private val bobAddress = SignalProtocolAddress("bob", 1)

    private fun newIdentity(): IdentityKeyPair {
        val ec = ECKeyPair.generate()
        return IdentityKeyPair(IdentityKey(ec.publicKey), ec.privateKey)
    }

    private fun newStore(registrationId: Int, vault: SignalRecordVault = InMemorySignalRecordVault()) =
        AndroidSignalProtocolStore.testingTOFU(newIdentity(), registrationId, vault)

    @Test
    fun fullPqxdhSessionEncryptDecrypt() {
        val alice = newStore(0x3f01)
        val bob = newStore(0x3f02)
        val now = 1_700_000_000_000L

        // Bob publishes prekeys; Alice claims his bundle (built here directly from Bob's records,
        // standing in for the server claim callable that lives on the functions lane).
        val bobPrekeys = AndroidSignalPreKeyGenerator.generatePreKeys(bob.getIdentityKeyPair(), 31337, 22, 8, now)
        AndroidSignalPreKeyGenerator.storePreKeys(bobPrekeys, bob)
        val bobBundle = AndroidSignalPreKeyGenerator.buildPreKeyBundle(
            bob.getIdentityKeyPair(),
            bob.getLocalRegistrationId(),
            bobAddress.deviceId,
            bobPrekeys,
        )

        // Alice establishes the session — SessionBuilder(store, REMOTE, LOCAL).
        SessionBuilder(alice, bobAddress, aliceAddress).process(bobBundle)
        assertTrue(alice.containsSession(bobAddress))

        // Alice's first message is a PreKey message (X3DH+PQXDH) — SessionCipher(store, LOCAL, REMOTE).
        val aliceCipher = SessionCipher(alice, aliceAddress, bobAddress)
        val plaintext = "secure window hello".toByteArray()
        val outgoing = aliceCipher.encrypt(plaintext)
        assertEquals(CiphertextMessage.PREKEY_TYPE, outgoing.type)

        // Bob decrypts the PreKey message, establishing his side of the session.
        val bobCipher = SessionCipher(bob, bobAddress, aliceAddress)
        val decrypted = bobCipher.decrypt(PreKeySignalMessage(outgoing.serialize()))
        assertArrayEquals(plaintext, decrypted)
        assertTrue(bob.containsSession(aliceAddress))

        // Bob replies with a Whisper (ratchet) message; Alice decrypts — the Double Ratchet advanced.
        val reply = "ratchet reply".toByteArray()
        val bobOutgoing = bobCipher.encrypt(reply)
        assertEquals(CiphertextMessage.WHISPER_TYPE, bobOutgoing.type)
        val aliceDecrypted = aliceCipher.decrypt(SignalMessage(bobOutgoing.serialize()))
        assertArrayEquals(reply, aliceDecrypted)
    }

    @Test
    fun sessionSurvivesStoreRoundTrip() {
        val aliceVault = InMemorySignalRecordVault()
        val aliceIdentity = newIdentity()
        val alice = AndroidSignalProtocolStore.testingTOFU(aliceIdentity, 0x4f01, aliceVault)
        val bob = newStore(0x4f02)
        val now = 1_700_000_000_000L

        val bobPrekeys = AndroidSignalPreKeyGenerator.generatePreKeys(bob.getIdentityKeyPair(), 4242, 7, 3, now)
        AndroidSignalPreKeyGenerator.storePreKeys(bobPrekeys, bob)
        val bobBundle = AndroidSignalPreKeyGenerator.buildPreKeyBundle(
            bob.getIdentityKeyPair(),
            bob.getLocalRegistrationId(),
            bobAddress.deviceId,
            bobPrekeys,
        )
        SessionBuilder(alice, bobAddress, aliceAddress).process(bobBundle)
        val first = SessionCipher(alice, aliceAddress, bobAddress).encrypt("first".toByteArray())
        SessionCipher(bob, bobAddress, aliceAddress).decrypt(PreKeySignalMessage(first.serialize()))

        // Reopen Alice's store from the SAME vault and decrypt Bob's later reply via the persisted session.
        val bobReply = SessionCipher(bob, bobAddress, aliceAddress).encrypt("second".toByteArray())
        val aliceReloaded = AndroidSignalProtocolStore.testingTOFU(aliceIdentity, 0x4f01, aliceVault)
        val out = SessionCipher(aliceReloaded, aliceAddress, bobAddress)
            .decrypt(SignalMessage(bobReply.serialize()))
        assertArrayEquals("second".toByteArray(), out)
    }
}
