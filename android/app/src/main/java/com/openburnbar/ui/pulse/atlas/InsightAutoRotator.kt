package com.openburnbar.ui.pulse.atlas

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedContentTransitionScope
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AcUnit
import androidx.compose.material.icons.filled.Analytics
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.DonutLarge
import androidx.compose.material.icons.filled.Insights
import androidx.compose.material.icons.filled.RocketLaunch
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material.icons.filled.TrendingDown
import androidx.compose.material.icons.filled.TrendingUp
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.openburnbar.data.derived.TrendInsight
import com.openburnbar.data.derived.TrendInsightTone
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraType
import kotlinx.coroutines.delay

/**
 * Bottom-of-card auto-rotator. Cycles through ranked insights every 6 seconds
 * with a fade+slide transition, pauses when [paused] is true (e.g. while a
 * details sheet is open). Mirrors iOS `InsightAutoRotator`.
 */
@Composable
fun InsightAutoRotator(
    insights: List<TrendInsight>,
    paused: Boolean = false,
    modifier: Modifier = Modifier
) {
    if (insights.isEmpty()) {
        EmptyInsight(modifier)
        return
    }

    var index by remember(insights) { mutableIntStateOf(0) }
    LaunchedEffect(insights, paused) {
        if (paused || insights.size <= 1) return@LaunchedEffect
        while (true) {
            delay(6_000)
            index = (index + 1) % insights.size
        }
    }

    Surface(
        modifier = modifier.fillMaxWidth(),
        shape = RoundedCornerShape(12.dp),
        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.45f),
        border = BorderStroke(0.5.dp, MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.4f))
    ) {
        Column(modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp)) {
            AnimatedContent(
                targetState = insights.getOrNull(index) ?: insights.first(),
                label = "insight-rotator",
                transitionSpec = {
                    (fadeIn(animationSpec = tween(400)) +
                        slideInHorizontally(animationSpec = tween(400)) { it / 4 }) togetherWith
                    (fadeOut(animationSpec = tween(300)) +
                        slideOutHorizontally(animationSpec = tween(300)) { -it / 4 })
                }
            ) { insight ->
                InsightContent(insight)
            }

            Spacer(Modifier.height(6.dp))

            // Dot indicator row (capped at 6 — beyond that the row becomes
            // visual clutter and the rotation cadence loses meaning).
            Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                val visible = insights.take(6)
                visible.forEachIndexed { i, _ ->
                    val active = i == (index % visible.size)
                    Box(
                        modifier = Modifier
                            .size(if (active) 6.dp else 4.dp)
                            .clip(CircleShape)
                            .background(
                                if (active) AuroraColors.ember
                                else MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.5f)
                            )
                    )
                }
            }
        }
    }
}

@Composable
private fun InsightContent(insight: TrendInsight) {
    val (icon, color) = remember(insight.symbolName, insight.tone) {
        symbolFor(insight.symbolName) to toneColor(insight.tone)
    }
    Row(verticalAlignment = Alignment.CenterVertically) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            tint = color,
            modifier = Modifier.size(16.dp)
        )
        Spacer(Modifier.width(8.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = insight.title,
                style = AuroraType.caption,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurface,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis
            )
            Text(
                text = insight.detail,
                style = AuroraType.tiny,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis
            )
        }
    }
}

@Composable
private fun EmptyInsight(modifier: Modifier = Modifier) {
    Surface(
        modifier = modifier.fillMaxWidth(),
        shape = RoundedCornerShape(12.dp),
        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.45f),
        border = BorderStroke(0.5.dp, MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.4f))
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Icon(
                imageVector = Icons.Filled.Insights,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.size(14.dp)
            )
            Spacer(Modifier.width(8.dp))
            Text(
                text = "No insights yet",
                style = AuroraType.caption,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
    }
}

private fun symbolFor(name: String): ImageVector = when (name) {
    "TrendingUp"   -> Icons.Filled.TrendingUp
    "TrendingDown" -> Icons.Filled.TrendingDown
    "DonutLarge"   -> Icons.Filled.DonutLarge
    "Bolt"         -> Icons.Filled.Bolt
    "AcUnit"       -> Icons.Filled.AcUnit
    "Schedule"     -> Icons.Filled.Schedule
    "RocketLaunch" -> Icons.Filled.RocketLaunch
    "Analytics"    -> Icons.Filled.Analytics
    else           -> Icons.Filled.Insights
}

private fun toneColor(tone: TrendInsightTone): Color = when (tone) {
    TrendInsightTone.POSITIVE -> AuroraColors.success
    TrendInsightTone.WARNING  -> AuroraColors.warning
    TrendInsightTone.NEUTRAL  -> AuroraColors.hermesAureate
}
