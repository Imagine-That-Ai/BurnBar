// SPDX-License-Identifier: AGPL-3.0-only
//
// MemoryExportClassifier — §3.1, the never-inherit-approved rule.
//
// A pure function over row structs, because this is the decision the whole
// migration turns on and it must be testable one row at a time. The single
// user-visible consequence, stated in words: *memories an agent approved for
// itself arrive needing review.*
//
// `human_verdict(m)` is six conjuncts, ALL required. Conjuncts 2-4 exist
// because `actor` is a self-declared string in a three-writer table with no
// lock. Conjunct 5 because a verdict resting on an unverifiable span is not
// proof. Conjunct 6 because a `memory.approve` row binds a memory ID, NOT a
// body, and the update path rewrites a sealed body in place without touching
// `review_status` — without it the migration would carry text no human ever
// read into the new authority as `approved`, permanently.

import Foundation

/// Everything the classifier needs about one memory. Assembled by the exporter;
/// constructed directly by tests.
public struct MemoryExportClassifierInput: Sendable {
    public var memory: MemoryExportMemoryRow
    /// `memory_audit` rows whose `subject_id` is this memory, any order.
    public var auditRows: [MemoryExportAuditRow]
    /// `memory_body_snapshots.updated_at` for this memory, when one exists.
    /// Conjunct 6 is `snapshot.updated_at <= the audit row's ts`; a missing
    /// value is `unprovable`, not `bound`.
    public var bodySnapshotUpdatedAt: Date?
    public var chain: MemoryExportChainVerification
    /// §3.1 row 16: false only when `memory_audit` is absent or unreadable.
    public var auditTableAvailable: Bool
    /// §8 row 15: a cloud `memory_facts` row with no local row 1-3 naming it.
    public var isCloudOnly: Bool

    public init(
        memory: MemoryExportMemoryRow,
        auditRows: [MemoryExportAuditRow] = [],
        bodySnapshotUpdatedAt: Date? = nil,
        chain: MemoryExportChainVerification = MemoryExportChainVerification(),
        auditTableAvailable: Bool = true,
        isCloudOnly: Bool = false
    ) {
        self.memory = memory
        self.auditRows = auditRows
        self.bodySnapshotUpdatedAt = bodySnapshotUpdatedAt
        self.chain = chain
        self.auditTableAvailable = auditTableAvailable
        self.isCloudOnly = isCloudOnly
    }
}

public struct MemoryExportClassification: Sendable, Equatable {
    /// Row 12: a stored `forgotten` row is **not a memory record**. It leaves as
    /// a `fact` tombstone and never appears in section 05.
    public var isTombstoneOnly: Bool
    public var reviewStatus: MIFReviewStatus
    public var originKind: MIFOriginKind
    public var importOriginDetail: MIFImportOriginDetail
    /// The raw stored value, always carried so nothing is silently rewritten.
    public var originalReviewStatus: String?
    /// Rows 1-3 name an `audit_seq` that section 09 must carry (M-20).
    public var verdictAuditSeq: Int?
    public var verdictTimestamp: String?
    public var verdictActor: String?
    public var verdictAuditRowHash: String?
    public var verdictFromStatus: String?
    public var bodyVerdictBinding: MIFBodyVerdictBinding
    public var findings: [MIFFindingCode]

    /// True only for rows 1-3. The only `human` exits there are.
    public var isProvenHumanVerdict: Bool { originKind == .human }
}

public enum MemoryExportClassifier {

    /// App-owned `source_kind` set — conjunct 2. "App-owned by feel" is what
    /// this list exists to prevent.
    public static let appOwnedSourceKinds: Set<String> = ["chat", "safari_ask", "agent_session"]

    static let appBodyRefPrefix = "memory_body_snapshots:"
    static let verdictActions: Set<String> = ["memory.approve", "memory.reject"]

