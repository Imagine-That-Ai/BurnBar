package com.openburnbar.data.insights

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import java.util.UUID

@Serializable
data class InsightAnalysisResult(
    val id: String = UUID.randomUUID().toString(),
    val requestID: String,
    val schemaVersion: Int = CURRENT_SCHEMA_VERSION,
    val generatedAt: String = java.time.Instant.now().toString(),
    val platform: InsightAnalysisPlatform,
    val timeWindow: InsightTimeWindow,
    val executiveSummary: String,
    val modelTag: InsightModelTag,
    val contextBudget: InsightContextBudgetReport,
    val findings: List<InsightFinding> = emptyList(),
    val anomalies: List<InsightAnomaly> = emptyList(),
    val recommendations: List<InsightRecommendation> = emptyList(),
    val missionCandidates: List<InsightMissionCandidate> = emptyList(),
    val generatedWidgets: List<InsightGeneratedWidget> = emptyList(),
    val followUpQuestions: List<InsightFollowUpQuestion> = emptyList(),
    val citations: List<InsightCitation> = emptyList(),
    val tokenUsage: InsightTokenUsage? = null,
    val estimatedCostUSD: Double? = null,
    val auditID: String? = null,
    val resultHash: String = ""
) {
    companion object {
        const val CURRENT_SCHEMA_VERSION = 1
    }
}

@Serializable
data class InsightAnalysisRequest(
    val id: String = UUID.randomUUID().toString(),
    val prompt: String,
    val context: InsightAnalysisContext,
    val currentCanvas: InsightCanvas? = null,
    val selectedModel: InsightModelTag,
    val instruction: Instruction = Instruction.DEFAULT_BRIEF,
    val allowDeepTranscriptAnalysis: Boolean = false,
    val maxGeneratedWidgets: Int = 8
) {
    @Serializable
    enum class Instruction {
        @SerialName("defaultBrief") DEFAULT_BRIEF,
        @SerialName("answerFollowUp") ANSWER_FOLLOW_UP,
        @SerialName("generateReport") GENERATE_REPORT,
        @SerialName("updateCanvas") UPDATE_CANVAS
    }
}

@Serializable
data class InsightAnalysisContext(
    val digest: InsightDigest,
    val evidenceIndex: List<InsightEvidence>,
    val budgetReport: InsightContextBudgetReport,
    val priorRunSummaries: List<String> = emptyList(),
    val evidencePacks: List<InsightEvidencePack> = emptyList()
)

@Serializable
data class InsightEvidence(
    val id: String,
    val citation: InsightCitation,
    val source: String,
    val summary: String,
    val numericValue: Double? = null
)

@Serializable
data class InsightEvidencePack(
    val id: String = UUID.randomUUID().toString(),
    val sourcePlatform: InsightAnalysisPlatform,
    val generatedAt: String = java.time.Instant.now().toString(),
    val timeWindow: InsightTimeWindow,
    val includedDataSources: List<String>,
    val budgetReport: InsightContextBudgetReport,
    val evidence: List<InsightEvidence>,
    val summary: String,
    val contentHash: String,
    val deepTranscriptIncluded: Boolean = false
)

@Serializable
data class InsightPlatformCapabilityReport(
    val platform: InsightAnalysisPlatform,
    val providerFamilies: List<InsightProviderFamily>,
    val includedDataSources: List<String>,
    val supportsDeepLocalLogs: Boolean,
    val supportsSyncedEvidencePacks: Boolean,
    val supportsModelSelection: Boolean = true,
    val supportsConversation: Boolean = true,
    val supportsGeneratedWidgetPinning: Boolean = true,
    val supportsAuditAndCache: Boolean = true,
    val gaps: List<String> = emptyList()
)

@Serializable
enum class InsightProviderFamily {
    @SerialName("codex") CODEX,
    @SerialName("claude") CLAUDE,
    @SerialName("minimax") MINIMAX,
    @SerialName("zai") ZAI,
    @SerialName("kimi") KIMI,
    @SerialName("ollama") OLLAMA,
    @SerialName("hermes") HERMES,
    @SerialName("openai") OPENAI,
    @SerialName("pi") PI,
    @SerialName("openrouter") OPENROUTER,
    @SerialName("local-rules") LOCAL_RULES,
    @SerialName("other") OTHER
}

@Serializable
data class InsightContextBudgetReport(
    val maxEncodedBytes: Int = InsightDigest.MAX_ENCODED_BYTES,
    val encodedBytes: Int,
    val estimatedPromptTokens: Int,
    val includedDataSources: List<String>,
    val truncatedDataSources: List<String> = emptyList(),
    val truncationSummary: String = "No truncation."
)

@Serializable
data class InsightFinding(
    val id: String = UUID.randomUUID().toString(),
    val title: String,
    val whyItMatters: String,
    val evidence: List<InsightCitation>,
    val confidence: InsightConfidence,
    val severity: InsightSeverity = InsightSeverity.MEDIUM,
    val recommendedAction: String,
    val generatedWidgetID: String? = null
)

