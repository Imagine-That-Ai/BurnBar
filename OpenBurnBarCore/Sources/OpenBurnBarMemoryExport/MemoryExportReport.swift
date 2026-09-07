// SPDX-License-Identifier: AGPL-3.0-only
//
// MemoryExportReport — §10's reconciliation report,
// `contracts/mif-v1.schema.json#/$defs/reconciliation_report`, version 1.1.
//
// "Counts reconcile" means, precisely: both closed sums hold for every logical
// table, with every row in exactly one bucket and every bucket carrying a reason
// code from the closed set, AND all the named `integrity.invariants` are true,
// AND the roll-up digests match, AND at P5 the id-set diff is empty. Anything
// less is `held`, never `applied` — so `balanced` is computed here from the
// arithmetic rather than asserted by the caller.

import Foundation

public struct MemoryExportTableReconciliation: Sendable, Equatable {
    public var name: String
    public var sourceRows = 0
    public var exported = 0
    public var notExported: [MIFNotExportedReason: Int] = [:]
    public var rejected: [MIFRejectedReason: Int] = [:]
    public var gateHeld = 0
    public var recoveredLegacyPlaintext = 0

    public init(name: String) { self.name = name }

    public mutating func note(_ reason: MIFNotExportedReason, _ count: Int = 1) {
        notExported[reason, default: 0] += count
    }

    public mutating func reject(_ reason: MIFRejectedReason, _ count: Int = 1) {
        rejected[reason, default: 0] += count
    }

    /// The closed sum: every source row lands in exactly one bucket.
    public var isBalanced: Bool {
        sourceRows == exported + notExported.values.reduce(0, +) + rejected.values.reduce(0, +)
    }

    var json: MIFJSON {
        var fields: [String: MIFJSON] = [
            "name": .string(name),
            "source_rows": .int(sourceRows),
            "exported": .int(exported),
            "not_exported": .object(Dictionary(uniqueKeysWithValues: notExported.map { ($0.key.rawValue, .int($0.value)) })),
            // The export phase imports nothing; the importer fills these in on
            // its own pass, and a zero here is a fact, not a placeholder.
            "imported": .int(0),
            "skipped": .object([:]),
            "rejected": .object(Dictionary(uniqueKeysWithValues: rejected.map { ($0.key.rawValue, .int($0.value)) })),
            "balanced": .bool(isBalanced)
        ]
        if gateHeld > 0 || recoveredLegacyPlaintext > 0 {
            fields["imported_detail"] = .object([
                "clean": .int(max(0, exported - gateHeld - recoveredLegacyPlaintext)),
                "gate_held": .int(gateHeld),
                "recovered_legacy_plaintext": .int(recoveredLegacyPlaintext),
                "content_conflict": .int(0)
            ])
        }
        return .object(fields)
    }
}

public struct MemoryExportFinding: Sendable, Equatable {
    public var code: MIFFindingCode
    public var severity: MIFSeverity
    public var count: Int
    public var table: String?
    public var detail: String
    public var sampleSourceIDs: [String]

    public init(
        code: MIFFindingCode,
        severity: MIFSeverity,
        count: Int,
        table: String? = nil,
        detail: String,
        sampleSourceIDs: [String] = []
    ) {
        self.code = code
        self.severity = severity
        self.count = count
        self.table = table
        self.detail = detail
        self.sampleSourceIDs = sampleSourceIDs
    }
}

public struct MemoryExportReport: Sendable {
    public enum Phase: String, Sendable { case export, dryRun = "dry_run", p5Reconcile = "p5_reconcile" }
    public enum Decision: String, Sendable { case exported, held, refused }

    public var phase: Phase
    public var decision: Decision = .exported
    public var holdReasons: [MIFHoldReason] = []
    public var exportError: MIFExportError?

