import Foundation

/// Cross-platform contract for a generated Insights analysis.
///
/// `InsightCanvas` remains the visual workspace contract. This type is the
/// intelligence contract above it: the model must explain what changed, why it
/// matters, what evidence supports it, and which widgets can be pinned.
public struct InsightAnalysisResult: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var requestID: UUID
    public var schemaVersion: Int
    public var generatedAt: Date
    public var platform: InsightAnalysisPlatform
    public var timeWindow: InsightTimeWindow
    public var executiveSummary: String
    public var modelTag: InsightModelTag
    public var contextBudget: InsightContextBudgetReport
    public var findings: [InsightFinding]
    public var anomalies: [InsightAnomaly]
    public var recommendations: [InsightRecommendation]
    public var generatedWidgets: [InsightGeneratedWidget]
    public var followUpQuestions: [InsightFollowUpQuestion]
    public var citations: [InsightCitation]
    /// Token accounting reported by the gateway. Absent for narrative-tier
    /// callers that don't surface usage.
    public var tokenUsage: InsightTokenUsage?
    /// USD cost estimate (gateway-supplied or derived from `tokenUsage`).
    public var estimatedCostUSD: Double?
    /// Audit entry identifier the engine wrote alongside this result.
    public var auditID: UUID?
    public var resultHash: String

    public static let currentSchemaVersion = 1

    public init(
        id: UUID = UUID(),
        requestID: UUID,
        schemaVersion: Int = InsightAnalysisResult.currentSchemaVersion,
        generatedAt: Date = Date(),
        platform: InsightAnalysisPlatform,
        timeWindow: InsightTimeWindow,
        executiveSummary: String,
        modelTag: InsightModelTag,
        contextBudget: InsightContextBudgetReport,
        findings: [InsightFinding] = [],
        anomalies: [InsightAnomaly] = [],
        recommendations: [InsightRecommendation] = [],
        generatedWidgets: [InsightGeneratedWidget] = [],
        followUpQuestions: [InsightFollowUpQuestion] = [],
        citations: [InsightCitation] = [],
        tokenUsage: InsightTokenUsage? = nil,
        estimatedCostUSD: Double? = nil,
        auditID: UUID? = nil,
        resultHash: String = ""
    ) {
        self.id = id
        self.requestID = requestID
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.platform = platform
        self.timeWindow = timeWindow
        self.executiveSummary = executiveSummary
        self.modelTag = modelTag
        self.contextBudget = contextBudget
        self.findings = findings
        self.anomalies = anomalies
        self.recommendations = recommendations
        self.generatedWidgets = generatedWidgets
        self.followUpQuestions = followUpQuestions
        self.citations = citations
        self.tokenUsage = tokenUsage
        self.estimatedCostUSD = estimatedCostUSD
        self.auditID = auditID
        self.resultHash = resultHash
    }
}

public struct InsightAnalysisRequest: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var prompt: String
    public var context: InsightAnalysisContext
    public var currentCanvas: InsightCanvas?
    public var selectedModel: InsightModelTag
    public var instruction: Instruction
    public var allowDeepTranscriptAnalysis: Bool
    public var maxGeneratedWidgets: Int

    public init(
        id: UUID = UUID(),
        prompt: String,
        context: InsightAnalysisContext,
        currentCanvas: InsightCanvas? = nil,
        selectedModel: InsightModelTag,
        instruction: Instruction = .defaultBrief,
        allowDeepTranscriptAnalysis: Bool = false,
        maxGeneratedWidgets: Int = 8
    ) {
        self.id = id
        self.prompt = prompt
        self.context = context
        self.currentCanvas = currentCanvas
        self.selectedModel = selectedModel
        self.instruction = instruction
        self.allowDeepTranscriptAnalysis = allowDeepTranscriptAnalysis
        self.maxGeneratedWidgets = maxGeneratedWidgets
    }

    public enum Instruction: String, Codable, Hashable, Sendable, CaseIterable {
        case defaultBrief
        case answerFollowUp
        case generateReport
        case updateCanvas
    }
}

