// SPDX-License-Identifier: AGPL-3.0-only
//
// MemoryExportRecords — one builder per MIF record type.
//
// Each builder emits an `MIFJSON.object` whose keys are exactly the ones
// `contracts/mif-v1.schema.json` allows for that `$def`. The record types are
// `additionalProperties: false`, so an extra key is a bundle-wide validation
// failure, and `MemoryExportSchemaValidatorTests` proves these agree with the
// contract rather than with this file's own opinion.

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Values shared by every record in one bundle.
public struct MemoryExportRecordContext: Sendable {
    public var storeID: String
    public var schemaVersion: Int
    public var userID: String?
    public var bundleKey: SymmetricKey

    public init(storeID: String, schemaVersion: Int = 1, userID: String?, bundleKey: SymmetricKey) {
        self.storeID = storeID
        self.schemaVersion = schemaVersion
        self.userID = userID
        self.bundleKey = bundleKey
    }

    public var originDeviceID: String { MemoryExportIdentity.migrationDeviceID(storeID: storeID) }
    public var humanActorID: String { MemoryExportIdentity.migrationHumanActorID(storeID: storeID) }
}

/// Scope resolved from a BurnBar row. Chat and usage rows carry a
/// partition-prefixed `project_id` which is **not a project**: it routes to
/// `scope_kind: 'user'` with no project row minted (§3.3).
public struct MemoryExportScope: Sendable, Equatable {
    public var kind: MIFScopeKind
    public var key: String
    public var userID: String?
    public var projectFingerprint: String?
    public var isPseudoProject: Bool
}

public enum MemoryExportRecords {

    // MARK: - Scope

    public static func scope(for memory: MemoryExportMemoryRow, manifestUserID: String?) -> MemoryExportScope {
        if MemoryExportPartition.isPartitionPseudoProject(memory.projectID) {
            let user = memory.userID
                ?? MemoryExportPartition.pseudoProjectUserID(memory.projectID)
                ?? manifestUserID
            // `unscoped` with no manifest user has nowhere honest to go — v1
            // forbids `global` — so the key names the pseudo-project and the
            // importer holds with UNSCOPED_ROWS_NO_USER rather than inventing a
            // user here.
            return MemoryExportScope(
                kind: .user,
                key: user ?? memory.projectID,
                userID: user,
                projectFingerprint: nil,
                isPseudoProject: true
            )
        }
        return MemoryExportScope(
            kind: .project,
            key: memory.projectID,
            userID: memory.userID ?? manifestUserID,
            projectFingerprint: memory.projectID,
            isPseudoProject: false
        )
    }

    // MARK: - 05 memories