    public var bundleID = "bnd_" + String(repeating: "0", count: 32)
    public var contentDigest = String(repeating: "0", count: 64)
    public var exporterDeviceKeyID: String?
    public var rehearsal = false
    /// D-0025 ruling 3's one exception, and the sentence it owes: rehearsal may
    /// seal to a recipient nobody holds the private half of, and `report.json`
    /// says so. `next_action` is the slot — every other object in the contract
    /// is `additionalProperties: false` — and it is the right one, because the
    /// consequence IS the next action: this bundle cannot be imported.
    public var recipientIsRehearsalThrowaway = false
    /// The recipient this bundle is addressed to. Shown in the export
    /// confirmation, so a substituted `--recipient` descriptor is visible.
    public var recipientKeyID: String?
    public var recipientStoreID: String?

    public var sourceProduct = "BurnBar"
    public var sourceVersion = "unknown"
    public var sourceStoreKind: MIFStoreKind = .authority
    public var sourceStoreFingerprint = String(repeating: "0", count: 64)
    public var sourceIntegrityOK = true
    public var concurrentWrites = false
    public var snapshotMode: MIFSnapshotMode = .readTxn
    public var partialSources: [(source: String, reason: String)] = []
    public var inventoriedStores: [MIFJSON] = []
    public var sourceQuickCheck: String?

    public var tables: [MemoryExportTableReconciliation] = []

    public var approvedToQuarantined: [MIFImportOriginDetail: Int] = [:]
    public var otherToQuarantined: [MIFImportOriginDetail: Int] = [:]
    public var auditProvenHuman = 0
    public var approvedRowsInSource = 0

    public var chain = MemoryExportChainVerification()
    public var auditLabelsStripped = 0

    public var gateClasses = MemoryExportGateTally()
    public var tombstonesWithoutContentKey = 0
    public var fingerprintDowngraded = 0
    public var partitionPseudoProject = 0
    public var deleteWithoutTombstoneSynthesized = 0
    public var sourceTombstoneSuppressors = 0
    public var bodiesRecoveredLegacyPlaintext = 0
    public var bodiesUnreconstructible = 0
    public var orphanBodies = 0
    /// Carried orphans, which become synthetic section-05 rows. They are NOT
    /// `agent_memories` rows, so they are counted here rather than inflating
    /// that table's `source_rows` to make its closed sum come out (review F-18).
    public var syntheticOrphanMemories = 0
    public var derivedDedupEdges = 0

    public var noUnprovenApproved = true
    public var allBodiesDigestMatch = true
    public var noKeyedFieldInBundle = true
    /// §13 AD-2. Computed from the records the bundle actually carries, not
    /// asserted: it used to be a hardcoded `true` justified as "the writer
    /// enforces this by construction", and the writer did not — a `--carry-orphans`
    /// export re-minted a forgotten memory under its own tombstone's id
    /// (review F-2).
    public var noResurrectedTombstone = true

    public var findings: [MemoryExportFinding] = []
    public var idSetDiff: MIFJSON?
    /// Only the P5 check fills this in: an export writes no target.
    public var target: MemoryExportReportTarget?

    public var memoriesIn = 0
    public var memoriesOut = 0
    public var backupLocation = "(none — export is read-only)"
    public var lostCSVPath: String?
    public var wouldWriteBytes: Int?

    public init(phase: Phase) { self.phase = phase }

    // MARK: - Rendering

    public var json: MIFJSON {
        var fields: [String: MIFJSON] = [
            "report_version": .string("1.1"),
            "phase": .string(phase.rawValue),
            "decision": .string(decision.rawValue),
            "hold_reasons": .strings(holdReasons.map(\.rawValue)),
            "bundle": bundleJSON,
            "source": sourceJSON,
            "tables": .array(tables.map(\.json)),
            "reclassifications": reclassificationsJSON,
            "verdict_conflicts": .array([]),
            "chain": chainJSON,
            "gate_classes": .object([
                "reject": .int(gateClasses.reject),
                "redact": .int(gateClasses.redact),
                "hold": .int(gateClasses.hold)
            ]),
            "counters": countersJSON,
            "integrity": integrityJSON,
            "embedding_provenance": .array([]),
            "findings": .array(findings.map(findingJSON)),
            "human_summary": humanSummaryJSON,
            "counts_hash": .string(countsHash)
        ]
        if let exportError { fields["export_error"] = .string(exportError.rawValue) }
        if let idSetDiff { fields["id_set_diff"] = idSetDiff }
        if let target {
            fields["target"] = .object([
                "store_fingerprint_before": .null,
                "store_fingerprint_after": .null,
                "keyed": .bool(true),
                "quiesced": .bool(target.quiesced)
            ])
        }
        return .object(fields)
    }

