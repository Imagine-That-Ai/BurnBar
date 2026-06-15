import Foundation

// MARK: - Fusion Session Spend
//
// The storage-agnostic spend model behind The Elder Wand's two spend surfaces:
// the end-of-session receipt modal and the standing "Fusion impact" screen.
//
// A fusion run records one `BurnBarUsageEvent` per sub-call (each panel member,
// the judge, the synthesis), all sharing one `parentRequestID` of the form
// `elderwand-<UUID>`. The stage of each sub-call is carried in the recorded
// idempotency-key / request signature (`<parentRequestID>|panel|<model>|<index>`,
// `|judge|`, `|synthesis|`) — see `ElderWandFusionOrchestrator.signature(_:_:_:_:)`.
//
// `FusionSpendAggregator` consumes `FusionUsageRow`s — a flat, platform-neutral
// projection a caller builds from whichever read path carries `parentRequestID`
// (the daemon `daemon.usage.recent` RPC, or the raw `usage-events.jsonl` line) —
// and produces:
//   • `FusionSessionSpend`   — one fusion run's itemized receipt (the modal).
//   • `FusionVsNormalTotals` — fusion versus normal spend over a window (the screen).
//
// The session total is the SUM of the recorded `cost` field on the run's rows, so
// the receipt reconciles to the ledger exactly — the aggregator never reprices.

// MARK: - Input row

/// One usage row, projected from whatever read path carries `parentRequestID`.
/// `cost` is the already-recorded cost (computed at record time by the gateway via
/// `BurnBarModelPricing.cost`), so summing it reproduces the ledger total.
public struct FusionUsageRow: Sendable, Hashable {
    /// The fusion run this row belongs to (`elderwand-<UUID>`); `nil` for a
    /// normal, non-fusion request.
    public let parentRequestID: String?
    /// The recorded stage label, parsed from the idempotency key / request
    /// signature when available (`panel`, `panel[0]`, `judge`, `synthesis`).
    public let stageLabel: String?
    public let modelID: String
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheCreationTokens: Int
    public let cacheReadTokens: Int
    public let reasoningTokens: Int
    public let cost: Double
    public let confidence: BurnBarUsageConfidence
    public let recordedAt: Date

    public init(
        parentRequestID: String?,
        stageLabel: String?,
        modelID: String,
        inputTokens: Int,
        outputTokens: Int,
        cacheCreationTokens: Int = 0,
        cacheReadTokens: Int = 0,
        reasoningTokens: Int = 0,
        cost: Double,
        confidence: BurnBarUsageConfidence,
        recordedAt: Date
    ) {
        self.parentRequestID = parentRequestID
        self.stageLabel = stageLabel
        self.modelID = modelID
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
        self.reasoningTokens = reasoningTokens
        self.cost = cost
        self.confidence = confidence
        self.recordedAt = recordedAt
    }

    /// Project a recorded `BurnBarUsageEvent` into a row. `stageLabel` is supplied
    /// separately because the event itself does not carry the stage — the caller
    /// parses it from the idempotency key on the same ledger line.
    public init(event: BurnBarUsageEvent, stageLabel: String?) {
        self.init(
            parentRequestID: event.parentRequestID,
            stageLabel: stageLabel,
            modelID: event.modelID,
            inputTokens: event.inputTokens,
            outputTokens: event.outputTokens,
            cacheCreationTokens: event.cacheCreationTokens,
            cacheReadTokens: event.cacheReadTokens,
            reasoningTokens: event.reasoningTokens,
            cost: event.cost,
            confidence: event.confidence,
            recordedAt: event.recordedAt
        )
    }

    /// The fusion-run prefix every Elder Wand `parentRequestID` carries.
    public static let fusionParentPrefix = "elderwand-"

    /// Whether this row belongs to a fusion run.
    public var isFusion: Bool {
        parentRequestID?.hasPrefix(FusionUsageRow.fusionParentPrefix) ?? false
    }

    public var totalTokens: Int {
        inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens + reasoningTokens
    }
}

// MARK: - Stage

/// Which pipeline stage produced a sub-call. Sorts panels first (by declared
/// index), then judge, then synthesis, so the receipt reads top-to-bottom in
/// pipeline order.
public enum FusionStage: Sendable, Hashable, Codable {
    case panel(index: Int)
    case judge
    case synthesis
    case unknown

    /// Parse a recorded stage label (`panel`, `panel[2]`, `judge`, `synthesis`).
    public static func parse(_ label: String?) -> FusionStage {
        guard let raw = label?.lowercased().trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return .unknown
        }
        if raw.hasPrefix("synthesis") { return .synthesis }
        if raw.hasPrefix("judge") { return .judge }
        if raw.hasPrefix("panel") {
            let digits = raw.drop { !$0.isNumber }.prefix { $0.isNumber }
            return .panel(index: Int(digits) ?? 0)
        }
        return .unknown
    }

    /// Stable ordering key: panels (0…) < judge < synthesis < unknown.
    public var sortKey: Int {
        switch self {
        case .panel(let index): return index
        case .judge: return 1_000
        case .synthesis: return 2_000
        case .unknown: return 3_000
        }
    }

    /// A short, user-facing role label.
    public var displayRole: String {
        switch self {
        case .panel: return "Panel"
        case .judge: return "Judge"
        case .synthesis: return "Final answer"
        case .unknown: return "Model"
        }
    }
}

