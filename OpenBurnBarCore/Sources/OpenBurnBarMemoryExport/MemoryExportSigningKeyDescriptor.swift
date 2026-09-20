// SPDX-License-Identifier: AGPL-3.0-only
//
// MemoryExportSigningKeyDescriptor — the exporter's Ed25519 public key as a
// self-authenticating JSON descriptor, written BESIDE the bundle (never inside
// it — Q-60's closed file set would hold it `MANIFEST_INVALID:bundle/<path>`).
//
// Review #2564: the bundle carries `exporter_device_key_id` — a truncated
// `edk_` id — and no public key, so nothing could verify `manifest.sig`
// without already holding the key. The manifest member list and the bundle
// file set are both contract-closed, so the verification key cannot travel
// inside the bundle; this file is the out-of-band half the spec's TOFU pin
// assumes exists. The operator carries bundle + descriptor together to the
// importer, which pins (store_id, key_id, public_key) on first import and
// refuses a later bundle claiming the same `edk_` under different bytes.
//
// The descriptor signs itself: `key_signature` is Ed25519 over
// sha256(JCS(descriptor minus key_signature)) under the key it names — the
// same D-0031 construction `manifest.sig` uses, applied to the descriptor. A
// self-signature proves nothing about WHO the key belongs to — that is what
// the operator's handoff and the first-import confirmation are for — but it
// does prove the file was produced by the holder of the private half: a
// descriptor whose signature fails, or whose `public_key` does not hash to
// its `signing_key_id`, is refused before it can mislabel a bundle.

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

public struct MemoryExportSigningKeyDescriptor: Sendable {
    public var keyID: String
    public var publicKey: Curve25519.Signing.PublicKey
    /// The producing store's canonical id — the TOFU pin keys on the pair,
    /// not on the key alone.
    public var storeID: String

    public init(keyID: String, publicKey: Curve25519.Signing.PublicKey, storeID: String) {
        self.keyID = keyID
        self.publicKey = publicKey
        self.storeID = storeID
    }

    /// From the private half, at export time. The id is derived, never
    /// asserted — two spellings of "this device's key" is how pins fork.
    public init(signingKey: Curve25519.Signing.PrivateKey, storeID: String) {
        self.init(
            keyID: MemoryExportCrypto.deviceKeyID(signingKey.publicKey),
            publicKey: signingKey.publicKey,
            storeID: storeID
        )
    }

    // MARK: - Emit

    /// `{signing_key_id, public_key, store_id}` — the signed members, in the
    /// order a reader sees them.
    private var signedMembers: MIFJSON {
        .object([
            "signing_key_id": .string(keyID),
            "public_key": .string(MemoryExportBase64URL.encode(publicKey.rawRepresentation)),
            "store_id": .string(storeID)
        ])
    }

    /// The signed bytes: `sha256(JCS(signedMembers))` — the descriptor's own
    /// content digest, over exactly the members a verifier needs.
    private func signedDigest() throws -> Data {
        MemoryExportDigest.sha256(MIFCanonicalJSON.data(signedMembers))
    }

    /// The descriptor as it is written to disk, self-signed under the key it
    /// names. The signature is a b64url rendering like every other binary in
    /// the format (§0.1).
    public func json(signingKey: Curve25519.Signing.PrivateKey) throws -> MIFJSON {
        guard case .object(var fields) = signedMembers else { return signedMembers }
        let digest = try signedDigest()
        let signature = try signingKey.signature(for: digest)
        fields["key_signature"] = .string(MemoryExportBase64URL.encode(signature))
        return .object(fields)
    }

    public func data(signingKey: Curve25519.Signing.PrivateKey) throws -> Data {
        try MIFCanonicalJSON.data(json(signingKey: signingKey))
    }

    // MARK: - Parse

    public enum DescriptorError: Error, Equatable {
        case malformed(String)
        /// `public_key` does not hash to the declared `signing_key_id` — the
        /// file mislabels the key it carries.
        case keyIDMismatch(declared: String, recomputed: String)
        /// The self-signature does not verify — the file was not produced by
        /// the holder of the key it names.
        case signatureInvalid
    }

    /// Read a descriptor, and refuse one whose id does not follow from its key
    /// or whose self-signature fails. The same posture `parse(descriptor:)`
    /// takes on the recipient side: an unverifiable handoff file is worse than
    /// none, because it LOOKS carried.
    public static func parse(descriptor data: Data) throws -> MemoryExportSigningKeyDescriptor {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DescriptorError.malformed("the signing-key descriptor is not a JSON object")
        }
        guard let declaredID = object["signing_key_id"] as? String,
              let encodedKey = object["public_key"] as? String,
              let storeID = object["store_id"] as? String,
              let encodedSignature = object["key_signature"] as? String else {
            throw DescriptorError.malformed(
                "the signing-key descriptor needs signing_key_id, public_key, store_id and key_signature"
            )
        }
        guard let raw = MemoryExportBase64URL.decode(encodedKey), raw.count == 32 else {
            throw DescriptorError.malformed("public_key must be a b64url Ed25519 public key of 32 bytes")
        }
        guard let signatureRaw = MemoryExportBase64URL.decode(encodedSignature), signatureRaw.count == 64 else {
            throw DescriptorError.malformed("key_signature must be a b64url Ed25519 signature of 64 bytes")
        }
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: raw)
        let descriptor = MemoryExportSigningKeyDescriptor(
            keyID: declaredID,
            publicKey: publicKey,
            storeID: storeID
        )
        let recomputed = MemoryExportCrypto.deviceKeyID(publicKey)
        guard recomputed == declaredID else {
            throw DescriptorError.keyIDMismatch(declared: declaredID, recomputed: recomputed)
        }
        let digest = try descriptor.signedDigest()
        guard publicKey.isValidSignature(signatureRaw, for: digest) else {
            throw DescriptorError.signatureInvalid
        }
        return descriptor
    }
}