    // swiftlint:disable:next function_parameter_count reason: a record type's fields are its parameters
    public static func memoryRecord(
        memory: MemoryExportMemoryRow,
        classification: MemoryExportClassification,
        body: MemoryExportResolvedBody,
        gate: MemoryExportGateOutcome,
        context: MemoryExportRecordContext,
        scope: MemoryExportScope
    ) -> MIFJSON {
        let canonicalID = MemoryExportIdentity.canonicalMemoryID(memory.id, storeID: context.storeID)
        let (memoryType, typeSource) = memoryType(for: memory.kind)
        let createdMS = MemoryExportTimestamp.milliseconds(memory.createdAt)
        let updatedMS = MemoryExportTimestamp.milliseconds(memory.updatedAt, fallback: createdMS)
        let carriedBody = gate.body

        var fields: [String: MIFJSON] = [
            "profile": .string(MIFProfile.migration.rawValue),
            "memory_id": .string(canonicalID),
            "schema_version": .int(context.schemaVersion),
            "store_id": .string(context.storeID),
            "memory_type": .string(memoryType.rawValue),
            "memory_type_source": .string(typeSource),
            "scope_kind": .string(scope.kind.rawValue),
            "scope_key": .string(scope.key),
            "project_fingerprint": .string(scope.projectFingerprint),
            "user_id": .string(scope.userID),
            "session_id": .string(memory.runID),
            "agent_id": .string(memory.agentID),
            "device_id": .null,
            "org_id": .null,
            "origin_kind": .string(classification.originKind.rawValue),
            "origin_client_id": .null,
            "origin_ingest": .string("migration"),
            "confidence": .double(memory.confidence),
            "confidence_bits": .string(String(format: "%016llx", memory.confidence.bitPattern)),
            // §2: `restricted` rows are excluded at export, so every row that
            // reaches here is `internal`.
            "classification": .string(MIFClassification.internalClass.rawValue),
            "sensitivity_labels": .strings(gate.sensitivityLabels),
            "redaction_state": .string(gate.redactionState.rawValue),
            "review_status": .string(gate.reviewStatus(classification.reviewStatus).rawValue),
            "review_policy_id": .null,
            "dedup_partition": .string(MemoryExportPartition.dedupPartition(sourceKind: memory.sourceKind).rawValue),
            "body_join_key": .string(MemoryExportCrypto.bodyJoinKey(bundleKey: context.bundleKey, body: carriedBody)),
            "body_norm_digest": .string(
                MemoryExportCrypto.bodyNormDigest(bundleKey: context.bundleKey, body: carriedBody)
            ),
            "byte_len": .int(carriedBody.utf8.count),
            "tags": .strings(memory.tags.sorted()),
            "valid_from_ms": .int(MemoryExportTimestamp.milliseconds(memory.validFrom, fallback: createdMS)),
            "deletion_state": .string(MIFDeletionState.live.rawValue),
            "forgotten_at_ms": .null,
            "body_purged_at_ms": .null,
            "lamport": .int(0),
            "wall_ms": .int(updatedMS),
            "origin_device_id": .string(context.originDeviceID),
            "created_at_ms": .int(createdMS),
            "updated_at_ms": .int(updatedMS),
            "original_review_status": .string(classification.originalReviewStatus),
            "import_origin_detail": .string(classification.importOriginDetail.rawValue),
            "body_ref_convention": .string(body.convention.rawValue),
            "body_integrity": .string(body.integrity.rawValue),
            "source_kind_inferred": .string(inferredSourceKind(memory: memory, convention: body.convention))
        ]

        // M-30: the oracle's dedup merge sets `valid_to` unconditionally on the
        // loser; the target sets it only when the edge's scope matches. There is
        // no authored edge to compare against here, so the carried value travels
        // with its origin named and the importer decides.
        if let validTo = memory.validTo, let ms = MemoryExportTimestamp.parse(validTo) {
            fields["valid_to_ms"] = .int(Int((ms.timeIntervalSince1970 * 1000).rounded()))
            fields["valid_to_origin"] = .string("oracle_unconditional_dedup")
        } else {
            fields["valid_to_ms"] = .null
            fields["valid_to_origin"] = .string("none")
        }

        if classification.isProvenHumanVerdict, let seq = classification.verdictAuditSeq {
            fields["origin_actor_id"] = .string(context.humanActorID)
            fields["verdict_audit_seq"] = .int(seq)
            fields["verdict_event_id"] = .string(
                MemoryExportIdentity.reviewEventID(storeID: context.storeID, auditSeq: seq)
            )
        } else {
            fields["origin_actor_id"] = .null
            fields["verdict_audit_seq"] = .null
            fields["verdict_event_id"] = .null
        }
        return .object(fields)
    }

    /// BurnBar's `MemoryKind` is not the target's `memory_type`. A kind with no
    /// clean counterpart maps to `observation` and SAYS so, rather than being
    /// silently promoted into a type that carries different merge behaviour.
    static func memoryType(for kind: String) -> (MIFMemoryType, String) {
        switch kind {
        case "fact": (.projectFact, "mapped")
        case "preference": (.preference, "mapped")
        case "event": (.episode, "mapped")
        case "profile": (.observation, "mapped")
        case "relationship": (.observation, "mapped")
        default: (.observation, "unknown_defaulted")
        }
    }

    /// §3.3: where the `source_kind` column does not exist, the body-store
    /// convention implies one. An inference, recorded as one, never written
    /// into an authoritative field.
    static func inferredSourceKind(memory: MemoryExportMemoryRow, convention: MIFBodyRefConvention) -> String? {
        guard memory.sourceKind == nil else { return nil }
        return switch convention {
        case .snapshotSlug, .adversarialSlugHex: "chat"
        case .sha256: "code"
        case .unknown, .absent: nil
        }
    }

