package com.openburnbar.data.insights

import kotlinx.serialization.Serializable

/**
 * A drill-down anchor a widget can attach to its narrative.
 * Opaque to the LLM — it produces them, but never needs to know
 * the storage layout. The shell layer resolves each citation.
 */
@Serializable
data class InsightCitation(
    val id: String,
    val kind: Kind,
    val label: String
) {
    @Serializable
    sealed class Kind {
        @Serializable data class Session(val id: String, val provider: String? = null) : Kind()
        @Serializable data class Model(val id: String) : Kind()
        @Serializable data class Agent(val provider: String) : Kind()
        @Serializable data class Project(val name: String) : Kind()
        @Serializable data class Day(val date: String) : Kind()
        @Serializable data class Anomaly(val id: String) : Kind()
        @Serializable data class Query(val text: String) : Kind()
        @Serializable data class Quota(val provider: String, val bucket: String) : Kind()
    }
}
