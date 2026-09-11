// SPDX-License-Identifier: AGPL-3.0-only
//
// MIFSignatureRedaction — test-only determinism comparison under I-76.
//
// Proven human verdicts leave section 02 signed under the device key with
// CryptoKit's randomized Ed25519, so `event_signature` (and, beside it, the
// key id that names the verifier) moves on every export even when every
// decision bit is identical. Tests that mean "the same store exports the
// same records" compare through this: everything but the per-export
// randomized signature bytes. Identity members (`bundle_id`,
// `content_digest`, roots) move with those bytes and are never compared;
// `determinismDigest` is the manifest-side half of the same claim.

@testable import OpenBurnBarMemoryExport

/// Section records keyed by section id, with the randomized review-event
/// signature bytes removed. Two exports of the same store through the same
/// keys compare equal here exactly when no decision changed.
func redactedSectionRecords(
    _ buffers: [MIFSection: MemoryExportSectionBuffer]
) -> [String: [MIFJSON]] {
    Dictionary(
        uniqueKeysWithValues: buffers.map { section, buffer in
            (
                section.rawValue,
                buffer.records.map { record in
                    guard section == .reviewEvents,
                          case .object(var members) = record
                    else { return record }
                    members.removeValue(forKey: "event_signature")
                    members.removeValue(forKey: "signing_key_id")
                    return .object(members)
                }
            )
        }
    )
}