    // swiftlint:disable:next cyclomatic_complexity reason: the §3.1 table is sixteen rows and splitting it hides the shape
    public static func classify(_ input: MemoryExportClassifierInput) -> MemoryExportClassification {
        let stored = input.memory.reviewStatus

        // Row 12 — `forgotten` is a delete that happened, not a memory.
        if stored == MIFReviewStatus.forgotten.rawValue {
            return base(
                stored: stored,
                status: .forgotten,
                detail: .asStored,
                tombstoneOnly: true
            )
        }

        // Row 16 — the retained fail-closed base case. Undecidable, so nothing
        // is decided in the user's disfavour by accident.
        guard input.auditTableAvailable else {
            return base(stored: stored, status: .quarantined, detail: .unknown)
        }

        // Row 13 — no `review_status` column at all (daemon-only / Python file).
        guard let stored else {
            return base(stored: nil, status: .quarantined, detail: .absentColumn)
        }

        if let verdict = latestVerdictRow(for: input.memory, in: input.auditRows) {
            return classifyAgainst(verdict: verdict, input: input, stored: stored)
        }

        // No verdict row for this subject. What the row says about itself is all
        // there is, and `approved` is never taken at its word.
        switch stored {
        case MIFReviewStatus.approved.rawValue:
            let detail = input.isCloudOnly ? MIFImportOriginDetail.cloud : approvedWithoutProofDetail(input)
            return base(stored: stored, status: .quarantined, detail: detail)
        case MIFReviewStatus.quarantined.rawValue:
            return base(stored: stored, status: .quarantined, detail: .asStored)
        case MIFReviewStatus.rejected.rawValue:
            // Row 11 — never raised. The safe direction.
            return base(stored: stored, status: .rejected, detail: .rejectedRetainedUnproven)
        default:
            // Row 14 — any other value, e.g. 'pending'.
            return base(
                stored: stored,
                status: .quarantined,
                detail: .unknownValue,
                findings: [.reviewStatusUnknownValue]
            )
        }
    }

    // MARK: - The six conjuncts

    private static func classifyAgainst(
        verdict: MemoryExportAuditRow,
        input: MemoryExportClassifierInput,
        stored: String
    ) -> MemoryExportClassification {
        let memory = input.memory

        // Conjunct 2 — an app-owned `source_kind`.
        let appOwnedKind = memory.sourceKind.map { appOwnedSourceKinds.contains($0) } ?? false
        // Conjunct 3 — the app body-ref convention, not a bare sha256.
        let appConvention = memory.bodyRef.hasPrefix(appBodyRefPrefix)
        // Conjunct 4 — only the app writes both of these.
        let appIdentified = memory.userID != nil && memory.appID != nil

        guard appOwnedKind, appConvention, appIdentified else {
            // Row 9 — a forged `actor: "app"`. The row still travels; only the
            // claim is refused.
            return base(
                stored: stored,
                status: .quarantined,
                detail: .unknown,
                findings: [.forgedHumanVerdictRefused],
                binding: .unprovable
            )
        }

        // Conjunct 5 — the audit row is chain-trustworthy.
        guard input.chain.isTrustworthy(seq: verdict.seq) else {
            // Row 7.
            return base(
                stored: stored,
                status: .quarantined,
                detail: .verdictOnBrokenChain,
                findings: [.verdictOnBrokenChain],
                binding: .unprovable
            )
        }

        // Conjunct 6 — the verdict is bound to a body. A body snapshot newer
        // than the verdict means the text was rewritten after the human read it.
        let verdictTime = MemoryExportTimestamp.parse(verdict.ts)
        let bound: Bool
        if let snapshotUpdatedAt = input.bodySnapshotUpdatedAt, let verdictTime {
            bound = snapshotUpdatedAt <= verdictTime
        } else {
            bound = false
        }
        guard bound else {
            // Row 8 — the worst finding in the attack, and the reason conjunct
            // 6 exists at all.
            return base(
                stored: stored,
                status: .quarantined,
                detail: .approvedBodyMutatedAfterVerdict,
                findings: [.approvedBodyMutatedAfterVerdict],
                binding: input.bodySnapshotUpdatedAt == nil ? .unprovable : .bodyMutatedAfterVerdict
            )
        }

        // Rows 1-3 — proven. The value comes from the label, never the verb.
        guard let label = verdict.reviewStatusLabelValue,
              let status = MIFReviewStatus(rawValue: label),
              status != .forgotten else {
            // A proven-shaped row whose label is missing or unknown is not a
            // proven verdict; it is an unknown value, and it quarantines.
            return base(
                stored: stored,
                status: .quarantined,
                detail: .unknownValue,
                findings: [.reviewStatusUnknownValue],
                binding: .bound
            )
        }

        var classification = base(
            stored: stored,
            status: status,
            detail: .humanVerdict,
            binding: .bound
        )
        classification.originKind = .human
        classification.verdictAuditSeq = verdict.seq
        classification.verdictTimestamp = verdict.ts
        classification.verdictActor = verdict.actor
        classification.verdictAuditRowHash = verdict.hash
        classification.verdictFromStatus = previousStatus(before: verdict, in: input.auditRows)
        return classification
    }

    // MARK: - Selection among oracle audit rows

