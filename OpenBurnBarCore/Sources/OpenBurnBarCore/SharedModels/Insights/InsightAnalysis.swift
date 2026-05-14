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
    public var missionCandidates: [InsightMissionCandidate]
    public var generatedWidgets: [InsightGeneratedWidget]
    public var followUpQuestions: [InsightFollowUpQuestion]
    public var citations: [InsightCitation]
    /// Direct Q&A reply rendered above the editorial brief. Present
    /// whenever the result was produced from a user prompt (a tapped
    /// follow-up question, a citation chip, or the inline composer);
    /// `nil` for the default first-launch brief. The reply gives the
    /// user an unambiguous "you asked X, here is the answer" surface
    /// so a follow-up tap is never invisible.
    public var briefingAnswer: InsightBriefingAnswer?
    /// Token accounting reported by the gateway. Absent for narrative-tier
    /// callers that don't surface usage.
    public var tokenUsage: InsightTokenUsage?
    /// USD cost estimate (gateway-supplied or derived from `tokenUsage`).
    public var estimatedCostUSD: Double?
    /// Audit entry identifier the engine wrote alongside this result.
    public var auditID: UUID?
    public var resultHash: String

    public static let currentSchemaVersion = 1

    private enum CodingKeys: String, CodingKey {
        case id
        case requestID
        case schemaVersion
        case generatedAt
        case platform
        case timeWindow
        case executiveSummary
        case modelTag
        case contextBudget
        case findings
        case anomalies
        case recommendations
        case missionCandidates
        case generatedWidgets
        case followUpQuestions
        case citations
        case briefingAnswer
        case tokenUsage
        case estimatedCostUSD
        case auditID
        case resultHash
    }

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
        missionCandidates: [InsightMissionCandidate] = [],
        generatedWidgets: [InsightGeneratedWidget] = [],
        followUpQuestions: [InsightFollowUpQuestion] = [],
        citations: [InsightCitation] = [],
        briefingAnswer: InsightBriefingAnswer? = nil,
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
        self.missionCandidates = missionCandidates
        self.generatedWidgets = generatedWidgets
        self.followUpQuestions = followUpQuestions
        self.citations = citations
        self.briefingAnswer = briefingAnswer
        self.tokenUsage = tokenUsage
        self.estimatedCostUSD = estimatedCostUSD
        self.auditID = auditID
        self.resultHash = resultHash
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.requestID = try container.decode(UUID.self, forKey: .requestID)
        self.schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        self.generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        self.platform = try container.decode(InsightAnalysisPlatform.self, forKey: .platform)
        self.timeWindow = try container.decode(InsightTimeWindow.self, forKey: .timeWindow)
        self.executiveSummary = try container.decode(String.self, forKey: .executiveSummary)
        self.modelTag = try container.decode(InsightModelTag.self, forKey: .modelTag)
        self.contextBudget = try container.decode(InsightContextBudgetReport.self, forKey: .contextBudget)
        self.findings = try container.decodeIfPresent([InsightFinding].self, forKey: .findings) ?? []
        self.anomalies = try container.decodeIfPresent([InsightAnomaly].self, forKey: .anomalies) ?? []
        self.recommendations = try container.decodeIfPresent([InsightRecommendation].self, forKey: .recommendations) ?? []
        self.missionCandidates = try container.decodeIfPresent([InsightMissionCandidate].self, forKey: .missionCandidates) ?? []
        self.generatedWidgets = try container.decodeIfPresent([InsightGeneratedWidget].self, forKey: .generatedWidgets) ?? []
        self.followUpQuestions = try container.decodeIfPresent([InsightFollowUpQuestion].self, forKey: .followUpQuestions) ?? []
        self.citations = try container.decodeIfPresent([InsightCitation].self, forKey: .citations) ?? []
        self.briefingAnswer = try container.decodeIfPresent(InsightBriefingAnswer.self, forKey: .briefingAnswer)
        self.tokenUsage = try container.decodeIfPresent(InsightTokenUsage.self, forKey: .tokenUsage)
        self.estimatedCostUSD = try container.decodeIfPresent(Double.self, forKey: .estimatedCostUSD)
        self.auditID = try container.decodeIfPresent(UUID.self, forKey: .auditID)
        self.resultHash = try container.decodeIfPresent(String.self, forKey: .resultHash) ?? ""
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

