package com.openburnbar.ui.streams

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Divider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.models.AgentProvider
import com.openburnbar.data.models.TokenUsage
import com.openburnbar.ui.burn.ProviderAuroraAvatar
import com.openburnbar.ui.components.AuroraGlassCard
import com.openburnbar.ui.theme.*
import com.openburnbar.util.Formatting

@Composable
fun SessionDetailView(
    usage: TokenUsage
) {
    val provider = AgentProvider.fromKey(usage.provider)
    val themeColor = provider?.let { Color(it.brandColor) } ?: MaterialTheme.colorScheme.onSurfaceVariant

    val cacheHitRatio = if (usage.totalTokens > 0) {
        ((usage.cacheReadTokens + usage.cacheCreationTokens).toDouble() / usage.totalTokens).coerceIn(0.0, 1.0)
    } else 0.0

    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = AuroraSpacing.lg.dp)
            .padding(top = AuroraSpacing.lg.dp)
            .padding(bottom = 120.dp)
    ) {
        // Hero header
        AuroraGlassCard {
            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(AuroraSpacing.xl.dp)
            ) {
                provider?.let {
                    ProviderAuroraAvatar(provider = it, size = 64, showHalo = true)
                }
                Spacer(modifier = Modifier.height(AuroraSpacing.md.dp))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    val modelKey = usage.model
                    if (!modelKey.isNullOrBlank()) {
                        com.openburnbar.ui.components.ModelLogo(modelKey = modelKey, size = 20.dp)
                        Spacer(modifier = Modifier.width(AuroraSpacing.xs.dp))
                    }
                    Text(
                        text = modelKey ?: "Unknown model",
                        fontSize = AuroraTypography.headline.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = MaterialTheme.colorScheme.onSurface
                    )
                }
                Text(
                    text = provider?.displayName ?: usage.provider,
                    fontSize = AuroraTypography.body.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
                Spacer(modifier = Modifier.height(AuroraSpacing.sm.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.md.dp)) {
                    MetricPill(title = "Cost", value = Formatting.formatCurrency(usage.effectiveCost))
                    MetricPill(title = "Tokens", value = Formatting.formatTokens(usage.totalTokens))
                    val durationMin = if (usage.endTime > usage.startTime) {
                        ((usage.endTime - usage.startTime) / 60000).toInt()
                    } else 0
                    MetricPill(title = "Duration", value = if (durationMin > 0) "${durationMin}m" else "—")
                    if (usage.cacheReadTokens > 0 || usage.cacheCreationTokens > 0) {
                        MetricPill(title = "Cache", value = "${(cacheHitRatio * 100).toInt()}%")
                    }
                }
            }
        }

        Spacer(modifier = Modifier.height(AuroraSpacing.xl.dp))

        // Token breakdown
        AuroraGlassCard {
            Column(modifier = Modifier.padding(AuroraSpacing.lg.dp)) {
                Text(
                    text = "Tokens",
                    fontSize = AuroraTypography.headline.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = MaterialTheme.colorScheme.onSurface
                )
                Spacer(modifier = Modifier.height(AuroraSpacing.md.dp))

                // Token mix bar
                TokenMixBar(usage = usage)
                Spacer(modifier = Modifier.height(AuroraSpacing.md.dp))

                Column(verticalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp)) {
                    TokenPill(label = "Input", value = usage.inputTokens, color = AuroraColors.whimsy)
                    TokenPill(label = "Output", value = usage.outputTokens, color = AuroraColors.ember)
                    if (usage.cacheCreationTokens > 0) {
                        TokenPill(label = "Cache Creation", value = usage.cacheCreationTokens, color = AuroraColors.amber)
                    }
                    if (usage.cacheReadTokens > 0) {
                        TokenPill(label = "Cache Read", value = usage.cacheReadTokens, color = AuroraColors.success)
                    }
                    if (usage.reasoningTokens > 0) {
                        TokenPill(label = "Reasoning", value = usage.reasoningTokens, color = Color(0xFFB580E8))
                    }
                    Divider(modifier = Modifier.padding(vertical = 2.dp))
                    TokenPill(label = "Total", value = usage.totalTokens, isTotal = true)
                }
            }
        }

        Spacer(modifier = Modifier.height(AuroraSpacing.xl.dp))

        // Provenance
        AuroraGlassCard {
            Column(modifier = Modifier.padding(AuroraSpacing.lg.dp)) {
                Text(
                    text = "Provenance",
                    fontSize = AuroraTypography.headline.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = MaterialTheme.colorScheme.onSurface
                )
                Spacer(modifier = Modifier.height(AuroraSpacing.md.dp))
                ProvenanceChip(label = "Method", value = usage.provenanceMethod ?: "—")
                ProvenanceChip(label = "Confidence", value = usage.provenanceConfidence ?: "—")
                if (!usage.projectName.isNullOrEmpty()) {
                    ProvenanceChip(label = "Project", value = usage.projectName)
                }
            }
        }

        Spacer(modifier = Modifier.height(AuroraSpacing.xl.dp))

        // Device
        if (!usage.sourceDeviceId.isNullOrEmpty()) {
            AuroraGlassCard {
                Column(modifier = Modifier.padding(AuroraSpacing.lg.dp)) {
                    Text(
                        text = "Device",
                        fontSize = AuroraTypography.headline.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = MaterialTheme.colorScheme.onSurface
                    )
                    Spacer(modifier = Modifier.height(AuroraSpacing.md.dp))
                    usage.sourceDeviceId?.let {
                        ProvenanceChip(label = "ID", value = it)
                    }
                }
            }
        }
    }
}

