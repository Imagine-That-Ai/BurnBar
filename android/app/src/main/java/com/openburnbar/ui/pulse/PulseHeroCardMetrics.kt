package com.openburnbar.ui.pulse

import com.openburnbar.data.models.RollupSummary
import com.openburnbar.data.models.TokenUsage
import com.openburnbar.data.models.UsageDisplayMode

data class PulseHeroCardMetrics(
    val displayMode: UsageDisplayMode,
    val value: Double,
    val trailingValue: Double,
    val tokenValue: Long,
    val trailingTokenValue: Long,
    val requestValue: Int,
    val totals: Map<String, Double>,
    val timelineScope: PulseTimelineScope,
    val topProvider: RollupSummary?,
    val liveUsages: List<TokenUsage> = emptyList(),
    val dailyPoints: Map<String, Double> = emptyMap(),
    val nowMillis: Long = System.currentTimeMillis(),
)
