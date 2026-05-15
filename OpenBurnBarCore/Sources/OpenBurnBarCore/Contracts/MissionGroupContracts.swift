import Foundation

// MARK: - Mission Group Contracts (Hermes Square §6.4)
//
// Firestore-shaped DTOs for the multi-agent fan-out flow.
//
// On the wire:
//   users/{uid}/mission_groups/{groupID}                  — group document
//   users/{uid}/cli_agent_mission_requests/{missionID}    — N child missions
//                                                          linked by `groupID`
//
// The Mac listener (`CLIAgentMissionRequestListener`) treats every child
// mission as independently claimable, but inspects `groupID` to:
//   • avoid two listeners claiming the same group's children (when only one
//     Mac is online, all children land there);
//   • respect a `parallelismLimit` so the Mac doesn't try to spawn 5
//     concurrent Codex sessions at once when only 2 cores are free.
//
// The mobile surface (`MissionFanOutGroup` card in §6.4) renders the
// group state as a horizontally-scrollable stack of `MissionConsoleActiveTile`s,
// then a merge card when all children terminate.
//
// All names + shapes mirror the existing `CLIAgentMissionRequestPayloadFactory`
// vocabulary so JSON-on-wire stays consistent.

// MARK: - Group lifecycle

public enum MissionGroupPhase: String, Codable, Sendable, Hashable, CaseIterable {
    /// Group created, children queued but no listener has claimed any yet.
    case queued
    /// At least one child is running.
    case fanningOut = "fanning_out"
    /// All children have reached a terminal state. Awaiting user merge.
    case awaitingMerge = "awaiting_merge"
    /// User picked a winner (or "keep all"). Group is closed.
    case merged
    /// Group cancelled by the user before all children terminated.
    case cancelled
    /// All children failed — group failed.
    case failed

    public var displayLabel: String {
        switch self {
        case .queued:          return "Queued"
        case .fanningOut:      return "Fanning out"
        case .awaitingMerge:   return "Ready to merge"
        case .merged:          return "Merged"
        case .cancelled:       return "Cancelled"
        case .failed:          return "Failed"
        }
    }

    public var isTerminal: Bool {
        switch self {
        case .merged, .cancelled, .failed: return true
        default: return false
        }
    }
}

// MARK: - Merge strategy

public enum MissionGroupMergeStrategy: String, Codable, Sendable, Hashable, CaseIterable {
    /// User picks exactly one winner (the others are kept as comparison).
    case pickOne = "pick_one"
    /// User asks the host to keep all results unmerged (e.g., for a side-by-side review).
    case keepAll = "keep_all"
    /// User asks an orchestrator runtime (default Hermes) to synthesize a
    /// single result from the N child outputs. Triggers a second-stage
    /// mission with `kind: synthesizer` whose prompt is the children's
    /// outputs.
    case synthesize
}

// MARK: - Group document

public struct MissionGroupDocument: Codable, Sendable, Hashable, Identifiable {
    /// Stable group ID (also the Firestore doc ID).
    public let id: String

    /// Display title (echoes the user's prompt-title).
    public let title: String

    /// The prompt fanned out across all children. Mirrors per-child
    /// `prompt` for transparency / replay.
    public let prompt: String

    /// Mission kind from `MissionConsoleKind.rawValue`.
    public let missionKind: String

    /// Target project path (echoes per-child).
    public let targetProject: String?

    /// Ordered list of child mission IDs (in dispatch order).
    public let childMissionIDs: [String]

    /// Runtime tokens (one per child). Order matches `childMissionIDs`.
    /// Persisted to make the merge UI clear about who did what.
    public let runtimeTokens: [String]

    /// Maximum number of concurrent child missions a single Mac listener
    /// will run. Set to children.count for full parallelism; 1 for
    /// strictly sequential.
    public let parallelismLimit: Int

    /// Merge strategy chosen at dispatch time.
    public let mergeStrategy: MissionGroupMergeStrategy

    /// Current rolled-up phase. Computed Mac-side on every child
    /// transition; the phone treats the doc as authoritative.
    public let phase: MissionGroupPhase

    /// The mission ID the user picked as winner. Nil until `phase == .merged`.
    public let winnerMissionID: String?

    /// Worst-case forecast: sum of per-runtime forecasts (plan §8 anti-pattern 10).
    public let forecast: ForecastBand

    /// ISO-8601 timestamps.
    public let createdAt: Date
    public let updatedAt: Date

    /// Optional summary / synthesis string when `mergeStrategy == .synthesize`.
    public let synthesisSummary: String?

