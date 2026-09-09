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

    // MARK: - Project identity (D-0033 ruling 1)

    /// The fingerprint the importer will match this project on. Identity is
    /// the fingerprint, never the carried id — so a memory's
    /// `project_fingerprint` must name the same value the section-04 record
    /// carries, in the importer's own arm order: the store's curated
    /// fingerprint when it has one, else the documented fallback the importer
    /// derives without inputs, `path:<primary_path>` (`MEMORY_SCHEMA.md`
    /// §2.2's last rung, review item 15). A v2 value ships as `fingerprint`,
    /// never as `fingerprint_v3`.
    public static func projectFingerprint(for project: MemoryExportProjectRow) -> String? {
        if !project.identityFingerprint.isEmpty { return project.identityFingerprint }
        guard !project.primaryPath.isEmpty else { return nil }
        return "path:" + project.primaryPath
    }

    /// The id the section-04 record carries for a fingerprinted project:
    /// `prj_` plus 32 hex over the fingerprint — the shape the importer's
    /// `id_shape("prj_", …)` accepts, so a fresh target inserts under it and
    /// the memories' `p:` scope keys resolve against the id the importer
    /// assigned (migration §4's carried-id path).
    public static func carriedProjectID(fingerprint: String) -> String {
        "prj_" + MemoryExportDigest.sha256Hex(fingerprint).prefix(32)
    }

    public static func scope(
        for memory: MemoryExportMemoryRow,
        manifestUserID: String?,
        projects: [String: MemoryExportProjectRow] = [:]
    ) -> MemoryExportScope {
        if MemoryExportPartition.isPartitionPseudoProject(memory.projectID) {
            let user = memory.userID
                ?? MemoryExportPartition.pseudoProjectUserID(memory.projectID)
                ?? manifestUserID
            // `unscoped` with no manifest user has nowhere honest to go — v1
            // forbids `global` — so the key names the pseudo-project and the
            // importer holds with UNSCOPED_ROWS_NO_USER rather than inventing a
            // user here. A routed user key carries the `u:` tag the importer's
            // scope derivation asserts (`MEMORY_SCHEMA.md` §2.3); the unrouted
            // fallback keeps today's bare shape so the hold still triggers.
            return MemoryExportScope(
                kind: .user,
                key: user.map { "u:" + $0 } ?? memory.projectID,
                userID: user,
                projectFingerprint: nil,
                isPseudoProject: true
            )
        }
        // A real project: the fingerprint the importer matches plus the
        // carried `prj_` id the scope key names, so `derive_scope_key`'s
        // `p:{project_id}` recomputes to the carried value on a fresh target.
        if let project = projects[memory.projectID],
           let fingerprint = projectFingerprint(for: project)
        {
            let carried = carriedProjectID(fingerprint: fingerprint)
            return MemoryExportScope(
                kind: .project,
                key: "p:" + carried,
                userID: memory.userID ?? manifestUserID,
                projectFingerprint: fingerprint,
                isPseudoProject: false
            )
        }
        return MemoryExportScope(
            kind: .project,
            key: "p:" + memory.projectID,
            userID: memory.userID ?? manifestUserID,
            projectFingerprint: nil,
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

        // MIF minor 2 [D-0021 ruling 4]. The producer's ORIGINAL id, carried
        // whenever `memory_id` had to be canonicalised — which is every app-lane
        // row, because `ControlPlaneStore.addMemoryAuthorityRecord` defaults its
        // id to a UUID that `^mem_[0-9a-f]{32}$` rejects. It makes `id-map.csv`
        // a convenience rather than the only record of the mapping, and it is a
        // producer-supplied opaque string, never an authority-computed one, so
        // INV-15 is untouched. Absent when the oracle id was already canonical.
        if canonicalID != memory.id {
            fields["source_memory_id"] = .string(memory.id)
        }

        // M-30: the oracle's dedup merge sets `valid_to` unconditionally on the
        // loser; the target sets it only when the edge's scope matches. There is
        // no authored edge to compare against here, so the carried value travels
        // with its origin named and the importer decides.
        if let validTo = memory.validTo, let ms = MemoryExportTimestamp.parse(validTo) {
            fields["valid_to_ms"] = .int(Int((ms.timeIntervalSince1970 * 1000).rounded()))
            fields["valid_to_origin"] = .string(MIFValidToOrigin.oracleUnconditionalDedup.rawValue)
        } else {
            fields["valid_to_ms"] = .null
            fields["valid_to_origin"] = .string(MIFValidToOrigin.none.rawValue)
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

    /// `record_body.body` — **base64url, unpadded, of the canonical body
    /// bytes** [D-0038 ruling 2, D-0039 ruling 4].
    ///
    /// The section AEAD seals the record, so the encoding is not privacy: it is
    /// what makes the member well defined for a body that is not valid text in
    /// the reader's sense, and it is what the importer decodes. Writing the
    /// plaintext was M-6 — the exporter and the Rust `mifgen` independently
    /// read the bare `{"type": "string"}` as plaintext while the importer read
    /// it as base64url, so every body arrived as garbage or not at all.
    ///
    /// `byte_len` stays the length of the CANONICAL bytes, not of this
    /// rendering: it describes the body, not its envelope.
    static func encodedBody(_ canonical: String) -> MIFJSON {
        .string(MemoryExportBase64URL.encode(MemoryExportCrypto.canonicalBodyBytes(canonical)))
    }

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
            "body": encodedBody(carried),
            "summary": .null,
            "recovered_from": .string(body.recoveredFrom.rawValue)
        ])
    }

    /// §3.3(a): a carried orphan BECOMES a synthetic row. It cannot exist in
    /// the target any other way — there is no authority row behind it — and the
    /// three records say exactly that: `origin_kind: import`,
    /// `dedup_partition: import`, and one body-only provenance marker.
    public static func orphanBodyMemoryRecord(
        snapshot: MemoryExportBodySnapshotRow,
        gate: MemoryExportGateOutcome,
        context: MemoryExportRecordContext,
        userID: String?
    ) -> (memory: MIFJSON, body: MIFJSON, provenance: MIFJSON, joinKey: String) {
        let canonicalID = MemoryExportIdentity.canonicalMemoryID(snapshot.memoryID, storeID: context.storeID)
        let createdMS = MemoryExportTimestamp.milliseconds(snapshot.createdAt)
        let updatedMS = MemoryExportTimestamp.milliseconds(snapshot.updatedAt, fallback: createdMS)
        let joinKey = MemoryExportCrypto.bodyJoinKey(bundleKey: context.bundleKey, body: gate.body)
        let normDigest = MemoryExportCrypto.bodyNormDigest(bundleKey: context.bundleKey, body: gate.body)
        let scopeKey = userID ?? "migration:unscoped"

        let memory = MIFJSON.object([
            "profile": .string(MIFProfile.migration.rawValue),
            "memory_id": .string(canonicalID),
            "schema_version": .int(context.schemaVersion),
            "store_id": .string(context.storeID),
            "memory_type": .string(MIFMemoryType.observation.rawValue),
            "memory_type_source": .string("unknown_defaulted"),
            "scope_kind": .string(MIFScopeKind.user.rawValue),
            "scope_key": .string(scopeKey),
            "project_fingerprint": .null,
            "user_id": .string(userID),
            "session_id": .null,
            "agent_id": .null,
            "device_id": .null,
            "org_id": .null,
            "origin_kind": .string(MIFOriginKind.importOrigin.rawValue),
            "origin_actor_id": .null,
            "origin_client_id": .null,
            "origin_ingest": .string("migration"),
            // No authority row means no recorded confidence. Half is the only
            // honest placeholder, and `import` origin says where it came from.
            "confidence": .double(0.5),
            "confidence_bits": .string(String(format: "%016llx", Double(0.5).bitPattern)),
            "classification": .string(MIFClassification.internalClass.rawValue),
            "sensitivity_labels": .strings(gate.sensitivityLabels),
            "redaction_state": .string(gate.redactionState.rawValue),
            "review_status": .string(MIFReviewStatus.quarantined.rawValue),
            "review_policy_id": .null,
            "dedup_partition": .string(MIFDedupPartition.importPartition.rawValue),
            "body_join_key": .string(joinKey),
            "body_norm_digest": .string(normDigest),
            "byte_len": .int(gate.body.utf8.count),
            "tags": .array([]),
            "valid_from_ms": .int(createdMS),
            "valid_to_ms": .null,
            "valid_to_origin": .string(MIFValidToOrigin.none.rawValue),
            "deletion_state": .string(MIFDeletionState.live.rawValue),
            "forgotten_at_ms": .null,
            "body_purged_at_ms": .null,
            "lamport": .int(0),
            "wall_ms": .int(updatedMS),
            "origin_device_id": .string(context.originDeviceID),
            "created_at_ms": .int(createdMS),
            "updated_at_ms": .int(updatedMS),
            "original_review_status": .null,
            "import_origin_detail": .string(MIFImportOriginDetail.unknown.rawValue),
            "body_ref_convention": .string(MIFBodyRefConvention.snapshotSlug.rawValue),
            "body_integrity": .string(
                MemoryExportDigest.sha256Hex(gate.body) == snapshot.bodyHash
                    ? MIFBodyIntegrity.verified.rawValue
                    : MIFBodyIntegrity.mismatch.rawValue
            ),
            "source_kind_inferred": .string(snapshot.sourceKind),
            "verdict_audit_seq": .null,
            "verdict_event_id": .null
        ])

        let body = MIFJSON.object([
            "profile": .string(MIFProfile.migration.rawValue),
            "body_join_key": .string(joinKey),
            "body_norm_digest": .string(normDigest),
            "byte_len": .int(gate.body.utf8.count),
            "body": encodedBody(gate.body),
            "summary": .null,
            "recovered_from": .string(MIFRecoveredFrom.memoryBodySnapshots.rawValue)
        ])

        let provenance = MIFJSON.object([
            "profile": .string(MIFProfile.migration.rawValue),
            "memory_id": .string(canonicalID),
            "citation_id": .string(MemoryExportIdentity.citationID(
                storeID: context.storeID,
                provenanceID: "body_only:\(snapshot.memoryID)"
            )),
            "schema_version": .int(context.schemaVersion),
            "source_type": .string(MIFSourceType.artifact.rawValue),
            "citation_state": .string(MIFCitationState.unknown.rawValue),
            "thread_id": .null,
            "message_id": .null,
            "role": .null,
            "occurrence": .int(0),
            "repo_origin_normalized": .null,
            "file_path": .null,
            "commit_sha": .null,
            "pr_number": .null,
            "issue_key": .null,
            // The marker §3.3(a) asks for: this row exists because a body did,
            // and nothing else.
            "artifact_digest": .string("migration:body_only"),
            "release_id": .null,
            "deployment_id": .null,
            "source_uri": .null,
            "source_content_hash": .null,
            "origin_kind": .string(MIFOriginKind.importOrigin.rawValue),
            "origin_actor_id": .null,
            "origin_client_id": .null,
            "authored_at_ms": .null,
            "created_at_ms": .int(createdMS)
        ])
        return (memory, body, provenance, joinKey)
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
        context: MemoryExportRecordContext,
        signingKey: Curve25519.Signing.PrivateKey? = nil,
        signingKeyID: String? = nil
    ) -> MIFJSON? {
        guard classification.isProvenHumanVerdict, let seq = classification.verdictAuditSeq else { return nil }
        let decidedMS = MemoryExportTimestamp.milliseconds(classification.verdictTimestamp)
        let unsigned: MIFJSON = .object([
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
        // I-76: a proven human verdict leaves signed when the device key is
        // present (the bundle path), unsigned when it is not (unit tests that
        // build records without a key). The preimage excludes the two
        // signature members, so signing the unsigned record is signing the
        // record the importer verifies — never the signature itself.
        guard let signingKey, let signingKeyID,
              case .object(var members) = unsigned,
              let signature = try? MemoryExportCrypto.signReviewEvent(
                unsigned, signingKey: signingKey
              ) else {
            return unsigned
        }
        members["event_signature"] = .string(signature)
        members["signing_key_id"] = .string(signingKeyID)
        return .object(members)
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
            // MIF minor 2 [D-0021 ruling 4] reversed §15 item 7: `record_memory`
            // carried both `scope_kind` and `scope_key` while `record_tombstone`
            // carried only the key, and this exporter is what proved that
            // asymmetry unworkable. It stays an INTERCHANGE field — the
            // importer still derives its routing from `scope_key`'s own leading
            // tag and never writes a tombstone column that does not exist, so a
            // `scope_kind` disagreeing with the tag is a finding, not a write.
            "scope_kind": .string(scope.kind.rawValue),
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
            "reason": .string(tombstoneReason(row.reason, default: .sourceDeleted).rawValue),
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

    /// The oracle's `reason` columns are free text written by three call sites
    /// (`user_delete`, `review_status_rejected`, `source_deleted`, …); MIF's is
    /// a closed six. Map what maps and fall back to the caller's default, so a
    /// `legal` or `retention` reason the oracle already records is not flattened
    /// into `user_forget` on the way out.
    public static func tombstoneReason(_ raw: String, default fallback: MIFTombstoneReason) -> MIFTombstoneReason {
        if let exact = MIFTombstoneReason(rawValue: raw) { return exact }
        return switch raw {
        case "user_delete", "user_forget": .userForget
        case let value where value.hasPrefix("review_status_"): .userForget
        case "secret", "secret_leak": .secretLeak
        default: fallback
        }
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
        // D-0033 ruling 1: the importer matches on the computed fingerprint
        // and inserts under the carried `prj_` id when it is well shaped and
        // free — so the record carries both, computed by the same helpers the
        // memories' scope keys use. A project with no fingerprint carries
        // neither, exactly today's shape.
        let fingerprint = projectFingerprint(for: project)
        let carriedID = fingerprint.map { carriedProjectID(fingerprint: $0) }
        return .object([
            "profile": .string(MIFProfile.migration.rawValue),
            "project_id": .string(carriedID),
            "fingerprint": .string(fingerprint),
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
                "source_label": .string(MIFAliasSourceLabel.migrationBurnBar.rawValue)
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
