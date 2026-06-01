@file:Suppress("MagicNumber")
// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.pulse.atlas

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
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
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.derived.TrendDataDigest
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraType

@Composable
fun CacheConstellationScene(digest: TrendDataDigest, modifier: Modifier = Modifier) {
    val sessions = digest.recentSessions.filter { it.durationSec > 0 }
    val userAvg = digest.cache.cacheHitRate

    Column(modifier = modifier) {
        Box(
            modifier =
            Modifier
                .fillMaxWidth()
                .height(200.dp)
                .clip(RoundedCornerShape(12.dp)),
        ) {
            ConstellationCanvas(sessions = sessions, userAvg = userAvg)
            AxisLabels(modifier = Modifier.fillMaxSize())
        }
        Spacer(Modifier.height(10.dp))
        StatsFooter(digest = digest)
    }
}

@Composable
private fun AxisLabels(modifier: Modifier = Modifier) {
    Box(modifier = modifier) {
        Text(
            text = "100% cache hit",
            style = AuroraType.tiny,
            color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f),
            modifier = Modifier.align(Alignment.TopEnd).padding(top = 2.dp, end = 4.dp),
        )
        Text(
            text = "0%",
            style = AuroraType.tiny,
            color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f),
            modifier = Modifier.align(Alignment.BottomEnd).padding(bottom = 2.dp, end = 4.dp),
        )
        Text(
            text = "longer →",
            style = AuroraType.tiny,
            color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f),
            modifier = Modifier.align(Alignment.BottomCenter).padding(bottom = 2.dp),
        )
    }
}

@Composable
private fun StatsFooter(digest: TrendDataDigest) {
    val cacheRate = digest.cache.cacheHitRate
    val rateColor = if (cacheRate >= 0.5) AuroraColors.success else AuroraColors.warning
    Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        StatCapsule(modifier = Modifier.weight(1f), dotColor = rateColor, label = "Hit rate", value = "${(cacheRate * 100).toInt()}%")
        StatCapsule(
            modifier = Modifier.weight(1f),
            dotColor = AuroraColors.whimsy,
            label = "Cache reads",
            value = formatTokensShort(digest.cache.totalCacheReadTokens),
        )
        StatCapsule(
            modifier = Modifier.weight(1f),
            dotColor = AuroraColors.ember,
            label = "Sessions",
            value = digest.recentSessions.size.toString(),
        )
    }
}

@Composable
private fun StatCapsule(modifier: Modifier = Modifier, dotColor: Color, label: String, value: String) {
    Surface(
        modifier = modifier,
        shape = CircleShape,
        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.45f),
        border = BorderStroke(0.5.dp, MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.5f)),
    ) {
        Row(modifier = Modifier.padding(horizontal = 10.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
            Box(modifier = Modifier.size(6.dp).clip(CircleShape).background(dotColor))
            Spacer(Modifier.width(6.dp))
            Column {
                Text(text = value, fontSize = 11.sp, fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.onSurface)
                Text(text = label, fontSize = 9.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}

private fun formatTokensShort(n: Long): String =
    when {
        n >= 1_000_000 -> "%.1fM".format(n / 1_000_000.0)
        n >= 1_000 -> "%.1fK".format(n / 1_000.0)
        else -> n.toString()
    }
