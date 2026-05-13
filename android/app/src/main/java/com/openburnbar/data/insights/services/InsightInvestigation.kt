package com.openburnbar.data.insights.services

import com.openburnbar.data.insights.InsightCanvas
import com.openburnbar.data.insights.InsightInvestigateEvent
import com.openburnbar.data.insights.InsightInvestigateRequest
import com.openburnbar.data.insights.InsightEgressTier
import com.openburnbar.data.insights.InsightFilter
import com.openburnbar.data.insights.InsightModelCapabilities
import com.openburnbar.data.insights.InsightModelGateway
import com.openburnbar.data.insights.InsightCatalogModel
import com.openburnbar.data.insights.services.adapters.LocalRuleBasedAdapter
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn

/**
 * Orchestrates an investigation: builds the digest, selects the gateway,
 * streams events, and persists the result.
 */
class InsightInvestigation(
    private val dataSources: Map<String, InsightModelGateway> = emptyMap()
) {

    suspend fun investigate(request: InsightInvestigateRequest): Flow<InsightInvestigateEvent> {
        val gateway = dataSources[request.modelTag.providerKey]
            ?: dataSources["local"]
            ?: LocalGateway

        return gateway.investigate(request).flowOn(Dispatchers.Default)
    }

    /** The built-in local gateway that always produces a rule-based canvas. */
    private object LocalGateway : InsightModelGateway {
        override val providerKey = "local"
        override val displayName = "Local Rules"
        override val capabilities = InsightModelCapabilities(
            supportsStrictJSONSchema = false,
            supportsJSONObject = false,
            supportsThinking = false,
            supportsToolUse = false,
            supportsStreaming = false
        )

        override suspend fun availableModels() = listOf(
            InsightCatalogModel(id = "rules", displayName = "Local Rules", providerKey = "local", capabilities = capabilities)
        )

        override fun investigate(request: InsightInvestigateRequest): Flow<InsightInvestigateEvent> = flow {
            emit(InsightInvestigateEvent.ThinkingDelta("Analyzing your data…"))
            delay(100)
            val canvas = LocalRuleBasedAdapter.buildCanvas(request.digest, request.canvas?.filter ?: InsightFilter())
            emit(InsightInvestigateEvent.FinalCanvas(canvas))
        }
    }
}
