package com.openburnbar.data.cloud.signalsession

import org.signal.libsignal.protocol.IdentityKeyPair
import org.signal.libsignal.protocol.ecc.ECKeyPair
import org.signal.libsignal.protocol.kem.KEMKeyPair
import org.signal.libsignal.protocol.kem.KEMKeyType
import org.signal.libsignal.protocol.state.KyberPreKeyRecord
import org.signal.libsignal.protocol.state.PreKeyBundle
import org.signal.libsignal.protocol.state.PreKeyRecord
import org.signal.libsignal.protocol.state.SignedPreKeyRecord

/**
 * Generates this device's PUBLIC prekey material (signed prekey + one-time prekey + mandatory
 * PQXDH Kyber prekey) and assembles a [PreKeyBundle] — the Android peer of the Swift
 * `OBBSignalPreKeyGenerator`. The PUBLIC halves are what the device publishes; the private
 * halves are persisted in [AndroidSignalProtocolStore] and never leave the device. The
 * libsignal API calls mirror the already-shipping `AndroidSignalPrekeyDirectory` generation.
 */
object AndroidSignalPreKeyGenerator {

    data class GeneratedPreKeys(
        val preKey: PreKeyRecord,
        val signedPreKey: SignedPreKeyRecord,
        val kyberPreKey: KyberPreKeyRecord,
    )

    fun generatePreKeys(
        identityKeyPair: IdentityKeyPair,
        preKeyId: Int,
        signedPreKeyId: Int,
        kyberPreKeyId: Int,
        nowMillis: Long,
    ): GeneratedPreKeys {
        val identityPrivate = identityKeyPair.privateKey

        val preKey = PreKeyRecord(preKeyId, ECKeyPair.generate())

        val signedPair = ECKeyPair.generate()
        val signedSignature = identityPrivate.calculateSignature(signedPair.publicKey.serialize())
        val signedPreKey = SignedPreKeyRecord(signedPreKeyId, nowMillis, signedPair, signedSignature)

        val kemPair = KEMKeyPair.generate(KEMKeyType.KYBER_1024)
        val kyberSignature = identityPrivate.calculateSignature(kemPair.publicKey.serialize())
        val kyberPreKey = KyberPreKeyRecord(kyberPreKeyId, nowMillis, kemPair, kyberSignature)

        return GeneratedPreKeys(preKey, signedPreKey, kyberPreKey)
    }

    fun storePreKeys(prekeys: GeneratedPreKeys, into: AndroidSignalProtocolStore) {
        into.storePreKey(prekeys.preKey.id, prekeys.preKey)
        into.storeSignedPreKey(prekeys.signedPreKey.id, prekeys.signedPreKey)
        into.storeKyberPreKey(prekeys.kyberPreKey.id, prekeys.kyberPreKey)
    }

    /** Assemble the PUBLIC [PreKeyBundle] a session initiator consumes (X3DH + PQXDH). */
    fun buildPreKeyBundle(
        identityKeyPair: IdentityKeyPair,
        registrationId: Int,
        deviceId: Int,
        prekeys: GeneratedPreKeys,
    ): PreKeyBundle = PreKeyBundle(
        registrationId,
        deviceId,
        prekeys.preKey.id,
        prekeys.preKey.keyPair.publicKey,
        prekeys.signedPreKey.id,
        prekeys.signedPreKey.keyPair.publicKey,
        prekeys.signedPreKey.signature,
        identityKeyPair.publicKey,
        prekeys.kyberPreKey.id,
        prekeys.kyberPreKey.keyPair.publicKey,
        prekeys.kyberPreKey.signature,
    )
}
