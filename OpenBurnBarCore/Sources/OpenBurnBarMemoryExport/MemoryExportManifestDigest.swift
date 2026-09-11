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
// D-0039 ruling 1 states it once and in full, and the spec's §2 now carries
// exactly this:
//
//     content_digest = sha256( JCS(manifest minus {created_at_ms, recipient_key_id,
//                                                  bundle_id, content_digest})
//                              ‖ hashtree_root_raw32 )
//
// The root is appended as its 32 RAW bytes, hex-decoded — never as its 64 ASCII
// characters. It is also a member of the manifest inside the JCS, so the suffix
// adds no new binding; what it adds is a second implementation's ability to
// check the digest without agreeing about where in the object the root sits,
// and the ruling pins it, so this build appends it. Until Q-53 this hashed the
// JCS alone, which is the value interop run 1 measured (`95ee02b1…`).
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

    /// `sha256(JCS(preimage) ‖ hashtree_root_raw32)`, as hex — the value
    /// `manifest.content_digest` carries and `manifest.sig` signs the 32 raw
    /// bytes of.
    ///
    /// The root is read out of the manifest being digested (`hashtree.root`),
    /// so there is one root in one place and no second value to pass in. A
    /// manifest with no root, or one that is not 64 hex characters, contributes
    /// no suffix rather than a guess: the digest is then the JCS alone, which
    /// is a value that will not match any conforming bundle — a refusal by
    /// mismatch rather than by silently hashing zeroes.
    public static func digest(of manifest: MIFJSON) -> String {
        var preimageBytes = MIFCanonicalJSON.data(preimage(manifest))
        if let root = hashtreeRoot(of: manifest), let raw = MemoryExportCrypto.hexToData(root) {
            preimageBytes.append(raw)
        }
        return MemoryExportDigest.sha256Hex(preimageBytes)
    }

    /// `manifest.hashtree.root`, the one member D-0039 ruling 1 appends.
    static func hashtreeRoot(of manifest: MIFJSON) -> String? {
        guard case .object(let fields) = manifest,
              case .object(let tree)? = fields["hashtree"],
              case .string(let root)? = tree["root"],
              root.count == 64 else { return nil }
        return root
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
