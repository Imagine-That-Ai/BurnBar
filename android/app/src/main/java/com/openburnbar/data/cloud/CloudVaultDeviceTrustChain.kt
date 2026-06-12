package com.openburnbar.data.cloud

import org.signal.libsignal.protocol.ecc.ECPublicKey

data class CloudVaultDeviceTrustChainPayload(
    val uid: String,
    val targetDeviceId: String,
    val targetEscrowPublicKeyFingerprint: String,
    val targetKeyVersion: Int,
    val targetSignalIdentityKeyId: String,
    val targetSignalIdentityPublicKeyFingerprint: String,
    val approverDeviceId: String,
    val approverSignalIdentityKeyId: String,
    val approverSignalIdentityPublicKeyFingerprint: String,
)

data class CloudVaultDeviceTrustChainProof(
    val version: Int = CloudVaultDeviceTrustChain.VERSION,
    val algorithm: String = CloudVaultDeviceTrustChain.ALGORITHM,
    val targetSignalIdentityKeyId: String,
    val targetSignalIdentityPublicKeyFingerprint: String,
    val approverSignalIdentityKeyId: String,
    val approverSignalIdentityPublicKeyFingerprint: String,
    val signature: String,
) {
    fun asMap(): Map<String, Any> =
        mapOf(
            "version" to version,
            "algorithm" to algorithm,
            "targetSignalIdentityKeyId" to targetSignalIdentityKeyId,
            "targetSignalIdentityPublicKeyFingerprint" to targetSignalIdentityPublicKeyFingerprint,
            "approverSignalIdentityKeyId" to approverSignalIdentityKeyId,
            "approverSignalIdentityPublicKeyFingerprint" to approverSignalIdentityPublicKeyFingerprint,
            "signature" to signature,
        )
}

data class CloudVaultTrustedDeviceActionProofPayload(
    val uid: String,
    val deviceId: String,
    val actionKind: String,
    val subjectId: String,
    val approve: Boolean,
    val nonce: String,
    val issuedAtMillis: Long,
    val deviceSignalIdentityKeyId: String,
    val deviceSignalIdentityPublicKeyFingerprint: String,
)

data class CloudVaultTrustedDeviceActionProof(
    val version: Int = CloudVaultTrustedDeviceActionProofSigner.VERSION,
    val algorithm: String = CloudVaultTrustedDeviceActionProofSigner.ALGORITHM,
    val deviceSignalIdentityKeyId: String,
    val deviceSignalIdentityPublicKeyFingerprint: String,
    val issuedAtMillis: Long,
    val signature: String,
) {
    fun asMap(): Map<String, Any> =
        mapOf(
            "version" to version,
            "algorithm" to algorithm,
            "deviceSignalIdentityKeyId" to deviceSignalIdentityKeyId,
            "deviceSignalIdentityPublicKeyFingerprint" to deviceSignalIdentityPublicKeyFingerprint,
            "issuedAtMillis" to issuedAtMillis,
            "signature" to signature,
        )
}

object CloudVaultTrustedDeviceActionProofSigner {
    const val VERSION: Int = 1
    const val ALGORITHM: String = CloudVaultDeviceTrustChain.ALGORITHM
    private const val DOMAIN: String = "OpenBurnBar-TrustedDeviceAction-v1"

    fun canonicalPayload(payload: CloudVaultTrustedDeviceActionProofPayload): ByteArray {
        val segments =
            listOf(
                "uid",
                payload.uid,
                "deviceId",
                payload.deviceId,
                "actionKind",
                payload.actionKind,
                "subjectId",
                payload.subjectId,
                "approve",
                if (payload.approve) "true" else "false",
                "nonce",
                payload.nonce,
                "issuedAtMillis",
                payload.issuedAtMillis.toString(),
                "deviceSignalIdentityKeyId",
                payload.deviceSignalIdentityKeyId,
                "deviceSignalIdentityPublicKeyFingerprint",
                payload.deviceSignalIdentityPublicKeyFingerprint,
            )
        val builder = StringBuilder()
        builder.append(DOMAIN).append('\n')
        for (segment in segments) {
            builder.append(segment.toByteArray(Charsets.UTF_8).size)
                .append(':')
                .append(segment)
                .append('\n')
        }
        return builder.toString().toByteArray(Charsets.UTF_8)
    }

    fun sign(
        payload: CloudVaultTrustedDeviceActionProofPayload,
        identity: AndroidSignalIdentityKeypair,
    ): String {
        val signature =
            CloudVaultCryptoSupport.decodeSignalPrivateKey(identity.privateKeyData)
                .calculateSignature(canonicalPayload(payload))
        return CloudVaultCryptoSupport.encodeBase64(signature)
    }

    fun verify(
        payload: CloudVaultTrustedDeviceActionProofPayload,
        signatureBase64: String,
        publicKeyData: ByteArray,
    ): Boolean =
        runCatching {
            val signature = CloudVaultCryptoSupport.decodeBase64(signatureBase64)
            ECPublicKey(publicKeyData).verifySignature(canonicalPayload(payload), signature)
        }.getOrDefault(false)
}

object CloudVaultDeviceTrustChain {
    const val VERSION: Int = 1
    const val ALGORITHM: String = "signal-identity-xeddsa-v1"
    private const val DOMAIN: String = "OpenBurnBar-CloudVault-DeviceTrust-v1"

    fun canonicalPayload(payload: CloudVaultDeviceTrustChainPayload): ByteArray {
        val segments =
            listOf(
                "uid",
                payload.uid,
                "targetDeviceId",
                payload.targetDeviceId,
                "targetEscrowPublicKeyFingerprint",
                payload.targetEscrowPublicKeyFingerprint,
                "targetKeyVersion",
                payload.targetKeyVersion.toString(),
                "targetSignalIdentityKeyId",
                payload.targetSignalIdentityKeyId,
                "targetSignalIdentityPublicKeyFingerprint",
                payload.targetSignalIdentityPublicKeyFingerprint,
                "approverDeviceId",
                payload.approverDeviceId,
                "approverSignalIdentityKeyId",
                payload.approverSignalIdentityKeyId,
                "approverSignalIdentityPublicKeyFingerprint",
                payload.approverSignalIdentityPublicKeyFingerprint,
            )
        val builder = StringBuilder()
        builder.append(DOMAIN).append('\n')
        for (segment in segments) {
            builder.append(segment.toByteArray(Charsets.UTF_8).size)
                .append(':')
                .append(segment)
                .append('\n')
        }
        return builder.toString().toByteArray(Charsets.UTF_8)
    }

    fun sign(
        payload: CloudVaultDeviceTrustChainPayload,
        approverIdentity: AndroidSignalIdentityKeypair,
    ): String {
        val signature =
            CloudVaultCryptoSupport.decodeSignalPrivateKey(approverIdentity.privateKeyData)
                .calculateSignature(canonicalPayload(payload))
        return CloudVaultCryptoSupport.encodeBase64(signature)
    }

    fun verify(
        payload: CloudVaultDeviceTrustChainPayload,
        signatureBase64: String,
        approverPublicKeyData: ByteArray,
    ): Boolean =
        runCatching {
            val signature = CloudVaultCryptoSupport.decodeBase64(signatureBase64)
            ECPublicKey(approverPublicKeyData).verifySignature(canonicalPayload(payload), signature)
        }.getOrDefault(false)
}
