@file:Suppress("MagicNumber")
// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.pulse.atlas

import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
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
import androidx.compose.ui.unit.dp
import com.openburnbar.data.derived.TrendDataDigest
import com.openburnbar.ui.components.ModelLogo
import com.openburnbar.ui.theme.AuroraType

@Composable
fun ModelLaneScene(digest: TrendDataDigest, modifier: Modifier = Modifier) {
    val lanes = rememberModelLanes(digest)
    Column(modifier = modifier, verticalArrangement = Arrangement.spacedBy(8.dp)) {
        if (lanes.isEmpty()) {
            EmptyLanesNotice()
        } else {
            lanes.forEachIndexed { index, lane -> LaneRow(lane = lane, rank = index + 1) }
        }
    }
}

@Composable
private fun rememberModelLanes(digest: TrendDataDigest): List<Lane> =
    remember(digest.models, digest.recentSessions) {
        digest.models.take(5).map { model ->
            val sessions = digest.recentSessions.filter { it.model.equals(model.model, ignoreCase = true) }
            val velocity =
                sessions
                    .filter { it.outputTokensPerSecond > 0 }
                    .map { it.outputTokensPerSecond }
                    .takeIf { it.isNotEmpty() }
                    ?.average()
                    ?: 0.0
            Lane(
                model = model,
                color = Color(model.brand.emblemColor),
                velocity = velocity,
                sparklineValues =
                sessions
                    .sortedBy { it.startedAtMs }
                    .map { (it.costUsd * 100).toFloat() }
                    .takeLast(20),
            )
        }
    }

@Suppress("UnusedParameter")
@Composable
private fun LaneRow(lane: Lane, rank: Int) {
    val target = (lane.model.sharePct / 100.0).toFloat().coerceIn(0f, 1f)
    val animatedProgress by animateFloatAsState(
        targetValue = target,
        animationSpec = spring(stiffness = Spring.StiffnessLow, dampingRatio = 0.8f),
        label = "lane-progress",
    )

    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
        Box(
            modifier =
            Modifier
                .width(4.dp)
                .height(36.dp)
                .clip(RoundedCornerShape(2.dp))
                .background(Brush.verticalGradient(colors = listOf(lane.color, lane.color.copy(alpha = 0.6f)))),
        )
        Spacer(Modifier.width(10.dp))
        ModelLogo(brand = lane.model.brand, size = 24.dp)
        Spacer(Modifier.width(10.dp))
        Column(modifier = Modifier.weight(1f)) {
            LaneRowTitle(lane = lane)
            Spacer(Modifier.height(4.dp))
            LaneRowProgressBar(lane = lane, animatedProgress = animatedProgress)
            Spacer(Modifier.height(4.dp))
            LaneRowStats(lane = lane)
        }
    }
}

@Composable
private fun EmptyLanesNotice() {
    Column(
        modifier = Modifier.fillMaxWidth().height(160.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(text = "No model data yet", style = AuroraType.body, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Spacer(Modifier.height(4.dp))
        Text(
            text = "We'll show your top models once a few sessions land.",
            style = AuroraType.tiny,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}