    /// M-12: latest-wins ordered by `(ts, seq)`, and on any tie `rejected` wins.
    ///
    /// Ordering by `seq` alone is undefined under payload-seq divergence and the
    /// app/daemon fork, where `approve(seq 100, ts T)` and `reject(seq 99, ts
    /// T+1)` resolve either way. This is the exporter's per-row SELECTION among
    /// oracle rows; it is not a merge rule and does not compete with §4.
    static func latestVerdictRow(
        for memory: MemoryExportMemoryRow,
        in rows: [MemoryExportAuditRow]
    ) -> MemoryExportAuditRow? {
        rows
            .filter { verdictActions.contains($0.action) && $0.actor == "app" && $0.subjectID == memory.id }
            .max { lhs, rhs in orderedBefore(lhs, rhs) }
    }

    /// A total order: timestamp, then seq, then `reject` above `approve` so a
    /// genuine tie resolves to the safe side.
    static func orderedBefore(_ lhs: MemoryExportAuditRow, _ rhs: MemoryExportAuditRow) -> Bool {
        let lhsTime = MemoryExportTimestamp.parse(lhs.ts) ?? .distantPast
        let rhsTime = MemoryExportTimestamp.parse(rhs.ts) ?? .distantPast
        if lhsTime != rhsTime { return lhsTime < rhsTime }
        if lhs.seq != rhs.seq { return lhs.seq < rhs.seq }
        return rejectRank(lhs) < rejectRank(rhs)
    }

    private static func rejectRank(_ row: MemoryExportAuditRow) -> Int {
        row.action == "memory.reject" ? 1 : 0
    }

    /// The status this memory held before the winning verdict, read from the
    /// preceding labelled row. `nil` when there is none, which the contract
    /// accepts for `from_status`.
    private static func previousStatus(
        before verdict: MemoryExportAuditRow,
        in rows: [MemoryExportAuditRow]
    ) -> String? {
        let earlier = rows
            .filter { $0.seq != verdict.seq && orderedBefore($0, verdict) }
            .filter { $0.reviewStatusLabelValue != nil }
            .max { orderedBefore($0, $1) }
        guard let value = earlier?.reviewStatusLabelValue,
              MIFReviewStatus(rawValue: value) != nil else {
            return nil
        }
        return value
    }

    /// Rows 4, 5 and 6 — which unproven `approved` bucket this row falls in.
    /// Every such row lands in exactly one, so the report's break-out sums.
    static func approvedWithoutProofDetail(_ input: MemoryExportClassifierInput) -> MIFImportOriginDetail {
        let actors = Set(input.auditRows.map(\.actor))
        if actors.contains("daemon") { return .daemonDefault }
        if actors.contains("local-mcp") { return .mcpDefault }
        // Row 6 — the v51 migration ran `UPDATE agent_memories SET
        // review_status = 'approved' WHERE source_kind = 'code'` and wrote no
        // audit row, so an approved row with no verdict evidence is that.
        return .v51Backfill
    }

    // MARK: - Construction

    private static func base(
        stored: String?,
        status: MIFReviewStatus,
        detail: MIFImportOriginDetail,
        findings: [MIFFindingCode] = [],
        binding: MIFBodyVerdictBinding = .unprovable,
        tombstoneOnly: Bool = false
    ) -> MemoryExportClassification {
        MemoryExportClassification(
            isTombstoneOnly: tombstoneOnly,
            reviewStatus: status,
            originKind: .importOrigin,
            importOriginDetail: detail,
            originalReviewStatus: stored,
            verdictAuditSeq: nil,
            verdictTimestamp: nil,
            verdictActor: nil,
            verdictAuditRowHash: nil,
            verdictFromStatus: nil,
            bodyVerdictBinding: binding,
            findings: findings
        )
    }
}

// MARK: - Partitioning

/// §3.3: `dedup_partition` is derived from the source lane, never stamped
/// `import` wholesale. That preserves the oracle invariant that a usage row and
/// a chat row with identical text never collapse, and it is what lets a
/// migrated chat row and a Po'dex-native chat row form a supersession edge.
public enum MemoryExportPartition {
    public static func dedupPartition(sourceKind: String?) -> MIFDedupPartition {
        switch sourceKind {
        case "chat": .chat
        case "usage": .usage
        case "code": .code
        case "safari_ask": .chat
        case "agent_session": .chat
        case "agent": .chat
        default: .importPartition
        }
    }

    /// `chat:<uid>` / `usage:<uid>` / `chat:unscoped` are **not projects**. They
    /// route to `scope_kind: 'user'` with no project row minted.
    public static func isPartitionPseudoProject(_ projectID: String) -> Bool {
        projectID.hasPrefix("chat:") || projectID.hasPrefix("usage:")
    }

    /// The user id a pseudo-project encodes, or nil when it is `unscoped`.
    public static func pseudoProjectUserID(_ projectID: String) -> String? {
        guard let separator = projectID.firstIndex(of: ":") else { return nil }
        let value = String(projectID[projectID.index(after: separator)...])
        return value == "unscoped" ? nil : value
    }
}
