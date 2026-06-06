package com.openburnbar.data.cloud.signalsession

import java.security.MessageDigest
import java.util.Base64
import org.signal.libsignal.protocol.IdentityKey
import org.signal.libsignal.protocol.SignalProtocolAddress
import org.signal.libsignal.protocol.ecc.ECPublicKey
import org.signal.libsignal.protocol.kem.KEMPublicKey
import org.signal.libsignal.protocol.state.PreKeyBundle

data class AndroidSignalSessionPeer(
    val uid: String,
    val deviceId: String,
    val identityKeyId: String,
    val keyVersion: Int? = null,
    val signalDeviceIdOverride: Int? = null,
    val registrationIdOverride: Int? = null,
) {
    val protocolAddressName: String
        get() = listOf(uid, deviceId, identityKeyId)
            .joinToString(separator = ".", prefix = "openburnbar.") { protocolSafeSegment(it) }

    val signalDeviceId: Int
        get() = signalDeviceIdOverride ?: stableInt(
            seed = "device|$uid|$deviceId|$identityKeyId|${keyVersion ?: 0}",
            min = 1,
            max = 127,
        )

    val registrationId: Int
        get() = registrationIdOverride ?: stableInt(
            seed = "registration|$uid|$deviceId|$identityKeyId|${keyVersion ?: 0}",
            min = 1,
            max = 0x3fff,
        )

    fun address(): SignalProtocolAddress = SignalProtocolAddress(protocolAddressName, signalDeviceId)

    companion object {
        private val unsafeProtocolChars = Regex("[^A-Za-z0-9_-]")

        private fun protocolSafeSegment(value: String): String {
            val normalized = value.trim().replace(unsafeProtocolChars, "_").trim('_')
            return normalized.ifEmpty { "unknown" }
        }

        private fun stableInt(seed: String, min: Int, max: Int): Int {
            require(min <= max)
            val digest = MessageDigest.getInstance("SHA-256").digest(seed.toByteArray(Charsets.UTF_8))
            val raw =
                ((digest[0].toInt() and 0xff) shl 24) or
                    ((digest[1].toInt() and 0xff) shl 16) or
                    ((digest[2].toInt() and 0xff) shl 8) or
                    (digest[3].toInt() and 0xff)
            val positive = raw.toLong() and 0xffff_ffffL
            return min + (positive % (max - min + 1)).toInt()
        }
    }
}

data class AndroidSignalClaimedSignedPreKey(
    val id: String,
    val numericId: Int,
    val publicKeyB64: String,
    val signatureB64: String,
)

data class AndroidSignalClaimedOneTimePreKey(
    val id: String,
    val numericId: Int,
    val publicKeyB64: String,
)

data class AndroidSignalClaimedKyberPreKey(
    val id: String,
    val numericId: Int,
    val publicKeyB64: String,
    val signatureB64: String,
)

data class AndroidSignalClaimedPreKeyBundle(
    val peerUid: String,
    val identityKeyId: String,
    val deviceId: String,
    val keyVersion: Int,
    val identityPublicKeyData: String,
    val signedPreKey: AndroidSignalClaimedSignedPreKey,
    val kyberPreKey: AndroidSignalClaimedKyberPreKey,
    val oneTimePreKey: AndroidSignalClaimedOneTimePreKey?,
    val signalDeviceId: Int? = null,
    val signalRegistrationId: Int? = null,
)

data class AndroidSignalDecodedRemotePreKeyBundle(
    val peer: AndroidSignalSessionPeer,
    val address: SignalProtocolAddress,
    val bundle: PreKeyBundle,
)

object AndroidSignalRemoteBundleDecoder {
    fun decode(claimed: AndroidSignalClaimedPreKeyBundle): AndroidSignalDecodedRemotePreKeyBundle {
        val peer =
            AndroidSignalSessionPeer(
                uid = claimed.peerUid,
                deviceId = claimed.deviceId,
                identityKeyId = claimed.identityKeyId,
                keyVersion = claimed.keyVersion,
                signalDeviceIdOverride = claimed.signalDeviceId,
                registrationIdOverride = claimed.signalRegistrationId,
            )
        val address = peer.address()
        val identity = IdentityKey(ECPublicKey(decodeB64(claimed.identityPublicKeyData)))
        val signedPublic = ECPublicKey(decodeB64(claimed.signedPreKey.publicKeyB64))
        val signedSignature = decodeB64(claimed.signedPreKey.signatureB64)
        val kyberPublic = KEMPublicKey(decodeB64(claimed.kyberPreKey.publicKeyB64))
        val kyberSignature = decodeB64(claimed.kyberPreKey.signatureB64)
        val bundle =
            claimed.oneTimePreKey?.let { oneTime ->
                PreKeyBundle(
                    peer.registrationId,
                    peer.signalDeviceId,
                    oneTime.numericId,
                    ECPublicKey(decodeB64(oneTime.publicKeyB64)),
                    claimed.signedPreKey.numericId,
                    signedPublic,
                    signedSignature,
                    identity,
                    claimed.kyberPreKey.numericId,
                    kyberPublic,
                    kyberSignature,
                )
            } ?: PreKeyBundle(
                peer.registrationId,
                peer.signalDeviceId,
                PreKeyBundle.NULL_PRE_KEY_ID,
                null,
                claimed.signedPreKey.numericId,
                signedPublic,
                signedSignature,
                identity,
                claimed.kyberPreKey.numericId,
                kyberPublic,
                kyberSignature,
            )
        return AndroidSignalDecodedRemotePreKeyBundle(peer = peer, address = address, bundle = bundle)
    }

    private fun decodeB64(value: String): ByteArray = Base64.getDecoder().decode(value)
}
