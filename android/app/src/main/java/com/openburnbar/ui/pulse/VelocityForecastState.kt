package com.openburnbar.ui.pulse

internal data class VelocityForecastState(
    val dayFraction: Double,
    val projected: Double,
    val aheadOfPace: Boolean,
)
