package com.openburnbar.data.insights

import java.util.UUID
import kotlinx.serialization.Serializable

/**
 * A single widget on a canvas. Mirrors Swift InsightWidget.
 */
@Serializable
data class InsightWidget(
    val id: String = UUID.randomUUID().toString(),
    val kind: InsightWidgetKind,
    val title: String,
    val subtitle: String? = null,
    val spec: InsightWidgetSpec,
    val dataBinding: InsightDataBinding,
    val data: InsightWidgetData? = null,
    val filter: InsightFilter? = null,
    val freshness: InsightFreshness = InsightFreshness.STALE,
    val modelTag: InsightModelTag? = null,
    val lockedAt: String? = null,
    val lastComputedAt: String? = null,
    val schemaVersion: Int = CURRENT_SCHEMA_VERSION,
    val rationale: String? = null,
) {
    companion object {
        const val CURRENT_SCHEMA_VERSION = 1
    }
}
