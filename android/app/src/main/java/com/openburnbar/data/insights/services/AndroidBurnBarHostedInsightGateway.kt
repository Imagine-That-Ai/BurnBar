package com.openburnbar.data.insights.services

import com.google.firebase.functions.FirebaseFunctions
import com.google.firebase.functions.FirebaseFunctionsException
import com.openburnbar.data.insights.InsightAnalysisRequest
import com.openburnbar.data.insights.InsightAnalysisResult
import com.openburnbar.data.insights.InsightBriefingAnswer
import com.openburnbar.data.insights.InsightEgressTier
import com.openburnbar.data.insights.InsightModelTag
import com.openburnbar.data.insights.InsightTokenUsage
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.tasks.await
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import java.time.Instant

/**
 * BurnBar-hosted Intelligence Brief fallback gateway.
 *
 * Used only when no user-owned LLM route (Hermes, Pi, OpenClaw,
 * Claude, Codex, OpenCode, Ollama, OpenAI-compatible, etc.) is
 * reachable. Proxies the user's prompt through the Firebase callable
 * `insightsHostedAnswer`, which in turn talks to OpenRouter → MiniMax
 * 2.7 so the OpenRouter API key never lands on the device.
 *
 * The Firebase Functions SDK attaches the Firebase Auth ID token (if
 * any) and App Check attestation automatically, so this class never
 * has to hand-roll the wire-level auth contract the way the iOS
 * `BurnBarHostedInsightAdapter` does.
 */
