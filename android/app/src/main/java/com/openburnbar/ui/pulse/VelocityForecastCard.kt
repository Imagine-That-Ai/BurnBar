// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.pulse

import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.openburnbar.data.models.TokenUsage
import com.openburnbar.data.models.UsageRollups
import com.openburnbar.ui.components.AuroraGlassCard
import com.openburnbar.ui.theme.AuroraRadius
import com.openburnbar.ui.theme.AuroraSpacing

@Composable
fun VelocityForecastCard(rollups: UsageRollups, liveUsages: List<TokenUsage> = emptyList()) {
    val state = remember(rollups, liveUsages) { computeVelocityForecastState(rollups, liveUsages) }
    AuroraGlassCard(
        modifier = Modifier.padding(horizontal = AuroraSpacing.LG.dp),
        cornerRadius = AuroraRadius.XL,
        contentPadding = AuroraSpacing.LG.dp,
    ) {
        VelocityForecastCardBody(state = state)
    }
}
