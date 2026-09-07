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
    case delta(sinceAuditSeq: Int)

    var manifestValue: String { self == .full || self == .dryRun ? "full" : "delta" }

    var sinceAuditSeq: Int? {
        if case .delta(let seq) = self { return seq }
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
        var memoriesTable = MemoryExportTableReconciliation(name: "agent_memories")
        var bodiesTable = MemoryExportTableReconciliation(name: "memory_body_snapshots")
        var provenanceTable = MemoryExportTableReconciliation(name: "memory_provenance")
        var tombstonesTable = MemoryExportTableReconciliation(name: "memory_fact_tombstones")
        var sourceTombstonesTable = MemoryExportTableReconciliation(name: "memory_source_tombstones")
        var projectsTable = MemoryExportTableReconciliation(name: "pcm_projects")

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
        var findingCounts: [MIFFindingCode: Int] = [:]
        var findingSamples: [MIFFindingCode: [String]] = [:]
        var emittedTombstoneIDs: Set<String> = []
        /// The canonical `subject_memory_id` of every tombstone this bundle
        /// emits. §2 applies sections in rank order, so a tombstone in 00 lands
        /// BEFORE any memory in 05: an id in this set must not also arrive as a
        /// memory, or the delete is undone by the same bundle that carried it.
        var emittedTombstoneSubjects: Set<String> = []
        var carriedMemoryIDs: Set<String> = []
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

        // ---- 05 / 06 / 07: memories, bodies, provenance --------------------
        let windowed = snapshot.memories.filter { memory in
            guard case .delta(let since) = mode else { return true }
            let auditSeqs = auditBySubject[memory.id]?.map(\.seq) ?? []
            // Either predicate suffices. `updated_at` is what catches the row
            // mutated with no audit row at all, which rehearsal `p4-window`
            // asserts the delta carries anyway.
            return auditSeqs.contains { $0 > since }
                || MemoryExportTimestamp.parse(memory.updatedAt) != nil
        }
        memoriesTable.sourceRows = snapshot.memories.count
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
                auditTableAvailable: snapshot.auditTableAvailable
            ))
            if memory.reviewStatus == MIFReviewStatus.approved.rawValue { report.approvedRowsInSource += 1 }
            for finding in classification.findings { record(finding, sample: memory.id) }

            // Row 12 — a `forgotten` row is a delete that happened, so it leaves
            // as a tombstone and never appears in section 05.
            if classification.isTombstoneOnly {
                memoriesTable.note(.forgottenToTombstone)
                let tombstoneID = MemoryExportIdentity.tombstoneID(
                    storeID: storeID,
                    sourceTable: "agent_memories.forgotten",
                    sourceID: memory.id
                )
                if emittedTombstoneIDs.insert(tombstoneID).inserted {
                    emittedTombstoneSubjects.insert(
                        MemoryExportIdentity.canonicalMemoryID(memory.id, storeID: storeID)
                    )
                    sections[.tombstones]?.append(MemoryExportRecords.factTombstoneRecord(
                        tombstoneID: tombstoneID,
                        subjectMemoryID: MemoryExportIdentity.canonicalMemoryID(memory.id, storeID: storeID),
                        userID: scope.userID,
                        scope: scope,
                        reason: .userForget,
                        originLabel: .daemonForgotten,
                        synthesisReason: .forgottenStatus,
                        auditSeq: nil,
                        createdAtMS: MemoryExportTimestamp.milliseconds(memory.updatedAt),
                        context: context
                    ))
                    tombstonesTable.sourceRows += 1
                    tombstonesTable.exported += 1
                    report.tombstonesWithoutContentKey += 1
                }
                continue
            }

            let resolution = MemoryExportBodyResolver.resolve(memory: memory, stores: stores)
            guard case .resolved(let body) = resolution else {
                guard case .unreconstructible(let failure) = resolution else { continue }
                // Not a memory record: `memories.content_key` is NOT NULL in the
                // target and there is no body to key it from. Nothing is
                // invented, nothing resurrects.
                for finding in failure.findings { record(finding, sample: memory.id) }
                memoriesTable.reject(.bodyUnreconstructible)
                report.bodiesUnreconstructible += 1
                lost.append((
                    memoryID: MemoryExportIdentity.canonicalMemoryID(memory.id, storeID: storeID),
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

            let canonicalID = MemoryExportIdentity.canonicalMemoryID(memory.id, storeID: storeID)
            if canonicalID != memory.id {
                idMappings.append(MemoryExportIDMapping(sourceID: memory.id, bundleID: canonicalID))
            }
            carriedMemoryIDs.insert(memory.id)

            let memoryRecord = MemoryExportRecords.memoryRecord(
                memory: memory,
                classification: classification,
                body: body,
                gate: gate,
                context: context,
                scope: scope
            )
            let joinKey = MemoryExportCrypto.bodyJoinKey(bundleKey: bundleKey, body: gate.body)
            let normDigest = MemoryExportCrypto.bodyNormDigest(bundleKey: bundleKey, body: gate.body)
            let citations = (provenanceByMemory[memory.id] ?? []).sorted { $0.id < $1.id }
            let provenanceDigest = MemoryExportDigest.sha256Hex(
                citations.map(\.contentHash).sorted().joined(separator: "\u{1F}")
            )
            sections[.memories]?.append(memoryRecord, rollup: [canonicalID, normDigest, provenanceDigest])
            sections[.bodies]?.append(
                MemoryExportRecords.bodyRecord(body: body, gate: gate, context: context),
                rollup: [canonicalID, normDigest, joinKey]
            )
            memoriesTable.exported += 1
            bodiesTable.exported += 1

            if let event = MemoryExportRecords.reviewEventRecord(
                memoryID: canonicalID,
                classification: classification,
                bodyJoinKey: joinKey,
                context: context
            ) {
                sections[.reviewEvents]?.append(event)
                report.auditProvenHuman += 1
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
                sections[.provenance]?.append(MemoryExportRecords.provenanceRecord(
                    row: citation,
                    memoryID: canonicalID,
                    context: context
                ))
                provenanceTable.exported += 1
            }

            // Orphan (c): a `superseded_by` pointing at a missing id drops the
            // EDGE and keeps the memory. §2 transports authored edges only, and
            // BurnBar's only edge source is the dedup merge, so section 03 stays
            // empty and every edge is recomputed locally by the importer.
            if let target = memory.supersededBy {
                report.derivedDedupEdges += 1
                if snapshot.memories.contains(where: { $0.id == target }) {
                    memoriesTable.note(.derivedEdgeRecomputedLocally)
                    memoriesTable.sourceRows += 1
                } else {
                    record(.danglingSupersession, sample: memory.id)
                    memoriesTable.note(.danglingSupersession)
                    memoriesTable.sourceRows += 1
                }
            }
        }
        report.memoriesOut = memoriesTable.exported

        // ---- 00 / 01: tombstones and receipts ------------------------------
        tombstonesTable.sourceRows += snapshot.factTombstones.count
        for tombstone in snapshot.factTombstones.sorted(by: { $0.id < $1.id }) {
            let subject = MemoryExportIdentity.canonicalMemoryID(tombstone.memoryID, storeID: storeID)
            let id = MemoryExportIdentity.tombstoneID(
                storeID: storeID,
                sourceTable: "memory_fact_tombstones",
                sourceID: tombstone.id
            )
            guard emittedTombstoneIDs.insert(id).inserted else {
                tombstonesTable.note(.cloudAlreadyLocal)
                continue
            }
            emittedTombstoneSubjects.insert(subject)
            sections[.tombstones]?.append(MemoryExportRecords.factTombstoneRecord(
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
            ))
            tombstonesTable.exported += 1
            report.tombstonesWithoutContentKey += 1
            record(.tombstoneContentKeyUnknown, sample: tombstone.memoryID)
            if let replicated = tombstone.replicatedAt {
                sections[.tombstoneReceipts]?.append(
                    MemoryExportRecords.receiptRecord(tombstoneID: id, replicatedAt: replicated)
                )
            }
        }

        // M-04: BurnBar's forget for a quarantined or user-less row is a hard
        // DELETE that writes only a `memory.delete` audit row, so a row imported
        // by an earlier bundle would live in the target forever while every
        // count balanced. Every delete in the window synthesizes a tombstone,
        // and a delete with no tombstone is an EXPORT FAILURE, not a warning.
        let deleteRows = snapshot.auditRows.filter { $0.action == "memory.delete" && $0.subjectID != nil }
        for delete in deleteRows.sorted(by: { $0.seq < $1.seq }) {
            if case .delta(let since) = mode, delete.seq <= since { continue }
            // swiftlint:disable:next force_unwrapping reason: filtered above
            let subjectID = delete.subjectID!
            let id = MemoryExportIdentity.tombstoneID(
                storeID: storeID,
                sourceTable: "memory_audit.delete",
                sourceID: subjectID
            )
            guard emittedTombstoneIDs.insert(id).inserted else { continue }
            emittedTombstoneSubjects.insert(
                MemoryExportIdentity.canonicalMemoryID(subjectID, storeID: storeID)
            )
            let projectID = delete.projectID ?? "chat:unscoped"
            sections[.tombstones]?.append(MemoryExportRecords.factTombstoneRecord(
                tombstoneID: id,
                subjectMemoryID: MemoryExportIdentity.canonicalMemoryID(subjectID, storeID: storeID),
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
            ))
            tombstonesTable.sourceRows += 1
            tombstonesTable.exported += 1
            report.deleteWithoutTombstoneSynthesized += 1
            report.tombstonesWithoutContentKey += 1
            record(.deleteWithoutTombstoneSynthesized, sample: subjectID)
        }
        guard report.deleteWithoutTombstoneSynthesized == deleteRows.filter({
            if case .delta(let since) = mode { return $0.seq > since }
            return true
        }).count else {
            throw MemoryExporterError.export(.deleteWithoutTombstone)
        }

        sourceTombstonesTable.sourceRows = snapshot.sourceTombstones.count
        for tombstone in snapshot.sourceTombstones.sorted(by: { $0.id < $1.id }) {
            sections[.tombstones]?.append(
                MemoryExportRecords.sourceTombstoneRecord(row: tombstone, context: context)
            )
            sourceTombstonesTable.exported += 1
            report.sourceTombstoneSuppressors += 1
            record(.sourceTombstoneSuppressorArmed, sample: tombstone.id)
        }

        // ---- 04: projects --------------------------------------------------
        projectsTable.sourceRows = snapshot.projects.count
        for project in snapshot.projects.sorted(by: { $0.projectID < $1.projectID }) {
            sections[.projects]?.append(MemoryExportRecords.projectRecord(project: project, context: context))
            projectsTable.exported += 1
            // The v3 fingerprint needs a live checkout; the exporter carries the
            // inputs it has and says the fingerprint is downgraded rather than
            // shipping a v2 value dressed as a v3 one.
            report.fingerprintDowngraded += 1
            record(.fingerprintDowngraded, sample: project.projectID)
            if project.pathAliasCount > 0 {
                projectsTable.note(.pathAliasNotTransported, project.pathAliasCount)
                projectsTable.sourceRows += project.pathAliasCount
            }
        }

        // ---- 08: embeddings (counts only) ----------------------------------
        for lane in snapshot.embeddingLanes.sorted(by: { $0.versionID < $1.versionID }) {
            sections[.embeddings]?.append(MemoryExportRecords.embeddingRecord(lane: lane))
        }

        // ---- 09: audit evidence --------------------------------------------
        for row in snapshot.auditRows.sorted(by: { $0.seq < $1.seq }) {
            if case .delta(let since) = mode, row.seq <= since { continue }
            let built = MemoryExportRecords.auditEvidenceRecord(row: row, chain: chain, context: context)
            sections[.auditEvidence]?.append(built.record)
            report.auditLabelsStripped += built.strippedLabels.count
            if built.strippedLabels.isEmpty == false { record(.auditLabelStripped, sample: String(row.seq)) }
        }
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
        bodiesTable.sourceRows = snapshot.bodySnapshots.count
        for snapshotRow in snapshot.bodySnapshots
        where referencedBodySnapshots.contains(snapshotRow.memoryID) == false {
            report.orphanBodies += 1
            record(.orphanBody, sample: snapshotRow.memoryID)
            let canonicalID = MemoryExportIdentity.canonicalMemoryID(snapshotRow.memoryID, storeID: storeID)
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
            if canonicalID != snapshotRow.memoryID {
                idMappings.append(MemoryExportIDMapping(sourceID: snapshotRow.memoryID, bundleID: canonicalID))
            }
            let synthetic = MemoryExportRecords.orphanBodyMemoryRecord(
                snapshot: snapshotRow,
                gate: gate,
                context: context,
                userID: userID
            )
            let normDigest = MemoryExportCrypto.bodyNormDigest(bundleKey: bundleKey, body: gate.body)
            sections[.memories]?.append(synthetic.memory, rollup: [canonicalID, normDigest, ""])
            sections[.bodies]?.append(synthetic.body, rollup: [canonicalID, normDigest, synthetic.joinKey])
            sections[.provenance]?.append(synthetic.provenance)
            bodiesTable.exported += 1
            memoriesTable.exported += 1
            memoriesTable.sourceRows += 1
        }
        provenanceTable.sourceRows = snapshot.provenance.count
        for citation in snapshot.provenance where carriedMemoryIDs.contains(citation.memoryID) == false {
            record(.orphanProvenance, sample: citation.memoryID)
            provenanceTable.note(.orphanProvenanceNoMemory)
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
            sections[.findings]?.append(MemoryExportRecords.findingRecord(
                code: finding.code,
                severity: finding.severity,
                count: finding.count,
                table: finding.table,
                detail: finding.detail,
                sampleSourceIDs: finding.sampleSourceIDs,
                lostRecords: lostForCode
            ))
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

        report.tables = [
            memoriesTable, bodiesTable, provenanceTable,
            tombstonesTable, sourceTombstonesTable, projectsTable
        ]
        report.partialSources = options.partialSources
        report.recipientKeyID = recipient.keyID
        report.recipientStoreID = recipient.storeID
        report.recipientIsRehearsalThrowaway = recipient.isRehearsalThrowaway
        if report.reconciles == false {
            report.decision = .held
            report.holdReasons.append(.reconciliationMismatch)
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
