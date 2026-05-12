package com.openburnbar.ui.pulse.atlas

import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Speed
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.derived.TrendDataDigest
import com.openburnbar.data.models.LLMModelBrand
import com.openburnbar.ui.components.AuroraSparkline
import com.openburnbar.ui.components.ModelLogo
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraType

/**
 * Mirrors iOS `ModelLaneScene` — top-5 model lanes drawn as horizontal
 * "lane racer" rows: brand-colored rail on the left, animated progress bar
 * filling the row width, a translucent sparkline overlaid on the bar, and a
 * tiny stats row underneath with velocity (tok/s) and cost.
 */
@Composable
fun ModelLaneScene(
    digest: TrendDataDigest,
    modifier: Modifier = Modifier
) {
    val lanes = remember(digest.models, digest.recentSessions) {
        digest.models.take(5).map { model ->
            val sessions = digest.recentSessions.filter {
                it.model.equals(model.model, ignoreCase = true)
            }
            val velocity = sessions
                .filter { it.outputTokensPerSecond > 0 }
                .map { it.outputTokensPerSecond }
                .takeIf { it.isNotEmpty() }
                ?.average()
                ?: 0.0
            val recentValues = sessions
                .sortedBy { it.startedAtMs }
                .map { (it.costUsd * 100).toFloat() }  // scale up so sparkline shape reads
                .takeLast(20)
            Lane(
                model = model,
                color = Color(model.brand.emblemColor),
                velocity = velocity,
                sparklineValues = recentValues
            )
        }
    }

    Column(
        modifier = modifier,
        verticalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        if (lanes.isEmpty()) {
            EmptyLanesNotice()
        } else {
            lanes.forEachIndexed { index, lane ->
                LaneRow(lane = lane, rank = index + 1)
            }
        }
    }
}

private data class Lane(
    val model: TrendDataDigest.ModelSlice,
    val color: Color,
    val velocity: Double,
    val sparklineValues: List<Float>
)

@Composable
private fun LaneRow(lane: Lane, rank: Int) {
    val target = (lane.model.sharePct / 100.0).toFloat().coerceIn(0f, 1f)
    val animatedProgress by animateFloatAsState(
        targetValue = target,
        animationSpec = spring(stiffness = Spring.StiffnessLow, dampingRatio = 0.8f),
        label = "lane-progress"
    )

    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth()
    ) {
        // Brand color rail (capsule) — anchors each lane to its brand
        Box(
            modifier = Modifier
                .width(4.dp)
                .height(36.dp)
                .clip(RoundedCornerShape(2.dp))
                .background(
                    Brush.verticalGradient(
                        colors = listOf(lane.color, lane.color.copy(alpha = 0.6f))
                    )
                )
        )

        Spacer(Modifier.width(10.dp))

        // Logo
        ModelLogo(brand = lane.model.brand, size = 24.dp)

        Spacer(Modifier.width(10.dp))

        Column(modifier = Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    text = lane.model.model.ifBlank { lane.model.provider },
                    style = AuroraType.caption,
                    fontWeight = FontWeight.SemiBold,
                    color = MaterialTheme.colorScheme.onSurface,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f)
                )
                Spacer(Modifier.width(6.dp))
                Text(
                    text = "${lane.model.sharePct.toInt()}%",
                    fontSize = 10.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = lane.color
                )
            }

            Spacer(Modifier.height(4.dp))

            // Layered progress bar + sparkline
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(10.dp)
            ) {
                // Track
                Box(
                    modifier = Modifier
                        .fillMaxSize()
                        .clip(RoundedCornerShape(5.dp))
                        .background(lane.color.copy(alpha = 0.14f))
                )
                // Filled progress
                Box(
                    modifier = Modifier
                        .fillMaxHeight()
                        .fillMaxWidth(animatedProgress.coerceAtLeast(0.04f))
                        .clip(RoundedCornerShape(5.dp))
                        .background(
                            Brush.horizontalGradient(
                                colors = listOf(lane.color, lane.color.copy(alpha = 0.55f))
                            )
                        )
                )
                // Sparkline overlay (subtle, blended brighter)
                if (lane.sparklineValues.size >= 2) {
                    AuroraSparkline(
                        data = lane.sparklineValues,
                        strokeColor = Color.White.copy(alpha = 0.55f),
                        fillColor = Color.Transparent,
                        strokeWidth = 1.2f,
                        showFill = false,
                        animate = false,
                        showLatestPoint = false,
                        modifier = Modifier.fillMaxSize()
                    )
                }
            }

            Spacer(Modifier.height(4.dp))

            Row(verticalAlignment = Alignment.CenterVertically) {
                if (lane.velocity > 0) {
                    Icon(
                        imageVector = Icons.Filled.Speed,
                        contentDescription = null,
                        tint = AuroraColors.amber,
                        modifier = Modifier.size(11.dp)
                    )
                    Spacer(Modifier.width(3.dp))
                    Text(
                        text = "${lane.velocity.toInt()} tok/s",
                        fontSize = 10.sp,
                        color = AuroraColors.amber,
                        fontWeight = FontWeight.SemiBold
                    )
                    Spacer(Modifier.width(10.dp))
                }
                Text(
                    text = formatTokens(lane.model.tokens),
                    fontSize = 10.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
                Spacer(Modifier.weight(1f))
                Text(
                    text = "$${"%.2f".format(lane.model.costUsd)}",
                    fontSize = 10.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    fontWeight = FontWeight.Medium
                )
            }
        }
    }
}

@Composable
private fun EmptyLanesNotice() {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .height(160.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Text(
            text = "No model data yet",
            style = AuroraType.body,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
        Spacer(Modifier.height(4.dp))
        Text(
            text = "We'll show your top models once a few sessions land.",
            style = AuroraType.tiny,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
    }
}

private fun formatTokens(n: Long): String = when {
    n >= 1_000_000_000 -> "%.1fB".format(n / 1_000_000_000.0)
    n >= 1_000_000     -> "%.1fM".format(n / 1_000_000.0)
    n >= 1_000         -> "%.1fK".format(n / 1_000.0)
    else               -> n.toString()
}
