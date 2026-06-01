@file:Suppress("ThrowsCount")
// Callable wiring maps Firebase/subscription failures to typed domain errors.

package com.openburnbar.data.insights.services

import com.google.firebase.functions.FirebaseFunctions
import com.openburnbar.data.insights.InsightAnalysisRequest
import com.openburnbar.data.insights.InsightAnalysisResult
import com.openburnbar.data.insights.InsightBriefingAnswer
import com.openburnbar.data.insights.InsightEgressTier
import com.openburnbar.data.insights.InsightModelTag
import com.openburnbar.data.insights.InsightTokenUsage
import java.time.Instant
import kotlinx.coroutines.tasks.await
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

private const val VAL_280 = 280
private const val VAL_3 = 3
private const val VAL_4 = 4

internal data class HostedCallableResponse(
    val envelope: String,
    val resolvedModelSlug: String,
    val resolvedDisplayName: String,
    val resolvedProviderKey: String,
    val resolvedEgress: InsightEgressTier,
    val tokenUsage: InsightTokenUsage?,
)

internal suspend fun invokeHostedInsightCallable(
    functionsProvider: () -> FirebaseFunctions,
    callableName: String,
    modelID: String,
    modelDisplayName: String,
    providerKey: String,
    request: InsightAnalysisRequest,
): HostedCallableResponse {
    val requestJSON = hostedJsonCodec.encodeToJsonElement(InsightAnalysisRequest.serializer(), request)
    val payload =
        mapOf(
            "schemaVersion" to InsightAnalysisResult.CURRENT_SCHEMA_VERSION,
            "platform" to "android",
            "modelID" to modelID,
            "instruction" to hostedInstructionWireString(request.instruction),
            "promptPreview" to request.prompt.take(VAL_280),
            "request" to hostedJsonElementToNative(requestJSON),
        )
    val callable =
        try {
            functionsProvider().getHttpsCallable(callableName)
        } catch (t: BurnBarProSubscriptionRequiredException) {
            throw IllegalStateException(
                "BurnBar Hosted callable unavailable: Firebase Functions not initialized (${t.message ?: t.javaClass.simpleName}).",
                t,
            )
        }
    val httpsResult =
        try {
            callable.call(payload).await()
        } catch (t: BurnBarProSubscriptionRequiredException) {
            if (AndroidBurnBarHostedInsightGateway.isSubscriptionRequired(t)) {
                throw BurnBarProSubscriptionRequiredException(
                    productID = AndroidBurnBarHostedInsightGateway.extractProductID(t),
                    cause = t,
                )
            }
            throw IllegalStateException(
                "BurnBar Hosted callable failed: ${t.message ?: t.javaClass.simpleName}",
                t,
            )
        }
    val rawData = httpsResult.getData() ?: error("BurnBar Hosted callable returned an empty payload.")
    val resultMap = rawData as? Map<*, *> ?: error("BurnBar Hosted callable returned a non-object payload.")
    val envelope =
        (resultMap["envelope"] as? String)?.takeIf { it.isNotBlank() }
            ?: error("BurnBar Hosted callable response missing or empty 'envelope'.")
    return HostedCallableResponse(
        envelope = envelope,
        resolvedModelSlug = (resultMap["modelSlug"] as? String)?.takeIf { it.isNotBlank() } ?: modelID,
        resolvedDisplayName = (resultMap["modelDisplayName"] as? String)?.takeIf { it.isNotBlank() } ?: modelDisplayName,
        resolvedProviderKey = (resultMap["providerKey"] as? String)?.takeIf { it.isNotBlank() } ?: providerKey,
        resolvedEgress = hostedParseEgressTier(resultMap["egressTier"] as? String) ?: InsightEgressTier.HOSTED,
        tokenUsage = hostedParseTokenUsage(resultMap["tokenUsage"], modelID, providerKey),
    )
}

internal fun hydrateHostedInsightResult(
    request: InsightAnalysisRequest,
    response: HostedCallableResponse,
): InsightAnalysisResult {
    val hostedTag =
        InsightModelTag(
            providerKey = response.resolvedProviderKey,
            modelID = response.resolvedModelSlug,
            displayName = response.resolvedDisplayName,
            egressTier = response.resolvedEgress,
            stampedAt = Instant.now().toString(),
        )
    val hostedRequest = request.copy(selectedModel = hostedTag)
    val hydrated = InsightAnalysisResultJsonDecoder.decode(response.envelope, hostedRequest, response.tokenUsage)
    return hydrated.copy(
        modelTag = hostedTag,
        tokenUsage = response.tokenUsage ?: hydrated.tokenUsage,
        estimatedCostUSD = response.tokenUsage?.estimatedCostUSD ?: hydrated.estimatedCostUSD,
    )
}

