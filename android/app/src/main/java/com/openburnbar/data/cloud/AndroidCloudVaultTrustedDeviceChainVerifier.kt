package com.openburnbar.data.cloud

import com.google.firebase.firestore.DocumentReference
import com.google.firebase.firestore.DocumentSnapshot
import com.google.firebase.firestore.FirebaseFirestore
import java.security.KeyPairGenerator
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECParameterSpec
import kotlinx.coroutines.tasks.await

private val trustedDeviceP256Parameters: ECParameterSpec by lazy {
    val generator = KeyPairGenerator.getInstance("EC")
    generator.initialize(ECGenParameterSpec("secp256r1"))
    val publicKey = generator.generateKeyPair().public as? ECPublicKey
        ?: error("Trusted-device escrow verifier requires a P-256 public key.")
    publicKey.params
}

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

    /**
     * RR-5 — verify a trusted device's full trust chain by device id (the rotation chain has only the
     * survivor device ids, not their Firestore snapshots), returning its escrow public key for the
     * survivor re-wrap. Mirrors Swift `CloudVaultTrustedDeviceChainVerifier.verifiedTrustedDevice(...deviceId:)`.
     */
    suspend fun verifiedTrustedDeviceById(
        uid: String,
        firestore: FirebaseFirestore,
        deviceId: String,
        localIdentity: AndroidSignalIdentityKeypair,
    ): AndroidCloudVaultVerifiedTrustedDevice = verifyTrustedDeviceChain(uid, firestore, deviceId, localIdentity, emptySet())
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

private suspend fun loadEscrowPublicKeyData(userRef: DocumentReference, deviceId: String, keyVersion: Int, escrowFingerprint: String): ByteArray {
    val escrowPublicKeyDoc =
        userRef.collection("escrow_public_keys").document("${deviceId}_$keyVersion").get().await()
    val escrowPublicKeyB64 =
        escrowPublicKeyDoc.getString("publicKeyData")
            ?: error("Trusted device ${deviceId}_$keyVersion has no escrow public key.")
    val escrowPublicKeyData = decodeCanonicalEscrowPublicKeyData(
        publicKeyBase64 = escrowPublicKeyB64,
        context = "Trusted device ${deviceId}_$keyVersion",
    )
    val derivedEscrowFingerprint = CloudVaultCrypto.sha256Base64(escrowPublicKeyData)
    check(
        escrowPublicKeyDoc.getString("deviceId") == deviceId &&
            escrowPublicKeyDoc.getLong("keyVersion")?.toInt() == keyVersion &&
            escrowPublicKeyDoc.getString("publicKeyFingerprint") == escrowFingerprint &&
            derivedEscrowFingerprint == escrowFingerprint,
    ) { "Trusted device ${deviceId}_$keyVersion escrow public key is invalid." }
    return escrowPublicKeyData
}

internal fun decodeCanonicalEscrowPublicKeyData(publicKeyBase64: String, context: String): ByteArray {
    val canonicalBase64 = publicKeyBase64.takeIf { it.isNotBlank() && it == it.trim() }
        ?: error("$context escrow public key is invalid.")
    val publicKeyData =
        runCatching { java.util.Base64.getDecoder().decode(canonicalBase64) }
            .getOrElse { error("$context escrow public key is invalid.") }
    check(CloudVaultCryptoSupport.encodeBase64(publicKeyData) == canonicalBase64) {
        "$context escrow public key is invalid."
    }
    val publicKey =
        runCatching { CloudVaultCryptoSupport.publicKeyFromX963(publicKeyData, trustedDeviceP256Parameters) }
            .getOrElse { error("$context escrow public key is invalid.") }
    requireP256Point(publicKey, context)
    check(CloudVaultCrypto.publicKeyX963(publicKey).contentEquals(publicKeyData)) {
        "$context escrow public key is invalid."
    }
    return publicKeyData
}

private suspend fun loadSignalIdentityMaterial(userRef: DocumentReference, deviceId: String, keyVersion: Int): TrustedSignalIdentityMaterial {
    val signalIdentityKeyId = AndroidSignalIdentityKeypair.identityKeyId(deviceId, keyVersion)
    val signalDoc =
        userRef.collection("signal_identity_public_keys").document(signalIdentityKeyId).get().await()
    val signalPublicKeyB64 =
        signalDoc.getString("publicKeyData")
            ?: error("Trusted device $signalIdentityKeyId has no Signal identity public key.")
    val signalFingerprint =
        signalDoc.getString("publicKeyFingerprint")
            ?: error("Trusted device $signalIdentityKeyId has no Signal identity fingerprint.")
    val signalPublicKeyData =
        runCatching { CloudVaultCryptoSupport.decodeBase64(signalPublicKeyB64) }
            .getOrElse { error("Trusted device $signalIdentityKeyId has an invalid Signal identity.") }
    val derivedSignalFingerprint = CloudVaultCrypto.sha256Base64(signalPublicKeyData)
    check(
        signalDoc.getString("deviceId") == deviceId &&
            signalDoc.getString("identityKeyId") == signalIdentityKeyId &&
            signalDoc.getLong("keyVersion")?.toInt() == keyVersion &&
            signalDoc.getString("algorithm") == CloudVaultCrypto.SIGNAL_AT_REST_ENCRYPTION &&
            derivedSignalFingerprint == signalFingerprint,
    ) { "Trusted device $signalIdentityKeyId has an invalid Signal identity." }
    return TrustedSignalIdentityMaterial(
        identityKeyId = signalIdentityKeyId,
        fingerprint = signalFingerprint,
        publicKeyData = signalPublicKeyData,
    )
}

private fun TrustedDeviceMaterial.toVerifiedTrustedDevice(): AndroidCloudVaultVerifiedTrustedDevice = AndroidCloudVaultVerifiedTrustedDevice(
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

private fun TrustedDeviceMaterial.trustChainPayload(uid: String, approver: AndroidCloudVaultVerifiedTrustedDevice): CloudVaultDeviceTrustChainPayload =
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
