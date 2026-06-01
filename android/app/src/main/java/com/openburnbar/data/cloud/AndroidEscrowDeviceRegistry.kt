package com.openburnbar.data.cloud

import android.os.Build
import android.util.Base64
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
        securityClient.approveEscrowDeviceTrust(keypair.deviceId)

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
