package com.openburnbar.data.cloud

import com.google.firebase.firestore.FieldValue
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.FirebaseFirestoreException
import com.google.firebase.firestore.SetOptions
import com.openburnbar.BurnBarApplication
import kotlinx.coroutines.tasks.await

/**
 * Persistent Android Signal at-rest identity store — the counterpart of iOS
 * `OpenBurnBarSignalIdentityKeyStore` (OpenBurnBarCore/.../SignalIdentityKeyStore.swift).
 *
 * Storage mirrors `AndroidCloudVaultDeviceKeypair` exactly: the libsignal private key
 * bytes are wrapped by `AndroidLocalSecretBox` (an Android-Keystore AES-GCM key) and
 * kept in `SharedPreferences`; the public key bytes are stored alongside. The PRIVATE
 * key never leaves the device. Only the PUBLIC key is published to
 * `users/{uid}/signal_identity_public_keys/{identityKeyId}` (a client-direct write
 * validated by firestore.rules:3511-3557).
 *
 * The identity binds to the device's ESCROW identity: `deviceId` is the escrow
 * `AndroidCloudVaultDeviceKeypair.deviceId` and `keyVersion` its `keyVersion`, so
 * `signal_identity_public_keys/{deviceId}_{keyVersion}` lines up with the
 * `escrow_devices/{deviceId}` doc the L41 rules cross-check.
 *
 * Keystore + SharedPreferences are Android-runtime only (instrumented-verified); the
 * pure published-doc shape (`signalIdentityPublicKeyDoc`) is unit-tested for rules parity.
 */
object AndroidSignalIdentityKeyStore {
    private const val PREFS = "openburnbar_signal_identity"

    private fun privatePref(deviceId: String, keyVersion: Int) = "signal_private_${deviceId}_$keyVersion"

    private fun publicPref(deviceId: String, keyVersion: Int) = "signal_public_${deviceId}_$keyVersion"

    /** Load the device's Signal identity, generating + persisting it on first use. */
    fun loadOrCreate(deviceId: String, keyVersion: Int = 1): AndroidSignalIdentityKeypair {
        load(deviceId, keyVersion)?.let { return it }
        val prefs = BurnBarApplication.appContext.getSharedPreferences(PREFS, 0)
        val generated = AndroidSignalIdentityKeypair.generate(deviceId, keyVersion)
        prefs.edit()
            .putString(
                privatePref(deviceId, keyVersion),
                CloudVaultCryptoSupport.encodeBase64(AndroidLocalSecretBox.encrypt(generated.privateKeyData)),
            )
            .putString(publicPref(deviceId, keyVersion), CloudVaultCryptoSupport.encodeBase64(generated.publicKeyData))
            .apply()
        return generated
    }

    /** Load the persisted Signal identity, or null if none exists / it cannot be decrypted. */
    fun load(deviceId: String, keyVersion: Int = 1): AndroidSignalIdentityKeypair? {
        val prefs = BurnBarApplication.appContext.getSharedPreferences(PREFS, 0)
        val storedPrivate = prefs.getString(privatePref(deviceId, keyVersion), null) ?: return null
        val storedPublic = prefs.getString(publicPref(deviceId, keyVersion), null) ?: return null
        val privateBytes =
            runCatching { AndroidLocalSecretBox.decrypt(CloudVaultCryptoSupport.decodeBase64(storedPrivate)) }
                .getOrNull() ?: return null
        return AndroidSignalIdentityKeypair(
            identityKeyId = AndroidSignalIdentityKeypair.identityKeyId(deviceId, keyVersion),
            publicKeyData = CloudVaultCryptoSupport.decodeBase64(storedPublic),
            privateKeyData = privateBytes,
            keyVersion = keyVersion,
        )
    }

    /**
     * Publish the PUBLIC identity key once (idempotent). Client-direct write; the doc
     * must satisfy firestore.rules `validSignalIdentityPublicKeyDocument` +
     * `signalIdentityMatchesKnownDevice` (the escrow device must already be pending/trusted
     * with a matching keyVersion).
     */
    suspend fun publishIfNeeded(
        uid: String,
        deviceId: String,
        identity: AndroidSignalIdentityKeypair,
        platform: String = "Android",
        firestore: FirebaseFirestore = FirebaseFirestore.getInstance(),
    ) {
        val ref =
            firestore.collection("users").document(uid)
                .collection("signal_identity_public_keys").document(identity.identityKeyId)
        val existing = ref.get().await()
        if (existing.exists()) {
            // The identity public key is IMMUTABLE (firestore.rules allow update/delete: if false).
            // A re-publish must carry the SAME key; a mismatch means the local identity diverged
            // (e.g. prefs wiped but the doc survived) and would silently break decryption — fail
            // loudly, mirroring iOS immutablePublicKeyConflict.
            check(existing.getString("publicKeyData") == CloudVaultCryptoSupport.encodeBase64(identity.publicKeyData)) {
                "Signal identity public key conflict for ${identity.identityKeyId}: stored key differs from the local key."
            }
            return
        }
        val doc = HashMap(signalIdentityPublicKeyDoc(deviceId, identity, platform))
        doc["createdAt"] = FieldValue.serverTimestamp()
        doc["updatedAt"] = FieldValue.serverTimestamp()
        try {
            ref.set(doc, SetOptions.merge()).await()
        } catch (e: FirebaseFirestoreException) {
            // TOCTOU: a sibling coroutine created the doc between our exists() check and this set,
            // so this set is now an UPDATE, which the rules forbid (PERMISSION_DENIED). If the doc
            // now exists, a sibling won the (idempotent) race — treat as success. Otherwise rethrow.
            if (e.code == FirebaseFirestoreException.Code.PERMISSION_DENIED && ref.get().await().exists()) return
            throw e
        }
    }

    /**
     * The published-doc field set (minus server timestamps). Pure + unit-tested so the
     * client-direct write can never drift from the L41 rules `keys().hasOnly([...])`.
     */
    fun signalIdentityPublicKeyDoc(
        deviceId: String,
        identity: AndroidSignalIdentityKeypair,
        platform: String,
    ): Map<String, Any> =
        mapOf(
            "deviceId" to deviceId,
            "platform" to platform,
            "identityKeyId" to identity.identityKeyId,
            "publicKeyFingerprint" to CloudVaultCrypto.sha256Base64(identity.publicKeyData),
            "publicKeyData" to CloudVaultCryptoSupport.encodeBase64(identity.publicKeyData),
            "keyVersion" to identity.keyVersion,
            "keyVersionLabel" to identity.keyVersion.toString(),
            "algorithm" to CloudVaultCrypto.SIGNAL_AT_REST_ENCRYPTION,
        )
}