    public init(
        id: String,
        title: String,
        prompt: String,
        missionKind: String,
        targetProject: String?,
        childMissionIDs: [String],
        runtimeTokens: [String],
        parallelismLimit: Int,
        mergeStrategy: MissionGroupMergeStrategy,
        phase: MissionGroupPhase = .queued,
        winnerMissionID: String? = nil,
        forecast: ForecastBand = .zero,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        synthesisSummary: String? = nil
    ) {
        self.id = id
        self.title = title
        self.prompt = prompt
        self.missionKind = missionKind
        self.targetProject = targetProject
        self.childMissionIDs = childMissionIDs
        self.runtimeTokens = runtimeTokens
        self.parallelismLimit = max(1, parallelismLimit)
        self.mergeStrategy = mergeStrategy
        self.phase = phase
        self.winnerMissionID = winnerMissionID
        self.forecast = forecast
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.synthesisSummary = synthesisSummary
    }
}

// MARK: - Forecast band

extension MissionGroupDocument {
    /// Aggregated forecast across all children. Hosts compute via
    /// `MissionGroupForecastComputer.combine`.
    public struct ForecastBand: Codable, Sendable, Hashable {
        public let tokensLow: Int
        public let tokensHigh: Int
        public let costLowUSD: Double
        public let costHighUSD: Double
        public let etaLow: TimeInterval
        public let etaHigh: TimeInterval

        public init(
            tokensLow: Int,
            tokensHigh: Int,
            costLowUSD: Double,
            costHighUSD: Double,
            etaLow: TimeInterval,
            etaHigh: TimeInterval
        ) {
            self.tokensLow = tokensLow
            self.tokensHigh = tokensHigh
            self.costLowUSD = costLowUSD
            self.costHighUSD = costHighUSD
            self.etaLow = etaLow
            self.etaHigh = etaHigh
        }

        public static let zero = ForecastBand(
            tokensLow: 0, tokensHigh: 0,
            costLowUSD: 0, costHighUSD: 0,
            etaLow: 0, etaHigh: 0
        )
    }
}

// MARK: - Forecast computer

public enum MissionGroupForecastComputer {
    /// Combine N per-child forecasts into a group forecast.
    /// • Tokens: sum across children (worst case).
    /// • Cost: sum across children (worst case — plan anti-pattern 10).
    /// • ETA: the **max** of children (children run in parallel up to
    ///   `parallelismLimit`, so the wall-clock is bounded below by the
    ///   slowest child). When `parallelismLimit < children.count`, we
    ///   approximate by `sum / parallelismLimit`.
    public static func combine(
        children: [MissionConsoleForecast],
        parallelismLimit: Int
    ) -> MissionGroupDocument.ForecastBand {
        guard !children.isEmpty else { return .zero }
        let plim = max(1, parallelismLimit)
        let tokensLow = children.reduce(0) { $0 + $1.tokensLow }
        let tokensHigh = children.reduce(0) { $0 + $1.tokensHigh }
        let costLow = children.reduce(0.0) { $0 + $1.costLowUSD }
        let costHigh = children.reduce(0.0) { $0 + $1.costHighUSD }
        let etaSumLow = children.reduce(0.0) { $0 + $1.etaLow }
        let etaSumHigh = children.reduce(0.0) { $0 + $1.etaHigh }
        let etaMaxLow = children.map(\.etaLow).max() ?? 0
        let etaMaxHigh = children.map(\.etaHigh).max() ?? 0
        let effectiveParallelism = min(plim, children.count)
        let etaLow = max(etaMaxLow, etaSumLow / Double(effectiveParallelism))
        let etaHigh = max(etaMaxHigh, etaSumHigh / Double(effectiveParallelism))
        return MissionGroupDocument.ForecastBand(
            tokensLow: tokensLow,
            tokensHigh: tokensHigh,
            costLowUSD: costLow,
            costHighUSD: costHigh,
            etaLow: etaLow,
            etaHigh: etaHigh
        )
    }
}

// MARK: - Phase reducer

public enum MissionGroupPhaseReducer {
    /// Roll up N child mission statuses into a single group phase. Used by
    /// the Mac listener and the iOS observer.
    public static func reduce(childStatuses: [String], current: MissionGroupPhase = .queued) -> MissionGroupPhase {
        guard !childStatuses.isEmpty else { return current }

        let live = childStatuses.contains { isLive($0) }
        let allDone = childStatuses.allSatisfy { isTerminal($0) }
        let allFailed = childStatuses.allSatisfy { isFailed($0) }
        let anyCancelled = childStatuses.contains { isCancelled($0) }

        if allDone {
            if allFailed { return .failed }
            return .awaitingMerge
        }
        if live { return .fanningOut }
        if anyCancelled && current == .queued { return .cancelled }
        return current
    }

    private static let liveStates: Set<String> = [
        "running", "starting", "tooling", "streaming", "waiting_for_approval", "model_streaming", "executing_tool"
    ]
    private static let terminalStates: Set<String> = [
        "completed", "failed", "canceled", "cancelled", "unauthorized", "agent_launch_failed"
    ]
    private static let failedStates: Set<String> = [
        "failed", "unauthorized", "agent_launch_failed"
    ]
    private static let cancelledStates: Set<String> = [
        "canceled", "cancelled"
    ]

