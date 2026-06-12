package com.openburnbar.data.cloud

import com.google.firebase.firestore.DocumentSnapshot
import com.google.firebase.firestore.DocumentReference
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

private data class TrustedDeviceMaterial(
    val document: DocumentSnapshot,
    val deviceId: String,
    val keyVersion: Int,
    val escrowPublicKeyFingerprint: String,
    val escrowPublicKeyData: ByteArray,
    val signalIdentityKeyId: String,
    val signalIdentityPublicKeyFingerprint: String,
    val signalIdentityPublicKeyData: ByteArray,
)

private data class TrustedSignalIdentityMaterial(
    val identityKeyId: String,
    val fingerprint: String,
    val publicKeyData: ByteArray,
)

object AndroidCloudVaultTrustedDeviceChainVerifier {
    suspend fun verifiedTrustedDevice(
        uid: String,
        firestore: FirebaseFirestore,
        deviceDocument: DocumentSnapshot,
        localIdentity: AndroidSignalIdentityKeypair,
    ): AndroidCloudVaultVerifiedTrustedDevice {
        val deviceId = deviceDocument.getString("deviceId")?.trim().takeUnless { it.isNullOrEmpty() } ?: deviceDocument.id
        return verifyTrustedDeviceChain(uid, firestore, deviceId, localIdentity, emptySet())
    }
}

private suspend fun verifyTrustedDeviceChain(
    uid: String,
    firestore: FirebaseFirestore,
    deviceId: String,
    localIdentity: AndroidSignalIdentityKeypair,
    visited: Set<String>,
): AndroidCloudVaultVerifiedTrustedDevice {
    require(deviceId.isNotBlank() && deviceId !in visited) { "Trusted device $deviceId has an invalid trust chain." }
    val material = loadTrustedDeviceMaterial(firestore.collection("users").document(uid), deviceId)
    val verified = material.toVerifiedTrustedDevice()
    if (material.signalIdentityKeyId == localIdentity.identityKeyId) {
        material.requireLocalIdentityMatch(localIdentity)
        return verified
    }
    verifyTrustedDeviceApprover(uid, firestore, material, verified, localIdentity, visited)
    return verified
}

private suspend fun loadTrustedDeviceMaterial(userRef: DocumentReference, deviceId: String): TrustedDeviceMaterial {
    val device = userRef.collection("escrow_devices").document(deviceId).get().await()
    val keyVersion =
        device.getLong("keyVersion")?.toInt()
            ?: error("Trusted device $deviceId has no keyVersion.")
    val escrowFingerprint =
        device.getString("publicKeyFingerprint")
            ?: error("Trusted device $deviceId has no escrow fingerprint.")
    check(device.getString("trustState") == AndroidEscrowDeviceRegistry.TRUSTED) {
        "Device $deviceId is not trusted."
    }

    val escrowPublicKeyData = loadEscrowPublicKeyData(userRef, deviceId, keyVersion, escrowFingerprint)
    val signal = loadSignalIdentityMaterial(userRef, deviceId, keyVersion)
    return TrustedDeviceMaterial(
        document = device,
        deviceId = deviceId,
        keyVersion = keyVersion,
        escrowPublicKeyFingerprint = escrowFingerprint,
        escrowPublicKeyData = escrowPublicKeyData,
        signalIdentityKeyId = signal.identityKeyId,
        signalIdentityPublicKeyFingerprint = signal.fingerprint,
        signalIdentityPublicKeyData = signal.publicKeyData,
    )
}

private suspend fun loadEscrowPublicKeyData(
    userRef: DocumentReference,
    deviceId: String,
    keyVersion: Int,
    escrowFingerprint: String,
): ByteArray {
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
    return CloudVaultCryptoSupport.decodeBase64(escrowPublicKeyB64)
}

private suspend fun loadSignalIdentityMaterial(
    userRef: DocumentReference,
    deviceId: String,
    keyVersion: Int,
): TrustedSignalIdentityMaterial {
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
    return TrustedSignalIdentityMaterial(
        identityKeyId = signalIdentityKeyId,
        fingerprint = signalFingerprint,
        publicKeyData = CloudVaultCryptoSupport.decodeBase64(signalPublicKeyB64),
    )
}

