package com.openburnbar.ui.pulse

import androidx.compose.animation.core.*
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.LocalFireDepartment
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.models.RollupSummary
import com.openburnbar.data.models.UsageDisplayMode
import com.openburnbar.data.models.UsageRollups
import com.openburnbar.ui.burn.ProviderAuroraAvatar
import com.openburnbar.ui.components.AuroraGlassCard
import com.openburnbar.ui.components.BreathingDot
import androidx.compose.foundation.border
import com.openburnbar.ui.theme.*
import com.openburnbar.util.Formatting

@Composable
fun PulseHeroBurnCard(
    rollups: UsageRollups,
    displayMode: UsageDisplayMode,
    scope: PulseTimelineScope,
    topProvider: RollupSummary?,
    dailyPoints: Map<String, Double>,
    onDisplayModeChange: (UsageDisplayMode) -> Unit
) {
    val windowValue = when (scope) {
        PulseTimelineScope.MINUTE,
        PulseTimelineScope.HOUR,
        PulseTimelineScope.DAY -> rollups.today
        PulseTimelineScope.WEEK -> rollups.sevenDays
        PulseTimelineScope.MONTH -> rollups.thirtyDays
    }
    val trailingValue = when (scope) {
        PulseTimelineScope.MINUTE,
        PulseTimelineScope.HOUR -> rollups.today
        PulseTimelineScope.DAY -> rollups.sevenDays
        PulseTimelineScope.WEEK -> rollups.thirtyDays
        PulseTimelineScope.MONTH -> rollups.ninetyDays
    }
    val totalTokens = rollups.totals["tokens"] ?: 0.0
    val totalRequests = rollups.totals["requests"] ?: 0.0

    val heroValueText = when (displayMode) {
        UsageDisplayMode.CURRENCY -> Formatting.formatCurrency(windowValue)
        UsageDisplayMode.TOKENS -> Formatting.formatTokens(totalTokens.toLong())
    }
    val heroSubtitleText = when (displayMode) {
        UsageDisplayMode.CURRENCY -> "${Formatting.formatTokens(totalTokens.toLong())} tokens · ${totalRequests.toInt()} requests"
        UsageDisplayMode.TOKENS -> "${Formatting.formatCurrency(windowValue)} · ${totalRequests.toInt()} requests"
    }

    // Delta calculation
    val divisor = when (scope) {
        PulseTimelineScope.MINUTE,
        PulseTimelineScope.HOUR,
        PulseTimelineScope.DAY,
        PulseTimelineScope.WEEK -> 7.0
        PulseTimelineScope.MONTH -> 30.0
    }
    val avg = trailingValue / divisor
    val pct = if (avg > 0) ((windowValue - avg) / avg) * 100 else 0.0
    val isAhead = pct >= 0

    AuroraGlassCard(
        modifier = Modifier.padding(horizontal = AuroraSpacing.lg.dp),
        cornerRadius = AuroraRadius.xl
    ) {
        Box(modifier = Modifier.fillMaxWidth()) {
            Column(
                modifier = Modifier
                    .padding(AuroraSpacing.lg.dp)
                    .fillMaxWidth()
            ) {
                // Top row
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            text = scope.headerLabel,
                            fontSize = AuroraTypography.tiny.sp,
                            fontWeight = FontWeight.SemiBold,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            letterSpacing = 2.sp
                        )
                        if (scope == PulseTimelineScope.MINUTE ||
                            scope == PulseTimelineScope.HOUR ||
                            scope == PulseTimelineScope.DAY) {
                            Spacer(modifier = Modifier.width(6.dp))
                            BreathingDot(size = 6, color = AuroraColors.success)
                        }
                    }
                    ModeToggleChip(
                        displayMode = displayMode,
                        onToggle = onDisplayModeChange
                    )
                }

                Spacer(modifier = Modifier.height(AuroraSpacing.md.dp))

                // Hero metric with sparkline
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.Bottom
                ) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            text = heroValueText,
                            fontSize = AuroraTypography.displayHero.sp,
                            fontWeight = FontWeight.Bold,
                            color = MaterialTheme.colorScheme.onSurface
                        )
                        Text(
                            text = heroSubtitleText,
                            fontSize = AuroraTypography.caption.sp,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                    // Mini sparkline
                    MiniSparkline(
                        values = dailyPoints.values.toList(),
                        modifier = Modifier
                            .width(80.dp)
                            .height(40.dp)
                    )
                }

                Spacer(modifier = Modifier.height(AuroraSpacing.sm.dp))

                // Supporting row
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(
                        imageVector = Icons.Filled.LocalFireDepartment,
                        contentDescription = null,
                        tint = AuroraColors.amber,
                        modifier = Modifier.size(12.dp)
                    )
                    Spacer(modifier = Modifier.width(4.dp))
                    Text(
                        text = "Streaming live from your Mac",
                        fontSize = AuroraTypography.tiny.sp,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }

                // Delta row
                if (trailingValue > 0) {
                    Spacer(modifier = Modifier.height(AuroraSpacing.sm.dp))
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            text = "${if (isAhead) "↑" else "↓"} ${if (isAhead) "Ahead of" else "Below"} your ${trailingLabel(scope)} average",
                            fontSize = AuroraTypography.tiny.sp,
                            fontWeight = FontWeight.SemiBold,
                            color = if (isAhead) AuroraColors.amber else AuroraColors.success
                        )
                    }
                }
            }

            // Top provider avatar
            topProvider?.let { tp ->
                ProviderAuroraAvatar(
                    providerKey = tp.provider,
                    size = 56,
                    modifier = Modifier
                        .align(Alignment.TopEnd)
                        .padding(AuroraSpacing.md.dp)
                )
            }
        }
    }
}

