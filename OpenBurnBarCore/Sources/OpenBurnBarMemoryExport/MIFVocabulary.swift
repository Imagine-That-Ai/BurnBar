// SPDX-License-Identifier: AGPL-3.0-only
//
// MIFVocabulary — every closed set `contracts/mif-v1.schema.json` defines,
// mirrored as Swift enums.
//
// The contract is the authority; these are a typed mirror of it so a wrong
// string is a compile error here rather than a schema failure three sections
// later. `MIFSchemaValidatorTests` validates the emitted JSON against the
// embedded copy of the contract, which is what keeps the mirror honest.

import Foundation

/// The format version this build writes, in ONE place.
///
/// `manifest.mif_version` / `manifest.mif_minor` and `report.bundle.mif_version`
/// / `report.bundle.mif_minor` are the same two numbers about the same bundle,
/// and nothing in the contract cross-checks them. Interop run 1 found the
/// manifest saying minor 2 and the report beside it saying 1 (M-9), because
/// each was typed as a literal where it was needed. D-0039 ruling 5 requires
/// them equal; one constant is how that stays true.
///
/// Minor 2 is D-0021 ruling 4's: `memory_quarantine_bodies` as a
/// `recovered_from` value, and `record_project`'s identity pair. Both additive,
/// so `min_importer_mif_version` stays 1.
public enum MIFFormatVersion {
    public static let major = 1
    public static let minor = 2
}

public enum MIFProfile: String, Sendable, CaseIterable {
    case sync
    case migration
}

public enum MIFReviewStatus: String, Sendable, CaseIterable {
    case quarantined
    case approved
    case rejected
    case forgotten
}

public enum MIFOriginKind: String, Sendable, CaseIterable {
    case human
    case agent
    case extractor
    /// Everything the migration cannot prove a human decided.
    case importOrigin = "import"
    case enrichment
}

public enum MIFActorKind: String, Sendable, CaseIterable {
    case human
    case agent
    case extractor
    case system
    case importActor = "import"
}

public enum MIFVerdictKind: String, Sendable, CaseIterable {
    case humanVerdict = "human_verdict"
    case automatic
}

public enum MIFDeletionState: String, Sendable, CaseIterable {
    case live
    case tombstoned
    case bodyPurged = "body_purged"
}

public enum MIFMemoryType: String, Sendable, CaseIterable {
    case preference
    case decision
    case projectFact = "project_fact"
    case procedure
    case finding
    case episode
    case summary
    case correction
    case observation
}

public enum MIFDedupPartition: String, Sendable, CaseIterable {
    case chat
    case usage
    case code
    case enrichment
    case system
    case importPartition = "import"
}

public enum MIFClassification: String, Sendable, CaseIterable {
    case publicClass = "public"
    case internalClass = "internal"
    case confidential
    /// Excluded at export (§2). Present so the exclusion is expressible.
    case restricted
}

public enum MIFRedactionState: String, Sendable, CaseIterable {
    case clean
    case redacted
    case heldForReview = "held_for_review"
}

public enum MIFCitationState: String, Sendable, CaseIterable {
    case live
    case unavailable
    case pruned
    case revoked
    case unknown
}

public enum MIFScopeKind: String, Sendable, CaseIterable {
    case global
    case user
    case org
    case project
    case repo
    case branch
    case session
    case agent
    case harness
    case device
}

public enum MIFTombstoneKind: String, Sendable, CaseIterable {
    case fact
    case source
}

public enum MIFTombstoneReason: String, Sendable, CaseIterable {
    case userForget = "user_forget"
    case sourceDeleted = "source_deleted"
    case retention
    case policy
    case secretLeak = "secret_leak"
    case legal
}

public enum MIFTombstoneOriginLabel: String, Sendable, CaseIterable {
    case daemonForgotten = "daemon_forgotten"
    case cloudReceipt = "cloud_receipt"
    case local
    case sync
}

