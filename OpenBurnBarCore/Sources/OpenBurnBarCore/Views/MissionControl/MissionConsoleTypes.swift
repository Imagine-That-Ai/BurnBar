import Foundation
import SwiftUI

// MARK: - Mission Control Console — Public Types
//
// The Mission Control Console is the shared launcher + live situation room.
// macOS and iOS render the same primitives (in `OpenBurnBarCore.Views.MissionControl`)
// and provide platform-specific hosts via the `MissionConsoleHost` protocol.
//
// Core stays free of Firebase / AppKit dependencies; hosts adapt their native
// snapshot types into the display view models below.

// MARK: Mission kind

public enum MissionConsoleKind: String, CaseIterable, Identifiable, Sendable, Hashable {
    case diligence
    case debt
    case creative
    case security
    case accretive
    case modernization
    case uiImprovement = "ui_improvement"
    case costEfficiency = "cost_efficiency"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .diligence:       return "Diligence"
        case .debt:            return "Debt Sweep"
        case .creative:        return "Creative Build"
        case .security:        return "Security Audit"
        case .accretive:       return "Accretive Polish"
        case .modernization:   return "Modernization"
        case .uiImprovement:   return "UI Improvement"
        case .costEfficiency:  return "Cost Efficiency"
        }
    }

    public var tagline: String {
        switch self {
        case .diligence:       return "Investigate, verify, write the receipts."
        case .debt:            return "Pay down debt without breaking surfaces."
        case .creative:        return "Build something new from the brief."
        case .security:        return "Threat-model the change and prove it."
        case .accretive:       return "Small wins that compound."
        case .modernization:   return "Migrate to current platform shape."
        case .uiImprovement:   return "Make the surface delightful."
        case .costEfficiency:  return "Trim tokens, route smarter."
        }
    }

    public var glyph: String {
        switch self {
        case .diligence:       return "magnifyingglass"
        case .debt:            return "wrench.and.screwdriver.fill"
        case .creative:        return "sparkles"
        case .security:        return "shield.lefthalf.filled"
        case .accretive:       return "leaf.fill"
        case .modernization:   return "arrow.up.right.square.fill"
        case .uiImprovement:   return "paintpalette.fill"
        case .costEfficiency:  return "gauge.with.dots.needle.bottom.50percent"
        }
    }

    /// Runtime preference order — mirrors `CLIAgentMissionRuntimePlanner`.
    /// Hosts can override; this is the design default surfaced as the
    /// "recommends ▸" hint in the kind chooser.
    public var preferredRuntimes: [MissionConsoleRuntime.ID] {
        switch self {
        case .diligence, .security:
            return ["claude", "codex", "hermes", "pi", "openclaw"]
        case .creative, .accretive, .uiImprovement:
            return ["openclaw", "codex", "hermes", "pi", "claude"]
        case .debt, .modernization, .costEfficiency:
            return ["codex", "claude", "hermes", "pi", "openclaw"]
        }
    }

    /// Multiplier applied to baseline token forecast.
    public var tokenMultiplier: Double {
        switch self {
        case .diligence:       return 1.20
        case .debt:            return 0.85
        case .creative:        return 1.35
        case .security:        return 1.15
        case .accretive:       return 0.75
        case .modernization:   return 1.10
        case .uiImprovement:   return 0.90
        case .costEfficiency:  return 0.65
        }
    }
}

// MARK: Mission depth

public enum MissionConsoleDepth: String, CaseIterable, Identifiable, Sendable, Hashable {
    case light
    case standard
    case deep

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .light:    return "Light"
        case .standard: return "Standard"
        case .deep:     return "Deep"
        }
    }

    public var subtitle: String {
        switch self {
        case .light:    return "Surface-level pass. Fast."
        case .standard: return "Full investigation. Default."
        case .deep:     return "Exhaustive. Every thread tied."
        }
    }

    /// Cost coefficient (× tokens × duration).
    public var coefficient: Double {
        switch self {
        case .light:    return 0.45
        case .standard: return 1.00
        case .deep:     return 2.25
        }
    }

    public var ordinal: Int {
        switch self {
        case .light:    return 0
        case .standard: return 1
        case .deep:     return 2
        }
    }
}

