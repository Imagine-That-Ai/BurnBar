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
