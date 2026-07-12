import Foundation

/// The fully-resolved Insights payload for a single `AgentInsightsScope`.
///
/// Every platform renders the same struct. Cross-platform visual parity
/// follows from the fact that every surface gets the *exact same data*
/// in the same order. macOS and iPad render more of it (inspector,
/// templates, compare) but never different data.
public struct AgentInsightsBundle: Hashable, Sendable {
    public let scope: AgentInsightsScope
    public let header: AgentInsightsHeader
    public let kpis: AgentInsightsKPIStrip
    public let brief: InsightAnalysisResult?
    public let canvases: [InsightCanvas]
    public let missions: [InsightMissionCandidate]
    public let auditTrail: [InsightAnalysisAuditEntry]
    public let generatedAt: Date

    public init(
        scope: AgentInsightsScope,
        header: AgentInsightsHeader,
        kpis: AgentInsightsKPIStrip,
        brief: InsightAnalysisResult? = nil,
        canvases: [InsightCanvas] = [],
        missions: [InsightMissionCandidate] = [],
        auditTrail: [InsightAnalysisAuditEntry] = [],
        generatedAt: Date = Date()
    ) {
        self.scope = scope
        self.header = header
        self.kpis = kpis
        self.brief = brief
        self.canvases = canvases
        self.missions = missions
        self.auditTrail = auditTrail
        self.generatedAt = generatedAt
    }

    /// True when there is no usage signal *and* no canvas to render.
    /// Used by the UI to choose an empty/onboarding state.
    public var isEmpty: Bool {
        kpis.sessions.raw == 0 && canvases.isEmpty && brief == nil
    }
}

// MARK: - Header

public struct AgentInsightsHeader: Hashable, Sendable {
    public let provider: AgentProvider?
    public let title: String
    public let subtitle: String?
    public let symbolName: String
    public let status: Status
    public let lastSeen: Date?
    /// Top three model identifiers ordered by token volume in the window.
    public let modelLineup: [String]

    public init(
        provider: AgentProvider? = nil,
        title: String,
        subtitle: String? = nil,
        symbolName: String,
        status: Status = .unconfigured,
        lastSeen: Date? = nil,
        modelLineup: [String] = []
    ) {
        self.provider = provider
        self.title = title
        self.subtitle = subtitle
        self.symbolName = symbolName
        self.status = status
        self.lastSeen = lastSeen
        self.modelLineup = modelLineup
    }

    public enum Status: String, Hashable, Sendable, CaseIterable {
        case active
        case idle
        case dormant
        case unconfigured

        public var displayLabel: String {
            switch self {
            case .active: return "Active"
            case .idle: return "Idle"
            case .dormant: return "Dormant"
            case .unconfigured: return "Not connected"
            }
        }
    }
}

// MARK: - KPI strip

public struct AgentInsightsKPIStrip: Hashable, Sendable {
    public let spend: KPI
    public let tokens: KPI
    public let sessions: KPI
    public let anomalyScore: KPI

    public init(spend: KPI, tokens: KPI, sessions: KPI, anomalyScore: KPI) {
        self.spend = spend
        self.tokens = tokens
        self.sessions = sessions
        self.anomalyScore = anomalyScore
    }

    /// Fixed display order for cross-platform parity.
    public var ordered: [KPI] { [spend, tokens, sessions, anomalyScore] }

    public struct KPI: Hashable, Sendable, Identifiable {
        public let id: String
        public let label: String
        public let valueText: String
        public let trendText: String?
        public let trendDirection: TrendDirection
        public let raw: Double
        public let symbolName: String

        public init(
            id: String,
            label: String,
            valueText: String,
            trendText: String? = nil,
            trendDirection: TrendDirection = .flat,
            raw: Double,
            symbolName: String
        ) {
            self.id = id
            self.label = label
            self.valueText = valueText
            self.trendText = trendText
            self.trendDirection = trendDirection
            self.raw = raw
            self.symbolName = symbolName
        }

        public enum TrendDirection: String, Hashable, Sendable {
            case up, down, flat
        }
    }
}