    public static func isLive(_ s: String)      -> Bool { liveStates.contains(s.lowercased()) }
    public static func isTerminal(_ s: String)  -> Bool { terminalStates.contains(s.lowercased()) }
    public static func isFailed(_ s: String)    -> Bool { failedStates.contains(s.lowercased()) }
    public static func isCancelled(_ s: String) -> Bool { cancelledStates.contains(s.lowercased()) }
}

// MARK: - Firestore Payload Factory

public enum MissionGroupPayloadFactory {
    /// Build the Firestore-shaped dictionary for the group document. Keep
    /// keys in lockstep with `CLIAgentMissionRequestPayloadFactory` so the
    /// server-side schema reviewer (`firestore.rules`) stays consistent.
    public static func buildGroupPayload(
        id: String,
        title: String,
        prompt: String,
        missionKind: String,
        targetProject: String?,
        childMissionIDs: [String],
        runtimeTokens: [String],
        parallelismLimit: Int,
        mergeStrategy: MissionGroupMergeStrategy,
        forecast: MissionGroupDocument.ForecastBand,
        now: Date = Date()
    ) -> [String: Any] {
        let ts = ISO8601DateFormatter().string(from: now)
        return [
            "id": id,
            "title": title,
            "prompt": prompt,
            "missionKind": missionKind,
            "targetProject": targetProject ?? "",
            "childMissionIDs": childMissionIDs,
            "runtimeTokens": runtimeTokens,
            "parallelismLimit": parallelismLimit,
            "mergeStrategy": mergeStrategy.rawValue,
            "phase": MissionGroupPhase.queued.rawValue,
            "winnerMissionID": "",
            "forecast": [
                "tokensLow": forecast.tokensLow,
                "tokensHigh": forecast.tokensHigh,
                "costLowUSD": forecast.costLowUSD,
                "costHighUSD": forecast.costHighUSD,
                "etaLow": forecast.etaLow,
                "etaHigh": forecast.etaHigh
            ],
            "createdAt": ts,
            "updatedAt": ts,
            "schemaVersion": 1,
            "source": "ios-hermes-square"
        ]
    }

    /// Build the per-child mission payload extension — the existing
    /// `CLIAgentMissionRequestPayloadFactory.build(...)` returns the base
    /// payload; we merge these keys so the child knows it's part of a
    /// group and which sibling index it occupies.
    public static func childPayloadOverlay(
        groupID: String,
        siblingIndex: Int,
        siblingCount: Int
    ) -> [String: Any] {
        [
            "groupID": groupID,
            "siblingIndex": siblingIndex,
            "siblingCount": siblingCount,
            "isGroupChild": true
        ]
    }
}

// MARK: - Decoding from Firestore data

extension MissionGroupDocument {
    public init?(documentID: String, data: [String: Any]) {
        guard
            let title = data["title"] as? String,
            let prompt = data["prompt"] as? String,
            let missionKind = data["missionKind"] as? String,
            let childIDs = data["childMissionIDs"] as? [String],
            let runtimes = data["runtimeTokens"] as? [String],
            let phaseRaw = data["phase"] as? String,
            let phase = MissionGroupPhase(rawValue: phaseRaw),
            let strategyRaw = data["mergeStrategy"] as? String,
            let strategy = MissionGroupMergeStrategy(rawValue: strategyRaw)
        else { return nil }

        let plim = (data["parallelismLimit"] as? Int) ?? childIDs.count
        let winner = (data["winnerMissionID"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let target = (data["targetProject"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let synthesis = (data["synthesisSummary"] as? String).flatMap { $0.isEmpty ? nil : $0 }

        let forecast: ForecastBand
        if let fmap = data["forecast"] as? [String: Any] {
            forecast = ForecastBand(
                tokensLow: (fmap["tokensLow"] as? Int) ?? 0,
                tokensHigh: (fmap["tokensHigh"] as? Int) ?? 0,
                costLowUSD: (fmap["costLowUSD"] as? Double) ?? 0,
                costHighUSD: (fmap["costHighUSD"] as? Double) ?? 0,
                etaLow: (fmap["etaLow"] as? Double) ?? 0,
                etaHigh: (fmap["etaHigh"] as? Double) ?? 0
            )
        } else {
            forecast = .zero
        }

        let createdAt = (data["createdAt"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date()
        let updatedAt = (data["updatedAt"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) } ?? createdAt

        self.init(
            id: (data["id"] as? String) ?? documentID,
            title: title,
            prompt: prompt,
            missionKind: missionKind,
            targetProject: target,
            childMissionIDs: childIDs,
            runtimeTokens: runtimes,
            parallelismLimit: plim,
            mergeStrategy: strategy,
            phase: phase,
            winnerMissionID: winner,
            forecast: forecast,
            createdAt: createdAt,
            updatedAt: updatedAt,
            synthesisSummary: synthesis
        )
    }
}