    // MARK: - 06 bodies

    public static func bodyRecord(
        body: MemoryExportResolvedBody,
        gate: MemoryExportGateOutcome,
        context: MemoryExportRecordContext
    ) -> MIFJSON {
        let carried = gate.body
        return .object([
            "profile": .string(MIFProfile.migration.rawValue),
            "body_join_key": .string(MemoryExportCrypto.bodyJoinKey(bundleKey: context.bundleKey, body: carried)),
            "body_norm_digest": .string(MemoryExportCrypto.bodyNormDigest(bundleKey: context.bundleKey, body: carried)),
            "byte_len": .int(carried.utf8.count),
            "body": .string(carried),
            "summary": .null,
            "recovered_from": .string(body.recoveredFrom.rawValue)
        ])
    }

    // MARK: - 02 review_events

    /// Emitted only for a PROVEN human verdict (§3.1 rows 1-3). An unproven
    /// verdict is represented by the memory's `import_origin_detail` and its
    /// finding; minting an `automatic` event for it would put a verdict into
    /// §4's merge that no one made.
    public static func reviewEventRecord(
        memoryID: String,
        classification: MemoryExportClassification,
        bodyJoinKey: String,
        context: MemoryExportRecordContext
    ) -> MIFJSON? {
        guard classification.isProvenHumanVerdict, let seq = classification.verdictAuditSeq else { return nil }
        let decidedMS = MemoryExportTimestamp.milliseconds(classification.verdictTimestamp)
        return .object([
            "profile": .string(MIFProfile.migration.rawValue),
            "event_id": .string(MemoryExportIdentity.reviewEventID(storeID: context.storeID, auditSeq: seq)),
            "memory_id": .string(memoryID),
            "from_status": .string(classification.verdictFromStatus),
            "to_status": .string(classification.reviewStatus.rawValue),
            "actor_kind": .string(MIFActorKind.human.rawValue),
            "actor_id": .string(context.humanActorID),
            "client_id": .null,
            "verdict_kind": .string(MIFVerdictKind.humanVerdict.rawValue),
            "policy_id": .null,
            "reason_label": .string("migration.human_verdict"),
            "decided_at_ms": .int(decidedMS),
            "lamport": .int(0),
            "wall_ms": .int(decidedMS),
            "origin_device_id": .string(context.originDeviceID),
            "event_signature": .null,
            "signing_key_id": .null,
            // BurnBar's v2 chain has no epoch; migration synthesizes 1.
            "audit_chain_epoch": .int(1),
            "audit_seq": .int(seq),
            "audit_row_hash": .string(classification.verdictAuditRowHash),
            "chain_verified": .bool(true),
            "body_hash_at_verdict": .string(bodyJoinKey),
            "body_verdict_binding": .string(MIFBodyVerdictBinding.bound.rawValue)
        ])
    }

    // MARK: - 00 tombstones

