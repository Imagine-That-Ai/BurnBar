// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.streams

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp
import androidx.compose.ui.unit.dp
import com.openburnbar.data.models.AgentProvider
import com.openburnbar.data.models.TokenUsage
import com.openburnbar.ui.burn.ProviderAuroraAvatar
import com.openburnbar.ui.components.AuroraGlassCard
import com.openburnbar.ui.components.ModelLogo
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraRadius
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraTypography
import com.openburnbar.util.Formatting

@Composable
internal fun SessionDetailHeroCard(usage: TokenUsage, provider: AgentProvider?, cacheHitRatio: Double) {
    AuroraGlassCard {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            modifier =
            Modifier
                .fillMaxWidth()
                .padding(AuroraSpacing.xl.dp),
        ) {
            provider?.let {
                ProviderAuroraAvatar(provider = it, size = 64, showHalo = true)
            }
            Spacer(modifier = Modifier.height(AuroraSpacing.md.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                val modelKey = usage.model
                if (!modelKey.isNullOrBlank()) {
                    ModelLogo(modelKey = modelKey, size = 20.dp)
                    Spacer(modifier = Modifier.width(AuroraSpacing.xs.dp))
                }
                Text(
                    text = modelKey ?: "Unknown model",
                    fontSize = AuroraTypography.headline.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = MaterialTheme.colorScheme.onSurface,
                )
            }
            Text(
                text = provider?.displayName ?: usage.provider,
                fontSize = AuroraTypography.body.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Spacer(modifier = Modifier.height(AuroraSpacing.sm.dp))
            SessionDetailMetricRow(usage = usage, cacheHitRatio = cacheHitRatio)
        }
    }
}

@Composable
private fun SessionDetailMetricRow(usage: TokenUsage, cacheHitRatio: Double) {
    Row(horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.md.dp)) {
        SessionDetailMetricPill(title = "Cost", value = Formatting.formatCurrency(usage.effectiveCost))
        SessionDetailMetricPill(title = "Tokens", value = Formatting.formatTokens(usage.totalTokens))
        val durationMin =
            if (usage.endTime > usage.startTime) {
                ((usage.endTime - usage.startTime) / 60000).toInt()
            } else {
                0
            }
        SessionDetailMetricPill(title = "Duration", value = if (durationMin > 0) "${durationMin}m" else "—")
        if (usage.cacheReadTokens > 0 || usage.cacheCreationTokens > 0) {
            SessionDetailMetricPill(title = "Cache", value = "${(cacheHitRatio * 100).toInt()}%")
        }
    }
}

@Composable
internal fun SessionDetailTokenBreakdownCard(usage: TokenUsage) {
    AuroraGlassCard {
        Column(modifier = Modifier.padding(AuroraSpacing.lg.dp)) {
            Text(
                text = "Tokens",
                fontSize = AuroraTypography.headline.sp,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurface,
            )
            Spacer(modifier = Modifier.height(AuroraSpacing.md.dp))
            SessionDetailTokenMixBar(usage = usage)
            Spacer(modifier = Modifier.height(AuroraSpacing.md.dp))
            Column(verticalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp)) {
                SessionDetailTokenPill(label = "Input", value = usage.inputTokens, color = AuroraColors.whimsy)
                SessionDetailTokenPill(label = "Output", value = usage.outputTokens, color = AuroraColors.ember)
                if (usage.cacheCreationTokens > 0) {
                    SessionDetailTokenPill(label = "Cache Creation", value = usage.cacheCreationTokens, color = AuroraColors.amber)
                }
                if (usage.cacheReadTokens > 0) {
                    SessionDetailTokenPill(label = "Cache Read", value = usage.cacheReadTokens, color = AuroraColors.success)
                }
                if (usage.reasoningTokens > 0) {
                    SessionDetailTokenPill(label = "Reasoning", value = usage.reasoningTokens, color = Color(0xFFB580E8))
                }
                HorizontalDivider(modifier = Modifier.padding(vertical = 2.dp))
                SessionDetailTokenPill(label = "Total", value = usage.totalTokens, isTotal = true)
            }
        }
    }
}

@Composable
internal fun SessionDetailProvenanceCard(usage: TokenUsage) {
    AuroraGlassCard {
        Column(modifier = Modifier.padding(AuroraSpacing.lg.dp)) {
            Text(
                text = "Provenance",
                fontSize = AuroraTypography.headline.sp,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurface,
            )
            Spacer(modifier = Modifier.height(AuroraSpacing.md.dp))
            SessionDetailProvenanceChip(label = "Method", value = usage.provenanceMethod ?: "—")
            SessionDetailProvenanceChip(label = "Confidence", value = usage.provenanceConfidence ?: "—")
            if (!usage.projectName.isNullOrEmpty()) {
                SessionDetailProvenanceChip(label = "Project", value = usage.projectName)
            }
        }
    }
}

