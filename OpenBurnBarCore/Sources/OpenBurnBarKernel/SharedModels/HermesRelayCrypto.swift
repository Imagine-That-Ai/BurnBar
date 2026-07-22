import Foundation

// MARK: - Security considerations (MP-16; mirror of relay_e2ee.py — keep in sync)
//
// Goals: (1) confidentiality of every sealed payload against the relay, which only
// store-and-forwards ciphertext; (2) sender authentication under the v2 2-DH
// key-wrap — a frame opens only if sealed by the holder of the PINNED peer static
// key, so the relay cannot forge agent↔phone replies/events; (3) forward secrecy for
// the ephemeral leg only (dh1 against a fresh per-message ephemeral key).
//
// Non-goals (explicit): no PFS for the static leg; NO protection against
// recipient-key compromise (KCI) — an inherent, documented property of every 2-DH
// AuthEncap (HPKE AuthEncap shares the bound), and NOT exploitable under the
// relay-only threat model. Do NOT "fix" KCI by bolting on a double ratchet / X3DH;
// mitigate instead by storing the recipient static key in the Keychain. Replay
// resistance comes from the AAD-bound id + the caller's record-after-auth cache, not
// the crypto alone.
//
// Empty-salt rationale: the key-wrap HKDF salt is empty (CryptoKit `Data()`) — a
// deliberate cross-language interop choice; the domain-separated `info` (binding the
// namespace version and, for v2, all three public keys) supplies the separation an
// explicit salt would otherwise provide. The v2 sender-auth property holds ONLY
// because the caller passes the PINNED peer key to `unwrapSymmetricKey` (never a wire
// `senderPublicKey` field), rooted at pairing time in the two-key safety code.

public struct HermesRelayPrivateKey: @unchecked Sendable, Equatable { // AUDIT sendable-allowlist: swift-crypto-key-material
    fileprivate let key: PlatformP256KeyAgreementPrivateKey

    public init(rawRepresentation: Data) throws {
        self.key = try PlatformCrypto.p256KeyAgreementPrivateKey(rawRepresentation: rawRepresentation)
    }

    fileprivate init(_ key: PlatformP256KeyAgreementPrivateKey) {
        self.key = key
    }

    public var rawRepresentation: Data {
        key.rawRepresentation
    }

    public var publicKeyBase64: String {
        key.publicKey.x963Representation.base64EncodedString()
    }

    public static func == (lhs: HermesRelayPrivateKey, rhs: HermesRelayPrivateKey) -> Bool {
        lhs.rawRepresentation == rhs.rawRepresentation
    }
}

public struct HermesRelayEncryptedRequestPayload: Codable, Sendable, Equatable {
    public var path: String?
    public var sessionId: String?
    public var body: String?

    public init(path: String? = nil, sessionId: String? = nil, body: String? = nil) {
        self.path = path
        self.sessionId = sessionId
        self.body = body
    }
}

/// RFC 9180 HPKE Auth-mode v3 key-wrap output (mirrors the Python
/// `RelayKeyWrapV3` dataclass in `gateway/crypto/relay_e2ee.py`).
///
/// `enc` is the HPKE encapsulated key — for DHKEM(P-256, HKDF-SHA256) this is the
/// 65-byte X9.63 uncompressed ephemeral public key. `wrappedKey` is the HPKE
/// Auth-mode ciphertext+tag over the 32-byte content key. Unlike the bespoke v2
/// wrap (which concatenated `enc ‖ AES-GCM-combined` into a single `wrappedKey`
/// field), v3 keeps `enc` and `wrappedKey` as the two distinct envelope fields
/// RFC 9180 defines, so the wire envelope gains an `enc` field at v3.
public struct HermesRelayKeyWrapV3: Codable, Sendable, Equatable {
    /// HPKE encapsulated key (P-256 X9.63 uncompressed, 65 bytes).
    public let enc: Data
    /// HPKE Auth-mode ciphertext+tag over the 32-byte content key (48 bytes:
    /// 32-byte ciphertext ‖ 16-byte GCM tag).
    public let wrappedKey: Data