    // swiftlint:disable:next function_parameter_count reason: a record type's fields are its parameters
    public static func factTombstoneRecord(
        tombstoneID: String,
        subjectMemoryID: String,
        userID: String?,
        scope: MemoryExportScope,
        reason: MIFTombstoneReason,
        originLabel: MIFTombstoneOriginLabel,
        synthesisReason: MIFSynthesisReason?,
        auditSeq: Int?,
        createdAtMS: Int,
        context: MemoryExportRecordContext
    ) -> MIFJSON {
        .object([
            "profile": .string(MIFProfile.migration.rawValue),
            "tombstone_id": .string(tombstoneID),
            "schema_version": .int(context.schemaVersion),
            "tombstone_kind": .string(MIFTombstoneKind.fact.rawValue),
            "subject_memory_id": .string(subjectMemoryID),
            // M-06: both forget paths destroy the body when the tombstone is
            // written, so `subject_content_key` is unknowable for every
            // pre-migration tombstone. The importer computes it from ITS OWN
            // copy before purging; where it never held the row, INV-08 degrades
            // to id-only and no surface may claim text-level blocking.
            "subject_content_key_known": .bool(false),
            "content_key_version": .null,
            "project_fingerprint": .string(scope.projectFingerprint),
            "user_id": .string(userID),
            // The contract's `record_tombstone` carries `scope_key` and NO
            // `scope_kind` — unlike `record_memory`, which has both. Emitting
            // the pair here fails `additionalProperties: false`, so the scope's
            // kind is expressed by the key alone.
            "scope_key": .string(scope.key),
            "reason": .string(reason.rawValue),
            "origin_label": .string(originLabel.rawValue),
            "synthesis_reason": .string(synthesisReason?.rawValue),
            "actor_kind": .string("human"),
            "actor_id": .string(context.humanActorID),
            "verdict_kind": .string(MIFVerdictKind.humanVerdict.rawValue),
            "hard_delete_after_ms": .null,
            "audit_chain_epoch": auditSeq == nil ? .null : .int(1),
            "audit_seq": .int(auditSeq),
            "lamport": .int(0),
            "wall_ms": .int(createdAtMS),
            "origin_device_id": .string(context.originDeviceID),
            "created_at_ms": .int(createdAtMS),
            "origin_store": .string(context.storeID)
        ])
    }

    public static func sourceTombstoneRecord(
        row: MemoryExportSourceTombstoneRow,
        context: MemoryExportRecordContext
    ) -> MIFJSON {
        let createdMS = MemoryExportTimestamp.milliseconds(row.createdAt)
        let hash = row.contentHash.flatMap { MemoryExportBodyResolver.isHex64($0) ? $0 : nil }
        return .object([
            "profile": .string(MIFProfile.migration.rawValue),
            "tombstone_id": .string(MemoryExportIdentity.tombstoneID(
                storeID: context.storeID,
                sourceTable: "memory_source_tombstones",
                sourceID: row.id
            )),
            "schema_version": .int(context.schemaVersion),
            "tombstone_kind": .string(MIFTombstoneKind.source.rawValue),
            "subject_memory_id": .null,
            "subject_content_key_known": .bool(false),
            "content_key_version": .null,
            "subject_source_refs": .array([.object([
                "source_type": .string(MIFSourceType.conversation.rawValue),
                "thread_id": .string(row.threadLogicalID),
                "message_id": .string(row.messageID),
                "repo_origin_normalized": .null,
                "file_path": .null,
                "source_content_hash": .string(hash)
            ])]),
            "project_fingerprint": .null,
            "user_id": .string(row.userID ?? context.userID),
            "scope_key": .string(row.userID ?? context.userID ?? "migration:unscoped"),
            "reason": .string(MIFTombstoneReason.sourceDeleted.rawValue),
            "origin_label": .string(MIFTombstoneOriginLabel.local.rawValue),
            "synthesis_reason": .string(MIFSynthesisReason.sourceTombstone.rawValue),
            "actor_kind": .string("human"),
            "actor_id": .string(context.humanActorID),
            "verdict_kind": .string(MIFVerdictKind.humanVerdict.rawValue),
            "hard_delete_after_ms": .null,
            "audit_chain_epoch": .null,
            "audit_seq": .null,
            "lamport": .int(0),
            "wall_ms": .int(createdMS),
            "origin_device_id": .string(context.originDeviceID),
            "created_at_ms": .int(createdMS),
            "origin_store": .string(context.storeID)
        ])
    }

    // MARK: - 01 tombstone_receipts

    public static func receiptRecord(tombstoneID: String, replicatedAt: String) -> MIFJSON {
        let ms = MemoryExportTimestamp.milliseconds(replicatedAt)
        return .object([
            "profile": .string(MIFProfile.migration.rawValue),
            "tombstone_id": .string(tombstoneID),
            // The oracle's single `replicated_at` names no replica. Cloud is the
            // only peer BurnBar replicates a forget to, so that is the label,
            // and R1's defect — collapsing delivery and ack — stays fixed by
            // carrying both fields even when they hold the same instant.
            "peer_label": .string("cloud"),
            "peer_public_key": .null,
            "delivered_at_ms": .int(ms),
            "acked_at_ms": .int(ms),
            "ack_signature": .null,
            "attempts": .int(1)
        ])
    }

