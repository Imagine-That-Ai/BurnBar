// SPDX-License-Identifier: AGPL-3.0-only
//
// MemoryExportManifestDigest — what `manifest.content_digest` is a digest OF,
// in one place, so the writer and `verify` cannot spell it two ways.
//
// §2 (`MEMORY_MIGRATION_SPEC.md`, the determinism claim):
//
//   "Determinism is claimed on `content_digest` and on the manifest minus
//    `{created_at_ms, recipient_key_id, wrapped key, signature}` — JCS
//    canonicalisation, fixed sort keys …"
//
// and D-0031 ruling 1 rests the signature on exactly that reading: "`manifest.sig`
// is Ed25519 over the 32 raw bytes of `content_digest` (the digest already binds
// the manifest minus the four excluded members, §2 line 244)".
//
// So the preimage is the manifest itself:
//
//     content_digest = sha256(JCS(manifest minus {created_at_ms, recipient_key_id,
//                                                 bundle_id, content_digest}))
//
// Two of §2's four excluded members are not manifest members at all — the
// wrapped key is `keys/wrapped-bundle-key` and the signature is `manifest.sig` —
// so removing them from a manifest is a no-op, and the two removals that are
// left are §2's. `bundle_id` and `content_digest` come off because a digest
// cannot bind itself: `bundle_id` is `"bnd_" + content_digest[0..<32]`
// (§4), so it carries no information the digest does not, and every other
// member — `hashtree.root` and the per-section subroots included (D-0031's "the
// root is an input to `content_digest`") — is inside the hash.
//
// This replaced a digest over `{<section>: sha256(plaintext), …, hashtree_root}`,
// which bound the section plaintexts and the tree and NOTHING else: the declared
// crypto profile, the recipient binding, `user_id`, `not_exported` and the
// roll-up digests were all rewritable on the wire under a signature that still
// verified (review F-1). The section plaintexts are still bound, transitively
// and more strongly: the per-section `subroot` is the keyed tree over the
// ciphertext they seal into, and every subroot is a member of the manifest this
// digest covers.

import Foundation

public enum MemoryExportManifestDigest {

    /// §2's excluded members that a manifest actually carries. The other two the
    /// sentence names live in their own files.
    public static let excludedMembers = ["created_at_ms", "recipient_key_id"]

    /// Members a digest of the manifest cannot cover because they are derived
    /// from it. Named separately from the §2 list so the departure is legible.
    public static let selfReferentialMembers = ["bundle_id", "content_digest"]

    /// Every member the signature transitively covers, for the operator-facing
    /// message when a manifest stops reproducing its own digest.
    public static func coveredMembers(of manifest: MIFJSON) -> [String] {
        guard case .object(let fields) = manifest else { return [] }
        return fields.keys
            .filter { excludedMembers.contains($0) == false && selfReferentialMembers.contains($0) == false }
            .sorted()
    }

    /// The manifest as the digest sees it: minus the four members above.
    public static func preimage(_ manifest: MIFJSON) -> MIFJSON {
        guard case .object(var fields) = manifest else { return manifest }
        for member in excludedMembers + selfReferentialMembers { fields.removeValue(forKey: member) }
        return .object(fields)
    }

    /// `sha256(JCS(preimage))`, as hex — the value `manifest.content_digest`
    /// carries and `manifest.sig` signs the 32 raw bytes of.
    public static func digest(of manifest: MIFJSON) -> String {
        MemoryExportDigest.sha256Hex(MIFCanonicalJSON.data(preimage(manifest)))
    }

    /// The same digest, recomputed from a `manifest.json` as it sits on disk.
    /// `nil` only when the bytes are not JSON at all — an edited member is a
    /// digest that differs, never a parse failure.
    ///
    /// Re-canonicalising rather than hashing the file's bytes is deliberate:
    /// the claim is about the manifest's MEMBERS, so reformatting the file is
    /// not tampering and changing a value is, whatever the whitespace.
    public static func digest(ofManifestBytes data: Data) -> String? {
        MIFCanonicalJSON.parse(data).map(digest(of:))
    }
}
