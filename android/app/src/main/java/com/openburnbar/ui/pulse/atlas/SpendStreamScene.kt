// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.pulse.atlas

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.openburnbar.data.derived.TrendDataDigest
import com.openburnbar.data.models.AgentProvider
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraType
import java.text.SimpleDateFormat
import java.util.Locale

@Composable
internal fun TotalRibbon(modifier: Modifier = Modifier) {
    // Decorative top-bleed ribbon — mimics iOS overlay with `.plusLighter`
    // blend. Compose Canvas doesn't expose plusLighter cleanly, so we use
    // BlendMode.Plus which is the standard analogue.
    Canvas(modifier = modifier) {
        drawRect(
            brush =
            Brush.verticalGradient(
                colors =
                listOf(
                    AuroraColors.ember.copy(alpha = 0.35f),
                    AuroraColors.amber.copy(alpha = 0.18f),
                    Color.Transparent,
                ),
            ),
            size = size,
            blendMode = BlendMode.Plus,
        )
    }
}

@Composable
internal fun SelectedAnnotation(series: TrendDataDigest.DailySeries, modifier: Modifier = Modifier) {
    Surface(
        modifier = modifier,
        shape = RoundedCornerShape(6.dp),
        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.92f),
    ) {
        Column(
            modifier = Modifier.padding(horizontal = 8.dp, vertical = 4.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Text(
                text = formatDayLong(series.date),
                style = AuroraType.tiny,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Text(
                text = "$${"%.2f".format(series.total)}",
                style = AuroraType.caption,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurface,
            )
        }
    }
}

@Composable
internal fun ProviderLegend(daily: List<TrendDataDigest.DailySeries>) {
    val providers =
        remember(daily) {
            daily.flatMap { it.perProvider.entries }
                .groupBy { it.key }
                .map { (k, v) -> k to v.sumOf { it.value } }
                .sortedByDescending { it.second }
                .map { it.first }
                .take(4)
        }
    if (providers.isEmpty()) return
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        providers.forEach { p ->
            val accent = providerAccent(p)
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(
                    modifier =
                    Modifier
                        .size(8.dp)
                        .clip(RoundedCornerShape(4.dp))
                        .background(accent.copy(alpha = 0.85f)),
                )
                Spacer(Modifier.width(4.dp))
                Text(
                    text = AgentProvider.fromKey(p)?.displayName ?: p,
                    style = AuroraType.tiny,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

@Composable
internal fun HourOfDayHeatStrip(digest: TrendDataDigest) {
    val buckets = digest.hourly
    val max = buckets.maxOfOrNull { it.tokens }?.toFloat()?.coerceAtLeast(1f) ?: 1f
    Row(
        modifier =
        Modifier
            .fillMaxWidth()
            .height(28.dp),
        horizontalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        for (b in buckets) {
            val intensity = b.tokens.toFloat() / max
            val alpha = 0.15f + intensity * 0.70f
            Box(
                modifier =
                Modifier
                    .weight(1f)
                    .fillMaxHeight()
                    .clip(RoundedCornerShape(4.dp))
                    .background(
                        Brush.verticalGradient(
                            colors =
                            listOf(
                                AuroraColors.amber.copy(alpha = alpha),
                                AuroraColors.ember.copy(alpha = alpha * 0.85f),
                            ),
                        ),
                    ),
            )
        }
    }
}

@Composable
internal fun EmptySpendScene(modifier: Modifier = Modifier) {
    Column(
        modifier =
        modifier
            .fillMaxWidth()
            .height(180.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Text(
            text = "No spend history yet",
            style = AuroraType.body,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(Modifier.height(4.dp))
        Text(
            text = "Run a session and Trend Atlas will fill in.",
            style = AuroraType.tiny,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

private val ISO = SimpleDateFormat("yyyy-MM-dd", Locale.US)
private val SHORT = SimpleDateFormat("MMM d", Locale.getDefault())
private val LONG = SimpleDateFormat("EEE, MMM d", Locale.getDefault())

internal fun formatDayShort(iso: String): String = runCatching { ISO.parse(iso)?.let { SHORT.format(it) } }.getOrNull() ?: iso

private fun formatDayLong(iso: String): String = runCatching { ISO.parse(iso)?.let { LONG.format(it) } }.getOrNull() ?: iso
