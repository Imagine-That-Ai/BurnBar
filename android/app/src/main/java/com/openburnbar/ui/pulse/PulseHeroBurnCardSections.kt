@file:Suppress("MagicNumber")
// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.pulse

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.GraphicEq
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.models.TokenUsage
import com.openburnbar.data.models.UsageDisplayMode
import com.openburnbar.ui.burn.ProviderAuroraAvatar
import com.openburnbar.ui.components.AuroraGlassCard
import com.openburnbar.ui.components.BreathingDot
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraRadius
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.util.Formatting
import java.util.Locale

internal fun derivePulseHeroState(metrics: PulseHeroCardMetrics): PulseHeroDerivedState {
    val trailingDivisor =
        when (metrics.timelineScope) {
            PulseTimelineScope.MINUTE,
            PulseTimelineScope.HOUR,
            PulseTimelineScope.DAY,
            PulseTimelineScope.WEEK,
            -> 7.0
            PulseTimelineScope.MONTH -> 30.0
        }
    val trailingAverage = metrics.trailingValue / trailingDivisor
    val deltaPct =
        if (trailingAverage > 0) {
            (metrics.value - trailingAverage) / trailingAverage * 100.0
        } else {
            0.0
        }
    val isBelow = deltaPct < 0
    val absDelta = kotlin.math.abs(deltaPct)
    val accent = providerAccentColor(metrics.topProvider?.provider)
    val isLive =
        metrics.timelineScope == PulseTimelineScope.MINUTE ||
            metrics.timelineScope == PulseTimelineScope.HOUR ||
            metrics.timelineScope == PulseTimelineScope.DAY
    return PulseHeroDerivedState(
        trailingAverage = trailingAverage,
        deltaPct = deltaPct,
        isBelow = isBelow,
        absDelta = absDelta,
        accent = accent,
        isLive = isLive,
        burnRateText = null,
        tokens = metrics.tokenValue,
        requests = metrics.requestValue,
    )
}

@Composable
internal fun PulseHeroBurnCardHeader(
    timelineScope: PulseTimelineScope,
    isLive: Boolean,
    burnRateText: String?,
    displayMode: UsageDisplayMode,
    accent: Color,
    hasTopProvider: Boolean,
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        SectionHeaderRow(label = timelineScope.headerLabel, modifier = Modifier.weight(1f))
        if (isLive) {
            BreathingDot(size = 8, color = AuroraColors.success)
            Spacer(Modifier.width(8.dp))
        }
        burnRateText?.let { rateLabel ->
            BurnVelocityPill(
                icon = if (displayMode == UsageDisplayMode.CURRENCY) "$" else "#",
                text = rateLabel,
                accent = accent,
            )
            Spacer(Modifier.width(if (hasTopProvider) 64.dp else 0.dp))
        }
    }
}

@Composable
internal fun PulseHeroBurnCardMetricsBlock(
    displayMode: UsageDisplayMode,
    value: Double,
    tokens: Long,
    requests: Int,
) {
    Spacer(Modifier.height(AuroraSpacing.sm.dp))
    GradientCurrency(
        text =
        if (displayMode == UsageDisplayMode.CURRENCY) {
            Formatting.formatCurrency(value)
        } else {
            Formatting.formatTokens(tokens)
        },
        fontSize = 56,
    )
    Spacer(Modifier.height(AuroraSpacing.xs.dp))
    MetaRow(text = "${Formatting.formatTokens(tokens)} tokens · $requests requests")
}

@Composable
internal fun PulseHeroBurnCardComparisonLine(
    trailingValue: Double,
    absDelta: Double,
    isBelow: Boolean,
    timelineScope: PulseTimelineScope,
) {
    if (trailingValue <= 0) return
    Spacer(Modifier.height(AuroraSpacing.sm.dp))
    ComparisonLine(
        text = "${if (isBelow) "Below" else "Above"} ${absDelta.toInt()}% your ${trailingWindowLabel(timelineScope)} average",
        isBelow = isBelow,
    )
}

