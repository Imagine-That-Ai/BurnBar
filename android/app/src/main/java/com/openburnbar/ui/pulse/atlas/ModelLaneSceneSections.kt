// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.pulse.atlas

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Speed
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.ui.components.AuroraSparkline
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraType
import com.openburnbar.util.Formatting

@Composable
internal fun LaneRowTitle(lane: Lane) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(
            text = lane.model.model.ifBlank { lane.model.provider },
            style = AuroraType.caption,
            fontWeight = FontWeight.SemiBold,
            color = MaterialTheme.colorScheme.onSurface,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
        Spacer(Modifier.width(6.dp))
        Text(
            text = "${lane.model.sharePct.toInt()}%",
            fontSize = 10.sp,
            fontWeight = FontWeight.SemiBold,
            color = lane.color,
        )
    }
}

@Composable
internal fun LaneRowProgressBar(lane: Lane, animatedProgress: Float) {
    Box(modifier = Modifier.fillMaxWidth().height(10.dp)) {
        Box(
            modifier =
            Modifier
                .fillMaxSize()
                .clip(RoundedCornerShape(5.dp))
                .background(lane.color.copy(alpha = 0.14f)),
        )
        Box(
            modifier =
            Modifier
                .fillMaxHeight()
                .fillMaxWidth(animatedProgress.coerceAtLeast(0.04f))
                .clip(RoundedCornerShape(5.dp))
                .background(
                    Brush.horizontalGradient(
                        colors = listOf(lane.color, lane.color.copy(alpha = 0.55f)),
                    ),
                ),
        )
        if (lane.sparklineValues.size >= 2) {
            AuroraSparkline(
                data = lane.sparklineValues,
                strokeColor = Color.White.copy(alpha = 0.55f),
                fillColor = Color.Transparent,
                strokeWidth = 1.2f,
                showFill = false,
                animate = false,
                showLatestPoint = false,
                modifier = Modifier.fillMaxSize(),
            )
        }
    }
}

@Composable
internal fun LaneRowStats(lane: Lane) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        if (lane.velocity > 0) {
            Icon(Icons.Filled.Speed, contentDescription = null, tint = AuroraColors.amber, modifier = Modifier.size(11.dp))
            Spacer(Modifier.width(3.dp))
            Text(
                text = "${lane.velocity.toInt()} tok/s",
                fontSize = 10.sp,
                color = AuroraColors.amber,
                fontWeight = FontWeight.SemiBold,
            )
            Spacer(Modifier.width(10.dp))
        }
        Text(
            text = formatLaneTokens(lane.model.tokens),
            fontSize = 10.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(Modifier.weight(1f))
        Text(
            text = Formatting.formatCurrency(lane.model.costUsd),
            fontSize = 10.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            fontWeight = FontWeight.Medium,
        )
    }
}

internal fun formatLaneTokens(n: Long): String =
    when {
        n >= 1_000_000_000 -> "%.1fB".format(n / 1_000_000_000.0)
        n >= 1_000_000 -> "%.1fM".format(n / 1_000_000.0)
        n >= 1_000 -> "%.1fK".format(n / 1_000.0)
        else -> n.toString()
    }
