// SPDX-License-Identifier: AGPL-3.0-only
//
// MemoryExporter — the BurnBar side of the migration, `MEMORY_MIGRATION_SPEC.md`
// §3.
//
// Release BB-E. Gated behind `burnbar.memory.export.enabled`, default OFF and
// user-initiated (§5, P1). Read-only in every mode: the exporter opens the
// store, classifies, dereferences and writes a bundle elsewhere. It never mints
// a key, never writes to the source, and never stops the daemon or changes the
// store's file mode — D-0007 forbids both, because that one LaunchAgent and that
// one `openburnbar.sqlite` serve roughly twenty unrelated RPC families.

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

public enum MemoryExportMode: Sendable, Equatable {
    case dryRun
    case full
    /// §5, P4. The completeness predicate is NOT `since_audit_seq` alone: the
    /// oracle's chain has payload-seq divergence and a `prev_hash` race, so the
    /// delta selects `audit_seq > since` OR `updated_at > watermark`.
    ///
    /// The watermark is a REQUIRED parameter, not an optional the caller can
    /// forget. It is the previous bundle's `delta_watermarks["agent_memories"]`,
    /// and without it the second disjunct has nothing to compare against — which
    /// is how every delta silently became a full export while the manifest still
    /// said `"delta"` (review F-4).
    case delta(sinceAuditSeq: Int, sinceUpdatedAtMS: Int)

    var manifestValue: String { self == .full || self == .dryRun ? "full" : "delta" }

    var sinceAuditSeq: Int? {
        if case .delta(let seq, _) = self { return seq }
        return nil
    }
}

public struct MemoryExportOptions: Sendable {
    /// §5: `burnbar.memory.export.enabled`, default OFF.
    public var enabled: Bool
    public var carryOrphans: Bool
    public var acceptDegradedSource: Bool
    public var rehearsal: Bool
    public var maxSectionBytes: Int
    public var snapshotMode: MIFSnapshotMode
    /// Sources this export could not read. Never a silent skip.
    public var partialSources: [(source: String, reason: String)]
    public var gate: MemoryExportGateRunner
    public var now: Date

    public init(
        enabled: Bool = false,
        carryOrphans: Bool = false,
        acceptDegradedSource: Bool = false,
        rehearsal: Bool = false,
        maxSectionBytes: Int = 256 * 1024 * 1024,
        snapshotMode: MIFSnapshotMode = .readTxn,
        partialSources: [(source: String, reason: String)] = [],
        gate: MemoryExportGateRunner = .shared,
        now: Date = Date()
    ) {
        self.enabled = enabled
        self.carryOrphans = carryOrphans
        self.acceptDegradedSource = acceptDegradedSource
        self.rehearsal = rehearsal
        self.maxSectionBytes = maxSectionBytes
        self.snapshotMode = snapshotMode
        self.partialSources = partialSources
        self.gate = gate
        self.now = now
    }
}

public enum MemoryExporterError: Error, Equatable {
    /// The flag is OFF and no one asked for this.
    case featureDisabled
    case export(MIFExportError)
    case held([MIFHoldReason])
}

public struct MemoryExporter: Sendable {
    /// A stable identifier for the source store. `sha256` over the store's own
    /// identity, never a path, because a path is not a fingerprint.
    public var storeID: String
    public var storeFingerprint: String
    public var sourceVersion: String
    public var userID: String?
    /// D-0025 ruling 3: required, and not an optional that can quietly be nil.
    /// A sealed bundle whose content key exists nowhere is never written.
    public var recipient: MemoryExportRecipient
    public var signingKey: Curve25519.Signing.PrivateKey?
    public var options: MemoryExportOptions

    public init(
        storeID: String,
        storeFingerprint: String,
        sourceVersion: String,
        userID: String?,
        recipient: MemoryExportRecipient,
        signingKey: Curve25519.Signing.PrivateKey?,
        options: MemoryExportOptions = MemoryExportOptions()
    ) {
        self.storeID = storeID
        self.storeFingerprint = storeFingerprint
        self.sourceVersion = sourceVersion
        self.userID = userID
        self.recipient = recipient
        self.signingKey = signingKey
        self.options = options
    }