@Composable
internal fun PulseHeroBurnCardStreamingFooter(requests: Int) {
    Spacer(Modifier.height(AuroraSpacing.sm.dp))
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        StreamingLine(modifier = Modifier.weight(1f))
        if (requests > 0) {
            CallsPill(count = requests)
        }
    }
}

@Composable
internal fun BurnVelocityPill(icon: String, text: String, accent: Color) {
    val transition = rememberInfiniteTransition(label = "burn-rate")
    val breathing by transition.animateFloat(
        initialValue = 0f,
        targetValue = 1f,
        animationSpec =
        infiniteRepeatable(
            animation = tween(1600, easing = LinearEasing),
            repeatMode = RepeatMode.Reverse,
        ),
        label = "breathing",
    )
    val bgAlpha = 0.14f + 0.08f * breathing
    Surface(
        shape = CircleShape,
        color = accent.copy(alpha = bgAlpha),
        border = BorderStroke(0.5.dp, accent.copy(alpha = 0.4f)),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.padding(horizontal = 9.dp, vertical = 4.dp),
        ) {
            Text(text = icon, fontSize = 10.sp, fontWeight = FontWeight.ExtraBold, color = accent)
            Spacer(Modifier.width(4.dp))
            Text(text = text, fontSize = 11.sp, fontWeight = FontWeight.Bold, color = accent)
        }
    }
}

