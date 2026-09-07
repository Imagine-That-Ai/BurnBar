// SPDX-License-Identifier: AGPL-3.0-only
//
// MemoryExportAuditChain — §7's chain walk, and the thing conjunct 5 of §3.1
// rests on.
//
// Each row's hash is recomputed from its canonical `openburnbar.memory_audit.v2`
// payload. Breaks are recorded and the section still exports **as evidence with
// that marker**: never repaired, renumbered, re-hashed or re-signed. A broken
// source chain does not block migration — the memories are the user's data — it
// blocks only the CLAIM that the span is audit-verified, and it fails conjunct 5
// for any verdict inside it.
//
// Two known oracle pathologies shape this walk:
//
//   * **payload-seq divergence.** `ControlPlaneStore.insertMemoryAuditEvent`
//     hashes `previousSequence + 1`, while the column is AUTOINCREMENT. After a
//     row is deleted the two diverge permanently, so a walk that only ever tries
//     `row.seq` declares every subsequent row broken. Trying the writer's own
//     expression second turns a false break into a recorded `seq_divergence`.
//   * **the app<->daemon `prev_hash` fork.** Two writers with no lock can both
//     read the same head and both link to it. That is a fork, not a break: both
//     rows recompute correctly and only their linkage disagrees.

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// The result of walking `memory_audit` from seq 1.
public struct MemoryExportChainVerification: Sendable, Equatable {
    /// The largest seq up to which every row recomputed AND linked. Rows above
    /// it are carried but are not audit-verified.
    public var verifiedThroughSeq: Int
    /// Seqs whose recomputed hash did not match the stored one.
    public var brokenAt: [Int]
    /// Seqs whose `prev_hash` did not name the previous row's `hash`.
    public var forks: [Int]
    /// True when any row only verified under the writer's `previousSeq + 1`
    /// expression rather than its own `seq`.
    public var seqDivergence: Bool
    /// How many rows were walked. Zero rows is not a verified chain.
    public var rowsWalked: Int

    public init(
        verifiedThroughSeq: Int = 0,
        brokenAt: [Int] = [],
        forks: [Int] = [],
        seqDivergence: Bool = false,
        rowsWalked: Int = 0
    ) {
        self.verifiedThroughSeq = verifiedThroughSeq
        self.brokenAt = brokenAt
        self.forks = forks
        self.seqDivergence = seqDivergence
        self.rowsWalked = rowsWalked
    }

    /// Conjunct 5: `seq <= chain_verified_through_seq`, not inside any
    /// `chain_broken_at[]` span, not a member of `chain_forks[]`.
    public func isTrustworthy(seq: Int) -> Bool {
        seq <= verifiedThroughSeq
            && brokenAt.contains(seq) == false
            && forks.contains(seq) == false
    }
}

public enum MemoryExportAuditChain {

    /// Walk the rows in `seq` order and report what is provable.
    ///
    /// - Parameter rows: every `memory_audit` row, in any order. The walk sorts.
    public static func verify(rows: [MemoryExportAuditRow]) -> MemoryExportChainVerification {
        let ordered = rows.sorted { $0.seq < $1.seq }
        var result = MemoryExportChainVerification(rowsWalked: ordered.count)
        var previousRow: MemoryExportAuditRow?
        // The walk stops advancing `verifiedThroughSeq` at the first failure but
        // keeps going, because §7 wants every break named, not just the first.
        var stillContiguous = true

        for row in ordered {
            var rowIsSound = true

            // Linkage first: a fork is about which head this row claims, and a
            // row can fork while hashing perfectly.
            let expectedPrevHash = previousRow?.hash
            let claimedPrevHash = (row.prevHash?.isEmpty == false) ? row.prevHash : nil
            if claimedPrevHash != expectedPrevHash {
                result.forks.append(row.seq)
                rowIsSound = false
            }

            // Recompute. `row.seq` is the honest first guess; the writer's own
            // `previousSeq + 1` is the second, and matching only on the second
            // is what `seq_divergence` means.
            let recomputedBySeq = payloadHash(row: row, payloadSeq: row.seq, prevHash: claimedPrevHash)
            if recomputedBySeq != row.hash {
                let writerSeq = (previousRow?.seq ?? 0) + 1
                let recomputedByWriterSeq = writerSeq == row.seq
                    ? recomputedBySeq
                    : payloadHash(row: row, payloadSeq: writerSeq, prevHash: claimedPrevHash)
                if recomputedByWriterSeq == row.hash {
                    result.seqDivergence = true
                } else {
                    result.brokenAt.append(row.seq)
                    rowIsSound = false
                }
            }

            if stillContiguous, rowIsSound {
                result.verifiedThroughSeq = row.seq
            } else {
                stillContiguous = false
            }
            previousRow = row
        }
        return result
    }

    /// `sha256` over the app's `openburnbar.memory_audit.v2` payload, byte for
    /// byte as `ControlPlaneStore.auditPayloadData` builds it.
    ///
    /// The app uses `JSONSerialization` with `.sortedKeys`, whose ordering for
    /// these seven ASCII keys is identical to JCS's, so re-deriving the payload
    /// through this target's canonicaliser reproduces the stored hash exactly.
    /// A missing `prevHash` is the empty string in the payload and NULL in the
    /// column — that asymmetry is the oracle's, and copying it is the point.
    public static func payloadHash(row: MemoryExportAuditRow, payloadSeq: Int, prevHash: String?) -> String {
        let payload = MIFJSON.object([
            "schema": .string("openburnbar.memory_audit.v2"),
            "seq": .int(payloadSeq),
            "ts": .string(row.ts),
            "actor": .string(row.actor),
            "action": .string(row.action),
            "domain": .string(row.domain),
            "projectID": .string(row.projectID),
            "subjectID": .string(row.subjectID),
            "labels": .strings(row.labels.sorted()),
            "prevHash": .string(prevHash ?? "")
        ])
        return MemoryExportDigest.sha256Hex(MIFCanonicalJSON.data(payload))
    }

    /// The canonical payload the bundle carries verbatim in section 09. Never
    /// re-minted: this is a re-serialisation of what the oracle hashed, and
    /// `recomputed_ok` says whether it reproduced the stored hash.
    public static func canonicalPayload(row: MemoryExportAuditRow) -> String {
        MIFCanonicalJSON.serialize(.object([
            "schema": .string("openburnbar.memory_audit.v2"),
            "seq": .int(row.seq),
            "ts": .string(row.ts),
            "actor": .string(row.actor),
            "action": .string(row.action),
            "domain": .string(row.domain),
            "projectID": .string(row.projectID),
            "subjectID": .string(row.subjectID),
            "labels": .strings(row.labels.sorted()),
            "prevHash": .string(row.prevHash ?? "")
        ]))
    }
}

/// The unkeyed digest helper. Keyed digests live in `MemoryExportCrypto`; these
/// two must not be confused, because §2's whole point is that a raw body hash is
/// a dictionary-invertible oracle and never enters MIF.
public enum MemoryExportDigest {
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256Hex(_ text: String) -> String {
        sha256Hex(Data(text.utf8))
    }
}
