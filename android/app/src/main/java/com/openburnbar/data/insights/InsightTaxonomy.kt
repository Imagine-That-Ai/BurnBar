package com.openburnbar.data.insights

import kotlinx.serialization.Serializable

/**
 * Controlled vocabulary the LLM must use when tagging conversations,
 * agents, and models. Mirrors Swift InsightTaxonomy.
 */
@Serializable
data class InsightTaxonomy(
    val focuses: List<String> = DEFAULT.focuses,
    val useCases: List<String> = DEFAULT.useCases
) {
    companion object {
        val DEFAULT = InsightTaxonomy(
            focuses = listOf(
                "code", "write", "debug", "research", "refactor",
                "ops", "test", "review", "design", "data", "doc", "explore"
            ),
            useCases = listOf(
                "feature-add", "bug-fix", "refactor", "test-write", "doc-write",
                "code-explain", "code-review", "data-analysis", "shell-script",
                "spike", "spike-cleanup", "infra-change", "migration",
                "perf-investigation", "security-investigation", "third-party-eval", "learning"
            )
        )
    }

    fun isKnownFocus(tag: String): Boolean = focuses.contains(tag)
    fun isKnownUseCase(tag: String): Boolean = useCases.contains(tag)
}