    // MARK: - 04 projects

    public static func projectRecord(
        project: MemoryExportProjectRow,
        context: MemoryExportRecordContext
    ) -> MIFJSON {
        .object([
            "profile": .string(MIFProfile.migration.rawValue),
            "identity_version": .int(project.identityVersion),
            "display_name": .string(project.projectName.isEmpty ? project.projectID : project.projectName),
            "primary_path": .string(project.primaryPath),
            // Review item 15: the v3 fingerprint needs a normalized remote plus
            // ALL sorted root commits under v3 normalization, which needs a live
            // checkout. The exporter carries the inputs it HAS and the importer
            // computes `project_id`; it never ships a v2 value as a v3 one.
            "fingerprint_v3": .null,
            "origin_normalized": .null,
            "root_commits": .array([]),
            "fingerprint_inputs_available": .bool(false),
            "aliases": .array([.object([
                "alias_kind": .string(MIFAliasKind.burnbarV2.rawValue),
                "alias_value": .string(project.projectID),
                "first_seen_ms": .int(MemoryExportTimestamp.milliseconds(project.createdAt)),
                "last_seen_ms": .int(MemoryExportTimestamp.milliseconds(project.updatedAt)),
                "source_label": .string(MIFAliasSourceLabel.migrationBurnBar)
            ])]),
            "created_at_ms": .int(MemoryExportTimestamp.milliseconds(project.createdAt)),
            "updated_at_ms": .int(MemoryExportTimestamp.milliseconds(project.updatedAt))
        ])
    }

    // MARK: - 07 provenance

    public static func provenanceRecord(
        row: MemoryExportProvenanceRow,
        memoryID: String,
        context: MemoryExportRecordContext
    ) -> MIFJSON {
        // A `live` citation with no hash is refused by the target's
        // `provenance_live_hash_ck`, and the source is not migrated by this
        // bundle, so `unknown` is the honest state — acceptance item 11's
        // literal word — rather than a hopeful `live`.
        let hash = MemoryExportBodyResolver.isHex64(row.contentHash) ? row.contentHash : nil
        return .object([
            "profile": .string(MIFProfile.migration.rawValue),
            "memory_id": .string(memoryID),
            "citation_id": .string(MemoryExportIdentity.citationID(storeID: context.storeID, provenanceID: row.id)),
            "schema_version": .int(context.schemaVersion),
            "source_type": .string(sourceType(for: row.sourceKind).rawValue),
            "citation_state": .string(MIFCitationState.unknown.rawValue),
            "thread_id": .string(row.threadLogicalID),
            "message_id": .string(row.messageID),
            "role": .string(role(for: row.role)),
            "occurrence": .int(max(0, row.occurrence)),
            "repo_origin_normalized": .null,
            "file_path": .null,
            "commit_sha": .null,
            "pr_number": .null,
            "issue_key": .null,
            "artifact_digest": .null,
            "release_id": .null,
            "deployment_id": .null,
            "source_uri": .null,
            "source_content_hash": .string(hash),
            "origin_kind": .string(MIFOriginKind.importOrigin.rawValue),
            "origin_actor_id": .null,
            "origin_client_id": .null,
            "authored_at_ms": .int(MemoryExportTimestamp.parse(row.authoredAt).map {
                Int(($0.timeIntervalSince1970 * 1000).rounded())
            }),
            "created_at_ms": .int(MemoryExportTimestamp.milliseconds(row.createdAt))
        ])
    }

    static func sourceType(for kind: String) -> MIFSourceType {
        switch kind {
        case "chat_message", "user_message": .userMessage
        case "agent_message", "agent_session_event": .agentMessage
        case "code_file", "code": .codeFile
        case "safari_ask": .externalDoc
        default: .conversation
        }
    }

    static func role(for value: String) -> String? {
        ["human", "agent", "notice", "injected"].contains(value) ? value : nil
    }

    // MARK: - 08 embeddings