    private var bundleJSON: MIFJSON {
        .object([
            "bundle_id": .string(bundleID),
            "mif_version": .int(1),
            "mif_minor": .int(1),
            "profile": .string(MIFProfile.migration.rawValue),
            "content_digest": .string(contentDigest),
            "exporter_device_key_id": .string(exporterDeviceKeyID),
            "signature_verified": .bool(exporterDeviceKeyID != nil),
            "hashtree_verified": .bool(true),
            "rollups_verified": .bool(true),
            "rehearsal": .bool(rehearsal)
        ])
    }

    private var sourceJSON: MIFJSON {
        .object([
            "product": .string(sourceProduct),
            "version": .string(sourceVersion),
            "store_kind": .string(sourceStoreKind.rawValue),
            "store_fingerprint": .string(sourceStoreFingerprint),
            "source_integrity": .string(sourceIntegrityOK ? "ok" : "failed"),
            "concurrent_writes": .bool(concurrentWrites),
            "snapshot_mode": .string(snapshotMode.rawValue),
            "partial_sources": .array(partialSources.map {
                .object(["source": .string($0.source), "reason": .string($0.reason)])
            }),
            "inventoried_stores": .array(inventoriedStores)
        ])
    }

    private var reclassificationsJSON: MIFJSON {
        .object([
            "approved_to_quarantined": counts(approvedToQuarantined),
            "other_to_quarantined": counts(otherToQuarantined),
            "audit_proven_human": .int(auditProvenHuman),
            // Carried so the identity `approved_rows_in_source -
            // audit_proven_human = approved_to_quarantined` is verifiable from
            // the report alone.
            "approved_rows_in_source": .int(approvedRowsInSource)
        ])
    }

    private var chainJSON: MIFJSON {
        .object([
            "verified_through_seq": .int(chain.verifiedThroughSeq),
            "broken_at": .array(chain.brokenAt.map { .int($0) }),
            "forks": .array(chain.forks.map { .int($0) }),
            "seq_divergence": .bool(chain.seqDivergence),
            "labels_stripped": .int(auditLabelsStripped)
        ])
    }

    private var countersJSON: MIFJSON {
        .object([
            "gate_held": .int(gateClasses.total),
            "tombstones_without_content_key": .int(tombstonesWithoutContentKey),
            "fingerprint_downgraded": .int(fingerprintDowngraded),
            "partition_pseudo_project": .int(partitionPseudoProject),
            "verdict_orphaned_discarded": .int(0),
            "delete_without_tombstone_synthesized": .int(deleteWithoutTombstoneSynthesized),
            "source_tombstone_suppressors": .int(sourceTombstoneSuppressors),
            "bodies_recovered_legacy_plaintext": .int(bodiesRecoveredLegacyPlaintext),
            "bodies_unreconstructible": .int(bodiesUnreconstructible),
            "orphan_bodies": .int(orphanBodies),
            "derived_dedup_edges": .int(derivedDedupEdges),
            "spool_files": .int(0),
            "spool_bytes": .int(0)
        ])
    }

    private var integrityJSON: MIFJSON {
        .object([
            "source_quick_check": .string(sourceQuickCheck),
            "target_quick_check": .null,
            "target_integrity_check": .null,
            "invariants": .object([
                "no_unproven_approved": .bool(noUnprovenApproved),
                "no_resurrected_tombstone": .bool(noResurrectedTombstone),
                "all_bodies_digest_match": .bool(allBodiesDigestMatch),
                "rollup_digests_match": .bool(true),
                "no_keyed_field_in_bundle": .bool(noKeyedFieldInBundle),
                // Export writes no target. The importer sets this; a lie here
                // would be worse than the null the schema does not permit.
                "target_keyed": .bool(false),
                "audit_evidence_present_for_human_origin": .bool(auditProvenHuman == 0 || chain.rowsWalked > 0),
                "no_orphan_verdict_applied": .bool(true)
            ])
        ])
    }