public enum MIFSynthesisReason: String, Sendable, CaseIterable {
    case appDeleted = "app_deleted"
    case forgottenStatus = "forgotten_status"
    case cloudReceipt = "cloud_receipt"
    case sourceTombstone = "source_tombstone"
    case native
}

public enum MIFAliasKind: String, Sendable, CaseIterable {
    case burnbarV2 = "burnbar_v2"
    case burnbarLegacy32 = "burnbar_legacy32"
    case burnbarLegacy16 = "burnbar_legacy16"
    case podexFolder = "podex_folder"
    case podexWorkspace = "podex_workspace"
    case repoSlug = "repo_slug"
}

public enum MIFAliasSourceLabel: String, Sendable, CaseIterable {
    case observed
    case migrationBurnBar = "migration:burnbar"
    case migrationPodex = "migration:podex"
    case importBundle = "import:bundle"
}

/// Where a carried `valid_to_ms` came from. M-30: the oracle's dedup merge sets
/// it unconditionally on the loser, while the target sets it only when the
/// edge's scope matches — so the origin travels and the importer decides.
public enum MIFValidToOrigin: String, Sendable, CaseIterable {
    case scoped
    case oracleUnconditionalDedup = "oracle_unconditional_dedup"
    case none
}

public enum MIFSourceType: String, Sendable, CaseIterable {
    case conversation
    case agentMessage = "agent_message"
    case userMessage = "user_message"
    case codeFile = "code_file"
    case commit
    case pullRequest = "pull_request"
    case issue
    case artifact
    case release
    case deploymentObservation = "deployment_observation"
    case deliveryRef = "delivery_ref"
    case externalDoc = "external_doc"
}

public enum MIFBodyIntegrity: String, Sendable, CaseIterable {
    case verified
    case mismatch
    case divergent
    case recoveredLegacyPlaintext = "recovered_legacy_plaintext"
    case absent
}

public enum MIFBodyRefConvention: String, Sendable, CaseIterable {
    /// Convention A — the app lane, `memory_body_snapshots:<slug>`.
    case snapshotSlug = "snapshot_slug"
    /// Convention B — the daemon/MCP lane, a bare `sha256(body)`.
    case sha256
    /// A hostile `memory_body_snapshots:<64 hex>` value. Detection is A-prefix
    /// first, so it resolves in the app store and cannot be steered into the
    /// daemon one; the distinct tag exists so the door test can see it.
    case adversarialSlugHex = "adversarial_slug_hex"
    case unknown
    case absent
}

public enum MIFBodyVerdictBinding: String, Sendable, CaseIterable {
    case bound
    case bodyMutatedAfterVerdict = "body_mutated_after_verdict"
    case unprovable
}

public enum MIFRecoveredFrom: String, Sendable, CaseIterable {
    case memoryBodySnapshots = "memory_body_snapshots"
    case projectMemorySnapshots = "project_memory_snapshots"
    case bodyRedactedLegacyPlaintext = "body_redacted_legacy_plaintext"
    /// MIF minor 2 [D-0021 ruling 4]. The daemon lane's quarantine table, which
    /// holds every quarantined and rejected body. Before minor 2 there was no
    /// member for it, so those bodies were stamped `project_memory_snapshots` —
    /// true about the lane, false about the table they were recovered from.
    case memoryQuarantineBodies = "memory_quarantine_bodies"
}

public enum MIFSeverity: String, Sendable, CaseIterable {
    case info
    case warn
    case error
}

/// D-0009's ladder, in order. A snapshot whose primitive is not recorded is not
/// a snapshot.
public enum MIFSnapshotMode: String, Sendable, CaseIterable {
    case vacuum
    case sqlcipherExport = "sqlcipher_export"
    case backupAPI = "backup_api"
    case readTxn = "read_txn"
}

public enum MIFStoreKind: String, Sendable, CaseIterable {
    case authority
    case authorityMASContainer = "authority_mas_container"
    case legacyPlaintext = "legacy_plaintext"
    case legacyPlaintextSecondary = "legacy_plaintext_secondary"
    case cloud
    case podexNative = "podex_native"
}

