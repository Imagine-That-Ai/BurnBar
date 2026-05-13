package com.openburnbar.data.insights

import kotlinx.serialization.Serializable
import kotlinx.coroutines.flow.Flow

/**
 * Interface for LLM-backed canvas authoring. Each adapter implements
 * this to connect to a different model provider via SSE.
 */
interface InsightModelGateway {
    val providerKey: String
    val displayName: String
    val capabilities: InsightModelCapabilities

    suspend fun availableModels(): List<InsightCatalogModel>
    fun investigate(request: InsightInvestigateRequest): Flow<InsightInvestigateEvent>
}

/**
 * Capability matrix advertised by each gateway adapter.
 * Mirrors Swift InsightModelCapabilities.
 */
@Serializable
data class InsightModelCapabilities(
    val supportsStrictJSONSchema: Boolean = false,
    val supportsJSONObject: Boolean = true,
    val supportsThinking: Boolean = false,
    val supportsToolUse: Boolean = false,
    val supportsStreaming: Boolean = true
) {
    /** The best supported tier given the requested tier. */
    fun bestTier(requested: InsightCapabilityTier): InsightCapabilityTier {
        return when (requested) {
            InsightCapabilityTier.STRICT_JSON_SCHEMA -> when {
                supportsStrictJSONSchema -> InsightCapabilityTier.STRICT_JSON_SCHEMA
                supportsJSONObject -> InsightCapabilityTier.JSON_OBJECT
                else -> InsightCapabilityTier.NARRATIVE_ONLY
            }
            InsightCapabilityTier.JSON_OBJECT -> when {
                supportsJSONObject -> InsightCapabilityTier.JSON_OBJECT
                else -> InsightCapabilityTier.NARRATIVE_ONLY
            }
            InsightCapabilityTier.NARRATIVE_ONLY -> InsightCapabilityTier.NARRATIVE_ONLY
        }
    }
}

@Serializable
data class InsightCatalogModel(
    val id: String,
    val displayName: String,
    val providerKey: String,
    val capabilities: InsightModelCapabilities
)