@Composable
internal fun SessionDetailDeviceCard(sourceDeviceId: String) {
    AuroraGlassCard {
        Column(modifier = Modifier.padding(AuroraSpacing.lg.dp)) {
            Text(
                text = "Device",
                fontSize = AuroraTypography.headline.sp,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurface,
            )
            Spacer(modifier = Modifier.height(AuroraSpacing.md.dp))
            SessionDetailProvenanceChip(label = "ID", value = sourceDeviceId)
        }
    }
}

@Composable
private fun SessionDetailTokenMixBar(usage: TokenUsage) {
    val total = usage.totalTokens.coerceAtLeast(1)
    val segments =
        listOfNotNull(
            if (usage.inputTokens > 0) usage.inputTokens to AuroraColors.whimsy else null,
            if (usage.outputTokens > 0) usage.outputTokens to AuroraColors.ember else null,
            if (usage.cacheReadTokens > 0) usage.cacheReadTokens to AuroraColors.success else null,
            if (usage.cacheCreationTokens > 0) usage.cacheCreationTokens to AuroraColors.amber else null,
            if (usage.reasoningTokens > 0) usage.reasoningTokens to Color(0xFFB580E8) else null,
        )

    Row(
        modifier =
        Modifier
            .fillMaxWidth()
            .height(10.dp)
            .clip(RoundedCornerShape(5.dp)),
    ) {
        segments.forEach { (value, color) ->
            val fraction = value.toFloat() / total
            val animatedFraction by animateFloatAsState(
                targetValue = fraction,
                animationSpec = tween(500),
                label = "token_mix",
            )
            Box(
                modifier =
                Modifier
                    .fillMaxHeight()
                    .weight(animatedFraction.coerceAtLeast(0.001f))
                    .background(color),
            )
        }
    }
}

@Composable
private fun SessionDetailTokenPill(label: String, value: Int, color: Color? = null, isTotal: Boolean = false) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth(),
    ) {
        if (color != null) {
            Box(
                modifier =
                Modifier
                    .size(14.dp)
                    .background(color.copy(alpha = 0.22f), RoundedCornerShape(7.dp)),
                contentAlignment = Alignment.Center,
            ) {
                Box(
                    modifier =
                    Modifier
                        .size(9.dp)
                        .background(color, RoundedCornerShape(4.5.dp)),
                )
            }
            Spacer(modifier = Modifier.width(AuroraSpacing.sm.dp))
        }
        Text(
            text = label,
            fontSize = if (isTotal) AuroraTypography.caption.sp else AuroraTypography.body.sp,
            fontWeight = if (isTotal) FontWeight.SemiBold else FontWeight.Normal,
            color = if (isTotal) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(modifier = Modifier.weight(1f))
        Text(
            text = Formatting.formatTokens(value),
            fontSize = if (isTotal) AuroraTypography.headline.sp else AuroraTypography.body.sp,
            fontWeight = if (isTotal) FontWeight.Bold else FontWeight.Medium,
            color = MaterialTheme.colorScheme.onSurface,
        )
    }
}

@Composable
private fun SessionDetailMetricPill(title: String, value: String) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier =
        Modifier
            .clip(RoundedCornerShape(AuroraRadius.sm.dp))
            .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.6f))
            .padding(horizontal = 12.dp, vertical = 6.dp),
    ) {
        Text(
            text = value,
            fontSize = AuroraTypography.caption.sp,
            color = MaterialTheme.colorScheme.onSurface,
        )
        Text(
            text = title,
            fontSize = AuroraTypography.tiny.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun SessionDetailProvenanceChip(label: String, value: String) {
    Row(
        modifier =
        Modifier
            .fillMaxWidth()
            .padding(vertical = 4.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = label,
            fontSize = AuroraTypography.body.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Text(
            text = value,
            fontSize = AuroraTypography.caption.sp,
            color = MaterialTheme.colorScheme.onSurface,
            modifier =
            Modifier
                .clip(RoundedCornerShape(6.dp))
                .background(MaterialTheme.colorScheme.surfaceVariant)
                .padding(horizontal = 8.dp, vertical = 2.dp),
        )
    }
}
