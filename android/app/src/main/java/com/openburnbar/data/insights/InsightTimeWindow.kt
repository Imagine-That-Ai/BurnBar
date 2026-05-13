package com.openburnbar.data.insights

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Time window the filter applies over. Mirrors Swift InsightTimeWindow.
 * Custom ranges use ISO-8601 start/end strings.
 * @SerialName annotations match the TypeScript discriminated union keys.
 */
@Serializable
sealed class InsightTimeWindow {
    @Serializable data object Today : InsightTimeWindow()
    @Serializable data object Last24h : InsightTimeWindow()
    @Serializable data object Last7d : InsightTimeWindow()
    @Serializable data object Last30d : InsightTimeWindow()
    @Serializable data object Last90d : InsightTimeWindow()
    @Serializable data object Last365d : InsightTimeWindow()
    @Serializable data object AllTime : InsightTimeWindow()
    @Serializable data class Custom(val start: String, val end: String) : InsightTimeWindow()
}
