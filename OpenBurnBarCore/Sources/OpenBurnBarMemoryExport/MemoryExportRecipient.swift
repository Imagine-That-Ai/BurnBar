// SPDX-License-Identifier: AGPL-3.0-only
//
// MemoryExportRecipient — D-0025's recipient descriptor, and the base64url
// rendering the wrapped key is written in.
//
// The descriptor is a JSON file the IMPORTER publishes
// (`memoryctl memory export-recipient`) carrying three fields:
//
//     { "recipient_key_id": "rcp_<32 hex>",
//       "public_key":       "<b64url X25519 public key>",
//       "store_id":         "<the importer's store fingerprint>" }
//
// Two of those exist because a public key alone is not enough:
//
//   * `recipient_key_id` is recomputed here from `public_key` and a mismatch is
//     a refusal, so a descriptor whose id was edited to look like somebody
//     else's cannot be used to address a bundle. It is also the HPKE `aad`, so
//     the binding is cryptographic rather than advisory.
//   * `store_id` is the TARGET store's id — `sto_` and 32 lowercase hex, the
//     shape `schema/memory-v1.sql` CHECKs (`GLOB 'sto_[0-9a-f]*' AND length =
//     36`). It reaches `manifest.recipient_store_id` and the export
//     confirmation, which is what makes a substituted `--recipient` file
//     visible to the operator rather than merely honoured (migration review
//     rec 5).
//
// The shape is enforced HERE, on the way in, because the contract does not:
// `$defs/manifest` types `recipient_store_id` as a bare
// `["string", "null"]`, so interop run 1's fixture sealed to the id
// `importer-store-fixture` and validated — against a target store that could
// not exist, which made `RECIPIENT_MISMATCH` unavoidable at whatever importer
// (M-10). D-0039 ruling 7 types the member; until the vendored schema carries
// the pattern, a descriptor this exporter cannot address is refused rather
// than sealed to.

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Unpadded base64url (§0.1's rendering): the alphabet MIF ids, signatures and
/// the wrapped key are all written in.
public enum MemoryExportBase64URL {
    public static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decode(_ text: String) -> Data? {
        var padded = text
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        padded += String(repeating: "=", count: (4 - padded.count % 4) % 4)
        return Data(base64Encoded: padded)
    }
}

public struct MemoryExportRecipient: Sendable {
    /// `"rcp_" + sha256(public_key)[0..32]`. The HPKE `aad`.
    public var keyID: String
    public var publicKey: Curve25519.KeyAgreement.PublicKey
    /// The importer's own store fingerprint, from the descriptor.
    public var storeID: String
    /// True when this recipient was minted by rehearsal rather than published
    /// by an importer. `report.json` says so; a real export never sets it.
    public var isRehearsalThrowaway: Bool

    public init(
        keyID: String,
        publicKey: Curve25519.KeyAgreement.PublicKey,
        storeID: String,
        isRehearsalThrowaway: Bool = false
    ) {
        self.keyID = keyID
        self.publicKey = publicKey
        self.storeID = storeID
        self.isRehearsalThrowaway = isRehearsalThrowaway
    }

    /// D-0025 ruling 2's id recipe.
    public static func keyID(for publicKey: Curve25519.KeyAgreement.PublicKey) -> String {
        "rcp_" + String(MemoryExportDigest.sha256Hex(publicKey.rawRepresentation).prefix(32))
    }

    /// `^sto_[0-9a-f]{32}$` — 36 characters, which is `schema/memory-v1.sql`
    /// line 32's CHECK on `schema_meta.store_id` written as a pattern
    /// [D-0039 ruling 7]. Hand-rolled rather than `NSRegularExpression`: the
    /// set is four characters and thirty-two hex digits, and a regex engine is
    /// a dependency for a `hasPrefix` and a scan. The digits are ASCII —
    /// `isHexDigit`/`isNumber`/`isLowercase` all pass the full-width forms
    /// (`０`…`９`, `ａ`…`ｆ`), which the importer's pattern refuses (review #2564).
    public static func isValidStoreID(_ storeID: String) -> Bool {
        guard storeID.count == 36, storeID.hasPrefix("sto_") else { return false }
        return storeID.dropFirst(4).allSatisfy(MemoryExportIdentity.isASCIILowerHex)
    }

    /// Mint one, from 16 random bytes. `memoryctl memory export-recipient`
    /// mints the real one on the importer's side; this is what
    /// `memory recipient-keypair` uses when the operator names no store, so a
    /// fixture cannot be addressed to a string no store can hold.
    public static func mintStoreID() -> String {
        var bytes = Data(count: 16)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        return "sto_" + bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// `manifest.recipient_key_id` is the `rcp_` id itself, and nothing else can
    /// be correct: D-0021 ruling 1 makes that string the HPKE `aad`, so an
    /// importer that reads this field and uses it to open the wrap must find the
    /// same bytes the wrap was sealed with. Emitting `sha256(public_key)` here
    /// while sealing under `rcp_…` produced bundles the addressed store could
    /// not open (review R4).
    ///
    /// The `hex64_null` typing that justified the old value is gone: D-0025
    /// retyped the member to `recipient_key_id_null` (`^rcp_[0-9a-f]{32}$`), and
    /// the schema vendored beside this file carries it.
    public var manifestKeyID: String { keyID }

    public enum DescriptorError: Error, Equatable {
        case malformed(String)
        case keyIDMismatch(declared: String, recomputed: String)
        /// A descriptor naming a store id no store can hold. Its own case
        /// because the operator's next step differs: the key is fine, the
        /// importer published the wrong id.
        case storeIDNotAStoreID(String)
    }

    /// Read a descriptor, and refuse one whose id does not follow from its key.
    public static func parse(descriptor data: Data) throws -> MemoryExportRecipient {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DescriptorError.malformed("the recipient descriptor is not a JSON object")
        }
        guard let declaredID = object["recipient_key_id"] as? String,
              let encodedKey = object["public_key"] as? String,
              let storeID = object["store_id"] as? String else {
            throw DescriptorError.malformed(
                "the recipient descriptor needs recipient_key_id, public_key and store_id"
            )
        }
        guard let raw = MemoryExportBase64URL.decode(encodedKey), raw.count == 32 else {
            throw DescriptorError.malformed("public_key must be a b64url X25519 public key of 32 bytes")
        }
        let publicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw)
        let recomputed = keyID(for: publicKey)
        guard recomputed == declaredID else {
            throw DescriptorError.keyIDMismatch(declared: declaredID, recomputed: recomputed)
        }
        // M-10: a bundle sealed to a store id the target's DDL forbids is a
        // bundle no store can accept — `RECIPIENT_MISMATCH` at the far end,
        // after the whole export. It is cheaper and clearer to refuse the
        // descriptor.
        guard isValidStoreID(storeID) else {
            throw DescriptorError.storeIDNotAStoreID(storeID)
        }
        return MemoryExportRecipient(keyID: recomputed, publicKey: publicKey, storeID: storeID)
    }

    /// A recipient keypair with **both halves kept**, for the D-0021 ruling 6
    /// interop fixture and nothing else.
    ///
    /// The importer publishes its own descriptor with `memoryctl memory
    /// export-recipient` and BurnBar never sees that private key; this exists
    /// because the interop gate needs a bundle the Rust importer can actually
    /// open before either side has run the other's tooling, and the two ways of
    /// getting one are both wrong:
    ///
    ///   * `--rehearsal` mints a throwaway and **discards the private half by
    ///     design** (`rehearsalThrowaway` below), so a rehearsal bundle is
    ///     sealed to a key nobody holds — correct for what it is for, useless as
    ///     a courier fixture, and marked `rehearsal: true`, which an importer
    ///     refuses outright (`MIF_REHEARSAL_BUNDLE_REFUSED`);
    ///   * hand-rolling an X25519 key beside the export is how two
    ///     implementations end up disagreeing about `recipient_key_id`.
    ///
    /// So the keypair is minted here, through the same `keyID(for:)` the
    /// exporter and the descriptor parser use, and the private half is written
    /// beside the descriptor as a file the fixture's consumer feeds its
    /// importer. It protects nothing of the user's: the bundle key it will
    /// unwrap belongs to a bundle built from GRDB fixtures.
    public struct Keypair: Sendable {
        public var recipient: MemoryExportRecipient
        public var privateKey: Curve25519.KeyAgreement.PrivateKey

        /// Public so a fixture generator can seed both halves and reproduce a
        /// bundle byte for byte, which `generateKeypair` deliberately cannot.
        public init(recipient: MemoryExportRecipient, privateKey: Curve25519.KeyAgreement.PrivateKey) {
            self.recipient = recipient
            self.privateKey = privateKey
        }

        /// D-0025's three-field descriptor, exactly as an importer publishes it.
        public var descriptorJSON: MIFJSON {
            .object([
                "recipient_key_id": .string(recipient.keyID),
                "public_key": .string(MemoryExportBase64URL.encode(recipient.publicKey.rawRepresentation)),
                "store_id": .string(recipient.storeID)
            ])
        }

        /// The half that never travels with the bundle. Named for what it is, so
        /// a file that leaks into a bundle directory is obvious on sight.
        public var secretJSON: MIFJSON {
            .object([
                "recipient_key_id": .string(recipient.keyID),
                "recipient_private_key_b64url": .string(
                    MemoryExportBase64URL.encode(privateKey.rawRepresentation)
                ),
                "store_id": .string(recipient.storeID),
                "purpose": .string(
                    "interop fixture only (D-0021 ruling 6). Feed this to the importer; never ship it "
                        + "inside a bundle, and never use it for a real export — the importer publishes "
                        + "its own descriptor with `memoryctl memory export-recipient`."
                )
            ])
        }
    }

    /// Mint one. `storeID` is the store the bundle will be addressed to, and it
    /// is what `manifest.recipient_store_id` carries; passing `nil` mints one.
    ///
    /// A store id that is not `^sto_[0-9a-f]{32}$` is refused here rather than
    /// carried: the descriptor this writes is fed straight back to `export`, so
    /// an id the target cannot hold would otherwise reach the manifest and the
    /// bundle would be unimportable everywhere (M-10, M-11).
    public static func generateKeypair(storeID: String? = nil) throws -> Keypair {
        let resolved = storeID ?? mintStoreID()
        guard isValidStoreID(resolved) else {
            throw DescriptorError.storeIDNotAStoreID(resolved)
        }
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        return Keypair(
            recipient: MemoryExportRecipient(
                keyID: keyID(for: privateKey.publicKey),
                publicKey: privateKey.publicKey,
                storeID: resolved
            ),
            privateKey: privateKey
        )
    }

    /// Write the descriptor and the private half into `directory`, returning
    /// both paths. The secret is written `0600`, and the two files are named so
    /// that neither can be mistaken for the other.
    @discardableResult
    public static func writeKeypair(
        _ keypair: Keypair,
        to directory: URL
    ) throws -> (descriptor: URL, secret: URL) {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = directory.appendingPathComponent("recipient.json")
        let secret = directory.appendingPathComponent("recipient-secret.json")
        try MIFCanonicalJSON.data(keypair.descriptorJSON).write(to: descriptor)
        try MIFCanonicalJSON.data(keypair.secretJSON).write(to: secret)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: secret.path)
        return (descriptor, secret)
    }

    /// D-0025 ruling 3's one exception: rehearsal may mint a recipient nobody
    /// holds the private half of — and `report.json` says it did, so a
    /// rehearsal bundle can never be mistaken for one addressed to a store.
    /// Compiled out of release builds for the same reason
    /// `deterministicBundleKey` is.
    #if DEBUG
    public static func rehearsalThrowaway() -> MemoryExportRecipient {
        let publicKey = Curve25519.KeyAgreement.PrivateKey().publicKey
        return MemoryExportRecipient(
            keyID: keyID(for: publicKey),
            publicKey: publicKey,
            storeID: "rehearsal:no-target-store",
            isRehearsalThrowaway: true
        )
    }
    #endif
}
