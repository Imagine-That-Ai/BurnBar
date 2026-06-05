import Foundation
import LibSignalClient

/// L41 client runtime (item 4): generates the device's PUBLIC prekey material
/// (signed prekey + one-time prekey + mandatory PQXDH Kyber prekey) and assembles a
/// `PreKeyBundle`. The PUBLIC halves are what the device publishes via the L41 server
/// callables (publishSignalPrekeyBundle); the private halves are persisted in
/// `OBBSignalProtocolStore` and never leave the device.
public enum OBBSignalPreKeyGenerator {
    public struct GeneratedPreKeys {
        public let preKey: PreKeyRecord
        public let signedPreKey: SignedPreKeyRecord
        public let kyberPreKey: KyberPreKeyRecord

        public init(preKey: PreKeyRecord, signedPreKey: SignedPreKeyRecord, kyberPreKey: KyberPreKeyRecord) {
            self.preKey = preKey
            self.signedPreKey = signedPreKey
            self.kyberPreKey = kyberPreKey
        }
    }

    /// Generate one signed prekey, one one-time prekey, and one Kyber prekey, each signed
    /// (where applicable) by the long-term identity key.
    public static func generatePreKeys(
        identityKeypair: IdentityKeyPair,
        preKeyId: UInt32,
        signedPreKeyId: UInt32,
        kyberPreKeyId: UInt32,
        now: Date = Date()
    ) throws -> GeneratedPreKeys {
        let timestamp = UInt64(now.timeIntervalSince1970 * 1000)

        let preKeyPriv = PrivateKey.generate()
        let preKey = try PreKeyRecord(id: preKeyId, privateKey: preKeyPriv)

        let signedPriv = PrivateKey.generate()
        let signedSig = identityKeypair.privateKey.generateSignature(message: signedPriv.publicKey.serialize())
        let signedPreKey = try SignedPreKeyRecord(
            id: signedPreKeyId,
            timestamp: timestamp,
            privateKey: signedPriv,
            signature: signedSig
        )

        let kemPair = KEMKeyPair.generate()
        let kyberSig = identityKeypair.privateKey.generateSignature(message: kemPair.publicKey.serialize())
        let kyberPreKey = try KyberPreKeyRecord(
            id: kyberPreKeyId,
            timestamp: timestamp,
            keyPair: kemPair,
            signature: kyberSig
        )

        return GeneratedPreKeys(preKey: preKey, signedPreKey: signedPreKey, kyberPreKey: kyberPreKey)
    }

    /// Persist all three private records into the device's durable store.
    public static func storePreKeys(
        _ prekeys: GeneratedPreKeys,
        into store: OBBSignalProtocolStore,
        context: StoreContext
    ) throws {
        try store.storePreKey(prekeys.preKey, id: prekeys.preKey.id, context: context)
        try store.storeSignedPreKey(prekeys.signedPreKey, id: prekeys.signedPreKey.id, context: context)
        try store.storeKyberPreKey(prekeys.kyberPreKey, id: prekeys.kyberPreKey.id, context: context)
    }

    /// Assemble the PUBLIC `PreKeyBundle` a session initiator consumes (X3DH + PQXDH).
    public static func buildPreKeyBundle(
        identityKeypair: IdentityKeyPair,
        registrationId: UInt32,
        deviceId: UInt32,
        prekeys: GeneratedPreKeys
    ) throws -> PreKeyBundle {
        try PreKeyBundle(
            registrationId: registrationId,
            deviceId: deviceId,
            prekeyId: prekeys.preKey.id,
            prekey: prekeys.preKey.publicKey(),
            signedPrekeyId: prekeys.signedPreKey.id,
            signedPrekey: prekeys.signedPreKey.publicKey(),
            signedPrekeySignature: prekeys.signedPreKey.signature,
            identity: IdentityKey(publicKey: identityKeypair.publicKey),
            kyberPrekeyId: prekeys.kyberPreKey.id,
            kyberPrekey: prekeys.kyberPreKey.publicKey(),
            kyberPrekeySignature: prekeys.kyberPreKey.signature
        )
    }
}
