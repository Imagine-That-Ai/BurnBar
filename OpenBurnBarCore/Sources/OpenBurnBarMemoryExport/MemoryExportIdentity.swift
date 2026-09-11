// SPDX-License-Identifier: AGPL-3.0-only
//
// MemoryExportIdentity — the deterministic ids MIF requires.
//
// Every id here is derived, never minted from a UUID or a clock: two exports of
// one unchanged store must produce the same bundle, or `INV-07` and R1
// convergence fail on the importer.
//
// **`memory_id` is the exception the spec did not anticipate.** §2 says the
// oracle `memory_id` travels verbatim and §4 calls it "the oracle's `mem_…`
// memory_id". That holds for the daemon lane, which mints
// `mem_<32 hex>` — but `ControlPlaneStore.addMemoryAuthorityRecord` defaults its
// id to `UUID().uuidString`, so every APP-lane row carries an uppercase,
// hyphenated UUID that `contracts/mif-v1.schema.json`'s
// `^mem_[0-9a-f]{32}$` rejects. Carrying those verbatim would fail validation on
// the largest lane in the store. The exporter therefore canonicalises the
// non-conforming ones, deterministically and store-scoped, and writes every
// rewritten pair to `id-map.csv` beside the bundle so nothing is silently
// renamed. See `docs/MEMORY_EXPORT_MIF.md` deviation D-BB-E-1.

import Foundation

public enum MemoryExportIdentity {

    /// The unit separator the spec's id recipes use between components.
    static let separator = "\u{1F}"

    /// ASCII-only lowercase hex. `Character.isNumber`/`isHexDigit` are
    /// Unicode-aware and pass full-width digits (`０`…`９`) and letters
    /// (`ａ`…`ｆ`), which the schema's `[0-9a-f]` patterns do not admit — an id
    /// carrying one would be "canonical" here and invalid on the importer
    /// (review #2564). The check is over `asciiValue`, not the character.
    public static func isASCIILowerHex(_ character: Character) -> Bool {
        guard let ascii = character.asciiValue else { return false }
        return (0x30...0x39).contains(ascii) || (0x61...0x66).contains(ascii)
    }

    public static func isCanonicalMemoryID(_ value: String) -> Bool {
        guard value.hasPrefix("mem_") else { return false }
        let body = value.dropFirst(4)
        return body.count == 32 && body.allSatisfy(isASCIILowerHex)
    }

    /// A conforming `memory_id`. Already-conforming ids pass through untouched,
    /// which keeps every daemon-lane reference — audit, provenance, tombstone —
    /// intact exactly as §4 requires.
    public static func canonicalMemoryID(_ raw: String, storeID: String) -> String {
        guard isCanonicalMemoryID(raw) == false else { return raw }
        return "mem_" + prefix32(MemoryExportDigest.sha256Hex(storeID + separator + raw))
    }

    /// `"tmb_" + sha256(producer_store_id ‖ 0x1F ‖ source_table ‖ 0x1F ‖ source_id)[:32]`
    public static func tombstoneID(storeID: String, sourceTable: String, sourceID: String) -> String {
        "tmb_" + prefix32(MemoryExportDigest.sha256Hex(
            storeID + separator + sourceTable + separator + sourceID
        ))
    }

    /// `"rev_" + sha256(producer_store_id ‖ 0x1F ‖ audit_seq)[:32]`
    public static func reviewEventID(storeID: String, auditSeq: Int) -> String {
        "rev_" + prefix32(MemoryExportDigest.sha256Hex(storeID + separator + String(auditSeq)))
    }

    public static func citationID(storeID: String, provenanceID: String) -> String {
        "cit_" + prefix32(MemoryExportDigest.sha256Hex(storeID + separator + provenanceID))
    }

    /// The bundle id is derived from the content digest, so a re-export of an
    /// unchanged store re-uses it and the importer's idempotency holds without
    /// a caller-supplied key.
    public static func bundleID(contentDigest: String) -> String {
        "bnd_" + prefix32(contentDigest)
    }

    /// `origin_device_id` must start with `migration:` for the migration
    /// profile; the store id is what makes it identify a source.
    public static func migrationDeviceID(storeID: String) -> String { "migration:\(storeID)" }

    /// The synthetic actor a proven human verdict imports under. The oracle has
    /// no per-human actor — `actor` is always `"app"` — and this is what lets
    /// the row satisfy the target's `review_status <> 'approved' OR origin_kind
    /// = 'human'` CHECK.
    public static func migrationHumanActorID(storeID: String) -> String { "migration:app:\(storeID)" }

    static func prefix32(_ hex: String) -> String { String(hex.prefix(32)) }
}

/// One rewritten `memory_id`, for `id-map.csv`.
public struct MemoryExportIDMapping: Sendable, Equatable {
    public var sourceID: String
    public var bundleID: String
}