/// Direct, conversational reply to the user's prompt. Surfaces above
/// the editorial brief as a `Q & A` card so a follow-up tap or a
/// composer message is *visibly* answered, not silently re-rendered.
///
/// `answer` carries the full multi-paragraph reply (LLM-generated when
/// a `userKey`-tier gateway is selected; deterministic and explicitly
/// labelled when the local rule engine is the only available
/// answerer). `bullets` are short data-grounded attestations the UI
/// renders as chips beneath the body — they prove the answer was
/// computed from the digest, not hallucinated.
public struct InsightBriefingAnswer: Codable, Hashable, Sendable, Identifiable {
    /// Provenance of the reply text — drives the badge that the UI
    /// renders next to the answer (`Local rules` vs. `<model name>`).
    public enum Source: String, Codable, Hashable, Sendable {
        /// Generated by an `InsightModelGateway` (Claude / OpenAI /
        /// Hermes etc.) using the privacy-bounded digest as context.
        case modelGateway
        /// Generated deterministically by the local rule engine —
        /// shown when the user is in privacy mode, when no remote
        /// gateway is configured, or when the gateway call failed
        /// and we degraded gracefully so the user still gets a reply.
        case localRules
    }

    public var id: UUID
    public var question: String
    public var answer: String
    public var bullets: [String]
    public var citations: [InsightCitation]
    /// Where the reply came from. Always rendered next to the answer
    /// so the user can trust the provenance at a glance.
    public var source: Source
    /// Display name of the model / engine that produced the reply
    /// (e.g. "Claude Sonnet 4.6", "Local rules"). Always shown.
    public var modelDisplayName: String
    /// `true` when the gateway path was attempted and failed; the UI
    /// surfaces a "Showing local fallback" hint so the user knows the
    /// remote engine wasn't reachable for this turn and offers Retry.
    public var isFallback: Bool

    public init(
        id: UUID = UUID(),
        question: String,
        answer: String,
        bullets: [String] = [],
        citations: [InsightCitation] = [],
        source: Source = .localRules,
        modelDisplayName: String = "Local rules",
        isFallback: Bool = false
    ) {
        self.id = id
        self.question = question
        self.answer = answer
        self.bullets = bullets
        self.citations = citations
        self.source = source
        self.modelDisplayName = modelDisplayName
        self.isFallback = isFallback
    }

    private enum CodingKeys: String, CodingKey {
        case id, question, answer, bullets, citations, source, modelDisplayName, isFallback
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        self.question = try c.decode(String.self, forKey: .question)
        self.answer = try c.decode(String.self, forKey: .answer)
        self.bullets = (try? c.decode([String].self, forKey: .bullets)) ?? []
        self.citations = (try? c.decode([InsightCitation].self, forKey: .citations)) ?? []
        self.source = (try? c.decode(Source.self, forKey: .source)) ?? .localRules
        self.modelDisplayName = (try? c.decode(String.self, forKey: .modelDisplayName)) ?? "Local rules"
        self.isFallback = (try? c.decode(Bool.self, forKey: .isFallback)) ?? false
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

public struct InsightMissionCandidate: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    public var summary: String
    public var projectID: String?
    public var projectDisplayName: String?
    public var lens: Lens
    public var priority: Priority
    public var confidence: InsightConfidence
    public var expectedImpact: String
    public var effort: Effort
    public var acceptanceCriteria: [String]
    public var sourceInsightIDs: [UUID]
    public var evidence: [InsightCitation]
    public var dispatchMetadata: [String: String]

    public init(
        id: UUID = UUID(),
        title: String,
        summary: String,
        projectID: String? = nil,
        projectDisplayName: String? = nil,
        lens: Lens,
        priority: Priority,
        confidence: InsightConfidence,
        expectedImpact: String,
        effort: Effort,
        acceptanceCriteria: [String],
        sourceInsightIDs: [UUID] = [],
        evidence: [InsightCitation],
        dispatchMetadata: [String: String] = [:]
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.projectID = projectID
        self.projectDisplayName = projectDisplayName
        self.lens = lens
        self.priority = priority
        self.confidence = confidence
        self.expectedImpact = expectedImpact
        self.effort = effort
        self.acceptanceCriteria = acceptanceCriteria
        self.sourceInsightIDs = sourceInsightIDs
        self.evidence = evidence
        self.dispatchMetadata = dispatchMetadata
    }

    public enum Lens: String, Codable, Hashable, Sendable, CaseIterable {
        case accretion
        case diligence
        case techDebt
        case routing
        case quota
        case focus
    }

    public enum Priority: String, Codable, Hashable, Sendable, CaseIterable {
        case low
        case medium
        case high
        case critical
    }

    public enum Effort: String, Codable, Hashable, Sendable, CaseIterable {
        case small
        case medium
        case large
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
