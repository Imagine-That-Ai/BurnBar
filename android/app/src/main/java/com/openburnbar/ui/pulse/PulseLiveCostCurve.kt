// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.pulse

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.models.TokenUsage
import com.openburnbar.data.models.UsageDisplayMode
import java.text.SimpleDateFormat
import java.util.Locale

@Composable
fun PulseLiveCostCurve(
    usages: List<TokenUsage>,
    dailyPoints: Map<String, Double>,
    scope: PulseTimelineScope,
    displayMode: UsageDisplayMode,
    nowMillis: Long,
    accent: Color,
    modifier: Modifier = Modifier,
) {
    val domain = remember(scope, nowMillis) { domainFor(scope, nowMillis) }
    val samples =
        remember(usages, dailyPoints, scope, displayMode, nowMillis) {
            buildPulseLiveCostSamples(
                usages = usages,
                dailyPoints = dailyPoints,
                scope = scope,
                displayMode = displayMode,
                domain = domain,
                nowMillis = nowMillis,
            )
        }
    val peak = samples.maxOfOrNull { it.cumulative } ?: 0.0
    val isEmpty = peak <= 0.0001
    val (pulse, sweep) = rememberLiveCostPulseAnimations()

    Box(
        modifier =
        modifier
            .fillMaxWidth()
            .height(120.dp)
            .padding(top = 4.dp),
    ) {
        PulseLiveCostCurveCanvas(
            args =
            PulseLiveCostCurveCanvasArgs(
                samples = samples,
                domain = domain,
                accent = accent,
                isEmpty = isEmpty,
                peak = peak,
                pulse = pulse,
                sweep = sweep,
            ),
        )
        TimeAxisLabels(
            domainStartMillis = domain.first,
            domainEndMillis = domain.second,
            scope = scope,
            modifier = Modifier.fillMaxWidth().align(Alignment.BottomStart),
        )
        if (isEmpty) {
            Box(modifier = Modifier.align(Alignment.Center)) {
                PulseLiveCostEmptyCaption(scope = scope, accent = accent)
            }
        }
    }
}

@Composable
private fun TimeAxisLabels(domainStartMillis: Long, domainEndMillis: Long, scope: PulseTimelineScope, modifier: Modifier) {
    val formatPattern =
        when (scope) {
            PulseTimelineScope.MINUTE -> "mm:ss"
            PulseTimelineScope.HOUR -> "h:mm a"
            PulseTimelineScope.DAY -> "ha"
            PulseTimelineScope.WEEK, PulseTimelineScope.MONTH -> "M/d"
        }
    val formatter = remember(formatPattern) { SimpleDateFormat(formatPattern, Locale.getDefault()) }
    val labels =
        remember(domainStartMillis, domainEndMillis, formatPattern) {
            val ticks = 4
            val span = (domainEndMillis - domainStartMillis).coerceAtLeast(1L)
            (0 until ticks).map { idx ->
                val t = domainStartMillis + span * idx / (ticks - 1)
                formatter.format(t).lowercase(Locale.getDefault())
            }
        }
    Row(modifier = modifier) {
        labels.forEach { label ->
            Text(
                text = label,
                fontSize = 9.sp,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f),
                modifier = Modifier.weight(1f),
            )
        }
    }
}

object PulseBurnRate {
    fun dollarsPerMinute(usages: List<TokenUsage>, nowMillis: Long): Double? {
        val windowStart = nowMillis - 5L * 60_000L
        val cost =
            usages
                .filter { it.startTime in windowStart..nowMillis }
                .sumOf { kotlin.math.max(0.0, it.effectiveCost) }
        return if (cost > 0.0) cost / 5.0 else null
    }

    fun tokensPerMinute(usages: List<TokenUsage>, nowMillis: Long): Int? {
        val windowStart = nowMillis - 5L * 60_000L
        val tokens =
            usages
                .filter { it.startTime in windowStart..nowMillis }
                .sumOf { kotlin.math.max(0, it.totalTokens) }
        return if (tokens > 0) tokens / 5 else null
    }
}