@Composable
private fun TokenMixBar(usage: TokenUsage) {
    val total = usage.totalTokens.coerceAtLeast(1)
    val segments = listOfNotNull(
        if (usage.inputTokens > 0) usage.inputTokens to AuroraColors.whimsy else null,
        if (usage.outputTokens > 0) usage.outputTokens to AuroraColors.ember else null,
        if (usage.cacheReadTokens > 0) usage.cacheReadTokens to AuroraColors.success else null,
        if (usage.cacheCreationTokens > 0) usage.cacheCreationTokens to AuroraColors.amber else null,
        if (usage.reasoningTokens > 0) usage.reasoningTokens to Color(0xFFB580E8) else null
    )

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .height(10.dp)
            .clip(RoundedCornerShape(5.dp))
    ) {
        segments.forEach { (value, color) ->
            val fraction = value.toFloat() / total
            val animatedFraction by animateFloatAsState(
                targetValue = fraction,
                animationSpec = tween(500),
                label = "token_mix"
            )
            Box(
                modifier = Modifier
                    .fillMaxHeight()
                    .weight(animatedFraction.coerceAtLeast(0.001f))
                    .background(color)
            )
        }
    }
}

@Composable
private fun TokenPill(
    label: String,
    value: Int,
    color: Color? = null,
    isTotal: Boolean = false
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth()
    ) {
        if (color != null) {
            Box(
                modifier = Modifier
                    .size(14.dp)
                    .background(color.copy(alpha = 0.22f), RoundedCornerShape(7.dp)),
                contentAlignment = Alignment.Center
            ) {
                Box(
                    modifier = Modifier
                        .size(9.dp)
                        .background(color, RoundedCornerShape(4.5.dp))
                )
            }
            Spacer(modifier = Modifier.width(AuroraSpacing.sm.dp))
        }
        Text(
            text = label,
            fontSize = if (isTotal) AuroraTypography.caption.sp else AuroraTypography.body.sp,
            fontWeight = if (isTotal) FontWeight.SemiBold else FontWeight.Normal,
            color = if (isTotal) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.onSurfaceVariant
        )
        Spacer(modifier = Modifier.weight(1f))
        Text(
            text = Formatting.formatTokens(value),
            fontSize = if (isTotal) AuroraTypography.headline.sp else AuroraTypography.body.sp,
            fontWeight = if (isTotal) FontWeight.Bold else FontWeight.Medium,
            color = MaterialTheme.colorScheme.onSurface
        )
    }
}

@Composable
private fun MetricPill(
    title: String,
    value: String
) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier = Modifier
            .clip(RoundedCornerShape(AuroraRadius.sm.dp))
            .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.6f))
            .padding(horizontal = 12.dp, vertical = 6.dp)
    ) {
        Text(
            text = value,
            fontSize = AuroraTypography.caption.sp,
            color = MaterialTheme.colorScheme.onSurface
        )
        Text(
            text = title,
            fontSize = AuroraTypography.tiny.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
    }
}

@Composable
private fun ProvenanceChip(
    label: String,
    value: String
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 4.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically
    ) {
        Text(
            text = label,
            fontSize = AuroraTypography.body.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
        Text(
            text = value,
            fontSize = AuroraTypography.caption.sp,
            color = MaterialTheme.colorScheme.onSurface,
            modifier = Modifier
                .clip(RoundedCornerShape(6.dp))
                .background(MaterialTheme.colorScheme.surfaceVariant)
                .padding(horizontal = 8.dp, vertical = 2.dp)
        )
    }
}
