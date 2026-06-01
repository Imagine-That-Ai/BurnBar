package com.openburnbar.data.insights.services

import com.openburnbar.data.insights.InsightAnalysisAuditEntry
import com.openburnbar.data.insights.InsightAnalysisPlatform
import com.openburnbar.data.insights.InsightAnalysisRequest
import com.openburnbar.data.insights.InsightAnalysisResult
import com.openburnbar.data.insights.InsightTimeWindow
import com.openburnbar.data.repos.InsightAnalysisAuditLogRepository
import com.openburnbar.data.repos.InsightAnalysisCacheRepository
import java.security.MessageDigest
import java.time.Instant
import java.util.UUID

internal fun androidInsightPromptHash(prompt: String): String = MessageDigest.getInstance("SHA-256")
    .digest(prompt.toByteArray(Charsets.UTF_8))
    .joinToString("") { "%02x".format(it) }

internal suspend fun resolveCachedAndroidInsightResult(
    cache: InsightAnalysisCacheRepository?,
    engine: AndroidInsightAnalysisEngine,
    request: InsightAnalysisRequest,
): InsightAnalysisResult? {
    val cacheKey =
        InsightAnalysisCacheRepository.key(
            prompt = request.prompt,
            digestContentHash = request.context.digest.contentHash,
            modelID = request.selectedModel.modelID,
            instruction = request.instruction,
        )
    val cached = cache?.lookup(cacheKey) ?: return null
    val result =
        engine.ensureBriefingAnswer(
            RuleBasedInsightAnalysisEngine.enrichMissionCandidates(
                result = cached.result,
                request = request,
                platform = InsightAnalysisPlatform.ANDROID,
            ),
            request,
        )
    if (result != cached.result) {
        cache.store(InsightAnalysisCacheRepository.cachedNow(cacheKey, result, cached.estimatedCostSavedUSD))
    }
    return result
}

internal fun buildStartedAndroidAuditEntry(
    request: InsightAnalysisRequest,
    auditID: String,
    startedAt: String,
): InsightAnalysisAuditEntry {
    val timeWindow = request.currentCanvas?.filter?.window ?: InsightTimeWindow.Last7d
    return InsightAnalysisAuditEntry(
        id = auditID,
        requestID = request.id,
        platform = InsightAnalysisPlatform.ANDROID,
        selectedModel = request.selectedModel,
        egressTier = request.selectedModel.egressTier,
        timeWindow = timeWindow,
        contextBudget = request.context.budgetReport,
        includedDataSources = request.context.budgetReport.includedDataSources,
        truncationSummary = request.context.budgetReport.truncationSummary,
        promptHash = androidInsightPromptHash(request.prompt),
        resultHash = "",
        status = InsightAnalysisAuditEntry.Status.STARTED,
        startedAt = startedAt,
        ranAt = startedAt,
    )
}

internal suspend fun completeAndroidInsightAnalysis(
    engine: AndroidInsightAnalysisEngine,
    request: InsightAnalysisRequest,
    startedEntry: InsightAnalysisAuditEntry,
    auditID: String,
    cache: InsightAnalysisCacheRepository?,
    auditLog: InsightAnalysisAuditLogRepository?,
): InsightAnalysisResult {
    val raw = engine.executeSelectedModel(request)
    val result =
        RuleBasedInsightAnalysisEngine.enrichMissionCandidates(
            result = raw,
            request = request,
            platform = InsightAnalysisPlatform.ANDROID,
        ).copy(auditID = auditID)
    val completedAt = Instant.now().toString()
    val completedEntry =
        startedEntry.copy(
            selectedModel = result.modelTag,
            egressTier = result.modelTag.egressTier,
            timeWindow = result.timeWindow,
            contextBudget = result.contextBudget,
            includedDataSources = result.contextBudget.includedDataSources,
            truncationSummary = result.contextBudget.truncationSummary,
            resultHash = result.resultHash,
            status = InsightAnalysisAuditEntry.Status.SUCCEEDED,
            completedAt = completedAt,
            tokenUsage = result.tokenUsage,
            estimatedCostUSD = result.estimatedCostUSD,
            ranAt = completedAt,
        )
    auditLog?.upsertLatest(completedEntry)
    maybeStoreAndroidInsightCache(cache, request, result)
    return result
}

internal fun maybeStoreAndroidInsightCache(
    cache: InsightAnalysisCacheRepository?,
    request: InsightAnalysisRequest,
    result: InsightAnalysisResult,
) {
    val cacheKey =
        InsightAnalysisCacheRepository.key(
            prompt = request.prompt,
            digestContentHash = request.context.digest.contentHash,
            modelID = request.selectedModel.modelID,
            instruction = request.instruction,
        )
    val answeringRouteMatchesSelection =
        result.modelTag.providerKey == request.selectedModel.providerKey &&
            result.modelTag.modelID == request.selectedModel.modelID
    val isHostedRoute =
        result.modelTag.providerKey == AndroidBurnBarHostedInsightGateway.PROVIDER_KEY
    if (answeringRouteMatchesSelection && !isHostedRoute) {
        cache?.store(InsightAnalysisCacheRepository.cachedNow(cacheKey, result))
    }
}

internal fun recordAndroidInsightPaywallFailure(
    auditLog: InsightAnalysisAuditLogRepository?,
    startedEntry: InsightAnalysisAuditEntry,
    error: BurnBarProSubscriptionRequiredException,
) {
    val failedAt = Instant.now().toString()
    val failed =
        startedEntry.copy(
            status = InsightAnalysisAuditEntry.Status.FAILED,
            completedAt = failedAt,
            errorDescription = error.message ?: error.javaClass.simpleName,
            ranAt = failedAt,
        )
    auditLog?.upsertLatest(failed)
}

internal fun newAndroidInsightAuditId(): String = UUID.randomUUID().toString()

internal fun androidInsightStartedAt(): String = Instant.now().toString()