// MARK: Approval mode

public enum MissionConsoleApprovalMode: String, CaseIterable, Identifiable, Sendable, Hashable {
    case existingPolicy = "existing_policy"
    case requireApproval = "require_approval"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .existingPolicy:  return "Honor existing policy"
        case .requireApproval: return "Require my approval"
        }
    }

    public var caption: String {
        switch self {
        case .existingPolicy:  return "Use the agent's standard approval rules for shell + edits."
        case .requireApproval: return "Pause mid-flight for every command and edit until I approve."
        }
    }
}

// MARK: Runtime model

public struct MissionConsoleRuntime: Identifiable, Hashable, Sendable {
    public typealias ID = String

    public enum Availability: String, Sendable {
        case online
        case offline
        case unknown
    }

    public let id: ID
    public let displayName: String
    /// 2–4 character monospaced call-sign (e.g. "CLD", "CDX", "HRM", "OCL", "PI").
    public let callSign: String
    public let provider: AgentProvider
    public let availability: Availability
    /// Median burn for the trailing window in USD, or nil if no history.
    public let recentMedianBurnUSD: Double?
    /// Number of completed missions in the trailing window.
    public let recentSampleSize: Int
    /// Optional one-line tagline shown beneath the call-sign.
    public let tagline: String?
    /// Pricing factor used in the burn forecast. Hosts can override per model.
    public let pricingFactor: Double

    public init(
        id: ID,
        displayName: String,
        callSign: String,
        provider: AgentProvider,
        availability: Availability = .unknown,
        recentMedianBurnUSD: Double? = nil,
        recentSampleSize: Int = 0,
        tagline: String? = nil,
        pricingFactor: Double = 1.0
    ) {
        self.id = id
        self.displayName = displayName
        self.callSign = callSign
        self.provider = provider
        self.availability = availability
        self.recentMedianBurnUSD = recentMedianBurnUSD
        self.recentSampleSize = recentSampleSize
        self.tagline = tagline
        self.pricingFactor = pricingFactor
    }

    public static let auto = MissionConsoleRuntime(
        id: "auto",
        displayName: "Auto-route",
        callSign: "AUTO",
        provider: .factory,
        availability: .online,
        recentMedianBurnUSD: nil,
        recentSampleSize: 0,
        tagline: "Let the planner pick the best agent for this kind.",
        pricingFactor: 1.0
    )
}

// MARK: Active mission tile

public struct MissionConsoleActiveTile: Identifiable, Hashable, Sendable {
    public enum Phase: String, Sendable {
        case queued
        case starting
        case running
        case tooling
        case awaitingApproval
        case streaming
        case completing
        case completed
        case failed
        case blocked
        case macOffline
        case cancelled

        public var displayLabel: String {
            switch self {
            case .queued:           return "Queued"
            case .starting:         return "Starting"
            case .running:          return "Running"
            case .tooling:          return "Tooling"
            case .awaitingApproval: return "Awaiting approval"
            case .streaming:        return "Streaming"
            case .completing:       return "Completing"
            case .completed:        return "Completed"
            case .failed:           return "Failed"
            case .blocked:          return "Blocked"
            case .macOffline:       return "Mac offline"
            case .cancelled:        return "Cancelled"
            }
        }

        public var isLive: Bool {
            switch self {
            case .queued, .starting, .running, .tooling, .streaming, .completing, .awaitingApproval:
                return true
            case .completed, .failed, .blocked, .macOffline, .cancelled:
                return false
            }
        }

        public var isProblem: Bool {
            switch self {
            case .failed, .blocked, .macOffline, .cancelled:
                return true
            default:
                return false
            }
        }
    }

    public let id: String
    public let title: String
    public let runtimeID: MissionConsoleRuntime.ID?
    public let runtimeDisplayLabel: String
    public let phase: Phase
    public let phaseDetail: String?
    public let currentToolName: String?
    public let lastEventSnippet: String?
    public let startedAt: Date?
    public let burnSoFarUSD: Double
    /// Optional progress fraction (0–1). Nil when unknown.
    public let progressFraction: Double?
    public let approvalPending: Bool

