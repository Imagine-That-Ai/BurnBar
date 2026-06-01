@file:Suppress("MatchingDeclarationName")

package com.openburnbar.data.insights.services

import com.openburnbar.data.insights.InsightCitation
import com.openburnbar.data.insights.InsightConfidence
import com.openburnbar.data.insights.InsightDigest
import com.openburnbar.data.insights.InsightFinding
import com.openburnbar.data.insights.InsightMissionCandidate
import com.openburnbar.data.insights.InsightRecommendation
import com.openburnbar.data.insights.InsightSeverity

internal data class RuleBasedMissionAdvice(
    val findings: List<InsightFinding>,
    val recommendations: List<InsightRecommendation>,
    val missions: List<InsightMissionCandidate>,
)

internal fun ruleBasedMissionIntelligence(
    digest: InsightDigest,
    topProvider: InsightDigest.ProviderSnapshot?,
    topModel: InsightDigest.ModelSnapshot?,
    sourceInsightIDs: List<String>,
): RuleBasedMissionAdvice {
    if (digest.totals.sessionCount <= 0 && digest.rowCount <= 0) {
        return RuleBasedMissionAdvice(emptyList(), emptyList(), emptyList())
    }
    val context = buildRuleBasedMissionContext(digest, topProvider, topModel)
    val findings = buildRuleBasedMissionFindings(context)
    val missions = buildRuleBasedMissionCandidates(context, topModel, digest, sourceInsightIDs)
    val recommendations = buildRuleBasedMissionRecommendations(context, topModel, digest)
    return RuleBasedMissionAdvice(findings, recommendations, missions)
}

private data class RuleBasedMissionContext(
    val topProject: InsightDigest.ProjectSnapshot?,
    val projectName: String,
    val projectCost: String,
    val projectSessions: Int,
    val projectCitation: InsightCitation?,
    val providerCitation: InsightCitation?,
    val modelCitation: InsightCitation?,
    val quotaRisk: InsightDigest.QuotaSnapshot?,
    val quotaCitation: InsightCitation?,
    val activityCitation: InsightCitation,
)

private fun buildRuleBasedMissionContext(
    digest: InsightDigest,
    topProvider: InsightDigest.ProviderSnapshot?,
    topModel: InsightDigest.ModelSnapshot?,
): RuleBasedMissionContext {
    val topProject = digest.projects.maxByOrNull { it.costUSD }
    val quotaRisk =
        digest.quotaSnapshots
            .filter { it.limit != null && it.limit > 0.0 }
            .maxByOrNull { it.used / maxOf(it.limit ?: 1.0, 1.0) }
    return RuleBasedMissionContext(
        topProject = topProject,
        projectName = topProject?.displayName ?: "the busiest project",
        projectCost = ruleBasedCurrency(topProject?.costUSD ?: digest.totals.costUSD),
        projectSessions = topProject?.sessionCount ?: digest.totals.sessionCount,
        projectCitation =
        topProject?.let {
            InsightCitation("project:${it.id}", InsightCitation.Kind.Project(it.id), it.displayName)
        },
        providerCitation =
        topProvider?.let {
            InsightCitation("provider:${it.id}", InsightCitation.Kind.Agent(it.id), it.displayName)
        },
        modelCitation =
        topModel?.let {
            InsightCitation("model:${it.id}", InsightCitation.Kind.Model(it.id), it.id)
        },
        quotaRisk = quotaRisk,
        quotaCitation =
        quotaRisk?.let {
            InsightCitation(
                "quota:${it.providerID}:${it.bucketName}",
                InsightCitation.Kind.Quota(it.providerID, it.bucketName),
                "${it.providerID} quota",
            )
        },
        activityCitation =
        InsightCitation(
            "query:${digest.contentHash.ifBlank { "insight-activity" }}",
            InsightCitation.Kind.Query("insight-activity"),
            "Activity digest",
        ),
    )
}

private fun buildRuleBasedMissionFindings(context: RuleBasedMissionContext): List<InsightFinding> {
    val topProject = context.topProject ?: return emptyList()
    val projectCitation = context.projectCitation ?: return emptyList()
    return listOf(
        InsightFinding(
            title = "${topProject.displayName} is where the work concentrated",
            whyItMatters =
            "${topProject.displayName} accounts for ${context.projectCost} across " +
                "${context.projectSessions} sessions, so missions should start where repeated AI effort is already compounding.",
            evidence = listOf(projectCitation),
            confidence = InsightConfidence.HIGH,
            severity = if (context.projectSessions >= 3) InsightSeverity.MEDIUM else InsightSeverity.LOW,
            recommendedAction = "Create one focused mission for ${topProject.displayName} instead of treating the brief as isolated observations.",
        ),
    )
}

