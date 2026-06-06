package com.openburnbar.data.cloud

import org.signal.libsignal.protocol.IdentityKeyPair

/**
 * A device's Signal at-rest identity keypair — the Android counterpart of iOS
 * `OpenBurnBarSignalIdentityKeypair` (OpenBurnBarCore/.../SignalIdentityKeyStore.swift).
 *
 * `publicKeyData` / `privateKeyData` are the libsignal `ECPublicKey`/`ECPrivateKey`
 * serializations (the same byte form `CloudVaultCryptoSupport.decodeSignalPublicKey`/
 * `decodeSignalPrivateKey` consume). The PRIVATE key never leaves the device; only
 * `publicKeyData` is published to `users/{uid}/signal_identity_public_keys/{identityKeyId}`.
 *
 * `identityKeyId` is `{deviceId}_{keyVersion}`, matching the Firestore L41 rules
 * (firestore.rules:3497-3509) and the iOS `identityKeyId(deviceId:keyVersion:)`.
 */
data class AndroidSignalIdentityKeypair(
    val identityKeyId: String,
    val publicKeyData: ByteArray,
    val privateKeyData: ByteArray,
    val keyVersion: Int,
) {
    /** This identity as a Signal at-rest recipient (so it can open its own writes). */
    fun asRecipient(): CloudVaultSignalRecipient =
        CloudVaultSignalRecipient(
            recipientKind = "device",
            recipientIdentityKeyId = identityKeyId,
            publicKeyData = publicKeyData,
        )

    // data class auto-equals/hashCode compare ByteArray by reference; override so two
    // keypairs with the same bytes compare equal (used in dedupe + tests).
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is AndroidSignalIdentityKeypair) return false
        return identityKeyId == other.identityKeyId &&
            keyVersion == other.keyVersion &&
            publicKeyData.contentEquals(other.publicKeyData) &&
            privateKeyData.contentEquals(other.privateKeyData)
    }

    override fun hashCode(): Int {
        var result = identityKeyId.hashCode()
        result = 31 * result + keyVersion
        result = 31 * result + publicKeyData.contentHashCode()
        result = 31 * result + privateKeyData.contentHashCode()
        return result
    }

    companion object {
        fun identityKeyId(deviceId: String, keyVersion: Int): String = "${deviceId}_$keyVersion"

        /** Generate a fresh libsignal identity keypair for this device + key version. */
        fun generate(deviceId: String, keyVersion: Int): AndroidSignalIdentityKeypair {
            val pair = IdentityKeyPair.generate()
            return AndroidSignalIdentityKeypair(
                identityKeyId = identityKeyId(deviceId, keyVersion),
                publicKeyData = pair.publicKey.publicKey.serialize(),
                privateKeyData = pair.privateKey.serialize(),
                keyVersion = keyVersion,
            )
        }
    }
}
