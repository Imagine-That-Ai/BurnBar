package com.openburnbar.data.insights

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Lifecycle state of an individual widget's data.
 */
@Serializable
enum class InsightFreshness {
    @SerialName("fresh") FRESH,
    @SerialName("stale") STALE,
    @SerialName("computing") COMPUTING,
    @SerialName("error") ERROR,
    @SerialName("locked") LOCKED;
}
