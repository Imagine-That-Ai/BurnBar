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

        if let selection = selectVerdict(for: input.memory, in: input.auditRows, chain: input.chain) {
            return classifyAgainst(selection: selection, input: input, stored: stored)
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
        selection: VerdictSelection,
        input: MemoryExportClassifierInput,
        stored: String
    ) -> MemoryExportClassification {
        let verdict = selection.row
        let memory = input.memory

        // Conjunct 2 — an app-owned `source_kind`.
        let appOwnedKind = memory.sourceKind.map { appOwnedSourceKinds.contains($0) } ?? false
        // Conjunct 3 — the app body-ref convention, not a bare sha256.
        let appConvention = memory.bodyRef.hasPrefix(appBodyRefPrefix)
        // Conjunct 4 — only the app writes both of these.
        let appIdentified = memory.userID != nil && memory.appID != nil

        guard appOwnedKind, appConvention, appIdentified else {
            // Row 9 — a forged `actor: "app"`. The row still travels; only the
            // claim is refused. The forged row's own label carries no weight
            // here — the app-ness of the whole row is what was refused — so only
            // the STORED value clamps the safe direction.
            return base(
                stored: stored,
                status: unprovenStatus(stored: stored),
                detail: .unknown,
                findings: [.forgedHumanVerdictRefused],
                binding: .unprovable
            )
        }

        // Conjunct 5, checked on every candidate that CAN WIN — which under a
        // case-2 regime is all of them, because the order across a broken or
        // forked boundary is not itself proof. §3.1: "Rows selected under case 2
        // additionally fail conjunct 5 and therefore export `quarantined` with
        // `verdict_on_broken_chain` (row 7)".
        //
        // Checking it on the WINNER ALONE is the R1 defect: one untrustworthy
        // SIBLING flipped the whole selection into wall-clock order while the
        // winner — an older approve the chain had already been overtaken by —
        // passed conjunct 5 on its own seq and left as `human`. A chain-later
        // human REJECTION was discarded for sitting in the broken span, and §4's
        // merge made the promotion permanent.
        guard selection.regimeIsIntact, input.chain.isTrustworthy(seq: verdict.seq) else {
            // Row 7, exactly as §3.1 writes it: "`quarantined` + finding
            // `verdict_on_broken_chain`". A stored `rejected` still stays
            // `rejected` (row 11's "never raised"), and nothing else moves.
            //
            // It used to LOWER the row to `rejected` whenever any candidate in
            // the span carried a `review_status:rejected` label — safe in
            // direction, and an invented rule with a cost in the other one
            // (review F-5): a writer who can break or fork a chain span can
            // force any memory to `rejected`, and §4's merge makes that
            // permanent and unrecallable — the mirror image of the defect M-13
            // describes. An unproven verdict decides nothing here; the row goes
            // back in the review queue, which is what row 7 is for.
            return base(
                stored: stored,
                status: unprovenStatus(stored: stored),
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
            // 6 exists at all. A body rewritten under a REJECTION does not
            // un-reject it, so the winner's own label still clamps.
            return base(
                stored: stored,
                status: unprovenStatus(stored: stored, winner: verdict),
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
            // proven verdict; it is an unknown value. It never RAISES the row,
            // though: §3.1 row 11 says a stored `rejected` is "never raised —
            // the safe direction", and quarantining one would put a memory the
            // user rejected back in the review queue (R8).
            return base(
                stored: stored,
                status: unprovenStatus(stored: stored),
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
        classification.verdictFromStatus = previousStatus(
            before: verdict,
            in: input.auditRows,
            // The same regime the winner was selected under, so `from_status`
            // is read in the order the verdict was.
            withinIntactSegment: selection.regimeIsIntact
        )
        return classification
    }

    // MARK: - Selection among oracle audit rows

    /// M-12's latest-wins, which is **segment-aware**: one rule, two cases.
    ///
    ///   1. **Inside one intact segment** — every candidate chain-verified, in
    ///      no `chain_broken_at[]` span and in no `chain_forks[]` member — order
    ///      by `seq DESC`. `seq` is the oracle's own append order, and inside an
    ///      intact run it is exactly the fact the chain proves.
    ///   2. **Across a broken or forked boundary**, where `seq` is undefined,
    ///      fall back to `(ts, seq)`. This is the case the oracle's two known
    ///      pathologies produce.
    ///   3. Either way, a tie is won by `rejected`.
    ///
    /// Applying case 2 universally — which is what this did — lets a clock skew
    /// between the app and daemon writers reorder rows the chain has already
    /// ordered: on an INTACT chain, `reject(seq 100, ts T)` and
    /// `approve(seq 99, ts T+1)` resolved to the approve, all six conjuncts
    /// passed, and a verdict no human gave survived into the new authority as
    /// `approved` with `origin_kind: human` (review F-5). Case 1 exists to
    /// neutralise exactly that, and §3.1 says so in as many words: "preferring
    /// `ts` there would let a wrong clock reorder rows the chain has already
    /// ordered".
    ///
    /// The regime is chosen from THIS row's own candidate set, and conjunct 5 is
    /// then checked on every candidate that can win rather than on the winner
    /// alone (R1). Deciding the regime over the whole set while proving only the
    /// winner is what let an untrustworthy SIBLING flip the selection into
    /// wall-clock order — the order §3.1 case 1 exists to ignore — and hand the
    /// exit to an older approve that passed conjunct 5 on its own seq.
    ///
    /// This is the exporter's per-row SELECTION among oracle rows; it is not a
    /// merge rule and does not compete with §4.
    static func selectVerdict(
        for memory: MemoryExportMemoryRow,
        in rows: [MemoryExportAuditRow],
        chain: MemoryExportChainVerification
    ) -> VerdictSelection? {
        // "This rule is **the exporter's per-row selection among oracle audit
        // rows**" — so the regime is decided from THIS row's own candidate set,
        // and a candidate set is intact only when every member of it is
        // chain-trustworthy. Nothing about another memory's rows reaches here.
        let candidates = rows
            .filter { verdictActions.contains($0.action) && $0.actor == "app" && $0.subjectID == memory.id }
        guard candidates.isEmpty == false else { return nil }
        let intact = candidates.allSatisfy { chain.isTrustworthy(seq: $0.seq) }
        guard let winner = candidates.max(by: { lhs, rhs in
            orderedBefore(lhs, rhs, withinIntactSegment: intact)
        }) else { return nil }
        return VerdictSelection(row: winner, candidates: candidates, regimeIsIntact: intact)
    }

    /// One row's verdict selection, and the regime that produced it.
    struct VerdictSelection {
        var row: MemoryExportAuditRow
        /// Every candidate for this memory, in source order — the set the
        /// regime was decided from, and what a caller inspecting the selection
        /// (or a test) needs to see why.
        var candidates: [MemoryExportAuditRow]
        /// True when §3.1 case 1 decided the order: every candidate for THIS row
        /// was chain-trustworthy, so `seq DESC` is the fact the chain proves.
        var regimeIsIntact: Bool
    }

    /// The exported status for a verdict that exists but is not proof:
    /// `quarantined`, which is what every unproven row in §3.1 exports.
    ///
    /// Two clamps, and no third:
    ///
    ///   * §3.1 row 11 — a stored `rejected` is "**never raised** — the safe
    ///     direction". Quarantining it would put a memory the user rejected back
    ///     in the review queue, and `quarantined` is a step TOWARDS `approved`,
    ///     the one direction this classifier may never take.
    ///   * Row 8 alone passes a `winner`: a proven-shaped verdict on an INTACT
    ///     chain whose body was rewritten under it. A body rewritten under a
    ///     REJECTION does not un-reject it, so that row's own label still clamps
    ///     downwards.
    ///
    /// `approved` is unreachable from here by construction — an unproven approve
    /// always quarantines.
    static func unprovenStatus(stored: String, winner: MemoryExportAuditRow? = nil) -> MIFReviewStatus {
        if stored == MIFReviewStatus.rejected.rawValue { return .rejected }
        let rejected = winner?.reviewStatusLabelValue == MIFReviewStatus.rejected.rawValue
        return rejected ? .rejected : .quarantined
    }

    /// A total order. Inside an intact segment it is `seq` then the tie rule;
    /// across a boundary it is the timestamp STRING, then `seq`, then the same
    /// tie rule.
    static func orderedBefore(
        _ lhs: MemoryExportAuditRow,
        _ rhs: MemoryExportAuditRow,
        withinIntactSegment intact: Bool
    ) -> Bool {
        if intact == false {
            // §3.1: "`ts` is **ISO TEXT** in the oracle and is compared
            // **lexicographically**, which is well-defined for its fixed-width
            // UTC format and is not otherwise treated as a clock."
            //
            // A `Date` compare is not that compare. It honours a `±HH:MM` offset
            // and truncates sub-millisecond digits, so `approve` at
            // "2026-01-01T20:00:00.000Z" beat `reject` at
            // "2026-01-02T00:00:00.000+09:00" as instants while the spec's
            // compare puts the reject later — the unsafe direction, decided by a
            // field the writing row supplies.
            if lhs.ts != rhs.ts { return lhs.ts < rhs.ts }
        }
        if lhs.seq != rhs.seq { return lhs.seq < rhs.seq }
        return rejectRank(lhs) < rejectRank(rhs)
    }

    /// §3.1 case 3: "Either way, a tie is won by `rejected`" — the safe
    /// direction, and the only one that cannot promote text no human read.
    ///
    /// WHICH row is the rejection is read from the `review_status:<raw>` label,
    /// never from the action verb (M-13): BurnBar writes `memory.reject` for
    /// every non-approved transition, including approved→quarantined, so ranking
    /// on the verb hands a tie between `memory.reject{review_status:approved}`
    /// and `memory.approve{review_status:rejected}` to the reject-VERB row and
    /// then exports `approved` from its label — the tie rule inverted by the one
    /// field §3.1 says never to read.
    private static func rejectRank(_ row: MemoryExportAuditRow) -> Int {
        row.reviewStatusLabelValue == MIFReviewStatus.rejected.rawValue ? 1 : 0
    }

    /// The status this memory held before the winning verdict, read from the
    /// preceding labelled row. `nil` when there is none, which the contract
    /// accepts for `from_status`.
    private static func previousStatus(
        before verdict: MemoryExportAuditRow,
        in rows: [MemoryExportAuditRow],
        withinIntactSegment intact: Bool
    ) -> String? {
        let earlier = rows
            .filter { $0.seq != verdict.seq && orderedBefore($0, verdict, withinIntactSegment: intact) }
            .filter { $0.reviewStatusLabelValue != nil }
            .max { orderedBefore($0, $1, withinIntactSegment: intact) }
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