    public static func embeddingRecord(lane: MemoryExportEmbeddingLane) -> MIFJSON {
        .object([
            "profile": .string(MIFProfile.migration.rawValue),
            "lane_label": .string("burnbar:\(lane.versionID)"),
            "model_id": .string(lane.versionID),
            "model_revision": .null,
            "version_tag": .string(lane.versionID),
            "dim": .int(max(1, lane.dimension)),
            "distance_metric": .string("cosine"),
            "normalization": .string("l2"),
            "row_count": .int(lane.rowCount),
            "disposable": .bool(true),
            // BurnBar's embedder is not pinned to a published revision, so the
            // vectors cannot be compared against anything the target produces.
            "reason": .string("unpinned_embedder"),
            "source_table": .string("memory_embedding_refs")
        ])
    }

    // MARK: - 09 audit_evidence

    public static func auditEvidenceRecord(
        row: MemoryExportAuditRow,
        chain: MemoryExportChainVerification,
        context: MemoryExportRecordContext
    ) -> (record: MIFJSON, strippedLabels: [String]) {
        // §8.2: `body_ref:<sha256(body)>` labels are stripped at export so the
        // body oracle never leaves BurnBar. The count is reported.
        var carried: [String] = []
        var stripped: [String] = []
        for label in row.labels.sorted() {
            if label.hasPrefix("body_ref:") || MemoryExportBodyResolver.isHex64(label) {
                stripped.append(label)
            } else if label.range(of: "^[a-z0-9][a-z0-9._:-]{0,63}$", options: .regularExpression) != nil {
                carried.append(label)
            } else {
                stripped.append(label)
            }
        }
        var sanitized = row
        sanitized.labels = carried
        let payload = MemoryExportAuditChain.canonicalPayload(row: sanitized)
        let record = MIFJSON.object([
            "profile": .string(MIFProfile.migration.rawValue),
            "peer_store_id": .string(context.storeID),
            "chain_epoch": .int(1),
            "peer_seq": .int(row.seq),
            "payload_seq": .int(row.seq),
            "ts": .string(row.ts),
            "actor": .string(row.actor),
            "action": .string(row.action),
            "domain": .string(row.domain),
            "project_id_raw": .string(row.projectID),
            "subject_id": .string(row.subjectID),
            "payload": .string(payload),
            "labels": .strings(carried),
            "stripped_labels": .strings(stripped),
            "prev_hash": .string(row.prevHash.flatMap { MemoryExportBodyResolver.isHex64($0) ? $0 : nil }),
            "hash": .string(row.hash),
            "recomputed_ok": .bool(chain.brokenAt.contains(row.seq) == false),
            "sanitized": .bool(true),
            "in_broken_span": .bool(row.seq > chain.verifiedThroughSeq || chain.brokenAt.contains(row.seq)),
            "in_fork": .bool(chain.forks.contains(row.seq))
        ])
        return (record, stripped)
    }

    // MARK: - 10 findings

    public static func findingRecord(
        code: MIFFindingCode,
        severity: MIFSeverity,
        count: Int,
        table: String?,
        detail: String,
        sampleSourceIDs: [String] = [],
        lostRecords: [MIFJSON] = []
    ) -> MIFJSON {
        var fields: [String: MIFJSON] = [
            "profile": .string(MIFProfile.migration.rawValue),
            "code": .string(code.rawValue),
            "severity": .string(severity.rawValue),
            "count": .int(count),
            "table": .string(table),
            "detail": .string(detail)
        ]
        if sampleSourceIDs.isEmpty == false {
            fields["sample_source_ids"] = .strings(Array(sampleSourceIDs.prefix(5)))
        }
        if lostRecords.isEmpty == false {
            fields["lost_records"] = .array(lostRecords)
        }
        return .object(fields)
    }

    /// M-29: a count is not a name. These become `lost.csv` beside the bundle.
    public static func lostRecord(
        memoryID: String,
        createdAtMS: Int,
        tags: [String],
        firstCitation: String?,
        reasonDetail: String
    ) -> MIFJSON {
        .object([
            "memory_id": .string(memoryID),
            "created_at_ms": .int(createdAtMS),
            "tags": .strings(tags),
            "first_citation": .string(firstCitation),
            "reason_detail": .string(reasonDetail)
        ])
    }
}

enum MIFAliasSourceLabel {
    static let migrationBurnBar = "migration:burnbar"
}