public struct InsightAnalysisContext: Codable, Hashable, Sendable {
    public var digest: InsightDigest
    public var evidenceIndex: [InsightEvidence]
    public var budgetReport: InsightContextBudgetReport
    public var priorRunSummaries: [String]
    /// Sanitized, cross-device evidence exported by a platform with deeper
    /// local access. Mobile shells use these packs to reach macOS-level
    /// insight depth without reading Mac disk logs or raw transcripts.
    public var evidencePacks: [InsightEvidencePack]

    public init(
        digest: InsightDigest,
        evidenceIndex: [InsightEvidence],
        budgetReport: InsightContextBudgetReport,
        priorRunSummaries: [String] = [],
        evidencePacks: [InsightEvidencePack] = []
    ) {
        self.digest = digest
        self.evidenceIndex = evidenceIndex
        self.budgetReport = budgetReport
        self.priorRunSummaries = priorRunSummaries
        self.evidencePacks = evidencePacks
    }
}

public struct InsightEvidence: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var citation: InsightCitation
    public var source: String
    public var summary: String
    public var numericValue: Double?

    public init(
        id: String,
        citation: InsightCitation,
        source: String,
        summary: String,
        numericValue: Double? = nil
    ) {
        self.id = id
        self.citation = citation
        self.source = source
        self.summary = summary
        self.numericValue = numericValue
    }
}

public struct InsightEvidencePack: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var sourcePlatform: InsightAnalysisPlatform
    public var generatedAt: Date
    public var timeWindow: InsightTimeWindow
    public var includedDataSources: [String]
    public var budgetReport: InsightContextBudgetReport
    public var evidence: [InsightEvidence]
    public var summary: String
    public var contentHash: String
    public var deepTranscriptIncluded: Bool

    public init(
        id: String = UUID().uuidString,
        sourcePlatform: InsightAnalysisPlatform,
        generatedAt: Date = Date(),
        timeWindow: InsightTimeWindow,
        includedDataSources: [String],
        budgetReport: InsightContextBudgetReport,
        evidence: [InsightEvidence],
        summary: String,
        contentHash: String,
        deepTranscriptIncluded: Bool = false
    ) {
        self.id = id
        self.sourcePlatform = sourcePlatform
        self.generatedAt = generatedAt
        self.timeWindow = timeWindow
        self.includedDataSources = includedDataSources
        self.budgetReport = budgetReport
        self.evidence = evidence
        self.summary = summary
        self.contentHash = contentHash
        self.deepTranscriptIncluded = deepTranscriptIncluded
    }
}

public struct InsightPlatformCapabilityReport: Codable, Hashable, Sendable {
    public var platform: InsightAnalysisPlatform
    public var providerFamilies: [InsightProviderFamily]
    public var includedDataSources: [String]
    public var supportsDeepLocalLogs: Bool
    public var supportsSyncedEvidencePacks: Bool
    public var supportsModelSelection: Bool
    public var supportsConversation: Bool
    public var supportsGeneratedWidgetPinning: Bool
    public var supportsAuditAndCache: Bool
    public var gaps: [String]

    public init(
        platform: InsightAnalysisPlatform,
        providerFamilies: [InsightProviderFamily],
        includedDataSources: [String],
        supportsDeepLocalLogs: Bool,
        supportsSyncedEvidencePacks: Bool,
        supportsModelSelection: Bool = true,
        supportsConversation: Bool = true,
        supportsGeneratedWidgetPinning: Bool = true,
        supportsAuditAndCache: Bool = true,
        gaps: [String] = []
    ) {
        self.platform = platform
        self.providerFamilies = providerFamilies
        self.includedDataSources = includedDataSources
        self.supportsDeepLocalLogs = supportsDeepLocalLogs
        self.supportsSyncedEvidencePacks = supportsSyncedEvidencePacks
        self.supportsModelSelection = supportsModelSelection
        self.supportsConversation = supportsConversation
        self.supportsGeneratedWidgetPinning = supportsGeneratedWidgetPinning
        self.supportsAuditAndCache = supportsAuditAndCache
        self.gaps = gaps
    }
}