    // swiftlint:disable:next function_body_length cyclomatic_complexity reason: this is the §3 pipeline; splitting it hides which section a row lands in
    public func export(
        _ snapshot: MemoryExportSourceSnapshot,
        mode: MemoryExportMode,
        to destination: URL?,
        bundleKey: SymmetricKey = MemoryExportCrypto.randomBundleKey()
    ) throws -> MemoryExportBundleResult {
        guard options.enabled else { throw MemoryExporterError.featureDisabled }

        // A gate that cannot load its corpus cannot decide anything, and
        // fail-closed here must not mean "placeholder every body in the store".
        guard options.gate.isAvailable() else {
            var report = baseReport(mode: mode, snapshot: snapshot)
            report.decision = .refused
            report.holdReasons = [.gateUnavailable]
            throw MemoryExporterError.held(report.holdReasons)
        }
        if snapshot.sourceQuickCheck != "ok", options.acceptDegradedSource == false {
            var report = baseReport(mode: mode, snapshot: snapshot)
            report.decision = .refused
            report.holdReasons = [.sourceIntegrityFailed]
            throw MemoryExporterError.held(report.holdReasons)
        }

        let context = MemoryExportRecordContext(storeID: storeID, userID: userID, bundleKey: bundleKey)
        let chain = snapshot.auditTableAvailable
            ? MemoryExportAuditChain.verify(rows: snapshot.auditRows)
            : MemoryExportChainVerification()
        var report = baseReport(mode: mode, snapshot: snapshot)
        report.chain = chain

        var sections = Dictionary(uniqueKeysWithValues: MIFSection.allCases.map {
            ($0, MemoryExportSectionBuffer(section: $0))
        })
        var memoriesTable = MemoryExportTableReconciliation(.agentMemories)
        var bodiesTable = MemoryExportTableReconciliation(.memoryBodySnapshots)
        var provenanceTable = MemoryExportTableReconciliation(.memoryProvenance)
        var tombstonesTable = MemoryExportTableReconciliation(.memoryFactTombstones)
        var sourceTombstonesTable = MemoryExportTableReconciliation(.memorySourceTombstones)
        var projectsTable = MemoryExportTableReconciliation(.pcmProjects)
        // M-8: five sections carried rows that no lane in `report.json.tables[]`
        // mentioned — 00 (a forgotten memory's tombstone), 01, 02, 09 and 10 —
        // so §10's closed sum, which is a sum over lanes, did not cover them.
        // D-0039 ruling 5 requires a lane per section; these are the five that
        // were missing, and each is a real obligation rather than a restatement
        // of a count: the forget path discharges a memory into a tombstone, a
        // replicated tombstone owes a receipt, a proven verdict owes an event,
        // an audit row owes its evidence, and a finding owes its record.
        var forgottenTable = MemoryExportTableReconciliation(.agentMemoriesForgotten)
        var receiptsTable = MemoryExportTableReconciliation(.memoryFactTombstoneReceipts)
        var reviewTable = MemoryExportTableReconciliation(.memoryAuditReview)
        var auditTable = MemoryExportTableReconciliation(.memoryAudit)
        var embeddingsTable = MemoryExportTableReconciliation(.embeddingVersions)
        var findingsTable = MemoryExportTableReconciliation(.reportFindings)
        // F-18: edges and aliases get their own closed sums. They used to be
        // added to `agent_memories.source_rows` and `pcm_projects.source_rows`
        // AFTER the fact, which made those numbers stop meaning "rows in the
        // source table" and closed the balance by construction instead of
        // checking it.
        var edgesTable = MemoryExportTableReconciliation(.agentMemoriesSupersededBy)
        var aliasesTable = MemoryExportTableReconciliation(.pcmProjectAliases)
        // R3: a synthesized tombstone is not a `memory_fact_tombstones` row, and
        // adding one to that table's `source_rows` on the same edge that added
        // it to `exported` is how its closed sum became `N == N`. The
        // `memory.delete` audit rows are their own logical table with their own
        // obligation (M-04), so they get their own row.
        var deletesTable = MemoryExportTableReconciliation(.memoryAuditDelete)

        let stores = MemoryExportBodyStores(
            snapshotsByMemoryID: Dictionary(
                snapshot.bodySnapshots.map { ($0.memoryID, $0) },
                uniquingKeysWith: { first, _ in first }
            ),
            projectSnapshotJSONBySlug: snapshot.projectSnapshots,
            quarantineBodiesByMemoryID: snapshot.quarantineBodies
        )
        let auditBySubject = Dictionary(grouping: snapshot.auditRows.filter { $0.subjectID != nil }) {
            // swiftlint:disable:next force_unwrapping reason: filtered above
            $0.subjectID!
        }
        let provenanceByMemory = Dictionary(grouping: snapshot.provenance, by: \.memoryID)

        var lost: [(memoryID: String, createdAtMS: Int, tags: [String], reason: String)] = []
        var idMappings: [MemoryExportIDMapping] = []
        var mappedSourceIDs: Set<String> = []
        var findingCounts: [MIFFindingCode: Int] = [:]
        var findingSamples: [MIFFindingCode: [String]] = [:]
        var emittedTombstoneIDs: Set<String> = []
        /// The canonical `subject_memory_id` of every tombstone this bundle
        /// emits. §2 applies sections in rank order, so a tombstone in 00 lands
        /// BEFORE any memory in 05: an id in this set must not also arrive as a
        /// memory, or the delete is undone by the same bundle that carried it.
        var emittedTombstoneSubjects: Set<String> = []
        var carriedMemoryIDs: Set<String> = []
        var tombstonedMemoryIDs: Set<String> = []
        var unreconstructibleMemoryIDs: Set<String> = []
        var carriedOrphanIDs: Set<String> = []
        /// M-20: rows 1-3 are the only `human` exits and "each names an
        /// `audit_seq` that section 09 must carry". The importer verifies each
        /// cited seq exists in 09, re-hashes it, and REFUSES the human claim
        /// otherwise — so a delta that dropped the row it cites would downgrade
        /// exactly the verdicts the migration exists to preserve.
        var auditSeqsSectionNineOwes: Set<Int> = []
        var quarantineStoreBodies = 0

        // §3.3(a) defines an orphan as "a body-snapshot row referenced by no
        // AUTHORITY row" — a fact about `agent_memories`, not about whether this
        // export happened to resolve a body from it. The old set was written in
        // one place, inside the resolved-body path, so a `forgotten` row, an
        // unreconstructible row and any row the delta window excluded all left
        // their snapshot looking unreferenced (review F-2).
        let referencedBodySnapshots: Set<String> = snapshot.bodySnapshots.reduce(into: []) { seen, row in
            let slugRef = MemoryExportClassifier.appBodyRefPrefix + row.id
            if snapshot.memories.contains(where: { $0.id == row.memoryID || $0.bodyRef == slugRef }) {
                seen.insert(row.memoryID)
            }
        }

        func record(_ code: MIFFindingCode, sample: String? = nil, count: Int = 1) {
            findingCounts[code, default: 0] += count
            if let sample, (findingSamples[code]?.count ?? 0) < 5 {
                findingSamples[code, default: []].append(sample)
            }
        }

        /// Canonicalise an oracle id AND record the rewrite, in one place.
        ///
        /// M-29's rule is that a lost row is named "by id", and `lost.csv` names
        /// the CANONICAL id. Recording the mapping only in the resolved-body
        /// path meant an app-lane row (UUID id, so always rewritten) whose body
        /// was unreconstructible appeared in `lost.csv` under an id that
        /// appeared nowhere else in the bundle and nowhere in `id-map.csv`, so
        /// the operator could not map it back to the oracle row — which is the
        /// entire purpose of naming it (review F-12). Tombstone subjects were
        /// rewritten and unmapped for the same reason.
        func canonical(_ rawID: String) -> String {
            let id = MemoryExportIdentity.canonicalMemoryID(rawID, storeID: storeID)
            if id != rawID, mappedSourceIDs.insert(rawID).inserted {
                idMappings.append(MemoryExportIDMapping(sourceID: rawID, bundleID: id))
            }
            return id
        }

        // ---- 05 / 06 / 07: memories, bodies, provenance --------------------
        let windowed = snapshot.memories.filter { memory in
            guard case .delta(let since, let watermark) = mode else { return true }
            let auditSeqs = auditBySubject[memory.id]?.map(\.seq) ?? []
            if auditSeqs.contains(where: { $0 > since }) { return true }
            // The second disjunct catches the row mutated with no audit row at
            // all. A row whose `updated_at` does not parse is carried: the
            // window cannot place it, and carrying too much is idempotent at
            // import while carrying too little loses data.
            guard let updatedAt = MemoryExportTimestamp.parse(memory.updatedAt) else { return true }
            return Int((updatedAt.timeIntervalSince1970 * 1000).rounded()) > watermark
        }
        memoriesTable.sourceRows = snapshot.sourceRows("agent_memories", observed: snapshot.memories.count)
        memoriesTable.note(.outOfWindow, snapshot.memories.count - windowed.count)
        report.memoriesIn = snapshot.memories.count

        for memory in windowed.sorted(by: { $0.id < $1.id }) {
            let scope = MemoryExportRecords.scope(for: memory, manifestUserID: userID)
            if scope.isPseudoProject {
                report.partitionPseudoProject += 1
                record(.partitionPseudoProject, sample: memory.id)
            }
            let classification = MemoryExportClassifier.classify(MemoryExportClassifierInput(
                memory: memory,
                auditRows: auditBySubject[memory.id] ?? [],
                bodySnapshotUpdatedAt: MemoryExportTimestamp.parse(stores.snapshotsByMemoryID[memory.id]?.updatedAt),
                chain: chain,
                auditTableAvailable: snapshot.auditTableAvailable,
                // A CONSTANT `false`, not a wiring — and the correction matters
                // because commit b7f7941f18's subject said "isCloudOnly is
                // wired" and it never was (review F-7). There is no source to
                // wire it to yet: every row BB-E classifies comes from the
                // authority store, which is local by construction, so §3.1 row
                // 15's shape cannot arise from these sources, and the cloud
                // vault is an unread `partial_sources` entry (D-BB-E-8). The
                // consequence, stated: **row 15 is unreachable in a real export
                // and `MIFImportOriginDetail.cloud` is production-dead** until
                // the vault reader lands and passes `true` for vault rows no
                // local row 1-3 names. The row-15 tests pin the branch that
                // reader will feed, so landing it will not touch classification.
                isCloudOnly: false
            ))
            if memory.reviewStatus == MIFReviewStatus.approved.rawValue { report.approvedRowsInSource += 1 }
            for finding in classification.findings { record(finding, sample: memory.id) }

            // Row 12 — a `forgotten` row is a delete that happened, so it leaves
            // as a tombstone and never appears in section 05.
            if classification.isTombstoneOnly {
                memoriesTable.note(.forgottenToTombstone)
                // The forget path's own lane. Its source rows are counted here
                // rather than read off the reader's table count, because they
                // are a SUBSET of `agent_memories` no reader can count on its
                // own edge — the same shape `memory_audit.delete` has.
                forgottenTable.sourceRows += 1
                let tombstoneID = MemoryExportIdentity.tombstoneID(
                    storeID: storeID,
                    sourceTable: "agent_memories.forgotten",
                    sourceID: memory.id
                )
                tombstonedMemoryIDs.insert(memory.id)
                if emittedTombstoneIDs.insert(tombstoneID).inserted {
                    emittedTombstoneSubjects.insert(
                        canonical(memory.id)
                    )
                    sections[.tombstones]?.append(
                        MemoryExportRecords.factTombstoneRecord(
                            tombstoneID: tombstoneID,
                            subjectMemoryID: canonical(memory.id),
                            userID: scope.userID,
                            scope: scope,
                            reason: .userForget,
                            originLabel: .daemonForgotten,
                            synthesisReason: .forgottenStatus,
                            auditSeq: nil,
                            createdAtMS: MemoryExportTimestamp.milliseconds(memory.updatedAt),
                            context: context
                        ),
                        lane: .agentMemoriesForgotten
                    )
                    forgottenTable.exported += 1
                    report.tombstonesWithoutContentKey += 1
                } else {
                    // The subject already has a tombstone from another path, so
                    // this forget is discharged by it.
                    forgottenTable.note(.cloudAlreadyLocal)
                }
                continue
            }

            // A `switch`, not a `guard` with an inner fallthrough: every
            // resolution has to land in a bucket, and a third case appearing one
            // day must be a compile error rather than a silent `continue` that
            // drops a row while the closed sum still adds up.
            let body: MemoryExportResolvedBody
            switch MemoryExportBodyResolver.resolve(memory: memory, stores: stores) {
            case .resolved(let resolved):
                body = resolved
            case .unreconstructible(let failure):
                // Not a memory record: `memories.content_key` is NOT NULL in the
                // target and there is no body to key it from. Nothing is
                // invented, nothing resurrects.
                for finding in failure.findings { record(finding, sample: memory.id) }
                memoriesTable.reject(.bodyUnreconstructible)
                unreconstructibleMemoryIDs.insert(memory.id)
                report.bodiesUnreconstructible += 1
                lost.append((
                    memoryID: canonical(memory.id),
                    createdAtMS: MemoryExportTimestamp.milliseconds(memory.createdAt),
                    tags: memory.tags,
                    reason: failure.reasonDetail
                ))
                continue
            }
            for finding in body.findings { record(finding, sample: memory.id) }
            if body.integrity == .recoveredLegacyPlaintext { report.bodiesRecoveredLegacyPlaintext += 1 }
            if body.integrity == .mismatch || body.integrity == .divergent { report.allBodiesDigestMatch = false }
            if body.fromQuarantineStore { quarantineStoreBodies += 1 }

            let gate = options.gate.apply(to: body.body)
            report.gateClasses.record(gate)
            if gate.isHeld {
                record(.secretGateHeld, sample: memory.id)
                memoriesTable.gateHeld += 1
            }
            if body.integrity == .recoveredLegacyPlaintext { memoriesTable.recoveredLegacyPlaintext += 1 }

            let canonicalID = canonical(memory.id)
            carriedMemoryIDs.insert(memory.id)

            let memoryRecord = MemoryExportRecords.memoryRecord(
                memory: memory,
                classification: classification,
                body: body,
                gate: gate,
                context: context,
                scope: scope
            )
            // The verdict binding in section 02, and the only reason this is
            // computed here: 05's roll-up tuple is projected from the record.
            let joinKey = MemoryExportCrypto.bodyJoinKey(bundleKey: bundleKey, body: gate.body)
            let citations = (provenanceByMemory[memory.id] ?? []).sorted { $0.id < $1.id }
            // The 05 tuple `(memory_id, body_join_key, body_norm_digest)` is
            // projected from this record by the buffer — the record carries all
            // three members, so there is nothing to pass.
            sections[.memories]?.append(memoryRecord, lane: .agentMemories)
            // ...and 06 emits no rollup at all: its tuple names
            // `seal_generation`, which `record_body` has no member for (§15
            // item 8). The 05 tuple above still binds every body to its id.
            sections[.bodies]?.append(
                MemoryExportRecords.bodyRecord(body: body, gate: gate, context: context),
                lane: .agentMemories
            )
            memoriesTable.exported += 1

            if let seq = classification.verdictAuditSeq,
               let event = MemoryExportRecords.reviewEventRecord(
                   memoryID: canonicalID,
                   classification: classification,
                   bodyJoinKey: joinKey,
                   context: context
               ) {
                // D-0031 ruling 2: 02 is `(event_id, memory_id, to_status)`.
                // The record is only minted for proven rows (D-BB-E-9), so the
                // seq this recomputes the id from is the audit row section 09
                // owes — the same seq, named once.
                sections[.reviewEvents]?.append(event, lane: .memoryAuditReview)
                report.auditProvenHuman += 1
                auditSeqsSectionNineOwes.insert(seq)
            } else if memory.reviewStatus == MIFReviewStatus.approved.rawValue {
                report.approvedToQuarantined[classification.importOriginDetail, default: 0] += 1
            } else if classification.reviewStatus == .quarantined,
                      classification.importOriginDetail != .asStored {
                report.otherToQuarantined[classification.importOriginDetail, default: 0] += 1
            }
            if classification.reviewStatus == .approved, classification.isProvenHumanVerdict == false {
                report.noUnprovenApproved = false
            }

            for citation in citations {
                sections[.provenance]?.append(
                    MemoryExportRecords.provenanceRecord(
                        row: citation,
                        memoryID: canonicalID,
                        context: context
                    ),
                    lane: .memoryProvenance
                )
                provenanceTable.exported += 1
            }

            // Orphan (c): a `superseded_by` pointing at a missing id drops the
            // EDGE and keeps the memory. §2 transports authored edges only, and
            // BurnBar's only edge source is the dedup merge, so section 03 stays
            // empty and every edge is recomputed locally by the importer.
            if let target = memory.supersededBy {
                report.derivedDedupEdges += 1
                if snapshot.memories.contains(where: { $0.id == target }) {
                    edgesTable.note(.derivedEdgeRecomputedLocally)
                } else {
                    record(.danglingSupersession, sample: memory.id)
                    edgesTable.note(.danglingSupersession)
                }
            }
        }

        // ---- 00 / 01: tombstones and receipts ------------------------------
        tombstonesTable.sourceRows = snapshot.sourceRows(
            "memory_fact_tombstones",
            observed: snapshot.factTombstones.count
        )
        // A replicated tombstone owes a section-01 receipt, which is section
        // 01's whole content and had no lane at all (M-8).
        receiptsTable.sourceRows = snapshot.factTombstones.count { $0.replicatedAt != nil }
        for tombstone in snapshot.factTombstones.sorted(by: { $0.id < $1.id }) {
            let subject = canonical(tombstone.memoryID)
            let id = MemoryExportIdentity.tombstoneID(
                storeID: storeID,
                sourceTable: "memory_fact_tombstones",
                sourceID: tombstone.id
            )
            guard emittedTombstoneIDs.insert(id).inserted else {
                tombstonesTable.note(.cloudAlreadyLocal)
                // Its receipt goes with it: the tombstone this one duplicates
                // carries the section-01 row.
                if tombstone.replicatedAt != nil { receiptsTable.note(.cloudAlreadyLocal) }
                continue
            }
            emittedTombstoneSubjects.insert(subject)
            sections[.tombstones]?.append(
                MemoryExportRecords.factTombstoneRecord(
                    tombstoneID: id,
                    subjectMemoryID: subject,
                    userID: tombstone.userID,
                    scope: MemoryExportScope(
                        kind: .user,
                        key: tombstone.userID,
                        userID: tombstone.userID,
                        projectFingerprint: nil,
                        isPseudoProject: true
                    ),
                    reason: MemoryExportRecords.tombstoneReason(tombstone.reason, default: .userForget),
                    originLabel: .local,
                    synthesisReason: nil,
                    auditSeq: nil,
                    createdAtMS: MemoryExportTimestamp.milliseconds(tombstone.createdAt),
                    context: context
                ),
                lane: .memoryFactTombstones
            )
            tombstonesTable.exported += 1
            report.tombstonesWithoutContentKey += 1
            record(.tombstoneContentKeyUnknown, sample: tombstone.memoryID)
            if let replicated = tombstone.replicatedAt {
                sections[.tombstoneReceipts]?.append(
                    MemoryExportRecords.receiptRecord(tombstoneID: id, replicatedAt: replicated),
                    lane: .memoryFactTombstoneReceipts
                )
                receiptsTable.exported += 1
            }
        }

        // M-04: BurnBar's forget for a quarantined or user-less row is a hard
        // DELETE that writes only a `memory.delete` audit row, so a row imported
        // by an earlier bundle would live in the target forever while every
        // count balanced. Every delete in the window synthesizes a tombstone,
        // and a delete with no tombstone is an EXPORT FAILURE, not a warning.
        let deleteRows = snapshot.auditRows.filter { $0.action == "memory.delete" && $0.subjectID != nil }
        deletesTable.sourceRows = snapshot.sourceRows("memory_audit.delete", observed: deleteRows.count)
        for delete in deleteRows.sorted(by: { $0.seq < $1.seq }) {
            if case .delta(let since, _) = mode, delete.seq <= since {
                deletesTable.note(.outOfWindow)
                continue
            }
            // swiftlint:disable:next force_unwrapping reason: filtered above
            let subjectID = delete.subjectID!
            let id = MemoryExportIdentity.tombstoneID(
                storeID: storeID,
                sourceTable: "memory_audit.delete",
                sourceID: subjectID
            )
            guard emittedTombstoneIDs.insert(id).inserted else {
                // A second `memory.delete` naming the same subject: the
                // obligation was discharged by the first, and the tombstone id
                // is keyed on the subject rather than on the delete's seq.
                deletesTable.note(.forgottenToTombstone)
                continue
            }
            emittedTombstoneSubjects.insert(
                canonical(subjectID)
            )
            let projectID = delete.projectID ?? "chat:unscoped"
            sections[.tombstones]?.append(
                MemoryExportRecords.factTombstoneRecord(
                    tombstoneID: id,
                    subjectMemoryID: canonical(subjectID),
                    userID: MemoryExportPartition.pseudoProjectUserID(projectID) ?? userID,
                    scope: MemoryExportScope(
                        kind: .user,
                        key: MemoryExportPartition.pseudoProjectUserID(projectID) ?? userID ?? projectID,
                        userID: MemoryExportPartition.pseudoProjectUserID(projectID) ?? userID,
                        projectFingerprint: nil,
                        isPseudoProject: true
                    ),
                    reason: .userForget,
                    originLabel: .local,
                    synthesisReason: .appDeleted,
                    auditSeq: delete.seq,
                    createdAtMS: MemoryExportTimestamp.milliseconds(delete.ts),
                    context: context
                ),
                lane: .memoryAuditDelete
            )
            deletesTable.exported += 1
            report.deleteWithoutTombstoneSynthesized += 1
            report.tombstonesWithoutContentKey += 1
            record(.deleteWithoutTombstoneSynthesized, sample: subjectID)
        }
        // M-04's obligation, as a SET difference rather than a running count.
        // The old guard compared a counter incremented once per loop iteration
        // against the same filter the loop ran, so it was true by construction —
        // and it fired falsely when two `memory.delete` rows named one subject,
        // because the tombstone id is keyed on the subject, not on the delete's
        // seq, and the first tombstone had already met the obligation for both
        // (review F-13).
        let owedDeleteSubjects = Set(deleteRows.compactMap { delete -> String? in
            if case .delta(let since, _) = mode, delete.seq <= since { return nil }
            return delete.subjectID.map { canonical($0) }
        })
        guard owedDeleteSubjects.subtracting(emittedTombstoneSubjects).isEmpty else {
            throw MemoryExporterError.export(.deleteWithoutTombstone)
        }

        sourceTombstonesTable.sourceRows = snapshot.sourceRows(
            "memory_source_tombstones",
            observed: snapshot.sourceTombstones.count
        )
        for tombstone in snapshot.sourceTombstones.sorted(by: { $0.id < $1.id }) {
            sections[.tombstones]?.append(
                MemoryExportRecords.sourceTombstoneRecord(row: tombstone, context: context),
                lane: .memorySourceTombstones
            )
            sourceTombstonesTable.exported += 1
            report.sourceTombstoneSuppressors += 1
            record(.sourceTombstoneSuppressorArmed, sample: tombstone.id)
        }

        // ---- 04: projects --------------------------------------------------
        projectsTable.sourceRows = snapshot.sourceRows("pcm_projects", observed: snapshot.projects.count)
        for project in snapshot.projects.sorted(by: { $0.projectID < $1.projectID }) {
            sections[.projects]?.append(
                MemoryExportRecords.projectRecord(project: project, context: context),
                lane: .pcmProjects
            )
            projectsTable.exported += 1
            // The v3 fingerprint needs a live checkout; the exporter carries the
            // inputs it has and says the fingerprint is downgraded rather than
            // shipping a v2 value dressed as a v3 one.
            report.fingerprintDowngraded += 1
            record(.fingerprintDowngraded, sample: project.projectID)
            if project.pathAliasCount > 0 {
                aliasesTable.note(.pathAliasNotTransported, project.pathAliasCount)
            }
        }

        // ---- 08: embeddings (counts only) ----------------------------------
        // §2 does not transport vectors; what travels is one count row per
        // embedding version, and `embedding_versions` is the lane that carries
        // them. The vectors themselves are `embedding_vector_disposable` on the
        // same lane, so the sum says both what came and what deliberately did
        // not.
        embeddingsTable.sourceRows = snapshot.embeddingLanes.count
        for lane in snapshot.embeddingLanes.sorted(by: { $0.versionID < $1.versionID }) {
            sections[.embeddings]?.append(
                MemoryExportRecords.embeddingRecord(lane: lane),
                lane: .embeddingVersions
            )
            embeddingsTable.exported += 1
        }

        // ---- 09: audit evidence --------------------------------------------
        auditTable.sourceRows = snapshot.sourceRows("memory_audit", observed: snapshot.auditRows.count)
        for row in snapshot.auditRows.sorted(by: { $0.seq < $1.seq }) {
            if case .delta(let since, _) = mode,
               row.seq <= since,
               auditSeqsSectionNineOwes.contains(row.seq) == false {
                auditTable.note(.outOfWindow)
                continue
            }
            let built = MemoryExportRecords.auditEvidenceRecord(row: row, chain: chain, context: context)
            sections[.auditEvidence]?.append(built.record, lane: .memoryAudit)
            auditTable.exported += 1
            report.auditLabelsStripped += built.strippedLabels.count
            if built.strippedLabels.isEmpty == false { record(.auditLabelStripped, sample: String(row.seq)) }
        }
        if snapshot.concurrentWrites { record(.concurrentWrites) }
        if chain.brokenAt.isEmpty == false { record(.chainBroken, count: chain.brokenAt.count) }
        if chain.forks.isEmpty == false { record(.chainFork, count: chain.forks.count) }
        if chain.seqDivergence { record(.seqDivergence) }

        // ---- orphans -------------------------------------------------------
        // §3.3(a): a body-snapshot row no authority row references is ALWAYS
        // counted, and carried only with `--carry-orphans` (default OFF). A
        // carried orphan BECOMES a synthetic quarantined row with
        // `origin_kind: 'import'`, `dedup_partition: 'import'` and a single
        // body-only provenance marker — it cannot exist in the target any other
        // way, and saying so is the point.
        for snapshotRow in snapshot.bodySnapshots
        where referencedBodySnapshots.contains(snapshotRow.memoryID) == false {
            report.orphanBodies += 1
            record(.orphanBody, sample: snapshotRow.memoryID)
            let canonicalID = canonical(snapshotRow.memoryID)
            // §13 AD-2, and the delete-wins invariant: a forget is not undone by
            // the bundle that carried it. Carrying this orphan would re-mint the
            // memory under the very id section 00 just tombstoned, and every
            // count would still balance.
            guard emittedTombstoneSubjects.contains(canonicalID) == false else {
                bodiesTable.note(.orphanBodyNotCarried)
                continue
            }
            guard options.carryOrphans, let orphanBody = snapshotRow.body else {
                bodiesTable.note(.orphanBodyNotCarried)
                continue
            }
            let gate = options.gate.apply(to: orphanBody)
            report.gateClasses.record(gate)
            if gate.isHeld { record(.secretGateHeld, sample: snapshotRow.memoryID) }
            let synthetic = MemoryExportRecords.orphanBodyMemoryRecord(
                snapshot: snapshotRow,
                gate: gate,
                context: context,
                userID: userID
            )
            // A carried orphan rolls up the same 05 tuple every other row does:
            // its synthetic memory record carries the join key and the norm
            // digest literally, so the buffer projects them like any other.
            sections[.memories]?.append(synthetic.memory, lane: .memoryBodySnapshots)
            sections[.bodies]?.append(synthetic.body, lane: .memoryBodySnapshots)
            sections[.provenance]?.append(synthetic.provenance, lane: .memoryBodySnapshots)
            carriedOrphanIDs.insert(snapshotRow.memoryID)
            report.syntheticOrphanMemories += 1
        }
        // The body table's closed sum is over ITS OWN rows. It used to count
        // every body that reached section 06 as `exported`, including bodies
        // recovered from `project_memory_snapshots` and `memory_quarantine_bodies`
        // — rows of two other tables — so `memory_body_snapshots` did not
        // balance and the fixture bundle was `held` without anyone noticing.
        // Every row lands in exactly one bucket here, by construction of the
        // if/else and not by adjusting `source_rows`.
        bodiesTable.sourceRows = snapshot.sourceRows(
            "memory_body_snapshots",
            observed: snapshot.bodySnapshots.count
        )
        for row in snapshot.bodySnapshots {
            if referencedBodySnapshots.contains(row.memoryID) == false {
                if carriedOrphanIDs.contains(row.memoryID) {
                    bodiesTable.exported += 1
                } else {
                    bodiesTable.note(.orphanBodyNotCarried)
                }
            } else if carriedMemoryIDs.contains(row.memoryID) {
                // The referencing memory travelled with a body. Where a daemon
                // convention won the lane, this row's text is the same fact and
                // its purpose in the source is discharged.
                bodiesTable.exported += 1
            } else if tombstonedMemoryIDs.contains(row.memoryID) {
                bodiesTable.note(.forgottenToTombstone)
            } else if unreconstructibleMemoryIDs.contains(row.memoryID) {
                bodiesTable.reject(.bodyUnreconstructible)
            } else {
                bodiesTable.note(.outOfWindow)
            }
        }

        // `memories_out` is what section 05 carries — the exported source rows
        // plus any synthetic orphan — so it is set after the orphan pass.
        report.memoriesOut = memoriesTable.exported + report.syntheticOrphanMemories

        provenanceTable.sourceRows = snapshot.sourceRows("memory_provenance", observed: snapshot.provenance.count)
        for citation in snapshot.provenance where carriedMemoryIDs.contains(citation.memoryID) == false {
            record(.orphanProvenance, sample: citation.memoryID)
            provenanceTable.note(.orphanProvenanceNoMemory)
        }

        // The two logical tables that are a predicate over another one: an edge
        // the walk never reached (its owning memory fell outside the window) and
        // an alias whose project row is missing are both real losses, and both
        // were invisible while these counted themselves.
        let edgesInSnapshot = snapshot.memories.count { $0.supersededBy != nil }
        edgesTable.sourceRows = snapshot.sourceRows(
            "agent_memories.superseded_by",
            observed: edgesInSnapshot
        )
        // An edge whose owning memory the delta window excluded is out of
        // window, exactly as the memory is. What is left unbucketed after this
        // is a row the reader counted and the snapshot did not hold.
        edgesTable.note(.outOfWindow, max(0, edgesInSnapshot - report.derivedDedupEdges))
        aliasesTable.sourceRows = snapshot.sourceRows(
            "pcm_project_aliases",
            observed: snapshot.projects.reduce(0) { $0 + $1.pathAliasCount }
        )

        // Section 02's lane. The source is the audit table's REVIEW rows —
        // `memory.approve` and `memory.reject`, the two verbs a verdict is
        // written with — and each one either becomes an event or lands in a
        // bucket. `auditSeqsSectionNineOwes` is exactly the set of seqs an
        // event was minted from, so this reads the emitted records rather than
        // recounting the loop that emitted them.
        let verdictRows = snapshot.auditRows.filter {
            MemoryExportClassifier.verdictActions.contains($0.action)
        }
        reviewTable.sourceRows = verdictRows.count
        for row in verdictRows {
            if auditSeqsSectionNineOwes.contains(row.seq) {
                reviewTable.exported += 1
            } else if case .delta(let since, _) = mode, row.seq <= since {
                reviewTable.note(.outOfWindow)
            } else {
                // The classifier did not admit it: an unproven verdict, a
                // broken chain around it, a second verdict on a memory whose
                // event was minted from another seq, or a memory that did not
                // travel. D-BB-E-9: section 02 carries proven verdicts only.
                reviewTable.note(.restrictedClassification)
            }
        }

        report.tables = [
            memoriesTable, bodiesTable, provenanceTable,
            tombstonesTable, sourceTombstonesTable, projectsTable,
            edgesTable, aliasesTable, deletesTable,
            forgottenTable, receiptsTable, reviewTable, auditTable,
            embeddingsTable, findingsTable
        ]
        // A table that does not balance is a row the source held and this bundle
        // cannot account for — the reader counted it, the export never saw it.
        // It is NOT given a bucket: a bucket would close the sum again, and the
        // point of the sum is that it can fail.
        for table in report.tables where table.isBalanced == false {
            record(
                .sourceUnreadable,
                sample: "\(table.name): counted \(table.sourceRows), accounted \(table.accountedRows)"
            )
        }

        // ---- 10: findings ---------------------------------------------------
        report.findings = findingCounts
            .map { code, count in
                MemoryExportFinding(
                    code: code,
                    severity: severity(for: code),
                    count: count,
                    table: nil,
                    detail: detail(for: code),
                    sampleSourceIDs: findingSamples[code] ?? []
                )
            }
            .sorted { $0.code.rawValue < $1.code.rawValue }
        // Section 10 is not data — §2 says a finding is never applied — but
        // D-0039 ruling 5's sum is over all ELEVEN sections, and a section
        // excused from the sum is the hole M-8 named. The lane is honest about
        // what it counts: findings computed in, finding records written out.
        findingsTable.sourceRows = report.findings.count
        for finding in report.findings {
            let lostForCode = finding.code == .bodyUnreconstructible
                ? lost.map {
                    MemoryExportRecords.lostRecord(
                        memoryID: $0.memoryID,
                        createdAtMS: $0.createdAtMS,
                        tags: $0.tags,
                        firstCitation: nil,
                        reasonDetail: $0.reason
                    )
                }
                : []
            sections[.findings]?.append(
                MemoryExportRecords.findingRecord(
                    code: finding.code,
                    severity: finding.severity,
                    count: finding.count,
                    table: finding.table,
                    detail: finding.detail,
                    sampleSourceIDs: finding.sampleSourceIDs,
                    lostRecords: lostForCode
                ),
                lane: .reportFindings
            )
            findingsTable.exported += 1
        }
        // `report.tables` was assembled before the findings were computed, so
        // the findings lane's own numbers land here — the one lane whose source
        // is this run rather than the store.
        if let index = report.tables.firstIndex(where: { $0.lane == .reportFindings }) {
            report.tables[index] = findingsTable
        }

        // §13 AD-2, checked rather than claimed: no id this bundle tombstones in
        // section 00 may also arrive as a memory in section 05. Read back off
        // the records that were actually emitted, so it is a property of the
        // bundle rather than a property of the code that built it.
        report.noResurrectedTombstone = (sections[.memories]?.records ?? []).allSatisfy { record in
            guard case .object(let fields) = record,
                  case .string(let id) = fields["memory_id"] ?? .null else { return true }
            return emittedTombstoneSubjects.contains(id) == false
        }

        // D-0039 ruling 5, checked rather than claimed: every row this bundle
        // carries is inside some lane's closed sum, and every one of the eleven
        // sections has a lane. `append` made each row name its lane, so this
        // re-reads the attribution off the buffers and refuses the two ways it
        // could still be wrong — a lane writing into a section it does not
        // declare, and a lane the report does not carry.
        let declaredLanes = Set(report.tables.map(\.lane))
        var coverageFailed = false
        for section in MIFSection.allCases {
            let buffer = sections[section] ?? MemoryExportSectionBuffer(section: section)
            for (lane, rows) in buffer.attribution.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                if lane.sections.contains(section) == false {
                    record(
                        .sourceUnreadable,
                        sample: "\(section.rawValue): \(rows) row(s) written by lane \(lane.rawValue), "
                            + "which does not declare this section"
                    )
                }
                if declaredLanes.contains(lane) == false {
                    record(
                        .sourceUnreadable,
                        sample: "\(section.rawValue): \(rows) row(s) on lane \(lane.rawValue), which "
                            + "report.json does not carry"
                    )
                }
            }
            let attributed = buffer.attribution.values.reduce(0, +)
            if attributed != buffer.records.count {
                record(
                    .sourceUnreadable,
                    sample: "\(section.rawValue): \(buffer.records.count) row(s) carried, \(attributed) "
                        + "attributed to a lane"
                )
                coverageFailed = true
            }
            if buffer.records.isEmpty == false, buffer.attribution.isEmpty {
                record(
                    .sourceUnreadable,
                    sample: "\(section.rawValue): \(buffer.records.count) row(s) carried by no lane at all"
                )
                coverageFailed = true
            }
        }