@Serializable
data class InsightAnomaly(
    val id: String = UUID.randomUUID().toString(),
    val title: String,
    val occurredAt: String? = null,
    val detail: String,
    val score: Double,
    val evidence: List<InsightCitation>,
    val confidence: InsightConfidence
)

@Serializable
data class InsightRecommendation(
    val id: String = UUID.randomUUID().toString(),
    val title: String,
    val rationale: String,
    val recommendedAction: String,
    val estimatedImpact: String? = null,
    val evidence: List<InsightCitation>,
    val confidence: InsightConfidence,
    val severity: InsightSeverity = InsightSeverity.MEDIUM
)

@Serializable
data class InsightMissionCandidate(
    val id: String = UUID.randomUUID().toString(),
    val title: String,
    val summary: String,
    val projectID: String? = null,
    val projectDisplayName: String? = null,
    val lens: Lens,
    val priority: Priority,
    val confidence: InsightConfidence,
    val expectedImpact: String,
    val effort: Effort,
    val acceptanceCriteria: List<String>,
    val sourceInsightIDs: List<String> = emptyList(),
    val evidence: List<InsightCitation>,
    val dispatchMetadata: Map<String, String> = emptyMap()
) {
    @Serializable
    enum class Lens {
        @SerialName("accretion") ACCRETION,
        @SerialName("diligence") DILIGENCE,
        @SerialName("techDebt") TECH_DEBT,
        @SerialName("routing") ROUTING,
        @SerialName("quota") QUOTA,
        @SerialName("focus") FOCUS
    }

    @Serializable
    enum class Priority {
        @SerialName("low") LOW,
        @SerialName("medium") MEDIUM,
        @SerialName("high") HIGH,
        @SerialName("critical") CRITICAL
    }

    @Serializable
    enum class Effort {
        @SerialName("small") SMALL,
        @SerialName("medium") MEDIUM,
        @SerialName("large") LARGE
    }
}

@Serializable
data class InsightGeneratedWidget(
    val id: String = UUID.randomUUID().toString(),
    val widget: InsightWidget,
    val reason: String,
    val citations: List<InsightCitation>
)

@Serializable
data class InsightFollowUpQuestion(
    val id: String = UUID.randomUUID().toString(),
    val question: String,
    val rationale: String? = null
)

@Serializable
data class InsightAnalysisAuditEntry(
    val id: String = UUID.randomUUID().toString(),
    val requestID: String,
    val platform: InsightAnalysisPlatform,
    val selectedModel: InsightModelTag,
    val egressTier: InsightEgressTier,
    val timeWindow: InsightTimeWindow,
    val contextBudget: InsightContextBudgetReport,
    val includedDataSources: List<String>,
    val truncationSummary: String,
    val promptHash: String,
    val resultHash: String,
    val status: Status,
    val startedAt: String = java.time.Instant.now().toString(),
    val completedAt: String? = null,
    val errorDescription: String? = null,
    val tokenUsage: InsightTokenUsage? = null,
    val estimatedCostUSD: Double? = null,
    val ranAt: String = java.time.Instant.now().toString()
) {
    @Serializable
    enum class Status {
        @SerialName("started") STARTED,
        @SerialName("succeeded") SUCCEEDED,
        @SerialName("partial") PARTIAL,
        @SerialName("modelUnavailable") MODEL_UNAVAILABLE,
        @SerialName("schemaViolation") SCHEMA_VIOLATION,
        @SerialName("cancelled") CANCELLED,
        @SerialName("failed") FAILED
    }
}

@Serializable
data class InsightModelPreference(
    val mode: Mode = Mode.AUTOMATIC,
    val explicitModel: InsightModelTag? = null,
    val restrictToLocalOnly: Boolean = false,
    val maxEgressTier: InsightEgressTier? = null,
    val deepTranscriptOptIn: Boolean = false
) {
    @Serializable
    enum class Mode {
        @SerialName("automatic") AUTOMATIC,
        @SerialName("explicit") EXPLICIT
    }

    companion object {
        val DEFAULT = InsightModelPreference()
    }
}

@Serializable
enum class InsightAnalysisPlatform {
    @SerialName("macOS") MACOS,
    @SerialName("iOS") IOS,
    @SerialName("iPadOS") IPADOS,
    @SerialName("android") ANDROID
}

@Serializable
enum class InsightConfidence {
    @SerialName("low") LOW,
    @SerialName("medium") MEDIUM,
    @SerialName("high") HIGH
}

@Serializable
enum class InsightSeverity {
    @SerialName("info") INFO,
    @SerialName("low") LOW,
    @SerialName("medium") MEDIUM,
    @SerialName("high") HIGH,
    @SerialName("critical") CRITICAL
}