/// §3.1's report-only break-out. Every row lands in exactly one of these.
public enum MIFImportOriginDetail: String, Sendable, CaseIterable {
    case humanVerdict = "human_verdict"
    case asStored = "as_stored"
    case rejectedRetainedUnproven = "rejected_retained_unproven"
    case daemonDefault = "daemon_default"
    case mcpDefault = "mcp_default"
    case v51Backfill = "v51_backfill"
    case cloud
    case absentColumn = "absent_column"
    case unknownValue = "unknown_value"
    case verdictOnBrokenChain = "verdict_on_broken_chain"
    case approvedBodyMutatedAfterVerdict = "approved_body_mutated_after_verdict"
    case partitionPseudoProject = "partition_pseudo_project"
    case unknown
}

public enum MIFNotExportedReason: String, Sendable, CaseIterable {
    case forgottenToTombstone = "forgotten_to_tombstone"
    case restrictedClassification = "restricted_classification"
    case sourceUnreadable = "source_unreadable"
    case cloudAlreadyLocal = "cloud_already_local"
    case outOfWindow = "out_of_window"
    case orphanBodyNotCarried = "orphan_body_not_carried"
    case orphanProvenanceNoMemory = "orphan_provenance_no_memory"
    case danglingSupersession = "dangling_supersession"
    case unmigratableSource = "unmigratable_source"
    case extractionJobOutbox = "extraction_job_outbox"
    case embeddingVectorDisposable = "embedding_vector_disposable"
    case pathAliasNotTransported = "path_alias_not_transported"
    case derivedEdgeRecomputedLocally = "derived_edge_recomputed_locally"
}

public enum MIFRejectedReason: String, Sendable, CaseIterable {
    case bodyUnreconstructible = "body_unreconstructible"
    case bodyNormDigestMismatch = "body_norm_digest_mismatch"
    case recordTooLarge = "record_too_large"
    case schemaVersionTooNew = "schema_version_too_new"
    case malformedRecord = "malformed_record"
    case humanOriginWithoutAuditEvidence = "human_origin_without_audit_evidence"
    case verdictOnBrokenChainClaimedHuman = "verdict_on_broken_chain_claimed_human"
    case unknownRequiredSection = "unknown_required_section"
}

public enum MIFHoldReason: String, Sendable, CaseIterable {
    case reconciliationMismatch = "RECONCILIATION_MISMATCH"
    /// D-0039 ruling 6: a manifest — or `hashtree.json` — that does not parse
    /// or does not validate is a HELD REPORT naming the member, never a serde
    /// error with no report, which is where interop run 1 stopped. The exporter
    /// never emits it (it writes the manifest); it is mirrored here because
    /// this enum is this build's copy of the contract's closed vocabulary, and
    /// `MIFContractPinTests` compares the two.
    case manifestInvalid = "MANIFEST_INVALID"
    case rollupDigestMismatch = "ROLLUP_DIGEST_MISMATCH"
    case unmigratableSourcePresent = "UNMIGRATABLE_SOURCE_PRESENT"
    case recipientKeyUnavailable = "RECIPIENT_KEY_UNAVAILABLE"
    case sourceIntegrityFailed = "SOURCE_INTEGRITY_FAILED"
    case signatureUnverified = "SIGNATURE_UNVERIFIED"
    case hashtreeMismatch = "HASHTREE_MISMATCH"
    case exporterKeyUnpinned = "EXPORTER_KEY_UNPINNED"
    case targetNotKeyed = "TARGET_NOT_KEYED"
    case gateUnavailable = "GATE_UNAVAILABLE"
    case mifVersionUnsupported = "MIF_VERSION_UNSUPPORTED"
    case mifProfileUnsupported = "MIF_PROFILE_UNSUPPORTED"
    case mifRequiredSectionMissing = "MIF_REQUIRED_SECTION_MISSING"
    case mifRehearsalBundleRefused = "MIF_REHEARSAL_BUNDLE_REFUSED"
    case unscopedRowsNoUser = "UNSCOPED_ROWS_NO_USER"
    case p5SourceNotQuiesced = "P5_SOURCE_NOT_QUIESCED"
    case p5SourceBuildTooOld = "P5_SOURCE_BUILD_TOO_OLD"
    case migrationWindowExpired = "MIGRATION_WINDOW_EXPIRED"
    /// D-0018's admission check. Only the IMPORTER produces it — the exporter
    /// carries the oracle's timestamps unreformatted and judges none of them —
    /// but the mirror is of the whole closed set or it is not a mirror.
    case verdictWallMSInFuture = "VERDICT_WALL_MS_IN_FUTURE"
}