        report.partialSources = options.partialSources
        report.recipientKeyID = recipient.keyID
        report.recipientStoreID = recipient.storeID
        report.recipientIsRehearsalThrowaway = recipient.isRehearsalThrowaway
        if report.reconciles == false || coverageFailed {
            report.decision = .held
            // One reason, however many ways the sums failed: `hold_reasons[]`
            // is a set of causes, not a log.
            if report.holdReasons.contains(.reconciliationMismatch) == false {
                report.holdReasons.append(.reconciliationMismatch)
            }
        }

        return try MemoryExportBundleWriter.build(
            MemoryExportBundleInputs(
                sections: sections,
                report: report,
                context: context,
                lostRecords: lost,
                idMappings: idMappings,
                recipient: recipient,
                signingKey: signingKey,
                exportMode: mode.manifestValue,
                sinceAuditSeq: mode.sinceAuditSeq,
                deltaWatermarks: deltaWatermarks(snapshot),
                carriesHumanOrigin: report.auditProvenHuman > 0,
                rehearsal: options.rehearsal,
                createdAtMS: Int((options.now.timeIntervalSince1970 * 1000).rounded()),
                maxSectionBytes: options.maxSectionBytes
            ),
            writingTo: mode == .dryRun ? nil : destination,
            dryRun: mode == .dryRun
        )
    }

    // MARK: - Helpers

    private func baseReport(mode: MemoryExportMode, snapshot: MemoryExportSourceSnapshot) -> MemoryExportReport {
        var report = MemoryExportReport(phase: mode == .dryRun ? .dryRun : .export)
        report.sourceVersion = sourceVersion
        report.sourceStoreFingerprint = storeFingerprint
        report.snapshotMode = options.snapshotMode
        report.sourceQuickCheck = snapshot.sourceQuickCheck
        report.sourceIntegrityOK = snapshot.sourceQuickCheck == "ok"
        report.concurrentWrites = snapshot.concurrentWrites
        report.partialSources = options.partialSources
        report.inventoriedStores = [.object([
            "label": .string("authority"),
            "store_kind": .string(MIFStoreKind.authority.rawValue),
            "present": .bool(true),
            "migratable": .bool(true),
            "reason": .null
        ])]
        return report
    }

    /// `max(updated_at)` per table. Review item 24: `audit_seq` alone is not a
    /// completeness predicate on a chain with seq divergence and forks.
    private func deltaWatermarks(_ snapshot: MemoryExportSourceSnapshot) -> [String: Int] {
        var watermarks: [String: Int] = [:]
        let memoryMax = snapshot.memories
            .compactMap { MemoryExportTimestamp.parse($0.updatedAt) }
            .max()
        if let memoryMax { watermarks["agent_memories"] = Int((memoryMax.timeIntervalSince1970 * 1000).rounded()) }
        let bodyMax = snapshot.bodySnapshots
            .compactMap { MemoryExportTimestamp.parse($0.updatedAt) }
            .max()
        if let bodyMax {
            watermarks["memory_body_snapshots"] = Int((bodyMax.timeIntervalSince1970 * 1000).rounded())
        }
        return watermarks
    }

    private func severity(for code: MIFFindingCode) -> MIFSeverity {
        switch code {
        case .bodyUnreconstructible, .chainBroken, .chainFork, .forgedHumanVerdictRefused,
             .approvedBodyMutatedAfterVerdict, .verdictOnBrokenChain, .bodyHashMismatch,
             .bodyDivergentStores, .sourceUnreadable, .unmigratableSourcePresent:
            .error
        case .secretGateHeld, .orphanBody, .orphanProvenance, .danglingSupersession,
             .reviewStatusUnknownValue, .seqDivergence, .fingerprintDowngraded,
             .bodyRefUnknownConvention, .concurrentWrites, .bodyRecoveredLegacyPlaintext:
            .warn
        default:
            .info
        }
    }

    private func detail(for code: MIFFindingCode) -> String {
        switch code {
        case .approvedBodyMutatedAfterVerdict:
            "A memory.approve row exists but the body snapshot is newer than the verdict, "
                + "so the approved text is not the text carried. Exported quarantined."
        case .forgedHumanVerdictRefused:
            "An audit row claims actor 'app' for a row that is not app-owned. The claim is refused; "
                + "the row still travels, quarantined."
        case .verdictOnBrokenChain:
            "A verdict sits inside a span the chain walk could not verify, so it is not proof."
        case .deleteWithoutTombstoneSynthesized:
            "A hard DELETE wrote only a memory.delete audit row; a fact tombstone was synthesized "
                + "so the delete survives the migration."
        case .secretGateHeld:
            "The pre-persistence gate found a secret or PII class. Held for review; the span never "
                + "reaches the sealed body."
        case .bodyUnreconstructible:
            "No body could be reconstructed from either convention or from body_redacted. "
                + "Named by id in lost.csv."
        case .fingerprintDowngraded:
            "The v3 project fingerprint needs a live checkout; the inputs are carried and the "
                + "importer computes project_id."
        case .partitionPseudoProject:
            "A chat:/usage: project_id is a storage partition, not a project. Routed to user scope "
                + "with no project row minted."
        case .tombstoneContentKeyUnknown:
            "Both forget paths destroy the body when the tombstone is written, so subject_content_key "
                + "is unknowable. Id-level blocking is unaffected."
        default:
            code.rawValue
        }
    }
}