private fun buildRuleBasedMissionCandidates(
    context: RuleBasedMissionContext,
    topModel: InsightDigest.ModelSnapshot?,
    digest: InsightDigest,
    sourceInsightIDs: List<String>,
): List<InsightMissionCandidate> {
    val missions = mutableListOf<InsightMissionCandidate>()
    appendRuleBasedAccretionMission(missions, context, sourceInsightIDs)
    appendRuleBasedDiligenceMission(missions, context, sourceInsightIDs)
    appendRuleBasedTechDebtMission(missions, context, topModel, digest, sourceInsightIDs)
    appendRuleBasedFocusMissionWhenOpaque(missions, context, topModel, digest, sourceInsightIDs)
    return missions
}

private fun appendRuleBasedAccretionMission(
    missions: MutableList<InsightMissionCandidate>,
    context: RuleBasedMissionContext,
    sourceInsightIDs: List<String>,
) {
    val accretionEvidence =
        ruleBasedNonEmptyEvidence(
            listOf(context.projectCitation, context.modelCitation, context.providerCitation),
            context.activityCitation,
        )
    if (accretionEvidence.isEmpty()) return
    missions.add(
        InsightMissionCandidate(
            title = "Turn repeated ${context.projectName} work into an accretive feature",
            summary =
            "Use the accretion lens to convert the highest-activity project into a small product or " +
                "workflow improvement that reuses existing primitives instead of becoming a one-off analysis.",
            projectID = context.topProject?.id,
            projectDisplayName = context.topProject?.displayName,
            lens = InsightMissionCandidate.Lens.ACCRETION,
            priority =
            if (context.projectSessions >= 3) {
                InsightMissionCandidate.Priority.HIGH
            } else {
                InsightMissionCandidate.Priority.MEDIUM
            },
            confidence = if (context.topProject == null) InsightConfidence.MEDIUM else InsightConfidence.HIGH,
            expectedImpact = "Compounds current AI spend into a durable workflow, trust cue, or UI affordance.",
            effort = InsightMissionCandidate.Effort.MEDIUM,
            acceptanceCriteria =
            listOf(
                "Name the concrete user job currently driving the repeated sessions.",
                "Ship one native workflow or polish layer that reuses existing BurnBar primitives.",
                "Verify the next brief can cite reduced friction, clearer routing, or better user confidence.",
            ),
            sourceInsightIDs = sourceInsightIDs,
            evidence = accretionEvidence,
            dispatchMetadata = mapOf("lens" to "accretion", "source" to "insight_engine"),
        ),
    )
}

private fun appendRuleBasedDiligenceMission(
    missions: MutableList<InsightMissionCandidate>,
    context: RuleBasedMissionContext,
    sourceInsightIDs: List<String>,
) {
    val diligenceEvidence =
        ruleBasedNonEmptyEvidence(
            listOf(context.projectCitation, context.quotaCitation, context.providerCitation),
            context.activityCitation,
        )
    if (diligenceEvidence.isEmpty()) return
    val quotaHot =
        context.quotaRisk?.let { it.limit != null && it.limit > 0.0 && it.used / it.limit >= INSIGHT_VAL_0_8 }
            ?: false
    missions.add(
        InsightMissionCandidate(
            title =
            if (quotaHot) {
                "Run a diligence pass before the next heavy session"
            } else {
                "Run a diligence pass on ${context.projectName}"
            },
            summary = "Use the diligence lens to turn the brief's risk signals into an evidence-backed launch-readiness check with explicit blockers, owner, and proof.",
            projectID = context.topProject?.id,
            projectDisplayName = context.topProject?.displayName,
            lens = InsightMissionCandidate.Lens.DILIGENCE,
            priority =
            if (quotaHot) {
                InsightMissionCandidate.Priority.CRITICAL
            } else {
                InsightMissionCandidate.Priority.HIGH
            },
            confidence = InsightConfidence.MEDIUM,
            expectedImpact = "Prevents cost, quota, or release surprises from hiding behind a normal-looking usage summary.",
            effort = InsightMissionCandidate.Effort.SMALL,
            acceptanceCriteria =
            listOf(
                "List the top production, cost, privacy, and reliability risks with citations.",
                "Separate blockers from serious concerns and acceptable tradeoffs.",
                "Attach the verification command or live evidence that closes each blocker.",
            ),
            sourceInsightIDs = sourceInsightIDs,
            evidence = diligenceEvidence,
            dispatchMetadata = mapOf("lens" to "diligence", "source" to "insight_engine"),
        ),
    )
}