// MARK: - Confidence rollup

extension BurnBarUsageConfidence {
    /// Numeric rank, higher = more certain. Used to collapse a set of sub-call
    /// confidences to their weakest (any estimate makes the whole an estimate).
    public var certaintyRank: Int {
        switch self {
        case .exact: return 4
        case .derivedExact: return 3
        case .highConfidenceEstimate: return 2
        case .lowConfidenceEstimate: return 1
        case .unknown: return 0
        }
    }

    /// `true` when this is an exact (non-estimated) count, so the UI can mark
    /// estimates honestly.
    public var isExact: Bool {
        self == .exact || self == .derivedExact
    }

    static func weakest(_ values: [BurnBarUsageConfidence]) -> BurnBarUsageConfidence {
        values.min(by: { $0.certaintyRank < $1.certaintyRank }) ?? .unknown
    }
}

// MARK: - Sub-call line item

/// One sub-call's spend within a fusion session — a row in the receipt.
public struct FusionSubCallSpend: Identifiable, Sendable, Hashable, Codable {
    public let id: String
    public let stage: FusionStage
    public let modelID: String
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheCreationTokens: Int
    public let cacheReadTokens: Int
    public let reasoningTokens: Int
    public let cost: Double
    public let confidence: BurnBarUsageConfidence

    public var totalTokens: Int {
        inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens + reasoningTokens
    }

    public init(
        id: String,
        stage: FusionStage,
        modelID: String,
        inputTokens: Int,
        outputTokens: Int,
        cacheCreationTokens: Int,
        cacheReadTokens: Int,
        reasoningTokens: Int,
        cost: Double,
        confidence: BurnBarUsageConfidence
    ) {
        self.id = id
        self.stage = stage
        self.modelID = modelID
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
        self.reasoningTokens = reasoningTokens
        self.cost = cost
        self.confidence = confidence
    }
}

// MARK: - Session

/// One fusion run's itemized receipt — the model behind the end-of-session modal.
public struct FusionSessionSpend: Identifiable, Sendable, Hashable, Codable {
    /// The wire key the daemon gateway emits the session under in a final SSE
    /// frame, so iOS (which runs fusion on the Mac over the relay and has no
    /// local ledger) gets the itemized receipt: `{"openburnbar_fusion_spend": …}`.
    public static let wireKey = "openburnbar_fusion_spend"

    public let parentRequestID: String
    public let lineItems: [FusionSubCallSpend]
    /// The most recent sub-call timestamp in the run (when the receipt is "as of").
    public let completedAt: Date

    public var id: String { parentRequestID }

    public init(parentRequestID: String, lineItems: [FusionSubCallSpend], completedAt: Date) {
        self.parentRequestID = parentRequestID
        self.lineItems = lineItems
        self.completedAt = completedAt
    }

    /// The session total — the SUM of the recorded `cost` of every sub-call, so
    /// the receipt reconciles to the usage ledger exactly.
    public var totalCost: Double { lineItems.reduce(0) { $0 + $1.cost } }

    public var totalInputTokens: Int { lineItems.reduce(0) { $0 + $1.inputTokens } }
    public var totalOutputTokens: Int { lineItems.reduce(0) { $0 + $1.outputTokens } }
    public var totalTokens: Int { lineItems.reduce(0) { $0 + $1.totalTokens } }

    /// The panel members in this run (sub-calls whose stage is `.panel`).
    public var panelItems: [FusionSubCallSpend] {
        lineItems.filter { if case .panel = $0.stage { return true } else { return false } }
    }
    public var panelCount: Int { panelItems.count }

    public var judgeItem: FusionSubCallSpend? { lineItems.first { $0.stage == .judge } }
    public var synthesisItem: FusionSubCallSpend? { lineItems.first { $0.stage == .synthesis } }

    /// The weakest confidence across the run — so the receipt marks the total an
    /// estimate when any sub-call was estimated.
    public var aggregateConfidence: BurnBarUsageConfidence {
        BurnBarUsageConfidence.weakest(lineItems.map(\.confidence))
    }

    /// The "solo" baseline: what one answer from the originating model cost. The
    /// synthesis sub-call IS the originating model running once, so it is the
    /// truest baseline; degraded runs fall back to the judge, then the costliest
    /// panel member.
    public var soloBaselineCost: Double {
        if let synthesis = synthesisItem, synthesis.cost > 0 { return synthesis.cost }
        if let judge = judgeItem, judge.cost > 0 { return judge.cost }
        return panelItems.map(\.cost).max() ?? 0
    }

    /// The "cost of certainty": how many times a single-model answer this fusion
    /// run cost. `nil` when no positive baseline exists (so the UI omits it
    /// rather than dividing by zero).
    public var costMultiplier: Double? {
        let baseline = soloBaselineCost
        guard baseline > 0 else { return nil }
        return totalCost / baseline
    }
}