    public init(enc: Data, wrappedKey: Data) {
        self.enc = enc
        self.wrappedKey = wrappedKey
    }

    /// Base64 of `enc`, for the envelope's `enc` field.
    public var encBase64: String { enc.base64EncodedString() }
    /// Base64 of `wrappedKey`, for the envelope's `wrappedKey` field.
    public var wrappedKeyBase64: String { wrappedKey.base64EncodedString() }
}

public enum HermesRelayCryptoError: LocalizedError, Sendable, Equatable {
    case invalidPublicKey
    case invalidCiphertext
    case invalidSymmetricKey
    case randomGenerationFailed

    public var errorDescription: String? {
        switch self {
        case .invalidPublicKey:
            return "The Hermes relay public key is invalid."
        case .invalidCiphertext:
            return "The Hermes relay ciphertext is invalid."
        case .invalidSymmetricKey:
            return "The Hermes relay symmetric key is invalid."
        case .randomGenerationFailed:
            return "Could not generate secure Hermes relay key material."
        }
    }
}

public enum HermesRelayCrypto {
    public static let algorithm = "p256-hkdf-sha256-aesgcm"
    /// Wrap-protocol version for the **realtime** relay (ephemeral-static, v1).
    /// Shared with the realtime iroh path — must stay 1.
    public static let keyVersion = 1
    /// Wrap-protocol version for the **gateway** (authenticated 2-DH, v2). This
    /// is the envelope `relayKeyVersion` the phone stamps on gateway seals and
    /// hard-requires on gateway opens. Distinct from `keyVersion` (realtime) and
    /// from the keypair's key-format version (the keypair is unchanged P-256).
    public static let gatewayRelayKeyVersion = 2
    /// Wrap-protocol version for the **gateway** RFC 9180 HPKE Auth migration
    /// (v3). This is the envelope `relayKeyVersion` the phone stamps on a v3
    /// gateway seal and hard-requires on a v3 gateway open. v2 stays supported
    /// for existing paired peers; v3 is emitted only when the peer advertises v3
    /// capability, so the migration never downgrades a v2 link or breaks pairing.
    public static let gatewayRelayKeyVersionV3 = 3
    /// Envelope `relayEncryption` marker for the v3 suite — DHKEM(P-256,
    /// HKDF-SHA256) / HKDF-SHA256 / AES-256-GCM in HPKE Auth mode. Mirrors the
    /// Python `HPKE_ALGORITHM` constant (`gateway/crypto/relay_e2ee.py`) byte
    /// for byte.
    public static let relayEncryptionV3 = "hpke-auth-p256-hkdfsha256-aes256gcm"
    public static let symmetricKeyByteCount = 32

    public static func generatePrivateKey() -> HermesRelayPrivateKey {
        HermesRelayPrivateKey(PlatformCrypto.p256KeyAgreementPrivateKey())
    }

    public static func generateSymmetricKeyData() throws -> Data {
        do {
            return try PlatformCrypto.secureRandomBytes(count: symmetricKeyByteCount)
        } catch {
            throw HermesRelayCryptoError.randomGenerationFailed
        }
    }

    public static func requestAAD(uid: String, connectionID: String, requestID: String) throws -> Data {
        try aad(["request", uid, connectionID, requestID])
    }

    public static func keyAAD(uid: String, connectionID: String, requestID: String) throws -> Data {
        try aad(["key", uid, connectionID, requestID])
    }

    public static func authenticatedRequestAAD(
        uid: String,
        connectionID: String,
        requestID: String,
        operation: HermesRelayOperation,
        senderDeviceID: String,
        senderPeerNodeID: String,
        senderCounter: Int64,
        keyID: String
    ) throws -> Data {
        try aad([
            "request-v3",
            uid,
            connectionID,
            requestID,
            operation.rawValue,
            senderDeviceID,
            senderPeerNodeID,
            String(senderCounter),
            keyID
        ])
    }