private fun appendRuleBasedTechDebtMission(
    missions: MutableList<InsightMissionCandidate>,
    context: RuleBasedMissionContext,
    topModel: InsightDigest.ModelSnapshot?,
    digest: InsightDigest,
    sourceInsightIDs: List<String>,
) {
    val model = topModel ?: return
    missions.add(
        InsightMissionCandidate(
            title = "Reduce repeated ${model.id} drag",
            summary =
            "Use the debt lens to decide whether high recurring model usage is doing essential expert " +
                "work or masking unclear requirements, weak tests, brittle routing, or missing automation.",
            projectID = context.topProject?.id,
            projectDisplayName = context.topProject?.displayName,
            lens = InsightMissionCandidate.Lens.TECH_DEBT,
            priority =
            if (model.costUSD > maxOf(1.0, digest.totals.costUSD * INSIGHT_VAL_0_35)) {
                InsightMissionCandidate.Priority.HIGH
            } else {
                InsightMissionCandidate.Priority.MEDIUM
            },
            confidence = InsightConfidence.MEDIUM,
            expectedImpact = "Cuts future analysis spend by removing the underlying delivery friction, not just swapping models.",
            effort = InsightMissionCandidate.Effort.MEDIUM,
            acceptanceCriteria =
            listOf(
                "Identify the repeated work pattern causing the expensive model usage.",
                "Choose the smallest remediation that prevents the same class of future sessions.",
                "Add or update a test, runbook, or automation proof that the drag was actually reduced.",
            ),
            sourceInsightIDs = sourceInsightIDs,
            evidence =
            ruleBasedNonEmptyEvidence(
                listOf(context.modelCitation, context.projectCitation),
                context.activityCitation,
            ),
            dispatchMetadata = mapOf("lens" to "techDebt", "source" to "insight_engine"),
        ),
    )
}

private fun appendRuleBasedFocusMissionWhenOpaque(
    missions: MutableList<InsightMissionCandidate>,
    context: RuleBasedMissionContext,
    topModel: InsightDigest.ModelSnapshot?,
    digest: InsightDigest,
    sourceInsightIDs: List<String>,
) {
    if (topModel != null || context.topProject != null) return
    missions.add(
        InsightMissionCandidate(
            title = "Upgrade the next brief with project and model attribution",
            summary =
            "The digest has activity totals but lacks enough project, provider, or model breakdown to explain the work " +
                "intelligently. Use the focus lens to make the next analysis more actionable instead of accepting generic totals.",
            lens = InsightMissionCandidate.Lens.FOCUS,
            priority =
            if (digest.totals.sessionCount > 0) {
                InsightMissionCandidate.Priority.HIGH
            } else {
                InsightMissionCandidate.Priority.MEDIUM
            },
            confidence = InsightConfidence.MEDIUM,
            expectedImpact = "Turns an opaque usage summary into a useful brief that can name the workflow, model choice, and cost driver.",
            effort = InsightMissionCandidate.Effort.SMALL,
            acceptanceCriteria =
            listOf(
                "Confirm mobile sync is receiving provider, model, and project summaries.",
                "Refresh Insights and verify the Mission Board names at least one concrete driver.",
                "Use the new driver to create one accretion, diligence, or debt mission.",
            ),
            sourceInsightIDs = sourceInsightIDs,
            evidence = listOf(context.activityCitation),
            dispatchMetadata = mapOf("lens" to "focus", "source" to "insight_engine"),
        ),
    )
}

private fun buildRuleBasedMissionRecommendations(
    context: RuleBasedMissionContext,
    topModel: InsightDigest.ModelSnapshot?,
    digest: InsightDigest,
): List<InsightRecommendation> {
    if (topModel == null || digest.modelBenchmarks.isEmpty()) return emptyList()
    return listOf(
        InsightRecommendation(
            title = "Convert model-board advice into a routing experiment",
            rationale = "Benchmark evidence is useful only after a bounded comparison against your actual ${context.projectName} work.",
            recommendedAction = "Run one UI/design or routine-coding session through the best-fit candidate, then compare quality, cost signal, and quota health before changing defaults.",
            estimatedImpact = "Turns abstract model rankings into a safer routing decision.",
            evidence =
            listOfNotNull(context.modelCitation) +
                digest.modelBenchmarks.take(2).map { ruleBasedBenchmarkCitation(it) },
            confidence = InsightConfidence.MEDIUM,
            severity = InsightSeverity.MEDIUM,
        ),
    )
}

internal fun ruleBasedNonEmptyEvidence(
    candidates: List<InsightCitation?>,
    fallback: InsightCitation,
): List<InsightCitation> = candidates.filterNotNull().ifEmpty { listOf(fallback) }
