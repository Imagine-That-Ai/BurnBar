package com.openburnbar.data.insights

import kotlinx.serialization.Serializable

/**
 * Identity of the model that authored a canvas or widget.
 */
@Serializable
data class InsightModelTag(
    val providerKey: String,
    val modelID: String,
    val displayName: String,
    val egressTier: InsightEgressTier = InsightEgressTier.LOCAL_ONLY,
    val stampedAt: String = ""
)