    public static func authenticatedKeyAAD(
        uid: String,
        connectionID: String,
        requestID: String,
        operation: HermesRelayOperation,
        senderDeviceID: String,
        senderPeerNodeID: String,
        senderCounter: Int64,
        keyID: String
    ) throws -> Data {
        try aad([
            "key-v3",
            uid,
            connectionID,
            requestID,
            operation.rawValue,
            senderDeviceID,
            senderPeerNodeID,
            String(senderCounter),
            keyID
        ])
    }

    public static func chunkAAD(
        uid: String,
        connectionID: String,
        requestID: String,
        sequence: Int,
        kind: String
    ) throws -> Data {
        try aad(["chunk", uid, connectionID, requestID, String(sequence), kind])
    }

    /// F7 — AAD for wrapping the per-mirror media-frame-AEAD session key the
    /// phone sends inside its mirror request (same wrap primitive and trust
    /// path as the F10 control seal; distinct domain tag so neither wrap can
    /// be replayed onto the other lane). `viewerId` binds the wrap to the
    /// specific mirror viewer it was minted for.
    public static func mediaSealKeyAAD(
        uid: String,
        connectionID: String,
        viewerId: String,
        senderDeviceID: String,
        senderKeyID: String,
        senderCounter: Int64
    ) throws -> Data {
        try aad(["mediaSealKey", uid, connectionID, viewerId, senderDeviceID, senderKeyID, String(senderCounter)])
    }

    /// F10 — AAD for wrapping the control-frame-seal session key the phone
    /// establishes at `control.classify` (sealKeyV3 to the Mac's pinned relay
    /// key, sender-authenticated by the phone's relay sender key). Binds owner,
    /// connection, the controller identity the seal will protect, and the
    /// sender device/key/counter so a wrap cannot be replayed across links,
    /// controllers, or onto the chat request path (distinct domain tag).
    public static func controlSealKeyAAD(
        uid: String,
        connectionID: String,
        peerNodeId: String,
        senderDeviceID: String,
        senderKeyID: String,
        senderCounter: Int64
    ) throws -> Data {
        try aad(["controlSealKey", uid, connectionID, peerNodeId, senderDeviceID, senderKeyID, String(senderCounter)])
    }

    // MARK: Hermes Gateway AAD namespacing
    //
    // The hosted chat gateway reuses this exact envelope (`p256-hkdf-sha256-aesgcm`,
    // 65-byte X9.63 pubkeys, `wrappedKey = ephemeralPub(65) || AES-GCM combined`).
    // Only the AAD parts differ so a gateway event/message frame can never be
    // replayed onto the realtime-relay request path (and vice versa). The prefix
    // (`OpenBurnBar-HermesRelay-v1|`) and the key-wrap shared info stay the single
    // source of truth via the private `aad`/`keyWrapSharedInfo`.

    /// AAD for the sealed payload of a phone→agent gateway event
    /// (`hermes_gateway_events`), binding owner + client + the client-generated
    /// event id so a ciphertext cannot be moved across users/clients/events.
    public static func gatewayEventAAD(uid: String, clientId: String, eventId: String) throws -> Data {
        try aad(["gatewayEvent", uid, clientId, eventId])
    }

    /// AAD for wrapping the per-event symmetric key to the agent's relay pubkey.
    public static func gatewayEventKeyAAD(uid: String, clientId: String, eventId: String) throws -> Data {
        try aad(["gatewayEventKey", uid, clientId, eventId])
    }

    /// AAD for the sealed payload of an agent→phone gateway message
    /// (`hermes_gateway_messages`), bound to owner + client + message id.
    public static func gatewayMessageAAD(uid: String, clientId: String, messageId: String) throws -> Data {
        try aad(["gatewayMessage", uid, clientId, messageId])
    }