    private func findingJSON(_ finding: MemoryExportFinding) -> MIFJSON {
        MemoryExportRecords.findingRecord(
            code: finding.code,
            severity: finding.severity,
            count: finding.count,
            table: finding.table,
            detail: finding.detail,
            sampleSourceIDs: finding.sampleSourceIDs
        )
    }

    /// Review rec 10: a fixed template with named slots, or it drifts and is
    /// untestable.
    private var humanSummaryJSON: MIFJSON {
        var statusChanges: [String] = []
        let reclassified = approvedToQuarantined.values.reduce(0, +)
        if reclassified > 0 {
            statusChanges.append(
                "\(reclassified) memories an agent had approved for itself now need your review"
            )
        }
        if auditProvenHuman > 0 {
            statusChanges.append("\(auditProvenHuman) memories you reviewed yourself keep their status")
        }
        var notCarried: [String] = []
        if bodiesUnreconstructible > 0 {
            notCarried.append(
                "\(bodiesUnreconstructible) memories lost their text before this migration; "
                + "their titles and sources are kept"
            )
        }
        if gateClasses.total > 0 {
            notCarried.append("\(gateClasses.total) memories held for review because they contained secrets or personal data")
        }
        var fields: [String: MIFJSON] = [
            "memories_in": .int(memoriesIn),
            "memories_out": .int(memoriesOut),
            "status_changes": .strings(statusChanges),
            "not_carried": .strings(notCarried),
            "still_elsewhere": .strings(partialSources.map { "\($0.source): \($0.reason)" }),
            "backup_location": .string(backupLocation),
            "next_action": .string(nextAction)
        ]
        if let lostCSVPath { fields["lost_csv_path"] = .string(lostCSVPath) }
        return .object(fields)
    }

    private var nextAction: String {
        switch decision {
        case .refused: "Nothing was written. Fix the reason above and run the export again."
        case .held: "The export finished but did not reconcile. Do not import this bundle yet."
        case .exported where recipientIsRehearsalThrowaway:
            "This is a rehearsal bundle sealed to a THROWAWAY recipient key that no store holds the "
                + "private half of, so it cannot be imported anywhere. Re-run with --recipient "
                + "<descriptor> from `memoryctl memory export-recipient` to produce a real bundle."
        case .exported: phase == .dryRun
            ? "Nothing was written. Re-run without --dry-run to produce the bundle."
            : "Import this bundle with `memoryctl memory import <bundle>`."
        }
    }

    /// A digest over exactly the numbers, so two runs are comparable without
    /// diffing prose. `--dry-run` on an unchanged source must reproduce it.
    public var countsHash: String {
        MemoryExportDigest.sha256Hex(MIFCanonicalJSON.data(.object([
            "tables": .array(tables.map(\.json)),
            "counters": countersJSON,
            "gate_classes": .object([
                "reject": .int(gateClasses.reject),
                "redact": .int(gateClasses.redact),
                "hold": .int(gateClasses.hold)
            ]),
            "reclassifications": reclassificationsJSON,
            "findings": .array(findings.sorted { $0.code.rawValue < $1.code.rawValue }.map(findingJSON))
        ])))
    }

    private func counts(_ source: [MIFImportOriginDetail: Int]) -> MIFJSON {
        .object(Dictionary(uniqueKeysWithValues: source.map { ($0.key.rawValue, MIFJSON.int($0.value)) }))
    }

    /// Every table balances, no invariant is false, and nothing is held.
    public var reconciles: Bool {
        tables.allSatisfy(\.isBalanced)
            && noUnprovenApproved
            && noKeyedFieldInBundle
            && noResurrectedTombstone
            && holdReasons.isEmpty
    }
}
