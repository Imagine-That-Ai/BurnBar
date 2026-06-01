@file:Suppress("MagicNumber")
// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.pulse

import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.openburnbar.data.models.TokenUsage
import com.openburnbar.data.models.UsageDisplayMode
import com.openburnbar.data.models.UsageRollups
import com.openburnbar.ui.components.AuroraGlassCard
import com.openburnbar.ui.theme.AuroraRadius
import com.openburnbar.ui.theme.AuroraSpacing

@Composable
fun VelocityForecastCard(rollups: UsageRollups, liveUsages: List<TokenUsage> = emptyList()) {
    val state = remember(rollups, liveUsages) { computeVelocityForecastState(rollups, liveUsages) }
    AuroraGlassCard(
        modifier = Modifier.padding(horizontal = AuroraSpacing.lg.dp),
        cornerRadius = AuroraRadius.xl,
        contentPadding = AuroraSpacing.lg.dp,
    ) {
        VelocityForecastCardBody(state = state)
    }
}

@Composable
fun VelocityForecastCard(todayValue: Double, trailingValue: Double, @Suppress("UNUSED_PARAMETER") displayMode: UsageDisplayMode) {
    val rollups = remember(todayValue, trailingValue) { UsageRollups(today = todayValue, sevenDays = trailingValue) }
    VelocityForecastCard(rollups = rollups, liveUsages = emptyList())
}
