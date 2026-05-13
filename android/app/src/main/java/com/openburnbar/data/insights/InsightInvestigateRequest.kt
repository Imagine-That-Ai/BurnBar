package com.openburnbar.data.insights

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * What the user is asking the model to do.
 */
@Serializable
data class InsightInvestigateRequest(
    val prompt: String,
    val digest: InsightDigest,
    val canvas: InsightCanvas? = null,
    val widget: InsightWidget? = null,
    val modelTag: InsightModelTag,
    val capabilityTier: InsightCapabilityTier = InsightCapabilityTier.STRICT_JSON_SCHEMA,
    val maxNewWidgets: Int = 12,
    val allowToolCalls: Boolean = true,
    val instruction: Instruction = Instruction.COMPOSE_CANVAS
) {
    @Serializable
    enum class Instruction {
        @SerialName("composeCanvas") COMPOSE_CANVAS,
        @SerialName("refineCanvas") REFINE_CANVAS,
        @SerialName("refreshNarratives") REFRESH_NARRATIVES,
        @SerialName("refineWidget") REFINE_WIDGET,
        @SerialName("explainBriefly") EXPLAIN_BRIEFLY
    }
}

/**
 * The structured-output tier a model is being invoked at.
 * Mirrors Swift InsightCapabilityTier exactly.
 */
@Serializable
enum class InsightCapabilityTier(val displayName: String) {
    @SerialName("strictJSONSchema") STRICT_JSON_SCHEMA("Strict JSON"),
    @SerialName("jsonObject") JSON_OBJECT("JSON Object"),
    @SerialName("narrativeOnly") NARRATIVE_ONLY("Narrative only");
}
