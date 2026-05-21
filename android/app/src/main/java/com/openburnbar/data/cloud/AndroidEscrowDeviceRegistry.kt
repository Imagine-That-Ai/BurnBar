package com.openburnbar.data.cloud

import android.os.Build
import android.util.Base64
import com.google.firebase.firestore.FieldValue
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.SetOptions
import kotlinx.coroutines.tasks.await

data class AndroidEscrowDeviceRegistration(
    val deviceId: String,
    val trustState: String,
)

class AndroidEscrowDeviceRegistry(
    private val firestore: FirebaseFirestore = FirebaseFirestore.getInstance(),
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
        val deviceName = listOf(Build.MANUFACTURER, Build.MODEL)
            .filter { !it.isNullOrBlank() }
            .joinToString(" ")
            .ifBlank { "Android" }

        val devicePayload = mutableMapOf<String, Any>(
            "deviceId" to keypair.deviceId,
            "deviceName" to deviceName,
            "platform" to "Android",
            "trustState" to trustState,
            "publicKeyFingerprint" to keypair.publicKeyFingerprint,
            "keyVersion" to keypair.keyVersion,
            "updatedAt" to FieldValue.serverTimestamp(),
        )
        if (existing?.exists() != true) {
            devicePayload["createdAt"] = FieldValue.serverTimestamp()
        }
        deviceRef.set(devicePayload, SetOptions.merge()).await()

        userRef.collection("escrow_public_keys")
            .document("${keypair.deviceId}_${keypair.keyVersion}")
            .set(
                mapOf(
                    "deviceId" to keypair.deviceId,
                    "publicKeyData" to Base64.encodeToString(keypair.publicKeyData, Base64.NO_WRAP),
                    "publicKeyFingerprint" to keypair.publicKeyFingerprint,
                    "keyVersion" to keypair.keyVersion,
                    "algorithm" to "ECIES-P256-AESGCM",
                    "createdAt" to FieldValue.serverTimestamp(),
                ),
                SetOptions.merge(),
            )
            .await()

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
        firestore.collection("users").document(uid)
            .collection("escrow_devices")
            .document(keypair.deviceId)
            .update(
                mapOf(
                    "trustState" to TRUSTED,
                    "approvedAt" to FieldValue.serverTimestamp(),
                    "updatedAt" to FieldValue.serverTimestamp(),
                )
            )
            .await()

        return AndroidEscrowDeviceRegistration(
            deviceId = keypair.deviceId,
            trustState = TRUSTED,
        )
    }

    companion object {
        const val PENDING = "pending"
        const val TRUSTED = "trusted"
    }
}
