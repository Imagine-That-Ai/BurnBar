package com.openburnbar.data.insights.services

import com.google.firebase.functions.FirebaseFunctions
import com.google.firebase.functions.FirebaseFunctionsException
import com.openburnbar.data.insights.InsightAnalysisRequest
import com.openburnbar.data.insights.InsightAnalysisResult
import com.openburnbar.data.insights.InsightEgressTier
import com.openburnbar.data.insights.InsightModelTag
import java.time.Instant
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

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
    override val models: List<InsightModelTag> =
        listOf(
            InsightModelTag(
                providerKey = providerKey,
                modelID = modelID,
                displayName = modelDisplayName,
                egressTier = InsightEgressTier.HOSTED,
                stampedAt = Instant.now().toString(),
            ),
        )

    override suspend fun analyze(request: InsightAnalysisRequest): InsightAnalysisResult = withContext(Dispatchers.IO) {
        val response =
            invokeHostedInsightCallable(
                functionsProvider = functionsProvider,
                callableName = callableName,
                modelID = modelID,
                modelDisplayName = modelDisplayName,
                providerKey = providerKey,
                request = request,
            )
        val stamped = hydrateHostedInsightResult(request, response)
        attachHostedFollowUpBriefing(request, stamped, response.resolvedDisplayName)
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
            val fex =
                t as? FirebaseFunctionsException
                    ?: t.cause as? FirebaseFunctionsException
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
            val fex =
                t as? FirebaseFunctionsException
                    ?: t.cause as? FirebaseFunctionsException
                    ?: return null
            val detailMap = fex.details as? Map<*, *>
            return detailMap?.get("productID") as? String
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