    public init(
        id: String,
        title: String,
        runtimeID: MissionConsoleRuntime.ID?,
        runtimeDisplayLabel: String,
        phase: Phase,
        phaseDetail: String? = nil,
        currentToolName: String? = nil,
        lastEventSnippet: String? = nil,
        startedAt: Date? = nil,
        burnSoFarUSD: Double = 0,
        progressFraction: Double? = nil,
        approvalPending: Bool = false
    ) {
        self.id = id
        self.title = title
        self.runtimeID = runtimeID
        self.runtimeDisplayLabel = runtimeDisplayLabel
        self.phase = phase
        self.phaseDetail = phaseDetail
        self.currentToolName = currentToolName
        self.lastEventSnippet = lastEventSnippet
        self.startedAt = startedAt
        self.burnSoFarUSD = burnSoFarUSD
        self.progressFraction = progressFraction
        self.approvalPending = approvalPending
    }
}

// MARK: Activity ticker entry

public struct MissionConsoleTickerEntry: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable {
        case status
        case toolCall
        case toolResult
        case llmResponse
        case finalAnswer
        case changedFile
        case artifact
        case error
        case approval
    }

    public let id: String
    public let timestamp: Date
    public let kind: Kind
    public let phase: String
    public let title: String?
    public let message: String
    public let toolName: String?
    public let pathDetail: String?
    public let missionID: String?
    public let runtimeID: MissionConsoleRuntime.ID?
    public let isError: Bool

    public init(
        id: String,
        timestamp: Date,
        kind: Kind,
        phase: String,
        title: String?,
        message: String,
        toolName: String? = nil,
        pathDetail: String? = nil,
        missionID: String? = nil,
        runtimeID: MissionConsoleRuntime.ID? = nil,
        isError: Bool = false
    ) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.phase = phase
        self.title = title
        self.message = message
        self.toolName = toolName
        self.pathDetail = pathDetail
        self.missionID = missionID
        self.runtimeID = runtimeID
        self.isError = isError
    }
}

// MARK: Approval ask

public struct MissionConsoleApprovalAsk: Identifiable, Hashable, Sendable {
    public let id: String
    public let missionID: String
    public let title: String
    public let message: String
    public let runtimeID: MissionConsoleRuntime.ID?
    public let runtimeDisplayLabel: String
    public let requestedAt: Date

    public init(
        id: String,
        missionID: String,
        title: String,
        message: String,
        runtimeID: MissionConsoleRuntime.ID?,
        runtimeDisplayLabel: String,
        requestedAt: Date
    ) {
        self.id = id
        self.missionID = missionID
        self.title = title
        self.message = message
        self.runtimeID = runtimeID
        self.runtimeDisplayLabel = runtimeDisplayLabel
        self.requestedAt = requestedAt
    }
}

// MARK: Forecast

public struct MissionConsoleForecast: Equatable, Sendable {
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

    public static let zero = MissionConsoleForecast(
        tokensLow: 0, tokensHigh: 0,
        costLowUSD: 0, costHighUSD: 0,
        etaLow: 0, etaHigh: 0
    )
}

// MARK: Dispatch request envelope

public struct MissionConsoleDispatchRequest: Sendable, Hashable {
    public var title: String
    public var prompt: String
    public var kind: MissionConsoleKind
    public var runtimeID: MissionConsoleRuntime.ID
    public var targetProject: String?
    public var depth: MissionConsoleDepth
    public var approvalMode: MissionConsoleApprovalMode
    public var commandsAllowed: Bool
    public var fileEditsAllowed: Bool

    public init(
        title: String,
        prompt: String,
        kind: MissionConsoleKind,
        runtimeID: MissionConsoleRuntime.ID,
        targetProject: String?,
        depth: MissionConsoleDepth,
        approvalMode: MissionConsoleApprovalMode,
        commandsAllowed: Bool,
        fileEditsAllowed: Bool
    ) {
        self.title = title
        self.prompt = prompt
        self.kind = kind
        self.runtimeID = runtimeID
        self.targetProject = targetProject
        self.depth = depth
        self.approvalMode = approvalMode
        self.commandsAllowed = commandsAllowed
        self.fileEditsAllowed = fileEditsAllowed
    }
}