class AndroidBurnBarHostedInsightGateway(
    /**
     * Lazy provider so construction doesn't require Firebase to be
     * initialized — `FirebaseFunctions.getInstance()` throws unless
     * `FirebaseApp.initializeApp()` has run, which is fine in the
     * production app (it has) but breaks unit tests and Compose
     * previews that wire a fresh view-model without booting Firebase.
     * The provider is only invoked inside `analyze()`.
     */
    private val functionsProvider: () -> FirebaseFunctions = { FirebaseFunctions.getInstance() },
    private val callableName: String = "insightsHostedAnswer",
    private val modelDisplayName: String = "MiniMax 2.7 · BurnBar Hosted",
    private val modelID: String = "minimax-m2.7",
) : InsightAnalysisModelGateway {

    override val providerKey: String = PROVIDER_KEY
    override val displayName: String = "BurnBar Hosted"
    override val models: List<InsightModelTag> = listOf(
        InsightModelTag(
            providerKey = providerKey,
            modelID = modelID,
            displayName = modelDisplayName,
            egressTier = InsightEgressTier.HOSTED,
            stampedAt = Instant.now().toString(),
        )
    )

    override suspend fun analyze(request: InsightAnalysisRequest): InsightAnalysisResult =
        withContext(Dispatchers.IO) {
            val requestJSON = jsonCodec.encodeToJsonElement(
                InsightAnalysisRequest.serializer(),
                request
            )
            val payload = mapOf(
                "schemaVersion" to InsightAnalysisResult.CURRENT_SCHEMA_VERSION,
                "platform" to "android",
                "modelID" to modelID,
                "instruction" to instructionWireString(request.instruction),
                "promptPreview" to request.prompt.take(280),
                "request" to jsonElementToNative(requestJSON)
            )

            val callable = try {
                functionsProvider().getHttpsCallable(callableName)
            } catch (t: Throwable) {
                throw IllegalStateException(
                    "BurnBar Hosted callable unavailable: Firebase Functions not initialized (${t.message ?: t.javaClass.simpleName}).",
                    t
                )
            }
            val httpsResult = try {
                callable.call(payload).await()
            } catch (t: Throwable) {
                if (isSubscriptionRequired(t)) {
                    throw BurnBarProSubscriptionRequiredException(
                        productID = extractProductID(t),
                        cause = t,
                    )
                }
                throw IllegalStateException(
                    "BurnBar Hosted callable failed: ${t.message ?: t.javaClass.simpleName}",
                    t
                )
            }

            val rawData = httpsResult.getData()
                ?: throw IllegalStateException("BurnBar Hosted callable returned an empty payload.")
            val resultMap = rawData as? Map<*, *>
                ?: throw IllegalStateException("BurnBar Hosted callable returned a non-object payload.")

            val envelope = (resultMap["envelope"] as? String)?.takeIf { it.isNotBlank() }
                ?: throw IllegalStateException(
                    "BurnBar Hosted callable response missing or empty 'envelope'."
                )
            val resolvedModelSlug = (resultMap["modelSlug"] as? String)?.takeIf { it.isNotBlank() } ?: modelID
            val resolvedDisplayName =
                (resultMap["modelDisplayName"] as? String)?.takeIf { it.isNotBlank() } ?: modelDisplayName
            val resolvedProviderKey =
                (resultMap["providerKey"] as? String)?.takeIf { it.isNotBlank() } ?: providerKey
            val resolvedEgress = parseEgressTier(resultMap["egressTier"] as? String) ?: InsightEgressTier.HOSTED
            val tokenUsage = parseTokenUsage(resultMap["tokenUsage"], resolvedModelSlug, resolvedProviderKey)

            // Stamp the request with the server's model identity so
            // the canonical `InsightAnalysisResultJsonDecoder` writes
            // the right modelTag onto the hydrated result — the audit
            // log and UI eyebrow both lean on this attribution.
            val hostedTag = InsightModelTag(
                providerKey = resolvedProviderKey,
                modelID = resolvedModelSlug,
                displayName = resolvedDisplayName,
                egressTier = resolvedEgress,
                stampedAt = Instant.now().toString(),
            )
            val hostedRequest = request.copy(selectedModel = hostedTag)

            // Reuse the canonical LLM-envelope decoder so we don't
            // re-implement citation hydration here. The envelope is
            // the same `{executiveSummary, findings, ...}` shape every
            // other user-key gateway returns, so this stays
            // consistent across routes.
            val hydrated = InsightAnalysisResultJsonDecoder.decode(envelope, hostedRequest, tokenUsage)
            val stamped = hydrated.copy(
                modelTag = hostedTag,
                tokenUsage = tokenUsage ?: hydrated.tokenUsage,
                estimatedCostUSD = tokenUsage?.estimatedCostUSD ?: hydrated.estimatedCostUSD,
            )

            if (request.instruction == InsightAnalysisRequest.Instruction.ANSWER_FOLLOW_UP) {
                val existing = stamped.briefingAnswer
                stamped.copy(
                    briefingAnswer = (existing ?: InsightBriefingAnswer(
                        question = request.prompt,
                        answer = composeAnswerBody(stamped),
                        bullets = composeGroundedPoints(stamped),
                        citations = stamped.citations.take(3),
                        source = InsightBriefingAnswer.Source.HOSTED_FALLBACK,
                        modelDisplayName = resolvedDisplayName,
                        isFallback = false,
                    )).copy(
                        source = InsightBriefingAnswer.Source.HOSTED_FALLBACK,
                        modelDisplayName = resolvedDisplayName,
                        isFallback = false,
                    )
                )
            } else {
                stamped
            }
        }

    private fun composeAnswerBody(result: InsightAnalysisResult): String =
        buildList {
            if (result.executiveSummary.isNotBlank()) add(result.executiveSummary)
            result.findings.firstOrNull()?.let {
                if (!result.executiveSummary.lowercase().contains(it.title.lowercase())) add(it.whyItMatters)
                add(it.recommendedAction)
            }
        }.joinToString(" ")

    private fun composeGroundedPoints(result: InsightAnalysisResult): List<String> =
        (result.findings.take(3).map { it.title } +
            result.anomalies.take(2).map { "Spike: ${it.title}" } +
            result.recommendations.take(2).map { "Action: ${it.title}" }).take(4)

    private fun parseEgressTier(raw: String?): InsightEgressTier? {
        if (raw.isNullOrBlank()) return null
        val normalized = raw.lowercase().replace("_", "").replace("-", "")
        return InsightEgressTier.values().firstOrNull { tier ->
            val canonical = tier.name.lowercase().replace("_", "")
            canonical == normalized
        }
    }

    private fun parseTokenUsage(
        raw: Any?,
        modelSlug: String,
        providerKey: String,
    ): InsightTokenUsage? {
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

    companion object {
        const val PROVIDER_KEY = "burnbar-hosted"
        /**
         * Stable detail-code the Cloud Function attaches to a
         * permission-denied response when the caller has no active
         * BurnBar Pro subscription. Mirrors the Swift adapter's
         * detection so both clients route to the upgrade CTA without
         * string-matching the human-readable message.
         */
        const val SUBSCRIPTION_REQUIRED_DETAIL_CODE = "subscription-required"

        /**
         * Recognize the Pro-paywall response. Three signals routed
         * to the same upgrade CTA — sign-in is the first step of
         * StoreKit / Play-Billing flows, so collapsing
         * `UNAUTHENTICATED` into the paywall path keeps the brief
         * pointing at a single recovery action:
         *
         *   1. `details.code == "subscription-required"` — our
         *      canonical, hand-attached marker. Strongest.
         *   2. `FirebaseFunctionsException.Code.PERMISSION_DENIED`
         *      with `"BurnBar Pro"` in the message.
         *   3. `FirebaseFunctionsException.Code.UNAUTHENTICATED` —
         *      anonymous caller; sign-in is a Pro precondition.
         */
        internal fun isSubscriptionRequired(t: Throwable): Boolean {
            val fex = (t as? FirebaseFunctionsException)
                ?: (t.cause as? FirebaseFunctionsException)
                ?: return false
            val detailMap = fex.details as? Map<*, *>
            val detailCode = detailMap?.get("code") as? String
            if (detailCode == SUBSCRIPTION_REQUIRED_DETAIL_CODE) return true
            return when (fex.code) {
                FirebaseFunctionsException.Code.PERMISSION_DENIED ->
                    fex.message?.contains("BurnBar Pro", ignoreCase = true) == true
                FirebaseFunctionsException.Code.UNAUTHENTICATED -> true
                else -> false
            }
        }

        internal fun extractProductID(t: Throwable): String? {
            val fex = (t as? FirebaseFunctionsException)
                ?: (t.cause as? FirebaseFunctionsException)
                ?: return null
            val detailMap = fex.details as? Map<*, *>
            return detailMap?.get("productID") as? String
        }

        private val jsonCodec = Json {
            ignoreUnknownKeys = true
            encodeDefaults = true
        }

        private fun instructionWireString(instruction: InsightAnalysisRequest.Instruction): String =
            when (instruction) {
                InsightAnalysisRequest.Instruction.DEFAULT_BRIEF -> "defaultBrief"
                InsightAnalysisRequest.Instruction.ANSWER_FOLLOW_UP -> "answerFollowUp"
                InsightAnalysisRequest.Instruction.GENERATE_REPORT -> "generateReport"
                InsightAnalysisRequest.Instruction.UPDATE_CANVAS -> "updateCanvas"
            }

        /**
         * Convert a `kotlinx.serialization` [JsonElement] tree into
         * the native `Map<String, Any?>` / `List<Any?>` Firebase
         * callables expect for the request payload.
         */
        private fun jsonElementToNative(element: JsonElement): Any? = when (element) {
            is JsonNull -> null
            is JsonPrimitive -> when {
                element.isString -> element.content
                else -> element.content.toLongOrNull()
                    ?: element.content.toDoubleOrNull()
                    ?: element.content.toBooleanStrictOrNull()
                    ?: element.content
            }
            is JsonArray -> element.map { jsonElementToNative(it) }
            is JsonObject -> element.mapValues { (_, value) -> jsonElementToNative(value) }
        }

    }
}

/**
 * Thrown by [AndroidBurnBarHostedInsightGateway] when the Cloud
 * Function rejects the call because the signed-in user does not
 * have an active BurnBar Pro subscription. The orchestrator
 * catches this specifically and degrades to local rules with the
 * "Upgrade to BurnBar Pro" UI disclosure.
 */
class BurnBarProSubscriptionRequiredException(
    val productID: String? = null,
    cause: Throwable? = null,
) : IllegalStateException(
    "BurnBar Pro subscription required to use the hosted Intelligence Brief.",
    cause,
)
