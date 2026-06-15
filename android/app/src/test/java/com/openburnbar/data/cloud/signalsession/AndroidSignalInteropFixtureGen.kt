package com.openburnbar.data.cloud.signalsession

import java.io.File
import java.util.Base64
import org.json.JSONObject
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.signal.libsignal.protocol.IdentityKeyPair
import org.signal.libsignal.protocol.SessionBuilder
import org.signal.libsignal.protocol.SessionCipher
import org.signal.libsignal.protocol.SignalProtocolAddress
import org.signal.libsignal.protocol.message.CiphertextMessage

/**
 * Reverse-direction cross-language interop fixture GENERATOR (run on demand, not a CI assertion) —
 * the Android mirror of the Swift `OBBSignalInteropFixtureGen`, in the OTHER direction.
 *
 * Emits a frozen fixture in which Alice (Android `AndroidSignalProtocolStore`) establishes an
 * X3DH+PQXDH session from Bob's bundle and encrypts two messages on the same sending chain. The
 * companion Swift test (`OBBSignalInteropKatTests`) reconstructs Bob's store from the same key
 * material and decrypts both — proving the Android and Swift session stores interoperate on the
 * real official-libsignal wire format in the Android-Alice -> Swift-Bob direction.
 *
 * Both messages are PreKey-type: libsignal keeps wrapping Alice's messages as PreKeySignalMessage
 * until she receives a reply, so the second message exercises the symmetric message-key chain
 * ratchet (not a DH-ratchet whisper). A DH-ratchet whisper from a peer reconstructed from public
 * material alone is not decryptable (it requires the receiver's prior random ratchet key); the
 * bidirectional DH-ratchet whisper reply is proven in-process by the loopback transport KATs
 * (`OBBSignalSessionOverIrohTests` / `AndroidSignalSessionOverIrohTest`).
 *
 * Run with: OBB_INTEROP_OUT=/abs/path.json ./gradlew :app:testDebugUnitTest \
 *   --tests 'com.openburnbar.data.cloud.signalsession.AndroidSignalInteropFixtureGen'
 * Then copy the JSON byte-for-byte into the three committed fixture locations consumed by both sides.
 */
class AndroidSignalInteropFixtureGen {

    @Test
    fun emitAndroidAliceToSwiftBobFixture() {
        val rawOut = System.getenv("OBB_INTEROP_OUT")
        assumeTrue("set OBB_INTEROP_OUT to emit the interop fixture", rawOut != null)
        val outPath = checkNotNull(rawOut)
        val now = 1_700_000_000_000L

        val bobReg = 0x0B0B
        val bobIdentity = IdentityKeyPair.generate()
        val bob = AndroidSignalProtocolStore.testingTOFU(bobIdentity, bobReg, InMemorySignalRecordVault())
        val alice = AndroidSignalProtocolStore.testingTOFU(IdentityKeyPair.generate(), 0x0A1C, InMemorySignalRecordVault())

        // Bob publishes a bundle (prekey ids 1/1/1).
        val bobPrekeys = AndroidSignalPreKeyGenerator.generatePreKeys(bob.getIdentityKeyPair(), 1, 1, 1, now)
        AndroidSignalPreKeyGenerator.storePreKeys(bobPrekeys, bob)
        val bobBundle = AndroidSignalPreKeyGenerator.buildPreKeyBundle(bob.getIdentityKeyPair(), bobReg, 1, bobPrekeys)

        // Address names MUST match what the Swift consumer uses.
        val aliceAddress = SignalProtocolAddress("alice", 1)
        val bobAddress = SignalProtocolAddress("bob", 1)

        // Alice establishes the session — SessionBuilder(store, REMOTE, LOCAL).
        SessionBuilder(alice, bobAddress, aliceAddress).process(bobBundle)
        val aliceCipher = SessionCipher(alice, aliceAddress, bobAddress)

        val firstPlaintext = "interop hello from android alice"
        val firstMessage = aliceCipher.encrypt(firstPlaintext.toByteArray())
        require(firstMessage.type == CiphertextMessage.PREKEY_TYPE) { "first message must be a PreKey message" }

        // Second message on the SAME sending chain (still PreKey-typed until Alice gets a reply);
        // exercises the symmetric message-key chain ratchet across the wire.
        val secondPlaintext = "second interop message from android alice"
        val secondMessage = aliceCipher.encrypt(secondPlaintext.toByteArray())

        val b64 = Base64.getEncoder()
        val fixture = JSONObject()
        fixture.put("schema", "obb-signal-interop-v1")
        fixture.put("direction", "android-alice-to-swift-bob")
        fixture.put("aliceAddressName", "alice")
        fixture.put("bobAddressName", "bob")
        fixture.put("deviceId", 1)
        fixture.put("bobRegistrationId", bobReg)
        fixture.put("bobIdentityKeyPairB64", b64.encodeToString(bob.getIdentityKeyPair().serialize()))
        fixture.put("bobPreKeyId", 1)
        fixture.put("bobPreKeyRecordB64", b64.encodeToString(bobPrekeys.preKey.serialize()))
        fixture.put("bobSignedPreKeyId", 1)
        fixture.put("bobSignedPreKeyRecordB64", b64.encodeToString(bobPrekeys.signedPreKey.serialize()))
        fixture.put("bobKyberPreKeyId", 1)
        fixture.put("bobKyberPreKeyRecordB64", b64.encodeToString(bobPrekeys.kyberPreKey.serialize()))
        fixture.put("ciphertextType", firstMessage.type)
        fixture.put("ciphertextB64", b64.encodeToString(firstMessage.serialize()))
        fixture.put("expectedPlaintext", firstPlaintext)
        fixture.put("secondCiphertextType", secondMessage.type)
        fixture.put("secondCiphertextB64", b64.encodeToString(secondMessage.serialize()))
        fixture.put("secondExpectedPlaintext", secondPlaintext)

        File(outPath).writeText(fixture.toString(2))
    }
}