public enum MIFExportError: String, Sendable, CaseIterable, Error {
    case keyUnavailable = "EXPORT_KEY_UNAVAILABLE"
    case sourceNotKeyed = "EXPORT_SOURCE_NOT_KEYED"
    case sourceRootOverridden = "EXPORT_SOURCE_ROOT_OVERRIDDEN"
    case recipientUnverified = "EXPORT_RECIPIENT_UNVERIFIED"
    case diskSpace = "EXPORT_DISK_SPACE"
    case snapshotUnavailable = "EXPORT_SNAPSHOT_UNAVAILABLE"
    /// §3.3 M-04: a `memory.delete` seq inside the window with no emitted
    /// tombstone. An exporter obligation, not a warning.
    case deleteWithoutTombstone = "EXPORT_DELETE_WITHOUT_TOMBSTONE"
    /// D-0021 ruling 1. HPKE is the only admitted wrap; below its floor the
    /// export refuses rather than falling back to a construction of its own.
    /// Added to the contract's closed set by Q-24.
    case hpkeUnavailable = "EXPORT_HPKE_UNAVAILABLE"
    /// D-0025 ruling 3. A sealed bundle whose key exists nowhere is never
    /// written. Added to the contract's closed set by D-0025.
    case recipientRequired = "EXPORT_RECIPIENT_REQUIRED"
    /// The store carries neither a local `devices` row nor an audit chain, so it
    /// has nothing that identifies it from the inside. Every canonical id is
    /// seeded from that value and the exporter will not invent one.
    ///
    /// The one code here the contract does NOT carry — it is BurnBar's own
    /// precondition, not a MIF concept, and like the two above it fires before
    /// any report is written, so it never reaches
    /// `reconciliation_report.export_error`. It is in this enum rather than a
    /// bare string literal so both lanes that refuse can name the same value
    /// (review R6).
    case storeIdentityAbsent = "EXPORT_STORE_IDENTITY_ABSENT"
}

