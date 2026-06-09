package com.openburnbar.data.cloud

import com.google.firebase.firestore.DocumentSnapshot
import com.google.firebase.firestore.FirebaseFirestore
import kotlinx.coroutines.tasks.await

data class AndroidCloudVaultVerifiedTrustedDevice(
    val deviceId: String,
    val keyVersion: Int,
    val escrowPublicKeyFingerprint: String,
    val escrowPublicKeyData: ByteArray,
    val signalIdentityKeyId: String,
    val signalIdentityPublicKeyFingerprint: String,
    val signalIdentityPublicKeyData: ByteArray,
)

object AndroidCloudVaultTrustedDeviceChainVerifier {
    suspend fun verifiedTrustedDevice(
        uid: String,
        firestore: FirebaseFirestore,
        deviceDocument: DocumentSnapshot,
        localIdentity: AndroidSignalIdentityKeypair,
    ): AndroidCloudVaultVerifiedTrustedDevice {
        val deviceId = deviceDocument.getString("deviceId")?.trim().takeUnless { it.isNullOrEmpty() } ?: deviceDocument.id
        return verifiedTrustedDevice(uid, firestore, deviceId, localIdentity, emptySet())
    }

    private suspend fun verifiedTrustedDevice(
        uid: String,
        firestore: FirebaseFirestore,
        deviceId: String,
        localIdentity: AndroidSignalIdentityKeypair,
        visited: Set<String>,
    ): AndroidCloudVaultVerifiedTrustedDevice {
        require(deviceId.isNotBlank() && deviceId !in visited) { "Trusted device $deviceId has an invalid trust chain." }
        val userRef = firestore.collection("users").document(uid)
        val device =
            userRef.collection("escrow_devices").document(deviceId).get().await()
        val keyVersion =
            device.getLong("keyVersion")?.toInt()
                ?: error("Trusted device $deviceId has no keyVersion.")
        val escrowFingerprint =
            device.getString("publicKeyFingerprint")
                ?: error("Trusted device $deviceId has no escrow fingerprint.")
        check(device.getString("trustState") == AndroidEscrowDeviceRegistry.TRUSTED) {
            "Device $deviceId is not trusted."
        }

        val escrowPublicKeyDoc =
            userRef.collection("escrow_public_keys").document("${deviceId}_$keyVersion").get().await()
        val escrowPublicKeyB64 =
            escrowPublicKeyDoc.getString("publicKeyData")
                ?: error("Trusted device ${deviceId}_$keyVersion has no escrow public key.")
        check(
            escrowPublicKeyDoc.getString("deviceId") == deviceId &&
                escrowPublicKeyDoc.getLong("keyVersion")?.toInt() == keyVersion &&
                escrowPublicKeyDoc.getString("publicKeyFingerprint") == escrowFingerprint,
        ) { "Trusted device ${deviceId}_$keyVersion escrow public key is invalid." }
        val escrowPublicKeyData = CloudVaultCryptoSupport.decodeBase64(escrowPublicKeyB64)

        val signalIdentityKeyId = AndroidSignalIdentityKeypair.identityKeyId(deviceId, keyVersion)
        val signalDoc =
            userRef.collection("signal_identity_public_keys").document(signalIdentityKeyId).get().await()
        val signalPublicKeyB64 =
            signalDoc.getString("publicKeyData")
                ?: error("Trusted device $signalIdentityKeyId has no Signal identity public key.")
        val signalFingerprint =
            signalDoc.getString("publicKeyFingerprint")
                ?: error("Trusted device $signalIdentityKeyId has no Signal identity fingerprint.")
        check(
            signalDoc.getString("deviceId") == deviceId &&
                signalDoc.getString("identityKeyId") == signalIdentityKeyId &&
                signalDoc.getLong("keyVersion")?.toInt() == keyVersion &&
                signalDoc.getString("algorithm") == CloudVaultCrypto.SIGNAL_AT_REST_ENCRYPTION,
        ) { "Trusted device $signalIdentityKeyId has an invalid Signal identity." }
        val signalPublicKeyData = CloudVaultCryptoSupport.decodeBase64(signalPublicKeyB64)

        val verified =
            AndroidCloudVaultVerifiedTrustedDevice(
                deviceId = deviceId,
                keyVersion = keyVersion,
                escrowPublicKeyFingerprint = escrowFingerprint,
                escrowPublicKeyData = escrowPublicKeyData,
                signalIdentityKeyId = signalIdentityKeyId,
                signalIdentityPublicKeyFingerprint = signalFingerprint,
                signalIdentityPublicKeyData = signalPublicKeyData,
            )
        if (signalIdentityKeyId == localIdentity.identityKeyId) {
            check(signalPublicKeyData.contentEquals(localIdentity.publicKeyData)) {
                "Local trusted root $signalIdentityKeyId does not match local identity."
            }
            return verified
        }

        check(device.getLong("trustChainVersion")?.toInt() == CloudVaultDeviceTrustChain.VERSION) {
            "Trusted device $deviceId is missing a trust-chain version."
        }
        check(device.getString("trustChainAlgorithm") == CloudVaultDeviceTrustChain.ALGORITHM) {
            "Trusted device $deviceId has an unsupported trust-chain algorithm."
        }
        check(device.getString("targetSignalIdentityKeyId") == signalIdentityKeyId)
        check(device.getString("targetSignalIdentityPublicKeyFingerprint") == signalFingerprint)
        val approvedByDeviceId =
            device.getString("approvedByDeviceId") ?: error("Trusted device $deviceId has no approver.")
        val approvedBySignalIdentityKeyId =
            device.getString("approvedBySignalIdentityKeyId")
                ?: error("Trusted device $deviceId has no approver Signal identity.")
        val approvedBySignalFingerprint =
            device.getString("approvedBySignalIdentityPublicKeyFingerprint")
                ?: error("Trusted device $deviceId has no approver Signal fingerprint.")
        val signature =
            device.getString("trustChainSignature") ?: error("Trusted device $deviceId has no trust-chain signature.")

        val approver = verifiedTrustedDevice(uid, firestore, approvedByDeviceId, localIdentity, visited + deviceId)
        check(approver.signalIdentityKeyId == approvedBySignalIdentityKeyId)
        check(approver.signalIdentityPublicKeyFingerprint == approvedBySignalFingerprint)
        val payload =
            CloudVaultDeviceTrustChainPayload(
                uid = uid,
                targetDeviceId = deviceId,
                targetEscrowPublicKeyFingerprint = escrowFingerprint,
                targetKeyVersion = keyVersion,
                targetSignalIdentityKeyId = signalIdentityKeyId,
                targetSignalIdentityPublicKeyFingerprint = signalFingerprint,
                approverDeviceId = approver.deviceId,
                approverSignalIdentityKeyId = approver.signalIdentityKeyId,
                approverSignalIdentityPublicKeyFingerprint = approver.signalIdentityPublicKeyFingerprint,
            )
        check(
            CloudVaultDeviceTrustChain.verify(
                payload = payload,
                signatureBase64 = signature,
                approverPublicKeyData = approver.signalIdentityPublicKeyData,
            ),
        ) { "Trusted device $deviceId has an invalid trust-chain signature." }
        return verified
    }
}
