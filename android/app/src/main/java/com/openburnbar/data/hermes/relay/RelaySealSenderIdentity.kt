package com.openburnbar.data.hermes.relay

import com.google.firebase.firestore.FirebaseFirestore
import com.openburnbar.BurnBarApplication
import com.openburnbar.data.cloud.AndroidCloudVaultDeviceKeypair
import com.openburnbar.data.cloud.AndroidSignalIdentityKeyStore
import com.openburnbar.data.cloud.CloudVaultCrypto
import com.openburnbar.data.computeruse.ComputerUseSecurityCallableClient
import com.openburnbar.data.computeruse.RelaySenderKeyPublishRequest
import java.security.PrivateKey
import kotlinx.coroutines.tasks.await

/**
 * F7/F10 — the relay sender identity both seal-key establishers wrap with.
 * One implementation of the exact publish dance the chat lane performs in
 * `HermesRelayClient.sendEnvelope` (and the iOS establishers perform via
 * `MobileHermesAuthenticatedRelayRequestSealer`):
 *
 *  1. load the persistent relay sender keypair ([HermesRelayKeyStore]),
 *  2. publish the Signal identity for this device if needed,
 *  3. publish the relay sender key through the `publishRelaySenderKey`
 *     callable (the Mac's pinned-sender trust resolver reads it from
 *     `relay_sender_keys/{deviceId}` and verifies escrow trust),
 *  4. mint a fresh monotonic counter namespaced to the seal lane
 *     (`control-seal.<keyId>` / `media-seal.<keyId>`).
 */
internal object RelaySealSenderIdentity {
    /** Counter namespaces, mirroring the iOS `nextCounter(keyID:)` call sites. */
    const val CONTROL_SEAL_COUNTER_PREFIX = "control-seal."
    const val MEDIA_SEAL_COUNTER_PREFIX = "media-seal."

    data class Prepared(
        val senderDeviceId: String,
        val senderPeerNodeId: String,
        val keyId: String,
        val senderCounter: Long,
        val senderPrivateKey: PrivateKey,
    )

    /**
     * Same derivation as the chat lane (`HermesRelayClient.relaySenderKeyId`)
     * and the iOS `MobileHermesAuthenticatedRelayRequestSealer.relaySenderKeyID`:
     * `"relay-v3-" ‖ first 12 bytes of SHA-256(key) as hex`.
     */
    fun relaySenderKeyId(publicKeyX963: ByteArray): String = "relay-v3-" + CloudVaultCrypto.sha256Hex(publicKeyX963).take(KEY_ID_HEX_CHARS)

    suspend fun prepareAndPublish(
        uid: String,
        connectionId: String,
        counterKeyPrefix: String,
        firestore: FirebaseFirestore = FirebaseFirestore.getInstance(),
        securityCallables: ComputerUseSecurityCallableClient = ComputerUseSecurityCallableClient(),
    ): Prepared {
        val keyStore = HermesRelayKeyStore(BurnBarApplication.appContext)
        val senderKeyPair = keyStore.loadOrCreateClientKeyPair()
        val senderPublicKeyX963 = keyStore.clientPublicKeyX963()
        val senderDevice = AndroidCloudVaultDeviceKeypair.loadOrCreate()
        val senderDeviceId = senderDevice.deviceId
        val keyId = relaySenderKeyId(senderPublicKeyX963)
        // The Mac resolves the pinned sender key through the SAME
        // relay_sender_keys + escrow-trust path as the chat lane, so the
        // identity must be published (and fresh) exactly like the chat sealer
        // publishes it.
        val signalIdentity = AndroidSignalIdentityKeyStore.loadOrCreate(senderDeviceId, senderDevice.keyVersion)
        AndroidSignalIdentityKeyStore.publishIfNeeded(
            uid = uid,
            deviceId = senderDeviceId,
            identity = signalIdentity,
            firestore = firestore,
        )
        securityCallables.publishRelaySenderKey(
            RelaySenderKeyPublishRequest(
                deviceId = senderDeviceId,
                peerNodeId = senderDeviceId,
                keyId = keyId,
                publicKeyBase64 = HermesRelayCryptoSupport.base64NoWrap(senderPublicKeyX963),
                relayKeyVersion = HermesRelayCrypto.KEY_VERSION_V3,
                publishedAtMillis = System.currentTimeMillis(),
                signalIdentityKeyId = signalIdentity.identityKeyId,
                signalIdentityKeyVersion = signalIdentity.keyVersion,
                signalIdentityPublicKeyFingerprint = CloudVaultCrypto.sha256Base64(signalIdentity.publicKeyData),
            ),
        )
        return Prepared(
            senderDeviceId = senderDeviceId,
            senderPeerNodeId = senderDeviceId,
            keyId = keyId,
            senderCounter = keyStore.nextAuthenticatedSenderCounter(connectionId, "$counterKeyPrefix$keyId"),
            senderPrivateKey = senderKeyPair.private,
        )
    }

    /**
     * The Mac's HPKE relay public key for [connectionId], read from the paired
     * connection record (`users/{uid}/hermes_connections/{id}.relayPublicKey`,
     * with the legacy collection fallback the chat lane also keeps) — never
     * from the stream itself. Returns null when the record is missing the key.
     */
    suspend fun macRelayPublicKeyBase64(uid: String, connectionId: String, firestore: FirebaseFirestore = FirebaseFirestore.getInstance()): String? {
        for (collection in listOf("hermes_connections", "hermes_relay_connections")) {
            val data =
                runCatching {
                    firestore.collection("users").document(uid)
                        .collection(collection).document(connectionId)
                        .get().await()
                        .data
                }.getOrNull() ?: continue
            val key =
                (data["relayPublicKey"] as? String ?: data["relay_public_key"] as? String)
                    ?.trim()
                    ?.takeIf { it.isNotEmpty() }
            if (key != null) return key
        }
        return null
    }

    private const val KEY_ID_HEX_CHARS = 24
}