    /// AAD for unwrapping the per-message symmetric key with the phone's relay key.
    public static func gatewayMessageKeyAAD(uid: String, clientId: String, messageId: String) throws -> Data {
        try aad(["gatewayMessageKey", uid, clientId, messageId])
    }

    // MARK: Gateway attachment AAD namespacing
    //
    // An agent→phone gateway attachment is sealed with a single per-attachment
    // symmetric key that is wrapped to the phone's relay pubkey. The key wrap, the
    // manifest payload (`{fileName, byteCount, contentType}`), and the body bytes
    // each authenticate under a DISTINCT AAD label so a relay can never move a
    // manifest ciphertext into the body slot (or vice versa): a cross-slot swap
    // fails the AES-GCM tag. The phone unwraps the body key once (under the *key*
    // AAD) and opens both the manifest and the body, each bound to its own label.
    // These labels mirror the Python adapter's `gatewayAttachmentManifest` /
    // `gatewayAttachmentBody` / `gatewayAttachmentKey` so the only counterparty
    // can open what the agent sealed.

    /// AAD for the sealed attachment *manifest* (`{fileName, byteCount, contentType}`).
    public static func gatewayAttachmentManifestAAD(uid: String, clientId: String, attachmentId: String) throws -> Data {
        try aad(["gatewayAttachmentManifest", uid, clientId, attachmentId])
    }

    /// AAD for the sealed attachment *body* (the raw file bytes).
    public static func gatewayAttachmentBodyAAD(uid: String, clientId: String, attachmentId: String) throws -> Data {
        try aad(["gatewayAttachmentBody", uid, clientId, attachmentId])
    }

    /// AAD for wrapping/unwrapping the per-attachment body key to the phone's relay pubkey.
    public static func gatewayAttachmentKeyAAD(uid: String, clientId: String, attachmentId: String) throws -> Data {
        try aad(["gatewayAttachmentKey", uid, clientId, attachmentId])
    }

    public static func sealToBase64(plaintext: Data, keyData: Data, aad: Data) throws -> String {
        guard keyData.count == symmetricKeyByteCount else {
            throw HermesRelayCryptoError.invalidSymmetricKey
        }
        return try HermesDomainCoreAdapter.seal(
            plaintext: plaintext,
            key: keyData,
            aad: aad
        ) {
            try HermesRelayLegacyCrypto.sealToBase64(plaintext: plaintext, keyData: keyData, aad: aad)
        }
    }

    public static func openBase64(ciphertext: String, keyData: Data, aad: Data) throws -> Data {
        guard keyData.count == symmetricKeyByteCount else {
            throw HermesRelayCryptoError.invalidSymmetricKey
        }
        return try HermesDomainCoreAdapter.open(
            ciphertext: ciphertext,
            key: keyData,
            aad: aad
        ) {
            try HermesRelayLegacyCrypto.openBase64(ciphertext: ciphertext, keyData: keyData, aad: aad)
        }
    }

