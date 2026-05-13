package com.openburnbar.data.insights

import kotlinx.serialization.Serializable

/**
 * Token + cost accounting produced by a single LLM investigation.
 */
@Serializable
data class InsightTokenUsage(
    val providerKey: String,
    val modelID: String,
    val inputTokens: Int = 0,
    val outputTokens: Int = 0,
    val reasoningTokens: Int = 0,
    val cacheCreationTokens: Int = 0,
    val cacheReadTokens: Int = 0,
    val estimatedCostUSD: Double = 0.0,
    val startedAt: String = "",
    val completedAt: String = ""
) {
    val totalTokens: Int get() = inputTokens + outputTokens + reasoningTokens + cacheCreationTokens + cacheReadTokens
}