public enum MIFFindingCode: String, Sendable, CaseIterable {
    case bodyHashMismatch = "body_hash_mismatch"
    case bodyDivergentStores = "body_divergent_stores"
    case bodyRefUnknownConvention = "body_ref_unknown_convention"
    case bodyUnreconstructible = "body_unreconstructible"
    case bodyRecoveredLegacyPlaintext = "body_recovered_legacy_plaintext"
    case orphanBody = "orphan_body"
    case orphanProvenance = "orphan_provenance"
    case danglingSupersession = "dangling_supersession"
    case aliasConflict = "alias_conflict"
    case fingerprintDowngraded = "fingerprint_downgraded"
    case reviewStatusUnknownValue = "review_status_unknown_value"
    case verdictOnBrokenChain = "verdict_on_broken_chain"
    case approvedBodyMutatedAfterVerdict = "approved_body_mutated_after_verdict"
    case chainBroken = "chain_broken"
    case chainFork = "chain_fork"
    case seqDivergence = "seq_divergence"
    case partitionPseudoProject = "partition_pseudo_project"
    case tombstoneContentKeyUnknown = "tombstone_content_key_unknown"
    case secretGateHeld = "secret_gate_held"
    case recordTooLarge = "record_too_large"
    case sourceUnreadable = "source_unreadable"
    case spoolNotCarried = "spool_not_carried"
    case receiptUnknownPeer = "receipt_unknown_peer"
    case validToDroppedScopeMismatch = "valid_to_dropped_scope_mismatch"
    case auditLabelStripped = "audit_label_stripped"
    case unknownFieldsIgnored = "unknown_fields_ignored"
    case concurrentWrites = "concurrent_writes"
    case snapshotModeDegraded = "snapshot_mode_degraded"
    case masContainerStorePresent = "mas_container_store_present"
    case contentConflict = "content_conflict"
    case verdictOrphanedDiscarded = "verdict_orphaned_discarded"
    case sourceTombstoneSuppressorArmed = "source_tombstone_suppressor_armed"
    case deleteWithoutTombstoneSynthesized = "delete_without_tombstone_synthesized"
    case forgedHumanVerdictRefused = "forged_human_verdict_refused"
    case unmigratableSourcePresent = "unmigratable_source_present"
    case stagedVerdictBundleScoped = "staged_verdict_bundle_scoped"
}

/// Section names and their order. **The order is the merge order**: tombstones,
/// receipts and verdicts land before any memory row, so a crash leaves deletes
/// applied without their rows — the safe direction.
public enum MIFSection: String, Sendable, CaseIterable {
    case tombstones = "00-tombstones"
    case tombstoneReceipts = "01-tombstone_receipts"
    case reviewEvents = "02-review_events"
    case supersessions = "03-supersessions"
    case projects = "04-projects"
    case memories = "05-memories"
    case bodies = "06-bodies"
    case provenance = "07-provenance"
    case embeddings = "08-embeddings"
    case auditEvidence = "09-audit_evidence"
    /// Migration only, never applied as data.
    case findings = "10-findings"

    public var rank: Int {
        // reason: self is always a member of allCases
        // swiftlint:disable:next force_unwrapping
        MIFSection.allCases.firstIndex(of: self)!
    }

    /// The name the **crypto** uses: `tombstones`, not `00-tombstones`.
    ///
    /// D-0025 ruling 1 pins this, because D-0021 ruling 2 did not and the two
    /// readings fail as a silent decryption error at import rather than as a
    /// mismatch anybody can see. The `NN-` prefix belongs to the directory on
    /// disk (`rawValue`, which is also the schema's `section_header.name`) and
    /// to nothing cryptographic: it keys neither the segment key, nor the
    /// nonce, nor the chunk AAD.
    public var bareName: String {
        guard let dash = rawValue.firstIndex(of: "-") else { return rawValue }
        return String(rawValue[rawValue.index(after: dash)...])
    }

    /// `$defs.section_record_map` — the pointer a section's NDJSON lines
    /// validate against.
    public var recordTypePointer: String {
        switch self {
        case .tombstones: "#/$defs/record_tombstone"
        case .tombstoneReceipts: "#/$defs/record_tombstone_receipt"
        case .reviewEvents: "#/$defs/record_review_event"
        case .supersessions: "#/$defs/record_supersession"
        case .projects: "#/$defs/record_project"
        case .memories: "#/$defs/record_memory"
        case .bodies: "#/$defs/record_body"
        case .provenance: "#/$defs/record_provenance"
        case .embeddings: "#/$defs/record_embedding_count"
        case .auditEvidence: "#/$defs/record_audit_evidence"
        case .findings: "#/$defs/record_finding"
        }
    }

    /// Sections 00, 02 and 05 are always required; 09 becomes required the
    /// moment any record claims `origin_kind: "human"` (M-20), which the writer
    /// decides per bundle.
    public var isAlwaysRequired: Bool {
        self == .tombstones || self == .reviewEvents || self == .memories
    }

    /// `10 findings` is read for the report and never applied.
    public var isMergeable: Bool { self != .findings }