    /// Wrap a symmetric key to a recipient.
    ///
    /// When `senderPrivateKey` is `nil` this is the v1 ephemeral-static ECIES
    /// wrap (byte-identical to the realtime relay path — do not change this leg).
    /// When `senderPrivateKey` is provided this is the **v2 authenticated** wrap:
    /// an HPKE-AuthEncap-shaped 2-DH KEM that binds the sender's static key so a
    /// party without the sender's private key cannot forge a valid envelope.
    /// `senderPrivateKey` is the *seal-side* sender's own static relay key.
    public static func wrapSymmetricKey(
        _ keyData: Data,
        recipientPublicKeyBase64: String,
        aad: Data,
        senderPrivateKey: HermesRelayPrivateKey? = nil
    ) throws -> String {
        guard keyData.count == symmetricKeyByteCount else {
            throw HermesRelayCryptoError.invalidSymmetricKey
        }
        guard let publicKeyData = Data(base64Encoded: recipientPublicKeyBase64),
              let recipientKey = try? PlatformCrypto.p256KeyAgreementPublicKey(x963Representation: publicKeyData) else {
            throw HermesRelayCryptoError.invalidPublicKey
        }
        let ephemeralKey = PlatformCrypto.p256KeyAgreementPrivateKey()
        let dh1 = try PlatformCrypto.p256KeyAgreementSharedSecret(privateKey: ephemeralKey, publicKey: recipientKey)
        let enc = ephemeralKey.publicKey.x963Representation

        let wrappingKey: PlatformSymmetricKey
        if let senderPrivateKey {
            // v2 authenticated: ikm = ECDH(eph, R) ‖ ECDH(skS, R)
            let dh2 = try PlatformCrypto.p256KeyAgreementSharedSecret(privateKey: senderPrivateKey.key, publicKey: recipientKey)
            wrappingKey = try authenticatedWrappingKey(
                dh1: dh1,
                dh2: dh2,
                enc: enc,
                recipientPublicKey: publicKeyData,
                senderPublicKey: senderPrivateKey.key.publicKey.x963Representation,
                aad: aad
            )
        } else {
            // v1 ephemeral-static (realtime relay) — unchanged byte layout.
            wrappingKey = try deriveWrappingKey(
                inputKeyMaterial: dh1.withUnsafeBytes { Data($0) },
                info: try keyWrapSharedInfo(aad: aad)
            )
        }
        let combined = try HermesDomainCoreAdapter.sealCombined(
            plaintext: keyData,
            key: PlatformCrypto.symmetricKeyData(wrappingKey),
            aad: aad
        ) {
            try HermesRelayLegacyCrypto.sealCombined(
                plaintext: keyData,
                key: wrappingKey,
                aad: aad
            )
        }
        return (enc + combined).base64EncodedString()
    }

    /// Unwrap a symmetric key.
    ///
    /// When `senderPublicKeyBase64` is `nil` this is the v1 path. When provided
    /// it is the **v2 authenticated** unwrap: the recipient binds the *pinned*
    /// sender static key (NOT the envelope's self-asserted field) into the second
    /// DH, so a swapped/forged sender key fails AES-GCM tag verification.
    public static func unwrapSymmetricKey(
        _ wrappedKeyBase64: String,
        privateKey: HermesRelayPrivateKey,
        aad: Data,
        senderPublicKeyBase64: String? = nil
    ) throws -> Data {
        guard let envelope = Data(base64Encoded: wrappedKeyBase64),
              envelope.count > 65 else {
            throw HermesRelayCryptoError.invalidCiphertext
        }
        let ephemeralPublicKeyData = envelope.prefix(65)
        let sealedBoxData = envelope.suffix(from: 65)
        guard let ephemeralPublicKey = try? PlatformCrypto.p256KeyAgreementPublicKey(x963Representation: Data(ephemeralPublicKeyData)) else {
            throw HermesRelayCryptoError.invalidPublicKey
        }
        let dh1 = try PlatformCrypto.p256KeyAgreementSharedSecret(privateKey: privateKey.key, publicKey: ephemeralPublicKey)

        let wrappingKey: PlatformSymmetricKey
        if let senderPublicKeyBase64 {
            // v2 authenticated: recompute ikm = ECDH(r, eph) ‖ ECDH(r, S_pinned).
            guard let senderPublicKeyData = Data(base64Encoded: senderPublicKeyBase64),
                  let senderKey = try? PlatformCrypto.p256KeyAgreementPublicKey(x963Representation: senderPublicKeyData) else {
                throw HermesRelayCryptoError.invalidPublicKey
            }
            let dh2 = try PlatformCrypto.p256KeyAgreementSharedSecret(privateKey: privateKey.key, publicKey: senderKey)
            wrappingKey = try authenticatedWrappingKey(
                dh1: dh1,
                dh2: dh2,
                enc: Data(ephemeralPublicKeyData),
                recipientPublicKey: privateKey.key.publicKey.x963Representation,
                senderPublicKey: senderPublicKeyData,
                aad: aad
            )
        } else {
            wrappingKey = try deriveWrappingKey(
                inputKeyMaterial: dh1.withUnsafeBytes { Data($0) },
                info: try keyWrapSharedInfo(aad: aad)
            )
        }
        return try HermesDomainCoreAdapter.openCombined(
            combined: Data(sealedBoxData),
            key: PlatformCrypto.symmetricKeyData(wrappingKey),
            aad: aad
        ) {
            try HermesRelayLegacyCrypto.openCombined(
                combined: Data(sealedBoxData),
                key: wrappingKey,
                aad: aad
            )
        }
    }

