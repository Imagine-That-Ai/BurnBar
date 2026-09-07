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
}

/// Refusals D-0021 and D-0025 name that the v1.2 contract's `export_error`
/// closed set does **not** yet carry.
///
/// They are deliberately a separate type rather than two more `MIFExportError`
/// cases: `reconciliation_report.export_error` validates against that closed
/// set, so a code the contract has never heard of would turn a refusal into an
/// unvalidatable report. Both fire before any bundle or report is written, so
/// nothing is lost by keeping them out of the wire vocabulary — and when the
/// contract grows them, the two enums merge and this comment goes.
public enum MIFExportRefusal: String, Sendable, CaseIterable, Error {
    /// D-0021 ruling 1. HPKE is the only admitted wrap; below its floor the
    /// export refuses rather than falling back to a construction of its own.
    case hpkeUnavailable = "EXPORT_HPKE_UNAVAILABLE"
    /// D-0025 ruling 3. A sealed bundle whose key exists nowhere is never
    /// written.
    case recipientRequired = "EXPORT_RECIPIENT_REQUIRED"
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
        // swiftlint:disable:next force_unwrapping reason: self is always a member of allCases
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

    /// The `(id, digest, digest)` triple this section's roll-up is taken over,
    /// as `manifest.rollups[].tuple` declares it. The importer recomputes the
    /// digest from these three field names post-apply and **holds** on a
    /// mismatch, so a tuple that names the wrong field is not a label error: it
    /// is a bundle nobody can import.
    ///
    /// 05 and 06 differ in the third element. 05 binds a memory to the sources
    /// it cites; 06 binds it to the body text itself. Only sections that push
    /// roll-up tuples appear here.
    public var rollupTuple: [String] {
        switch self {
        case .memories: ["memory_id", "body_norm_digest", "provenance_digest"]
        case .bodies: ["memory_id", "body_norm_digest", "body_join_key"]
        default: ["memory_id", "body_norm_digest", "provenance_digest"]
        }
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