private fun TrustedDeviceMaterial.toVerifiedTrustedDevice(): AndroidCloudVaultVerifiedTrustedDevice =
    AndroidCloudVaultVerifiedTrustedDevice(
        deviceId = deviceId,
        keyVersion = keyVersion,
        escrowPublicKeyFingerprint = escrowPublicKeyFingerprint,
        escrowPublicKeyData = escrowPublicKeyData,
        signalIdentityKeyId = signalIdentityKeyId,
        signalIdentityPublicKeyFingerprint = signalIdentityPublicKeyFingerprint,
        signalIdentityPublicKeyData = signalIdentityPublicKeyData,
    )

private fun TrustedDeviceMaterial.requireLocalIdentityMatch(localIdentity: AndroidSignalIdentityKeypair) {
    check(signalIdentityPublicKeyData.contentEquals(localIdentity.publicKeyData)) {
        "Local trusted root $signalIdentityKeyId does not match local identity."
    }
}

private suspend fun verifyTrustedDeviceApprover(
    uid: String,
    firestore: FirebaseFirestore,
    material: TrustedDeviceMaterial,
    verified: AndroidCloudVaultVerifiedTrustedDevice,
    localIdentity: AndroidSignalIdentityKeypair,
    visited: Set<String>,
) {
    val device = material.document
    check(device.getLong("trustChainVersion")?.toInt() == CloudVaultDeviceTrustChain.VERSION) {
        "Trusted device ${material.deviceId} is missing a trust-chain version."
    }
    check(device.getString("trustChainAlgorithm") == CloudVaultDeviceTrustChain.ALGORITHM) {
        "Trusted device ${material.deviceId} has an unsupported trust-chain algorithm."
    }
    check(device.getString("targetSignalIdentityKeyId") == material.signalIdentityKeyId)
    check(device.getString("targetSignalIdentityPublicKeyFingerprint") == material.signalIdentityPublicKeyFingerprint)

    val approvedByDeviceId =
        device.getString("approvedByDeviceId") ?: error("Trusted device ${material.deviceId} has no approver.")
    val approvedBySignalIdentityKeyId =
        device.getString("approvedBySignalIdentityKeyId")
            ?: error("Trusted device ${material.deviceId} has no approver Signal identity.")
    val approvedBySignalFingerprint =
        device.getString("approvedBySignalIdentityPublicKeyFingerprint")
            ?: error("Trusted device ${material.deviceId} has no approver Signal fingerprint.")
    val signature =
        device.getString("trustChainSignature")
            ?: error("Trusted device ${material.deviceId} has no trust-chain signature.")

    val approver = verifyTrustedDeviceChain(uid, firestore, approvedByDeviceId, localIdentity, visited + material.deviceId)
    check(approver.signalIdentityKeyId == approvedBySignalIdentityKeyId)
    check(approver.signalIdentityPublicKeyFingerprint == approvedBySignalFingerprint)
    check(
        CloudVaultDeviceTrustChain.verify(
            payload = material.trustChainPayload(uid, approver),
            signatureBase64 = signature,
            approverPublicKeyData = approver.signalIdentityPublicKeyData,
        ),
    ) { "Trusted device ${verified.deviceId} has an invalid trust-chain signature." }
}

private fun TrustedDeviceMaterial.trustChainPayload(
    uid: String,
    approver: AndroidCloudVaultVerifiedTrustedDevice,
): CloudVaultDeviceTrustChainPayload =
    CloudVaultDeviceTrustChainPayload(
        uid = uid,
        targetDeviceId = deviceId,
        targetEscrowPublicKeyFingerprint = escrowPublicKeyFingerprint,
        targetKeyVersion = keyVersion,
        targetSignalIdentityKeyId = signalIdentityKeyId,
        targetSignalIdentityPublicKeyFingerprint = signalIdentityPublicKeyFingerprint,
        approverDeviceId = approver.deviceId,
        approverSignalIdentityKeyId = approver.signalIdentityKeyId,
        approverSignalIdentityPublicKeyFingerprint = approver.signalIdentityPublicKeyFingerprint,
    )
