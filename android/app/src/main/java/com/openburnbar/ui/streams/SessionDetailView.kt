@file:Suppress("MagicNumber")
// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.streams

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.openburnbar.data.models.AgentProvider
import com.openburnbar.data.models.TokenUsage
import com.openburnbar.ui.theme.AuroraSpacing

@Composable
fun SessionDetailView(usage: TokenUsage) {
    val provider = AgentProvider.fromKey(usage.provider)
    val cacheHitRatio =
        if (usage.totalTokens > 0) {
            ((usage.cacheReadTokens + usage.cacheCreationTokens).toDouble() / usage.totalTokens).coerceIn(0.0, 1.0)
        } else {
            0.0
        }

    Column(
        modifier =
        Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = AuroraSpacing.lg.dp)
            .padding(top = AuroraSpacing.lg.dp)
            .padding(bottom = 120.dp),
    ) {
        SessionDetailHeroCard(usage = usage, provider = provider, cacheHitRatio = cacheHitRatio)
        Spacer(modifier = Modifier.height(AuroraSpacing.xl.dp))
        SessionDetailTokenBreakdownCard(usage = usage)
        Spacer(modifier = Modifier.height(AuroraSpacing.xl.dp))
        SessionDetailProvenanceCard(usage = usage)
        usage.sourceDeviceId?.takeIf { it.isNotEmpty() }?.let { deviceId ->
            Spacer(modifier = Modifier.height(AuroraSpacing.xl.dp))
            SessionDetailDeviceCard(sourceDeviceId = deviceId)
        }
    }
}