@Composable
private fun ModeToggleChip(
    displayMode: UsageDisplayMode,
    onToggle: (UsageDisplayMode) -> Unit
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .clip(CircleShape)
            .background(AuroraColors.ember.copy(alpha = 0.18f))
            .border(0.5.dp, AuroraColors.ember.copy(alpha = 0.4f), CircleShape)
            .clickable { onToggle(if (displayMode == UsageDisplayMode.CURRENCY) UsageDisplayMode.TOKENS else UsageDisplayMode.CURRENCY) }
            .padding(horizontal = 10.dp, vertical = 5.dp)
    ) {
        Text(
            text = if (displayMode == UsageDisplayMode.CURRENCY) "$" else "#",
            fontSize = 10.sp,
            fontWeight = FontWeight.Bold,
            color = AuroraColors.ember
        )
        Spacer(modifier = Modifier.width(4.dp))
        Text(
            text = displayMode.label,
            fontSize = AuroraTypography.tiny.sp,
            fontWeight = FontWeight.SemiBold,
            color = AuroraColors.ember
        )
    }
}

private fun trailingLabel(scope: PulseTimelineScope): String = when (scope) {
    PulseTimelineScope.MINUTE,
    PulseTimelineScope.HOUR,
    PulseTimelineScope.DAY -> "7-day"
    PulseTimelineScope.WEEK -> "30-day"
    PulseTimelineScope.MONTH -> "90-day"
}

@Composable
private fun MiniSparkline(
    values: List<Double>,
    modifier: Modifier = Modifier
) {
    if (values.size < 2) return
    val primary = AuroraColors.ember
    Canvas(modifier = modifier) {
        val maxVal = values.maxOrNull() ?: 1.0
        val minVal = values.minOrNull() ?: 0.0
        val range = (maxVal - minVal).coerceAtLeast(0.001)
        val stepX = size.width / (values.size - 1)

        val path = Path().apply {
            values.forEachIndexed { index, value ->
                val x = index * stepX
                val y = size.height - ((value - minVal) / range * size.height).toFloat()
                if (index == 0) moveTo(x, y) else lineTo(x, y)
            }
        }
        drawPath(
            path = path,
            color = primary.copy(alpha = 0.6f),
            style = androidx.compose.ui.graphics.drawscope.Stroke(width = 2f)
        )
    }
}
