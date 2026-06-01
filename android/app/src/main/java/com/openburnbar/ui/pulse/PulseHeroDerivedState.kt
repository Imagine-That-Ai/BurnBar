package com.openburnbar.ui.pulse

import androidx.compose.ui.graphics.Color

internal data class PulseHeroDerivedState(
    val trailingAverage: Double,
    val deltaPct: Double,
    val isBelow: Boolean,
    val absDelta: Double,
    val accent: Color,
    val isLive: Boolean,
    val burnRateText: String?,
    val tokens: Long,
    val requests: Int,
)
