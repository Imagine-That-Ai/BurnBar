package com.openburnbar.data.cloud

import android.os.Build
import com.google.firebase.firestore.FieldValue
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.SetOptions
import com.openburnbar.data.computeruse.ComputerUseSecurityCallableClient
import kotlinx.coroutines.tasks.await

data class AndroidEscrowDeviceRegistration(
    val deviceId: String,
    val trustState: String,
)

class AndroidEscrowDeviceRegistry(
    private val firestore: FirebaseFirestore = FirebaseFirestore.getInstance(),
    private val securityClient: ComputerUseSecurityCallableClient = ComputerUseSecurityCallableClient(),
) {
    suspend fun registerSelf(
        uid: String,
        keypair: AndroidCloudVaultDeviceKeypair = AndroidCloudVaultDeviceKeypair.loadOrCreate(),
        signalIdentity: AndroidSignalIdentityKeypair = AndroidSignalIdentityKeyStore.loadOrCreate(
            uid = uid,
            deviceId = keypair.deviceId,
        ),
    ): AndroidEscrowDeviceRegistration {
        val userRef = firestore.collection("users").document(uid)
        val deviceRef = userRef.collection("escrow_devices").document(keypair.deviceId)
        val existing = runCatching { deviceRef.get().await() }.getOrNull()
        val existingTrustState = existing?.getString("trustState")
        val trustState = if (existingTrustState == TRUSTED) TRUSTED else PENDING
        val deviceName =
            listOf(Build.MANUFACTURER, Build.MODEL)
                .filter { !it.isNullOrBlank() }
                .joinToString(" ")
                .ifBlank { "Android" }

        runCatching {
            securityClient.registerEscrowDevice(
                deviceId = keypair.deviceId,
                deviceName = deviceName,
                platform = "Android",
                publicKeyFingerprint = keypair.publicKeyFingerprint,
                keyVersion = keypair.keyVersion,
            )
        }

        publishPublicKeyIfNeeded(keypair = keypair, userRef = userRef)
        publishSignalIdentityIfNeeded(
            deviceId = keypair.deviceId,
            platform = "Android",
            identity = signalIdentity,
            userRef = userRef,
        )
        AndroidSignalPrekeyDirectory.publishIfNeeded(
            uid = uid,
            deviceId = keypair.deviceId,
            identity = signalIdentity,
            userRef = userRef,
        )

        return AndroidEscrowDeviceRegistration(
            deviceId = keypair.deviceId,
            trustState = trustState,
        )
    }

    suspend fun trustSelf(
        uid: String,
        keypair: AndroidCloudVaultDeviceKeypair = AndroidCloudVaultDeviceKeypair.loadOrCreate(),
    ): AndroidEscrowDeviceRegistration {
        registerSelf(uid = uid, keypair = keypair)
        securityClient.approveEscrowDeviceTrust(
            deviceId = keypair.deviceId,
            approverDeviceId = keypair.deviceId,
        )

        return AndroidEscrowDeviceRegistration(
            deviceId = keypair.deviceId,
            trustState = TRUSTED,
        )
    }

    companion object {
        const val PENDING = "pending"
        const val TRUSTED = "trusted"

        internal const val ESCROW_PUBLIC_KEY_ALGORITHM = "ECIES-P256-AESGCM"

        internal fun publicKeyDocumentMatches(
            data: Map<String, Any?>,
            keypair: AndroidCloudVaultDeviceKeypair,
            publicKeyDataBase64: String = CloudVaultCryptoSupport.encodeBase64(keypair.publicKeyData),
        ): Boolean = publicKeyDocumentMatches(
            data = data,
            deviceId = keypair.deviceId,
            publicKeyDataBase64 = publicKeyDataBase64,
            publicKeyFingerprint = keypair.publicKeyFingerprint,
            keyVersion = keypair.keyVersion,
        )

        internal fun publicKeyDocumentMatches(
            data: Map<String, Any?>,
            deviceId: String,
            publicKeyDataBase64: String,
            publicKeyFingerprint: String,
            keyVersion: Int,
        ): Boolean {
            if (data["deviceId"] != deviceId) return false
            if (data["publicKeyData"] != publicKeyDataBase64) return false
            if ((data["keyVersion"] as? Number)?.toInt() != keyVersion) return false
            if (data["algorithm"] != ESCROW_PUBLIC_KEY_ALGORITHM) return false

            val existingFingerprint = data["publicKeyFingerprint"] as? String
            return existingFingerprint == null || existingFingerprint == publicKeyFingerprint
        }

        internal fun signalIdentityDocumentMatches(
            data: Map<String, Any?>,
            deviceId: String,
            platform: String,
            identity: AndroidSignalIdentityKeypair,
        ): Boolean {
            if (data["deviceId"] != deviceId) return false
            if (data["platform"] != platform) return false
            if (data["identityKeyId"] != identity.identityKeyId) return false
            if (data["publicKeyData"] != identity.publicKeyBase64) return false
            if (data["publicKeyFingerprint"] != identity.publicKeyFingerprint) return false
            if ((data["keyVersion"] as? Number)?.toInt() != identity.keyVersion) return false
            if (data["algorithm"] != CloudVaultCrypto.SIGNAL_AT_REST_ENCRYPTION) return false
            return true
        }
    }

    private suspend fun publishPublicKeyIfNeeded(
        keypair: AndroidCloudVaultDeviceKeypair,
        userRef: com.google.firebase.firestore.DocumentReference,
    ) {
        val publicKeyDataBase64 = CloudVaultCryptoSupport.encodeBase64(keypair.publicKeyData)
        val publicKeyRef = userRef.collection("escrow_public_keys")
            .document("${keypair.deviceId}_${keypair.keyVersion}")
        val existing = publicKeyRef.get().await()
        if (existing.exists()) {
            val data = existing.data ?: emptyMap()
            require(publicKeyDocumentMatches(data, keypair, publicKeyDataBase64)) {
                "Escrow public key conflict for ${keypair.deviceId}_${keypair.keyVersion}."
            }
            return
        }

        publicKeyRef
            .set(
                mapOf(
                    "deviceId" to keypair.deviceId,
                    "publicKeyData" to publicKeyDataBase64,
                    "publicKeyFingerprint" to keypair.publicKeyFingerprint,
                    "keyVersion" to keypair.keyVersion,
                    "algorithm" to ESCROW_PUBLIC_KEY_ALGORITHM,
                    "createdAt" to FieldValue.serverTimestamp(),
                ),
                SetOptions.merge(),
            )
            .await()
    }

    private suspend fun publishSignalIdentityIfNeeded(
        deviceId: String,
        platform: String,
        identity: AndroidSignalIdentityKeypair,
        userRef: com.google.firebase.firestore.DocumentReference,
    ) {
        val identityRef = userRef.collection("signal_identity_public_keys")
            .document(identity.identityKeyId)
        val existing = identityRef.get().await()
        if (existing.exists()) {
            val data = existing.data ?: emptyMap()
            require(signalIdentityDocumentMatches(data, deviceId, platform, identity)) {
                "Signal identity public key conflict for ${identity.identityKeyId}."
            }
            return
        }

        identityRef
            .set(
                mapOf(
                    "deviceId" to deviceId,
                    "platform" to platform,
                    "identityKeyId" to identity.identityKeyId,
                    "publicKeyData" to identity.publicKeyBase64,
                    "publicKeyFingerprint" to identity.publicKeyFingerprint,
                    "keyVersion" to identity.keyVersion,
                    "algorithm" to CloudVaultCrypto.SIGNAL_AT_REST_ENCRYPTION,
                    "createdAt" to FieldValue.serverTimestamp(),
                ),
                SetOptions.merge(),
            )
            .await()
    }
}