    /// This section's roll-up tuple, transcribed exactly from D-0031 ruling 2
    /// (which §2's record table repeats as the table's third column). The
    /// importer recomputes the digest from these member names post-apply and
    /// **holds** on `ROLLUP_DIGEST_MISMATCH`, so a tuple that names the wrong
    /// field is not a label error: it is a bundle nobody can import.
    /// `manifest.rollups[].tuple` carries the names; the digest is over the
    /// tuples sorted member by member, as the JCS encoding of the array of
    /// arrays.
    ///
    /// **All eleven are computable** [D-0039 ruling 6; Q-51's reconciliation of
    /// the five the 2026-09-08 amendment left marked]. Every member below is
    /// defined by `contracts/mif-v1.schema.json` for that section's record
    /// type, which is the amendment's rule — the schema is the source, and a
    /// tuple may not name a member it does not define. The five that moved:
    ///
    ///   * 00 drops `subject_content_key`, which §2 refuses by name;
    ///   * 01 keys on `(tombstone_id, peer_label)` rather than a `receipt_id`
    ///     the record type has never had — one tombstone has one receipt PER
    ///     PEER;
    ///   * 06 takes `body_norm_digest` where the tuple said `seal_generation`,
    ///     a store column that does not travel: all three members are
    ///     `required` on `record_body`, so this tuple is never null anywhere;
    ///   * 09 takes `peer_seq`, the chain coordinate the section is keyed on,
    ///     and not `payload_seq`, which is the producer's sequence inside the
    ///     carried payload;
    ///   * 10 is a per-code aggregate with no row id and no single memory, so
    ///     it is `(code, severity, count, detail)` — the one tuple with FOUR
    ///     members, which is legal because arity is per section.
    ///
    /// Until this, eight of eleven named members no record carried, so the
    /// exporter could compute no digest for them and `ROLLUP_DIGEST_MISMATCH`
    /// was unreachable for eight sections while every count balanced (M-12).
    public var rollupTuple: [String] {
        switch self {
        case .tombstones: ["tombstone_id", "subject_memory_id", "wall_ms"]
        case .tombstoneReceipts: ["tombstone_id", "peer_label", "acked_at_ms"]
        case .reviewEvents: ["event_id", "memory_id", "to_status"]
        case .supersessions: ["supersession_id", "superseded_id", "superseded_by_id"]
        // Q-51 (iii): the third leg is the LITERAL empty string, a value and
        // not a member lookup.
        case .projects: ["project_id", "fingerprint", ""]
        case .memories: ["memory_id", "body_join_key", "body_norm_digest"]
        case .bodies: ["body_join_key", "body_norm_digest", "byte_len"]
        case .provenance: ["citation_id", "memory_id", "source_content_hash"]
        case .embeddings: ["lane_label", "model_id", "row_count"]
        case .auditEvidence: ["chain_epoch", "peer_seq", "hash"]
        case .findings: ["code", "severity", "count", "detail"]
        }
    }

    /// The reconciliation lanes that may write into this section — the inverse
    /// of `MIFReconciliationLane.sections`, derived rather than restated so the
    /// two cannot disagree.
    ///
    /// D-0039 ruling 5: **every** section has at least one lane, and §10's
    /// closed sum therefore covers all eleven. A section with no lane is a set
    /// of carried rows no sum accounts for, which is what interop run 1 found
    /// for 00, 02 and 09 (M-8).
    public var lanes: [MIFReconciliationLane] {
        MIFReconciliationLane.allCases.filter { $0.sections.contains(self) }
    }

    /// Byte-ascending sort key, per §2 "within a section, records sort
    /// byte-ascending on the declared sort key".
    public var sortKeys: [String] {
        switch self {
        case .tombstones: ["tombstone_id"]
        case .tombstoneReceipts: ["tombstone_id", "peer_label"]
        case .reviewEvents: ["event_id"]
        case .supersessions: ["supersession_id"]
        case .projects: ["display_name"]
        case .memories: ["memory_id"]
        case .bodies: ["body_join_key"]
        case .provenance: ["memory_id", "citation_id"]
        case .embeddings: ["lane_label", "model_id"]
        case .auditEvidence: ["peer_seq"]
        case .findings: ["code"]
        }
    }
}