    /// v2 authenticated wrapping-key derivation (HPKE-AuthEncap-shaped):
    /// `ikm = dh1 ‖ dh2`, `info = "…KeyWrap-v2|" ‖ aad ‖ enc ‖ pkR ‖ pkS`
    /// (kem_context binds the ephemeral pub + both party identities → UKS-resistant).
    private static func authenticatedWrappingKey(
        dh1: PlatformSharedSecret,
        dh2: PlatformSharedSecret,
        enc: Data,
        recipientPublicKey: Data,
        senderPublicKey: Data,
        aad: Data
    ) throws -> PlatformSymmetricKey {
        var ikm = Data()
        dh1.withUnsafeBytes { ikm.append(contentsOf: $0) }
        dh2.withUnsafeBytes { ikm.append(contentsOf: $0) }
        let info = try HermesDomainCoreAdapter.keyWrapInfoV2(
            aad: aad,
            enc: enc,
            recipient: recipientPublicKey,
            sender: senderPublicKey
        ) {
            HermesRelayLegacyCrypto.keyWrapInfoV2(
                aad: aad,
                enc: enc,
                recipientPublicKey: recipientPublicKey,
                senderPublicKey: senderPublicKey
            )
        }
        return try deriveWrappingKey(
            inputKeyMaterial: ikm,
            info: info
        )
    }

    // MARK: - RFC 9180 HPKE Auth mode v3 key wrap
    //
    // v3 replaces the bespoke v2 2-DH key wrap with standards-shaped RFC 9180
    // HPKE Auth mode, implemented with Apple CryptoKit's `HPKE.Sender` /
    // `HPKE.Recipient` (the same API the Remote Unlock credential envelope
    // already uses). The content-key wrap is the ONLY layer that changes: the
    // payload and attachment AES-GCM sealing (`sealToBase64` / `openBase64`)
    // are untouched, so a v3 frame is a v2 frame whose `wrappedKey` is produced
    // by HPKE and whose encapsulated key `enc` is carried as a distinct envelope
    // field instead of being prepended to `wrappedKey`.
    //
    // Byte contract — must stay identical to `gateway/crypto/relay_e2ee.py`:
    //   suite = DHKEM(P-256, HKDF-SHA256) / HKDF-SHA256 / AES-256-GCM
    //         = HPKE.Ciphersuite.P256_SHA256_AES_GCM_256
    //   mode  = Auth (the sender authenticates with its static relay key)
    //   info  = "OpenBurnBar-HermesRelay-HPKE-v3|" ‖ key_aad   (RFC 9180 `info`)
    //   aad   = key_aad   (the RFC 9180 per-encryption AEAD associated data)
    //   pt    = the 32-byte content key
    //   enc   = HPKE encapsulated key (P-256 X9.63, 65 bytes)
    //   wrappedKey = HPKE Auth seal(pt, aad)  (48 bytes: 32 ct ‖ 16 tag)
    //
    // The recipient binds the PINNED sender static key (the pairing-rooted trust
    // anchor in the two-key safety code), never a wire-asserted `senderPublicKey`
    // field — exactly as v2. KCI and static-leg-PFS limits are identical to v2
    // (RFC 9180 AuthEncap shares the same bound); see the file-top note.

