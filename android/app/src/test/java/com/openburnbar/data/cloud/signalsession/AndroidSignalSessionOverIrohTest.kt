package com.openburnbar.data.cloud.signalsession

import com.openburnbar.irohrelay.IrohDialTarget
import com.openburnbar.irohrelay.LoopbackIrohRelayRendezvous
import com.openburnbar.irohrelay.LoopbackIrohRelayTransport
import java.util.Base64
import kotlinx.coroutines.async
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Test
import org.signal.libsignal.protocol.IdentityKeyPair
import org.signal.libsignal.protocol.message.CiphertextMessage

class AndroidSignalSessionOverIrohTest {
    @Test
    fun loopbackSignalSessionRoundTrip() =
        runTest {
            val uid = "signal-user"
            val alicePeer =
                AndroidSignalSessionPeer(
                    uid = uid,
                    deviceId = "android-device",
                    identityKeyId = "android-device_1",
                    keyVersion = 1,
                    signalDeviceIdOverride = 1,
                    registrationIdOverride = 0x3f01,
                )
            val bobPeer =
                AndroidSignalSessionPeer(
                    uid = uid,
                    deviceId = "mac-device",
                    identityKeyId = "mac-device_1",
                    keyVersion = 1,
                    signalDeviceIdOverride = 1,
                    registrationIdOverride = 0x3f02,
                )
            val aliceAddress = alicePeer.address()
            val bobAddress = bobPeer.address()
            val alice = AndroidSignalProtocolStore(IdentityKeyPair.generate(), alicePeer.registrationId, InMemorySignalRecordVault())
            val bob = AndroidSignalProtocolStore(IdentityKeyPair.generate(), bobPeer.registrationId, InMemorySignalRecordVault())
            val bobPrekeys = AndroidSignalPreKeyGenerator.generatePreKeys(
                identityKeyPair = bob.getIdentityKeyPair(),
                preKeyId = 31337,
                signedPreKeyId = 22,
                kyberPreKeyId = 8,
                nowMillis = 1_700_000_000_000L,
            )
            AndroidSignalPreKeyGenerator.storePreKeys(bobPrekeys, bob)
            val claimedBobBundle = claimedBundle(uid = uid, peer = bobPeer, store = bob, prekeys = bobPrekeys)

            val rendezvous = LoopbackIrohRelayRendezvous()
            val host = LoopbackIrohRelayTransport(rendezvous, nodeId = "mac-signal-loopback")
            val client = LoopbackIrohRelayTransport(rendezvous, nodeId = "android-signal-loopback")
            host.start()
            client.start()

            val aliceManager = AndroidSignalSessionManager(store = alice, localAddress = aliceAddress)
            val bobManager = AndroidSignalSessionManager(store = bob, localAddress = bobAddress)

            val hostTask =
                async {
                    val inbound = host.accept(timeoutMillis = 2_000)
                    val received = bobManager.receive(stream = inbound, remoteAddress = aliceAddress)
                    val replyFrame =
                        bobManager.send(
                            plaintext = "ratchet reply over iroh".toByteArray(),
                            remoteAddress = aliceAddress,
                            stream = inbound,
                            uid = uid,
                            connectionId = "session-conn",
                            requestId = "session-req",
                        )
                    received to replyFrame
                }

            val outbound = client.connect(IrohDialTarget(nodeId = "mac-signal-loopback"), timeoutMillis = 2_000)
            val firstFrame =
                aliceManager.establishOutbound(
                    claimSignalPrekeyBundle = { claimedBobBundle },
                    plaintext = "hello over signal+iroh".toByteArray(),
                    stream = outbound,
                    uid = uid,
                    connectionId = "session-conn",
                    requestId = "session-req",
                )
            assertEquals(CiphertextMessage.PREKEY_TYPE, firstFrame.signalMessageType)
            assertNotNull(firstFrame.signalSessionCiphertextB64)

            val reply = withTimeout(2_000) { aliceManager.receive(stream = outbound, remoteAddress = bobAddress) }
            assertEquals(CiphertextMessage.WHISPER_TYPE, reply.messageType)
            assertArrayEquals("ratchet reply over iroh".toByteArray(), reply.plaintext)

            val (hostReceived, replyFrame) = hostTask.await()
            assertEquals(CiphertextMessage.PREKEY_TYPE, hostReceived.messageType)
            assertArrayEquals("hello over signal+iroh".toByteArray(), hostReceived.plaintext)
            assertEquals(CiphertextMessage.WHISPER_TYPE, replyFrame.signalMessageType)

            client.shutdown()
            host.shutdown()
        }

    @Test
    fun peerMappingIsDeterministic() {
        val first = AndroidSignalSessionPeer(uid = "u", deviceId = "phone/one", identityKeyId = "phone/one_1", keyVersion = 1)
        val second = AndroidSignalSessionPeer(uid = "u", deviceId = "phone/one", identityKeyId = "phone/one_1", keyVersion = 1)

        assertEquals(first.protocolAddressName, second.protocolAddressName)
        assertEquals(first.signalDeviceId, second.signalDeviceId)
        assertEquals(first.registrationId, second.registrationId)
        assertEquals(first.address(), second.address())
    }

    private fun claimedBundle(
        uid: String,
        peer: AndroidSignalSessionPeer,
        store: AndroidSignalProtocolStore,
        prekeys: AndroidSignalPreKeyGenerator.GeneratedPreKeys,
    ): AndroidSignalClaimedPreKeyBundle =
        AndroidSignalClaimedPreKeyBundle(
            peerUid = uid,
            identityKeyId = peer.identityKeyId,
            deviceId = peer.deviceId,
            keyVersion = peer.keyVersion ?: 1,
            identityPublicKeyData = b64(store.getIdentityKeyPair().publicKey.publicKey.serialize()),
            signedPreKey =
                AndroidSignalClaimedSignedPreKey(
                    id = "spk-${prekeys.signedPreKey.id}",
                    numericId = prekeys.signedPreKey.id,
                    publicKeyB64 = b64(prekeys.signedPreKey.keyPair.publicKey.serialize()),
                    signatureB64 = b64(prekeys.signedPreKey.signature),
                ),
            kyberPreKey =
                AndroidSignalClaimedKyberPreKey(
                    id = "kpk-${prekeys.kyberPreKey.id}",
                    numericId = prekeys.kyberPreKey.id,
                    publicKeyB64 = b64(prekeys.kyberPreKey.keyPair.publicKey.serialize()),
                    signatureB64 = b64(prekeys.kyberPreKey.signature),
                ),
            oneTimePreKey =
                AndroidSignalClaimedOneTimePreKey(
                    id = "otpk-${prekeys.preKey.id}",
                    numericId = prekeys.preKey.id,
                    publicKeyB64 = b64(prekeys.preKey.keyPair.publicKey.serialize()),
                ),
            signalDeviceId = peer.signalDeviceId,
            signalRegistrationId = peer.registrationId,
        )

    private fun b64(bytes: ByteArray): String = Base64.getEncoder().encodeToString(bytes)
}