@Composable
internal fun CallsPill(count: Int) {
    Surface(
        shape = CircleShape,
        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.65f),
        border = BorderStroke(0.5.dp, MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.5f)),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.padding(horizontal = 9.dp, vertical = 4.dp),
        ) {
            Icon(
                imageVector = Icons.Filled.GraphicEq,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.size(10.dp),
            )
            Spacer(Modifier.width(4.dp))
            Text(text = "$count", fontSize = 11.sp, fontWeight = FontWeight.Bold, color = MaterialTheme.colorScheme.onSurface)
            Spacer(Modifier.width(4.dp))
            Text(text = "calls", fontSize = 10.sp, fontWeight = FontWeight.Medium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

@Composable
internal fun ProviderHaloAvatar(providerKey: String, accent: Color, modifier: Modifier = Modifier) {
    Box(modifier = modifier.size(80.dp), contentAlignment = Alignment.Center) {
        Canvas(modifier = Modifier.fillMaxSize()) {
            val r = size.minDimension / 2f
            drawCircle(
                brush =
                Brush.radialGradient(
                    colors =
                    listOf(
                        accent.copy(alpha = 0.55f),
                        accent.copy(alpha = 0.18f),
                        Color.Transparent,
                    ),
                    center = Offset(size.width / 2f, size.height / 2f),
                    radius = r,
                ),
                radius = r,
                center = Offset(size.width / 2f, size.height / 2f),
            )
        }
        ProviderAuroraAvatar(providerKey = providerKey, size = 52)
    }
}

internal fun providerAccentColor(providerKey: String?): Color {
    if (providerKey.isNullOrBlank()) return AuroraColors.ember
    return when (providerKey.lowercase()) {
        "openai" -> Color(0xFF74AA9C)
        "anthropic", "claude" -> Color(0xFFD97757)
        "google", "gemini" -> Color(0xFF4285F4)
        "cursor" -> Color(0xFF6E6E73)
        "codex" -> AuroraColors.whimsy
        "openrouter" -> AuroraColors.amber
        "zai" -> AuroraColors.whimsy
        "factory" -> AuroraColors.teal
        "kimi" -> AuroraColors.purple
        else -> AuroraColors.ember
    }
}

internal fun trailingWindowLabel(scope: PulseTimelineScope): String =
    when (scope) {
        PulseTimelineScope.MINUTE,
        PulseTimelineScope.HOUR,
        PulseTimelineScope.DAY,
        -> "7-day"
        PulseTimelineScope.WEEK -> "30-day"
        PulseTimelineScope.MONTH -> "90-day"
    }

@Composable
internal fun rememberBurnRateText(
    displayMode: UsageDisplayMode,
    liveUsages: List<TokenUsage>,
    nowMillis: Long,
): String? =
    remember(displayMode, liveUsages, nowMillis) {
        when (displayMode) {
            UsageDisplayMode.CURRENCY ->
                PulseBurnRate.dollarsPerMinute(liveUsages, nowMillis)?.let { rate ->
                    if (rate < 0.01) "<$0.01/min" else String.format(Locale.getDefault(), "$%.2f/min", rate)
                }
            UsageDisplayMode.TOKENS ->
                PulseBurnRate.tokensPerMinute(liveUsages, nowMillis)?.let { rate ->
                    "${Formatting.formatTokens(rate.toLong())}/min"
                }
        }
    }

@Composable
internal fun PulseHeroBurnCardBody(metrics: PulseHeroCardMetrics) {
    val derived = derivePulseHeroState(metrics)
    val burnRateText = rememberBurnRateText(metrics.displayMode, metrics.liveUsages, metrics.nowMillis)
    Box(modifier = Modifier.padding(horizontal = AuroraSpacing.lg.dp)) {
        PulseHeroBurnCardGlass(metrics = metrics, derived = derived, burnRateText = burnRateText)
    }
}

@Composable
private fun PulseHeroBurnCardGlass(
    metrics: PulseHeroCardMetrics,
    derived: PulseHeroDerivedState,
    burnRateText: String?,
) {
    val topProvider = metrics.topProvider
    AuroraGlassCard(
        modifier = Modifier.fillMaxWidth(),
        cornerRadius = AuroraRadius.xl,
        contentPadding = AuroraSpacing.lg.dp,
    ) {
        Box(modifier = Modifier.fillMaxWidth()) {
            PulseHeroBurnCardMainColumn(
                metrics = metrics,
                derived = derived,
                burnRateText = burnRateText,
                hasTopProvider = topProvider != null,
            )
            topProvider?.let { tp ->
                ProviderHaloAvatar(
                    providerKey = tp.provider,
                    accent = derived.accent,
                    modifier = Modifier.align(Alignment.TopEnd),
                )
            }
        }
    }
}

@Composable
private fun PulseHeroBurnCardMainColumn(
    metrics: PulseHeroCardMetrics,
    derived: PulseHeroDerivedState,
    burnRateText: String?,
    hasTopProvider: Boolean,
) {
    Column(
        modifier =
        Modifier
            .fillMaxWidth()
            .padding(end = if (hasTopProvider) 64.dp else 0.dp),
    ) {
        PulseHeroBurnCardHeader(
            timelineScope = metrics.timelineScope,
            isLive = derived.isLive,
            burnRateText = burnRateText,
            displayMode = metrics.displayMode,
            accent = derived.accent,
            hasTopProvider = hasTopProvider,
        )
        PulseHeroBurnCardMetricsBlock(
            displayMode = metrics.displayMode,
            value = metrics.value,
            tokens = derived.tokens,
            requests = derived.requests,
        )
        if (metrics.trailingValue > 0) {
            Spacer(Modifier.height(AuroraSpacing.sm.dp))
            DeltaBadge(percent = derived.absDelta, isBelow = derived.isBelow)
        }
        Spacer(Modifier.height(AuroraSpacing.md.dp))
        PulseLiveCostCurve(
            usages = metrics.liveUsages,
            dailyPoints = metrics.dailyPoints,
            scope = metrics.timelineScope,
            displayMode = metrics.displayMode,
            nowMillis = metrics.nowMillis,
            accent = derived.accent,
        )
        PulseHeroBurnCardStreamingFooter(requests = derived.requests)
        PulseHeroBurnCardComparisonLine(
            trailingValue = metrics.trailingValue,
            absDelta = derived.absDelta,
            isBelow = derived.isBelow,
            timelineScope = metrics.timelineScope,
        )
    }
}