    /// Seal a 32-byte content key to `recipientPublicKeyBase64` under RFC 9180
    /// HPKE Auth mode, authenticated by `senderPrivateKey` (the seal-side
    /// sender's own static relay key). Returns the distinct `enc` and
    /// `wrappedKey` envelope fields. `aad` MUST be the `key_aad` for the frame.
    public static func sealKeyV3(
        _ keyData: Data,
        recipientPublicKeyBase64: String,
        senderPrivateKey: HermesRelayPrivateKey,
        aad: Data
    ) throws -> HermesRelayKeyWrapV3 {
        guard keyData.count == symmetricKeyByteCount else {
            throw HermesRelayCryptoError.invalidSymmetricKey
        }
        guard let publicKeyData = Data(base64Encoded: recipientPublicKeyBase64),
              let recipientKey = try? PlatformCrypto.p256KeyAgreementPublicKey(x963Representation: publicKeyData) else {
            throw HermesRelayCryptoError.invalidPublicKey
        }
        let sealed = try PlatformCrypto.hpkeSealP256SHA256AESGCM256(
            plaintext: keyData,
            recipientPublicKey: recipientKey,
            info: try hpkeV3Info(aad: aad),
            aad: aad,
            authenticatedBy: senderPrivateKey.key
        )
        return HermesRelayKeyWrapV3(enc: sealed.encapsulatedKey, wrappedKey: sealed.ciphertext)
    }

    /// Open a v3 HPKE Auth key wrap, binding the PINNED sender static key.
    /// Opening throws `HermesRelayCryptoError.invalidCiphertext` on every
    /// tampered input: a forged/swapped sender key, a wrong recipient key, a
    /// mutated `wrappedKey`, or a wrong `aad` fail the authenticated KEM/AEAD
    /// tag. A malformed `enc` (not a valid P-256 point) fails point validation
    /// up front, while a valid-but-wrong `enc` fails the AEAD tag because `enc`
    /// is bound into the HPKE `kem_context` — either way the open is refused.
    /// `aad` MUST be the same `key_aad` used to seal.
    public static func openKeyV3(
        enc: Data,
        wrappedKey: Data,
        privateKey: HermesRelayPrivateKey,
        pinnedSenderPublicKeyBase64: String,
        aad: Data
    ) throws -> Data {
        guard let senderPublicKeyData = Data(base64Encoded: pinnedSenderPublicKeyBase64),
              let senderKey = try? PlatformCrypto.p256KeyAgreementPublicKey(x963Representation: senderPublicKeyData) else {
            throw HermesRelayCryptoError.invalidPublicKey
        }
        do {
            let opened = try PlatformCrypto.hpkeOpenP256SHA256AESGCM256(
                ciphertext: wrappedKey,
                recipientPrivateKey: privateKey.key,
                info: try hpkeV3Info(aad: aad),
                encapsulatedKey: enc,
                authenticatedBy: senderKey,
                aad: aad
            )
            guard opened.count == symmetricKeyByteCount else {
                throw HermesRelayCryptoError.invalidSymmetricKey
            }
            return opened
        } catch let error as HermesRelayCryptoError {
            throw error
        } catch {
            // Normalize every HPKE failure (bad encapsulated point, KEM/KDF
            // mismatch, AEAD tag failure on a forged sender / mutated input) to
            // the existing typed error so callers keep a stable error surface,
            // matching the v2 unwrap taxonomy.
            throw HermesRelayCryptoError.invalidCiphertext
        }
    }