// MARK: System health

public struct MissionConsoleSystemHealth: Equatable, Sendable {
    public enum DaemonState: String, Sendable {
        case live
        case stale
        case macOffline
        case unknown
    }

    public let daemonState: DaemonState
    public let lastRefresh: Date?
    public let openMissions: Int
    public let queuedMissions: Int
    public let blockedMissions: Int
    public let burnTodayUSD: Double
    public let burnPerHourUSD: Double
    public let onlineRuntimes: Int
    public let totalRuntimes: Int

    public init(
        daemonState: DaemonState,
        lastRefresh: Date?,
        openMissions: Int,
        queuedMissions: Int,
        blockedMissions: Int,
        burnTodayUSD: Double,
        burnPerHourUSD: Double,
        onlineRuntimes: Int,
        totalRuntimes: Int
    ) {
        self.daemonState = daemonState
        self.lastRefresh = lastRefresh
        self.openMissions = openMissions
        self.queuedMissions = queuedMissions
        self.blockedMissions = blockedMissions
        self.burnTodayUSD = burnTodayUSD
        self.burnPerHourUSD = burnPerHourUSD
        self.onlineRuntimes = onlineRuntimes
        self.totalRuntimes = totalRuntimes
    }

    public static let empty = MissionConsoleSystemHealth(
        daemonState: .unknown,
        lastRefresh: nil,
        openMissions: 0,
        queuedMissions: 0,
        blockedMissions: 0,
        burnTodayUSD: 0,
        burnPerHourUSD: 0,
        onlineRuntimes: 0,
        totalRuntimes: 0
    )
}

// MARK: Console snapshot

public struct MissionConsoleSnapshot: Sendable {
    public let health: MissionConsoleSystemHealth
    public let runtimes: [MissionConsoleRuntime]
    public let activeTiles: [MissionConsoleActiveTile]
    public let recentTicker: [MissionConsoleTickerEntry]
    public let approvalAsks: [MissionConsoleApprovalAsk]
    public let knownProjects: [String]
    public let recentProjects: [String]
    public let burnHistorySpark: [Double]

    public init(
        health: MissionConsoleSystemHealth,
        runtimes: [MissionConsoleRuntime],
        activeTiles: [MissionConsoleActiveTile],
        recentTicker: [MissionConsoleTickerEntry],
        approvalAsks: [MissionConsoleApprovalAsk],
        knownProjects: [String],
        recentProjects: [String],
        burnHistorySpark: [Double] = []
    ) {
        self.health = health
        self.runtimes = runtimes
        self.activeTiles = activeTiles
        self.recentTicker = recentTicker
        self.approvalAsks = approvalAsks
        self.knownProjects = knownProjects
        self.recentProjects = recentProjects
        self.burnHistorySpark = burnHistorySpark
    }

    public static let empty = MissionConsoleSnapshot(
        health: .empty,
        runtimes: [],
        activeTiles: [],
        recentTicker: [],
        approvalAsks: [],
        knownProjects: [],
        recentProjects: []
    )
}

// MARK: Dispatch outcome

public enum MissionConsoleDispatchOutcome: Sendable {
    case dispatched(missionID: String)
    case failed(message: String)
}

// MARK: Host services (platform-side adapter)

/// Implemented by each platform host (iOS / macOS). The shared
/// `MissionControlConsoleView` reads from `snapshot` and emits dispatches /
/// approvals through these callbacks. Hosts adapt their native services
/// (`CLIAgentMissionDispatcher` on iOS, `OpenBurnBarOperatingLayer` on macOS)
/// to this minimal contract.
@MainActor
public protocol MissionConsoleHost: AnyObject, Observable {
    var snapshot: MissionConsoleSnapshot { get }
    /// Most recently-dispatched mission ID (for the lift-off transition).
    var lastDispatchedMissionID: String? { get }
    /// Whether a dispatch is currently in-flight.
    var isDispatching: Bool { get }
    /// Surfaced when dispatch or approval calls fail.
    var inlineError: String? { get }

