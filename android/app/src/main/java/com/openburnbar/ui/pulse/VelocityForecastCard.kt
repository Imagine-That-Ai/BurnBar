package com.openburnbar.ui.pulse

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.*
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.models.UsageDisplayMode
import com.openburnbar.ui.components.AuroraGlassCard
import com.openburnbar.ui.components.SectionHeader
import com.openburnbar.ui.theme.*
import com.openburnbar.util.Formatting
import kotlinx.coroutines.delay

@Composable
fun VelocityForecastCard(
    todayValue: Double,
    trailingValue: Double,
    displayMode: UsageDisplayMode
) {
    var nowTick by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(Unit) {
        while (true) {
            delay(60_000)
            nowTick = System.currentTimeMillis()
        }
    }

    val calendar = java.util.Calendar.getInstance()
    val hour = calendar.get(java.util.Calendar.HOUR_OF_DAY)
    val minute = calendar.get(java.util.Calendar.MINUTE)
    val dayProgress = ((hour * 60 + minute) / (24.0 * 60.0)).coerceIn(0.0, 1.0)

    val avgDaily = if (trailingValue > 0) trailingValue / 7.0 else 0.0
    val projected = if (dayProgress > 0) todayValue / dayProgress else todayValue

    val pace = when {
        avgDaily <= 0 -> "Awaiting data"
        projected > avgDaily * 1.15 -> "Above average pace"
        projected < avgDaily * 0.85 -> "Below average pace"
        else -> "On track"
    }
    val paceColor = when {
        avgDaily <= 0 -> MaterialTheme.colorScheme.onSurfaceVariant
        projected > avgDaily * 1.15 -> AuroraColors.warning
        projected < avgDaily * 0.85 -> AuroraColors.success
        else -> AuroraColors.amber
    }
    val variantColor = when {
        projected > avgDaily * 1.15 -> AuroraColors.warning
        projected < avgDaily * 0.85 -> AuroraColors.success
        else -> MaterialTheme.colorScheme.onSurfaceVariant
    }

    val projectedText = when (displayMode) {
        UsageDisplayMode.CURRENCY -> Formatting.formatCurrency(projected)
        UsageDisplayMode.TOKENS -> Formatting.formatTokens(projected.toInt())
    }

    AuroraGlassCard(
        modifier = Modifier.padding(horizontal = AuroraSpacing.lg.dp),
        cornerRadius = AuroraRadius.xl
    ) {
        Column(modifier = Modifier.padding(AuroraSpacing.lg.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    text = "End-of-day forecast",
                    fontSize = AuroraTypography.caption.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = paceColor
                )
                Text(
                    text = pace,
                    fontSize = AuroraTypography.caption.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = paceColor
                )
            }

            Spacer(modifier = Modifier.height(AuroraSpacing.md.dp))

            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = "PROJECTED",
                        fontSize = AuroraTypography.tiny.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        letterSpacing = 2.sp
                    )
                    Spacer(modifier = Modifier.height(4.dp))
                    Text(
                        text = if (avgDaily > 0) projectedText else "—",
                        fontSize = AuroraTypography.display.sp,
                        fontWeight = FontWeight.Bold,
                        color = MaterialTheme.colorScheme.onSurface
                    )
                    if (avgDaily > 0) {
                        Spacer(modifier = Modifier.height(4.dp))
                        Text(
                            text = pace,
                            fontSize = AuroraTypography.caption.sp,
                            fontWeight = FontWeight.SemiBold,
                            color = paceColor
                        )
                    }
                }

                DayProgressGauge(
                    progress = dayProgress,
                    modifier = Modifier.size(88.dp)
                )
            }
        }
    }
}

@Composable
private fun DayProgressGauge(
    progress: Double,
    modifier: Modifier = Modifier
) {
    val animatedProgress by animateFloatAsState(
        targetValue = progress.coerceIn(0.0, 1.0).toFloat(),
        animationSpec = tween(800),
        label = "day_progress"
    )

    val trackColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.3f)
    Box(contentAlignment = Alignment.Center, modifier = modifier) {
        Canvas(modifier = Modifier.fillMaxSize()) {
            val strokeWidth = 6f
            val diameter = size.minDimension - strokeWidth
            val topLeft = androidx.compose.ui.geometry.Offset(
                (size.width - diameter) / 2,
                (size.height - diameter) / 2
            )
            // Track
            drawCircle(
                color = trackColor,
                radius = diameter / 2,
                style = Stroke(width = strokeWidth)
            )
            // Progress
            drawArc(
                brush = Brush.sweepGradient(
                    colors = listOf(AuroraColors.amber, AuroraColors.ember, AuroraColors.amber),
                    center = androidx.compose.ui.geometry.Offset(size.width / 2, size.height / 2)
                ),
                startAngle = -90f,
                sweepAngle = 360f * animatedProgress.coerceAtLeast(0.02f),
                useCenter = false,
                topLeft = topLeft,
                size = androidx.compose.ui.geometry.Size(diameter, diameter),
                style = Stroke(width = 8f, cap = StrokeCap.Round)
            )
        }
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Text(
                text = "${(animatedProgress * 100).toInt()}%",
                fontSize = 18.sp,
                fontWeight = FontWeight.Bold,
                color = MaterialTheme.colorScheme.onSurface
            )
            Text(
                text = "of day",
                fontSize = AuroraTypography.tiny.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
    }
}
