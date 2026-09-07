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
//   * `store_id` is the TARGET store's fingerprint. It reaches
//     `manifest.recipient_store_id` and the export confirmation, which is what
//     makes a substituted `--recipient` file visible to the operator rather
//     than merely honoured (migration review rec 5).

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

    /// `manifest.recipient_key_id` is `hex64_null` in `mif-v1.schema.json`, so
    /// the `rcp_` id cannot go in it verbatim. What travels is the full
    /// `sha256(public_key)` the id is a prefix of, which an importer checks
    /// against its own id in one comparison. See the schema conflict recorded
    /// in `docs/MEMORY_EXPORT_MIF.md` §6.
    public var manifestKeyID: String {
        MemoryExportDigest.sha256Hex(publicKey.rawRepresentation)
    }

    public enum DescriptorError: Error, Equatable {
        case malformed(String)
        case keyIDMismatch(declared: String, recomputed: String)
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
        return MemoryExportRecipient(keyID: recomputed, publicKey: publicKey, storeID: storeID)
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