    /// Base64 convenience wrapper around
    /// ``openKeyV3(enc:wrappedKey:privateKey:pinnedSenderPublicKeyBase64:aad:)``
    /// for callers reading the `enc` / `wrappedKey` envelope fields directly.
    public static func openKeyV3(
        encBase64: String,
        wrappedKeyBase64: String,
        privateKey: HermesRelayPrivateKey,
        pinnedSenderPublicKeyBase64: String,
        aad: Data
    ) throws -> Data {
        guard let enc = Data(base64Encoded: encBase64),
              let wrappedKey = Data(base64Encoded: wrappedKeyBase64) else {
            throw HermesRelayCryptoError.invalidCiphertext
        }
        return try openKeyV3(
            enc: enc,
            wrappedKey: wrappedKey,
            privateKey: privateKey,
            pinnedSenderPublicKeyBase64: pinnedSenderPublicKeyBase64,
            aad: aad
        )
    }

    /// HPKE `info` for v3 = `"OpenBurnBar-HermesRelay-HPKE-v3|" ‖ key_aad`.
    /// Mirrors Python `_hpke_info` / `_HPKE_INFO_PREFIX`.
    private static func hpkeV3Info(aad: Data) throws -> Data {
        try HermesDomainCoreAdapter.hpkeV3Info(aad: aad) {
            HermesRelayLegacyCrypto.hpkeV3Info(aad: aad)
        }
    }

    public static func gatewayRelaySafetyCode(
        agentPublicKeyX963: Data,
        phonePublicKeyX963: Data
    ) throws -> String {
        try HermesDomainCoreAdapter.safetyCode(agent: agentPublicKeyX963, phone: phonePublicKeyX963) {
            let ordered = [agentPublicKeyX963, phonePublicKeyX963].sorted {
                $0.lexicographicallyPrecedes($1)
            }
            let digest = PlatformCrypto.sha256(ordered[0] + ordered[1])
            return stride(from: 0, to: 16, by: 2)
                .map { String(format: "%02X%02X", digest[$0], digest[$0 + 1]) }
                .joined(separator: " ")
        }
    }

    private static func aad(_ parts: [String]) throws -> Data {
        let legacy = { HermesRelayLegacyCrypto.aad(parts) }
        guard let label = parts.first, let kind = aadKind(label) else { return legacy() }
        return try HermesDomainCoreAdapter.aad(
            kind: kind,
            arguments: Array(parts.dropFirst()),
            legacy: legacy
        )
    }

    private static func aadKind(_ label: String) -> HermesAadKindAdapter? {
        switch label {
        case "request": .request
        case "key": .key
        case "request-v3": .authenticatedRequest
        case "key-v3": .authenticatedKey
        case "chunk": .chunk
        case "mediaSealKey": .mediaSealKey
        case "controlSealKey": .controlSealKey
        case "gatewayEvent": .gatewayEvent
        case "gatewayEventKey": .gatewayEventKey
        case "gatewayMessage": .gatewayMessage
        case "gatewayMessageKey": .gatewayMessageKey
        case "gatewayAttachmentKey": .gatewayAttachmentKey
        case "gatewayAttachmentManifest": .gatewayAttachmentManifest
        case "gatewayAttachmentBody": .gatewayAttachmentBody
        default: nil
        }
    }

    private static func keyWrapSharedInfo(aad: Data) throws -> Data {
        try HermesDomainCoreAdapter.keyWrapInfoV1(aad: aad) {
            HermesRelayLegacyCrypto.keyWrapInfo(aad: aad)
        }
    }

    private static func deriveWrappingKey(
        inputKeyMaterial: Data,
        info: Data
    ) throws -> PlatformSymmetricKey {
        let bytes = try HermesDomainCoreAdapter.hkdf(
            inputKeyMaterial: inputKeyMaterial,
            salt: Data(),
            info: info,
            outputByteCount: symmetricKeyByteCount
        ) {
            try HermesRelayLegacyCrypto.deriveWrappingKey(inputKeyMaterial: inputKeyMaterial, info: info)
        }
        return try PlatformCrypto.symmetricKey(data: bytes)
    }
}
