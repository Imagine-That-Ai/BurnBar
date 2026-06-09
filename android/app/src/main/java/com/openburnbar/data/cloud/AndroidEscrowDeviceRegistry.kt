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

        // Eagerly publish this device's Signal identity PUBLIC key (item 3, iOS parity:
        // MobileCloudVaultKeyAccess publishes it during keyForWriting). Publishing at escrow
        // registration ensures every trusted device's Signal identity exists in Firestore BEFORE
        // the at-rest sealing gate is ever flipped, so atRestRecipients never fail-closes on a
        // peer that simply hasn't published yet (closes the activation bootstrap gap). Best-effort:
        // a rules race during the pending window must not break escrow registration. This writes
        // only a public key — it does NOT activate Signal sealing (sealingScheme stays default).
        runCatching {
            val identity = AndroidSignalIdentityKeyStore.loadOrCreate(keypair.deviceId, keypair.keyVersion)
            AndroidSignalIdentityKeyStore.publishIfNeeded(
                uid = uid,
                deviceId = keypair.deviceId,
                identity = identity,
                firestore = firestore,
            )
        }

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
        val trustChain = buildTrustChainProof(
            uid = uid,
            targetDeviceId = keypair.deviceId,
            approverDeviceId = keypair.deviceId,
            approverKeyVersion = keypair.keyVersion,
        )
        securityClient.approveEscrowDeviceTrust(
            deviceId = keypair.deviceId,
            approverDeviceId = keypair.deviceId,
            trustChain = trustChain.asMap(),
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

    private suspend fun buildTrustChainProof(
        uid: String,
        targetDeviceId: String,
        approverDeviceId: String,
        approverKeyVersion: Int,
    ): CloudVaultDeviceTrustChainProof {
        val userRef = firestore.collection("users").document(uid)
        val approverIdentity = AndroidSignalIdentityKeyStore.loadOrCreate(approverDeviceId, approverKeyVersion)
        AndroidSignalIdentityKeyStore.publishIfNeeded(
            uid = uid,
            deviceId = approverDeviceId,
            identity = approverIdentity,
            firestore = firestore,
        )

        val targetDevice = userRef.collection("escrow_devices").document(targetDeviceId).get().await()
        val targetKeyVersion =
            targetDevice.getLong("keyVersion")?.toInt()
                ?: error("Target device escrow key is not published.")
        val targetEscrowFingerprint =
            targetDevice.getString("publicKeyFingerprint")
                ?: error("Target device escrow fingerprint is not published.")
        val targetSignalIdentityKeyId = AndroidSignalIdentityKeypair.identityKeyId(targetDeviceId, targetKeyVersion)
        val targetIdentity =
            userRef.collection("signal_identity_public_keys").document(targetSignalIdentityKeyId).get().await()
        val targetSignalFingerprint =
            targetIdentity.getString("publicKeyFingerprint")
                ?: error("Target device Signal identity is not published.")
        check(
            targetIdentity.getString("deviceId") == targetDeviceId &&
                targetIdentity.getString("identityKeyId") == targetSignalIdentityKeyId &&
                targetIdentity.getLong("keyVersion")?.toInt() == targetKeyVersion,
        ) { "Target device Signal identity does not match escrow device." }

        val payload =
            CloudVaultDeviceTrustChainPayload(
                uid = uid,
                targetDeviceId = targetDeviceId,
                targetEscrowPublicKeyFingerprint = targetEscrowFingerprint,
                targetKeyVersion = targetKeyVersion,
                targetSignalIdentityKeyId = targetSignalIdentityKeyId,
                targetSignalIdentityPublicKeyFingerprint = targetSignalFingerprint,
                approverDeviceId = approverDeviceId,
                approverSignalIdentityKeyId = approverIdentity.identityKeyId,
                approverSignalIdentityPublicKeyFingerprint = CloudVaultCrypto.sha256Base64(approverIdentity.publicKeyData),
            )
        return CloudVaultDeviceTrustChainProof(
            targetSignalIdentityKeyId = targetSignalIdentityKeyId,
            targetSignalIdentityPublicKeyFingerprint = targetSignalFingerprint,
            approverSignalIdentityKeyId = approverIdentity.identityKeyId,
            approverSignalIdentityPublicKeyFingerprint = CloudVaultCrypto.sha256Base64(approverIdentity.publicKeyData),
            signature = CloudVaultDeviceTrustChain.sign(payload, approverIdentity),
        )
    }
}