internal fun attachHostedFollowUpBriefing(
    request: InsightAnalysisRequest,
    stamped: InsightAnalysisResult,
    resolvedDisplayName: String,
): InsightAnalysisResult {
    if (request.instruction != InsightAnalysisRequest.Instruction.ANSWER_FOLLOW_UP) return stamped
    val existing = stamped.briefingAnswer
    return stamped.copy(
        briefingAnswer =
        (
            existing ?: InsightBriefingAnswer(
                question = request.prompt,
                answer = hostedComposeAnswerBody(stamped),
                bullets = hostedComposeGroundedPoints(stamped),
                citations = stamped.citations.take(VAL_3),
                source = InsightBriefingAnswer.Source.HOSTED_FALLBACK,
                modelDisplayName = resolvedDisplayName,
                isFallback = false,
            )
            ).copy(
            source = InsightBriefingAnswer.Source.HOSTED_FALLBACK,
            modelDisplayName = resolvedDisplayName,
            isFallback = false,
        ),
    )
}

private fun hostedComposeAnswerBody(result: InsightAnalysisResult): String = buildList {
    if (result.executiveSummary.isNotBlank()) add(result.executiveSummary)
    result.findings.firstOrNull()?.let {
        if (!result.executiveSummary.lowercase().contains(it.title.lowercase())) add(it.whyItMatters)
        add(it.recommendedAction)
    }
}.joinToString(" ")

private fun hostedComposeGroundedPoints(result: InsightAnalysisResult): List<String> = (
    result.findings.take(VAL_3).map { it.title } +
        result.anomalies.take(2).map { "Spike: ${it.title}" } +
        result.recommendations.take(2).map { "Action: ${it.title}" }
    ).take(VAL_4)

private fun hostedParseEgressTier(raw: String?): InsightEgressTier? {
    if (raw.isNullOrBlank()) return null
    val normalized = raw.lowercase().replace("_", "").replace("-", "")
    return InsightEgressTier.values().firstOrNull { tier ->
        val canonical = tier.name.lowercase().replace("_", "")
        canonical == normalized
    }
}

private fun hostedParseTokenUsage(raw: Any?, modelSlug: String, providerKey: String): InsightTokenUsage? {
    val map = raw as? Map<*, *> ?: return null
    val started = (map["startedAt"] as? String)?.takeIf { it.isNotBlank() } ?: Instant.now().toString()
    val completed = (map["completedAt"] as? String)?.takeIf { it.isNotBlank() } ?: started
    return InsightTokenUsage(
        providerKey = (map["providerKey"] as? String)?.takeIf { it.isNotBlank() } ?: providerKey,
        modelID = (map["modelID"] as? String)?.takeIf { it.isNotBlank() } ?: modelSlug,
        inputTokens = (map["inputTokens"] as? Number)?.toInt() ?: 0,
        outputTokens = (map["outputTokens"] as? Number)?.toInt() ?: 0,
        estimatedCostUSD = (map["estimatedCostUSD"] as? Number)?.toDouble() ?: 0.0,
        startedAt = started,
        completedAt = completed,
    )
}

private val hostedJsonCodec =
    Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
    }

private fun hostedInstructionWireString(instruction: InsightAnalysisRequest.Instruction): String = when (instruction) {
    InsightAnalysisRequest.Instruction.DEFAULT_BRIEF -> "defaultBrief"
    InsightAnalysisRequest.Instruction.ANSWER_FOLLOW_UP -> "answerFollowUp"
    InsightAnalysisRequest.Instruction.GENERATE_REPORT -> "generateReport"
    InsightAnalysisRequest.Instruction.UPDATE_CANVAS -> "updateCanvas"
}

private fun hostedJsonElementToNative(element: JsonElement): Any? = when (element) {
    is JsonNull -> null
    is JsonPrimitive ->
        when {
            element.isString -> element.content
            else ->
                element.content.toLongOrNull()
                    ?: element.content.toDoubleOrNull()
                    ?: element.content.toBooleanStrictOrNull()
                    ?: element.content
        }
    is JsonArray -> element.map { hostedJsonElementToNative(it) }
    is JsonObject -> element.mapValues { (_, value) -> hostedJsonElementToNative(value) }
}
