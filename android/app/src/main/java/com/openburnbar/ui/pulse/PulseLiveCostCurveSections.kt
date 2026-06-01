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
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Timeline
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.models.TokenUsage
import com.openburnbar.data.models.UsageDisplayMode
import com.openburnbar.ui.theme.AuroraColors
import kotlin.math.max

@Composable
internal fun rememberLiveCostPulseAnimations(): Pair<Float, Float> {
    val pulseTransition = rememberInfiniteTransition(label = "live-cost-pulse")
    val pulse by pulseTransition.animateFloat(
        initialValue = 0f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(animation = tween(1400, easing = LinearEasing), repeatMode = RepeatMode.Reverse),
        label = "pulse",
    )
    val sweep by pulseTransition.animateFloat(
        initialValue = 0f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(animation = tween(4200, easing = LinearEasing), repeatMode = RepeatMode.Restart),
        label = "sweep",
    )
    return pulse to sweep
}

internal data class PulseLiveCostCurveCanvasArgs(
    val samples: List<CostSample>,
    val domain: Pair<Long, Long>,
    val accent: Color,
    val isEmpty: Boolean,
    val peak: Double,
    val pulse: Float,
    val sweep: Float,
)

internal data class PulseLiveCostCurveDrawState(
    val samples: List<CostSample>,
    val domain: Pair<Long, Long>,
    val accent: Color,
    val isEmpty: Boolean,
    val peak: Double,
    val pulse: Float,
    val sweep: Float,
)

@Composable
internal fun PulseLiveCostCurveCanvas(
    args: PulseLiveCostCurveCanvasArgs,
    modifier: Modifier = Modifier,
) {
    val isDark = isSystemInDarkTheme()
    Canvas(modifier = modifier.fillMaxSize()) {
        val w = size.width
        val h = size.height
        val axisH = 14.dp.toPx()
        val plotH = h - axisH
        val yMax = max(args.peak * 1.08, 0.0001)
        drawPulseLiveBaseline(accent = args.accent, plotH = plotH, width = w)
        if (args.isEmpty) {
            drawPulseLiveEmptyRail(accent = args.accent, plotH = plotH, width = w, sweep = args.sweep)
        } else if (args.samples.size >= 2) {
            drawPulseLiveFilledCurve(
                PulseFilledCurveDrawParams(
                    samples = args.samples,
                    domain = args.domain,
                    plotH = plotH,
                    width = w,
                    yMax = yMax,
                    accent = args.accent,
                    isDark = isDark,
                    pulse = args.pulse,
                ),
            )
        }
    }
}

private fun androidx.compose.ui.graphics.drawscope.DrawScope.drawPulseLiveBaseline(accent: Color, plotH: Float, width: Float) {
    drawRect(
        brush =
        androidx.compose.ui.graphics.Brush.verticalGradient(
            colors = listOf(accent.copy(alpha = 0.04f), Color.Transparent),
            startY = 0f,
            endY = plotH,
        ),
        size = androidx.compose.ui.geometry.Size(width, plotH),
    )
    drawLine(
        color = AuroraColors.lightTextMuted.copy(alpha = 0.10f),
        start = Offset(0f, plotH - 0.5f),
        end = Offset(width, plotH - 0.5f),
        strokeWidth = 0.5.dp.toPx(),
    )
}

@Composable
internal fun PulseLiveCostEmptyCaption(scope: PulseTimelineScope, accent: Color) {
    Surface(
        shape = CircleShape,
        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.65f),
        border = BorderStroke(0.5.dp, accent.copy(alpha = 0.4f)),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.padding(horizontal = 10.dp, vertical = 5.dp),
        ) {
            Icon(
                imageVector = Icons.Filled.Timeline,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.size(11.dp),
            )
            Spacer(modifier = Modifier.width(6.dp))
            Text(
                text = emptyMessage(scope),
                fontSize = 11.sp,
                fontWeight = FontWeight.SemiBold,
                letterSpacing = 0.6.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

internal data class CostSample(val timeMillis: Long, val cumulative: Double)

internal fun buildPulseLiveCostSamples(
    usages: List<TokenUsage>,
    dailyPoints: Map<String, Double>,
    scope: PulseTimelineScope,
    displayMode: UsageDisplayMode,
    domain: Pair<Long, Long>,
    nowMillis: Long,
): List<CostSample> =
    when (scope) {
        PulseTimelineScope.MINUTE,
        PulseTimelineScope.HOUR,
        PulseTimelineScope.DAY,
        -> buildLiveSamples(usages, scope, domain, displayMode, nowMillis)
        PulseTimelineScope.WEEK,
        PulseTimelineScope.MONTH,
        -> buildAggregateSamples(dailyPoints, domain)
    }