// MARK: - Period partition

/// Fusion-versus-normal spend over a window — the model behind the impact screen's
/// headline comparison.
public struct FusionVsNormalTotals: Sendable, Hashable {
    public let fusionCost: Double
    public let normalCost: Double
    public let fusionRuns: Int
    public let fusionTokens: Int
    public let normalTokens: Int
    /// Per-model fusion spend (model id → summed cost), for the contribution view.
    public let fusionCostByModel: [String: Double]

    public init(
        fusionCost: Double,
        normalCost: Double,
        fusionRuns: Int,
        fusionTokens: Int,
        normalTokens: Int,
        fusionCostByModel: [String: Double]
    ) {
        self.fusionCost = fusionCost
        self.normalCost = normalCost
        self.fusionRuns = fusionRuns
        self.fusionTokens = fusionTokens
        self.normalTokens = normalTokens
        self.fusionCostByModel = fusionCostByModel
    }

    public var totalCost: Double { fusionCost + normalCost }

    /// Fusion's share of total spend over the window (0…1).
    public var fusionShareFraction: Double {
        let total = totalCost
        return total > 0 ? fusionCost / total : 0
    }

    public var averageCostPerFusionRun: Double? {
        fusionRuns > 0 ? fusionCost / Double(fusionRuns) : nil
    }
}

// MARK: - Aggregator

/// Pure functions that turn flat usage rows into the two spend models. No I/O, no
/// repricing — the callers feed rows from their platform read path.
public enum FusionSpendAggregator {

    /// Group fusion rows into per-run sessions, sorted newest run first. Rows
    /// without a fusion `parentRequestID` are ignored.
    public static func sessions(from rows: [FusionUsageRow]) -> [FusionSessionSpend] {
        var byParent: [String: [FusionUsageRow]] = [:]
        for row in rows where row.isFusion {
            byParent[row.parentRequestID!, default: []].append(row)
        }
        let sessions = byParent.map { parentID, runRows -> FusionSessionSpend in
            let items = runRows
                .map { row -> FusionSubCallSpend in
                    let stage = FusionStage.parse(row.stageLabel)
                    return FusionSubCallSpend(
                        id: "\(parentID)|\(row.stageLabel ?? row.modelID)|\(row.modelID)",
                        stage: stage,
                        modelID: row.modelID,
                        inputTokens: row.inputTokens,
                        outputTokens: row.outputTokens,
                        cacheCreationTokens: row.cacheCreationTokens,
                        cacheReadTokens: row.cacheReadTokens,
                        reasoningTokens: row.reasoningTokens,
                        cost: row.cost,
                        confidence: row.confidence
                    )
                }
                .sorted { lhs, rhs in
                    lhs.stage.sortKey != rhs.stage.sortKey
                        ? lhs.stage.sortKey < rhs.stage.sortKey
                        : lhs.modelID < rhs.modelID
                }
            let completedAt = runRows.map(\.recordedAt).max() ?? Date(timeIntervalSince1970: 0)
            return FusionSessionSpend(parentRequestID: parentID, lineItems: items, completedAt: completedAt)
        }
        return sessions.sorted { $0.completedAt > $1.completedAt }
    }

    /// The most recently completed fusion run — what the end-of-session modal
    /// shows. Correct in the common serialized case (one fusion at a time, modal
    /// fires at completion). Returns `nil` when no fusion rows are present.
    public static func newestSession(from rows: [FusionUsageRow]) -> FusionSessionSpend? {
        sessions(from: rows).first
    }

    /// The fusion run with a specific `parentRequestID`, when the caller already
    /// knows it (e.g. threaded back from the daemon). Returns `nil` when absent.
    public static func session(parentRequestID: String, from rows: [FusionUsageRow]) -> FusionSessionSpend? {
        sessions(from: rows).first { $0.parentRequestID == parentRequestID }
    }

    /// Partition a window of rows into fusion versus normal spend for the impact
    /// screen. Fusion = rows whose `parentRequestID` is `elderwand-…`; everything
    /// else is normal.
    public static func partition(_ rows: [FusionUsageRow]) -> FusionVsNormalTotals {
        var fusionCost = 0.0, normalCost = 0.0
        var fusionTokens = 0, normalTokens = 0
        var fusionParents = Set<String>()
        var byModel: [String: Double] = [:]
        for row in rows {
            if row.isFusion {
                fusionCost += row.cost
                fusionTokens += row.totalTokens
                fusionParents.insert(row.parentRequestID!)
                byModel[row.modelID, default: 0] += row.cost
            } else {
                normalCost += row.cost
                normalTokens += row.totalTokens
            }
        }
        return FusionVsNormalTotals(
            fusionCost: fusionCost,
            normalCost: normalCost,
            fusionRuns: fusionParents.count,
            fusionTokens: fusionTokens,
            normalTokens: normalTokens,
            fusionCostByModel: byModel
        )
    }
}