    func dispatch(_ request: MissionConsoleDispatchRequest) async -> MissionConsoleDispatchOutcome
    func respond(to ask: MissionConsoleApprovalAsk, approve: Bool) async
    func clearInlineError()
    /// Pull current state — called when the console opens.
    func refresh() async
}

// MARK: Forecast computation

public enum MissionConsoleForecastComputer {
    /// Compute a forecast band from a draft. Pure function so tests can lock
    /// in the math regardless of platform.
    public static func forecast(
        for draft: MissionConsoleDispatchRequest,
        runtime: MissionConsoleRuntime
    ) -> MissionConsoleForecast {
        let baselineTokens = 12_000.0
        let kindMul = draft.kind.tokenMultiplier
        let depthMul = draft.depth.coefficient
        let runtimeMul = runtime.pricingFactor

        let centerTokens = baselineTokens * kindMul * depthMul * runtimeMul
        // ±30% band — wider for "deep" / "creative" where output variance is high.
        let widen = (draft.depth == .deep || draft.kind == .creative) ? 0.45 : 0.30
        let tokensLow = Int((centerTokens * (1.0 - widen)).rounded())
        let tokensHigh = Int((centerTokens * (1.0 + widen)).rounded())

        // Cost: assume $3 per 1M input + $15 per 1M output, 70/30 split, then
        // scaled by runtime.pricingFactor and the historical median (when
        // present) to soak up reality.
        let mixCost: Double = (3.0 * 0.7 + 15.0 * 0.3) / 1_000_000.0
        var centerCost = centerTokens * mixCost
        if let median = runtime.recentMedianBurnUSD, median > 0 {
            // Blend forecast with historical median 50/50.
            centerCost = (centerCost + median) / 2.0
        }
        let costLow = max(0, centerCost * (1.0 - widen))
        let costHigh = centerCost * (1.0 + widen)

        // ETA: standard runs ~2min/k-tokens; tune by depth.
        let centerETA: TimeInterval = (centerTokens / 1000.0) * 120.0 * 0.6
        let etaLow = max(0, centerETA * (1.0 - widen))
        let etaHigh = centerETA * (1.0 + widen)

        return MissionConsoleForecast(
            tokensLow: tokensLow,
            tokensHigh: tokensHigh,
            costLowUSD: costLow,
            costHighUSD: costHigh,
            etaLow: etaLow,
            etaHigh: etaHigh
        )
    }
}

// MARK: Number / time formatting helpers (shared across console views)

public enum MissionConsoleFormatting {
    public static func cost(_ usd: Double, precise: Bool = false) -> String {
        if !precise && usd >= 100 {
            return String(format: "$%.0f", usd)
        }
        if precise || usd < 1 {
            return String(format: "$%.4f", usd)
        }
        return String(format: "$%.2f", usd)
    }

    public static func costRange(_ low: Double, _ high: Double) -> String {
        "\(cost(low))–\(cost(high))"
    }

    public static func tokens(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000.0)
        }
        if count >= 1_000 {
            return String(format: "%.1fk", Double(count) / 1_000.0)
        }
        return "\(count)"
    }

    public static func tokenRange(_ low: Int, _ high: Int) -> String {
        "\(tokens(low))–\(tokens(high))"
    }

    public static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }

    public static func durationRange(_ low: TimeInterval, _ high: TimeInterval) -> String {
        "\(duration(low))–\(duration(high))"
    }

    public static func relativeTime(_ date: Date, reference: Date = Date()) -> String {
        let delta = reference.timeIntervalSince(date)
        if delta < 5  { return "just now" }
        if delta < 60 { return "\(Int(delta))s ago" }
        if delta < 3_600 { return "\(Int(delta / 60))m ago" }
        if delta < 86_400 { return "\(Int(delta / 3_600))h ago" }
        return "\(Int(delta / 86_400))d ago"
    }
}