public struct InsightContextBudgetReport: Codable, Hashable, Sendable {
    public var maxEncodedBytes: Int
    public var encodedBytes: Int
    public var estimatedPromptTokens: Int
    public var includedDataSources: [String]
    public var truncatedDataSources: [String]
    public var truncationSummary: String

    public init(
        maxEncodedBytes: Int = InsightDigest.maxEncodedBytes,
        encodedBytes: Int,
        estimatedPromptTokens: Int,
        includedDataSources: [String],
        truncatedDataSources: [String] = [],
        truncationSummary: String = "No truncation."
    ) {
        self.maxEncodedBytes = maxEncodedBytes
        self.encodedBytes = encodedBytes
        self.estimatedPromptTokens = estimatedPromptTokens
        self.includedDataSources = includedDataSources
        self.truncatedDataSources = truncatedDataSources
        self.truncationSummary = truncationSummary
    }
}

public struct InsightFinding: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    public var whyItMatters: String
    public var evidence: [InsightCitation]
    public var confidence: InsightConfidence
    public var severity: InsightSeverity
    public var recommendedAction: String
    public var generatedWidgetID: UUID?

    public init(
        id: UUID = UUID(),
        title: String,
        whyItMatters: String,
        evidence: [InsightCitation],
        confidence: InsightConfidence,
        severity: InsightSeverity = .medium,
        recommendedAction: String,
        generatedWidgetID: UUID? = nil
    ) {
        self.id = id
        self.title = title
        self.whyItMatters = whyItMatters
        self.evidence = evidence
        self.confidence = confidence
        self.severity = severity
        self.recommendedAction = recommendedAction
        self.generatedWidgetID = generatedWidgetID
    }
}

public struct InsightAnomaly: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    public var occurredAt: Date?
    public var detail: String
    public var score: Double
    public var evidence: [InsightCitation]
    public var confidence: InsightConfidence

    public init(
        id: UUID = UUID(),
        title: String,
        occurredAt: Date?,
        detail: String,
        score: Double,
        evidence: [InsightCitation],
        confidence: InsightConfidence
    ) {
        self.id = id
        self.title = title
        self.occurredAt = occurredAt
        self.detail = detail
        self.score = score
        self.evidence = evidence
        self.confidence = confidence
    }
}

public struct InsightRecommendation: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    public var rationale: String
    public var recommendedAction: String
    public var estimatedImpact: String?
    public var evidence: [InsightCitation]
    public var confidence: InsightConfidence
    public var severity: InsightSeverity

    public init(
        id: UUID = UUID(),
        title: String,
        rationale: String,
        recommendedAction: String,
        estimatedImpact: String? = nil,
        evidence: [InsightCitation],
        confidence: InsightConfidence,
        severity: InsightSeverity = .medium
    ) {
        self.id = id
        self.title = title
        self.rationale = rationale
        self.recommendedAction = recommendedAction
        self.estimatedImpact = estimatedImpact
        self.evidence = evidence
        self.confidence = confidence
        self.severity = severity
    }
}

public struct InsightGeneratedWidget: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var widget: InsightWidget
    public var reason: String
    public var citations: [InsightCitation]

    public init(
        id: UUID = UUID(),
        widget: InsightWidget,
        reason: String,
        citations: [InsightCitation]
    ) {
        self.id = id
        self.widget = widget
        self.reason = reason
        self.citations = citations
    }
}

public struct InsightFollowUpQuestion: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var question: String
    public var rationale: String?

    public init(id: UUID = UUID(), question: String, rationale: String? = nil) {
        self.id = id
        self.question = question
        self.rationale = rationale
    }
}