/// The logical tables §10 reconciles, as a closed set.
///
/// A "lane" is one closed sum in `report.json.tables[]`: source rows in, every
/// row in exactly one bucket, and — for the rows that travel — a section they
/// land in. The vocabulary is closed for the same reason the reason codes are:
/// interop run 1 found three sections (00 tombstones, 02 review events, 09
/// audit evidence) carrying rows that belonged to no lane at all, so no sum
/// covered them and `report.json` could balance while the bundle carried rows
/// nobody had accounted for (M-8).
///
/// Several lanes are not store tables, and are named so that this is legible:
/// `agent_memories.forgotten` is the forget path, `memory_audit.delete` and
/// `memory_audit.review` are two obligations of one audit table, and
/// `report.findings` is section 10, which §2 says is not data — it gets a lane
/// anyway, because D-0039 ruling 5's sum is over all eleven sections and a
/// section excused from the sum is exactly the hole this closes.
public enum MIFReconciliationLane: String, Sendable, CaseIterable {
    case agentMemories = "agent_memories"
    /// Row 12 of §3.1: a `forgotten` memory leaves as a tombstone and never as
    /// a memory. The tombstone is a section-00 row, so the path needs a lane of
    /// its own — `agent_memories` accounts for the same source row under
    /// `not_exported.forgotten_to_tombstone`, which says what did NOT travel.
    case agentMemoriesForgotten = "agent_memories.forgotten"
    case agentMemoriesSupersededBy = "agent_memories.superseded_by"
    case memoryBodySnapshots = "memory_body_snapshots"
    case memoryProvenance = "memory_provenance"
    case memoryFactTombstones = "memory_fact_tombstones"
    /// A tombstone that has been replicated carries a receipt into section 01.
    case memoryFactTombstoneReceipts = "memory_fact_tombstones.replicated_at"
    case memorySourceTombstones = "memory_source_tombstones"
    case memoryAuditDelete = "memory_audit.delete"
    /// The `memory.approve` / `memory.reject` rows a review event is minted
    /// from (D-BB-E-9: proven verdicts only).
    case memoryAuditReview = "memory_audit.review"
    /// The audit rows themselves, as section 09's evidence.
    case memoryAudit = "memory_audit"
    case pcmProjects = "pcm_projects"
    case pcmProjectAliases = "pcm_project_aliases"
    case embeddingVersions = "embedding_versions"
    case reportFindings = "report.findings"

    /// The sections this lane's carried rows land in. Empty means the lane
    /// transports nothing — `pcm_project_aliases` is real source rows that §2
    /// does not carry, and saying so with an empty list is the point.
    public var sections: [MIFSection] {
        switch self {
        case .agentMemories: [.memories, .bodies]
        case .agentMemoriesForgotten: [.tombstones]
        case .agentMemoriesSupersededBy: [.supersessions]
        // A carried orphan becomes a synthetic memory, its body and one
        // body-only provenance marker — three sections from one lane.
        case .memoryBodySnapshots: [.memories, .bodies, .provenance]
        case .memoryProvenance: [.provenance]
        case .memoryFactTombstones: [.tombstones]
        case .memoryFactTombstoneReceipts: [.tombstoneReceipts]
        case .memorySourceTombstones: [.tombstones]
        case .memoryAuditDelete: [.tombstones]
        case .memoryAuditReview: [.reviewEvents]
        case .memoryAudit: [.auditEvidence]
        case .pcmProjects: [.projects]
        case .pcmProjectAliases: []
        case .embeddingVersions: [.embeddings]
        case .reportFindings: [.findings]
        }
    }
}