public struct InsightAnalysisAuditEntry: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var requestID: UUID
    public var platform: InsightAnalysisPlatform
    public var selectedModel: InsightModelTag
    public var egressTier: InsightEgressTier
    public var timeWindow: InsightTimeWindow
    public var contextBudget: InsightContextBudgetReport
    public var includedDataSources: [String]
    public var truncationSummary: String
    public var promptHash: String
    public var resultHash: String
    public var status: Status
    public var startedAt: Date
    public var completedAt: Date?
    public var errorDescription: String?
    public var tokenUsage: InsightTokenUsage?
    public var estimatedCostUSD: Double?
    public var ranAt: Date

    public init(
        id: UUID = UUID(),
        requestID: UUID,
        platform: InsightAnalysisPlatform,
        selectedModel: InsightModelTag,
        egressTier: InsightEgressTier,
        timeWindow: InsightTimeWindow,
        contextBudget: InsightContextBudgetReport,
        includedDataSources: [String],
        truncationSummary: String,
        promptHash: String,
        resultHash: String,
        status: Status,
        startedAt: Date = Date(),
        completedAt: Date? = nil,
        errorDescription: String? = nil,
        tokenUsage: InsightTokenUsage? = nil,
        estimatedCostUSD: Double? = nil,
        ranAt: Date = Date()
    ) {
        self.id = id
        self.requestID = requestID
        self.platform = platform
        self.selectedModel = selectedModel
        self.egressTier = egressTier
        self.timeWindow = timeWindow
        self.contextBudget = contextBudget
        self.includedDataSources = includedDataSources
        self.truncationSummary = truncationSummary
        self.promptHash = promptHash
        self.resultHash = resultHash
        self.status = status
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.errorDescription = errorDescription
        self.tokenUsage = tokenUsage
        self.estimatedCostUSD = estimatedCostUSD
        self.ranAt = ranAt
    }

    public enum Status: String, Codable, Hashable, Sendable, CaseIterable {
        case started
        case succeeded
        case partial
        case modelUnavailable
        case schemaViolation
        case cancelled
        case failed
    }
}

public struct InsightModelPreference: Codable, Hashable, Sendable {
    public var mode: Mode
    public var explicitModel: InsightModelTag?
    /// When true, the picker only surfaces models with `egressTier == .localOnly`
    /// and the engine refuses to dispatch to anything else.
    public var restrictToLocalOnly: Bool
    /// Hard ceiling for routing — the engine will never exceed this tier.
    public var maxEgressTier: InsightEgressTier?
    /// Whether the user has accepted the deep-transcript opt-in. The composer
    /// shows the larger-budget warning when this is true.
    public var deepTranscriptOptIn: Bool

    public init(
        mode: Mode = .automatic,
        explicitModel: InsightModelTag? = nil,
        restrictToLocalOnly: Bool = false,
        maxEgressTier: InsightEgressTier? = nil,
        deepTranscriptOptIn: Bool = false
    ) {
        self.mode = mode
        self.explicitModel = explicitModel
        self.restrictToLocalOnly = restrictToLocalOnly
        self.maxEgressTier = maxEgressTier
        self.deepTranscriptOptIn = deepTranscriptOptIn
    }

    public enum Mode: String, Codable, Hashable, Sendable, CaseIterable {
        case automatic
        case explicit
    }

    public static let `default` = InsightModelPreference()
}

public enum InsightAnalysisPlatform: String, Codable, Hashable, Sendable, CaseIterable {
    case macOS
    case iOS
    case iPadOS
    case android
}

public enum InsightConfidence: String, Codable, Hashable, Sendable, CaseIterable {
    case low
    case medium
    case high
}

public enum InsightSeverity: String, Codable, Hashable, Sendable, CaseIterable {
    case info
    case low
    case medium
    case high
    case critical
}
