// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.burn

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.derived.TrendDataDigest
import com.openburnbar.data.models.AgentProvider
import com.openburnbar.data.models.RollupSummary
import com.openburnbar.data.models.UsageDisplayMode
import com.openburnbar.ui.components.AuroraGlassCard
import com.openburnbar.ui.components.ProviderAvatar
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraRadius
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraTypography
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.sin

// ── Burn view-style bodies ──
//
// The four alternate Burn-tab visualizations the user can pick from (the
// fifth, CARDS, stays inline in `BurnView`). Each body receives exactly the
// data it needs; the shared header + view switcher live in `BurnView`.

// MARK: - Constellation

/** Cinematic orbital ring cluster: a central fleet gauge with provider rings
 *  arranged on a y-squashed circle. Tap a ring to drill into a provider. */
@Composable
fun BurnConstellationBody(items: List<QuotaRingItem>, onProviderClick: (String) -> Unit, modifier: Modifier = Modifier) {
    AuroraGlassCard(modifier = modifier, cornerRadius = AuroraRadius.XL) {
        BurnSectionLabel("Quota constellation", "Tap a ring to drill into a provider")
        Spacer(Modifier.height(AuroraSpacing.MD.dp))
        if (items.isEmpty()) {
            BurnEmptyHint("Link a provider to populate the constellation.")
        } else {
            val avg = items.map { it.pressureRemaining }.average().coerceIn(0.0, 1.0)
            BoxWithConstraints(
                modifier = Modifier.fillMaxWidth().height(300.dp),
                contentAlignment = Alignment.Center,
            ) {
                val side = if (maxWidth < maxHeight) maxWidth else maxHeight
                val rPx = side.value * 0.34f
                FleetHealthGauge(
                    progress = avg,
                    accent = accentFor(avg),
                    modifier = Modifier.size(124.dp),
                )
                val shown = items.take(8)
                val count = shown.size
                shown.forEachIndexed { i, item ->
                    val theta = -PI / 2.0 + i.toDouble() * (2.0 * PI / count.toDouble())
                    val x = (cos(theta) * rPx).toFloat().dp
                    val y = (sin(theta) * rPx * 0.55).toFloat().dp
                    Box(modifier = Modifier.offset(x = x, y = y)) {
                        ProviderQuotaChip(item = item, onClick = { onProviderClick(item.providerKey) })
                    }
                }
            }
        }
    }
}

// MARK: - Gauge Grid

/** Dense grid of compact provider gauge tiles — most pressured first. */
@Composable
fun BurnGaugeGridBody(items: List<QuotaRingItem>, onProviderClick: (String) -> Unit, modifier: Modifier = Modifier) {
    AuroraGlassCard(modifier = modifier, cornerRadius = AuroraRadius.XL) {
        BurnSectionLabel("Quota gauges", "Most pressured first")
        Spacer(Modifier.height(AuroraSpacing.MD.dp))
        if (items.isEmpty()) {
            BurnEmptyHint("Link a provider to populate the grid.")
        } else {
            val columns = 3
            Column(verticalArrangement = Arrangement.spacedBy(AuroraSpacing.MD.dp)) {
                items.chunked(columns).forEach { rowItems ->
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.SM.dp),
                    ) {
                        rowItems.forEach { item ->
                            Box(modifier = Modifier.weight(1f), contentAlignment = Alignment.Center) {
                                BurnGaugeTile(item = item) { onProviderClick(item.providerKey) }
                            }
                        }
                        repeat(columns - rowItems.size) { Spacer(Modifier.weight(1f)) }
                    }
                }
            }
        }
    }
}

@Composable
private fun BurnGaugeTile(item: QuotaRingItem, onClick: () -> Unit) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier = Modifier.clickable { onClick() }.padding(vertical = 8.dp),
    ) {
        ProviderQuotaChip(item = item, onClick = onClick)
        Spacer(Modifier.height(4.dp))
        Text(
            text = item.label,
            fontSize = AuroraTypography.tiny.sp,
            fontWeight = FontWeight.SemiBold,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            color = MaterialTheme.colorScheme.onSurface,
        )
    }
}

// MARK: - Leaderboard

/** Providers ranked by spend for the selected window/mode, with bold bars
 *  normalized to the top spender + a secondary quota-% read. */
@Composable
fun BurnLeaderboardBody(
    summaries: List<RollupSummary>,
    quotaItems: List<QuotaRingItem>,
    displayMode: UsageDisplayMode,
    onProviderClick: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val quotaByProvider =
        remember(quotaItems) {
            quotaItems.mapNotNull { item ->
                AgentProvider.fromKey(item.providerKey)?.let { it to item.pressureRemaining }
            }.toMap()
        }
    val ranked = BurnLeaderboardMath.ranked(summaries, displayMode)
    val maxValue =
        (ranked.maxOfOrNull { BurnLeaderboardMath.value(it, displayMode) } ?: 1.0)
            .coerceAtLeast(0.0001)

    AuroraGlassCard(modifier = modifier, cornerRadius = AuroraRadius.XL) {
        BurnSectionLabel(
            "Spend leaderboard",
            "Top providers · by ${if (displayMode == UsageDisplayMode.CURRENCY) "cost" else "tokens"}",
        )
        Spacer(Modifier.height(AuroraSpacing.MD.dp))
        if (ranked.isEmpty()) {
            BurnEmptyHint("No spend recorded yet.")
        } else {
            Column(verticalArrangement = Arrangement.spacedBy(AuroraSpacing.MD.dp)) {
                ranked.forEachIndexed { index, p ->
                    val value = BurnLeaderboardMath.value(p, displayMode)
                    val provider = AgentProvider.fromKey(p.provider)
                    val quotaPct = provider?.let { quotaByProvider[it] }?.let { (it * 100).toInt() }
                    LeaderRow(
                        model =
                        LeaderRowModel(
                            rank = index + 1,
                            provider = provider,
                            fallbackName = p.accountLabel.ifBlank { p.provider },
                            providerKey = p.provider,
                            amount =
                            if (displayMode == UsageDisplayMode.CURRENCY) {
                                formatCost(value)
                            } else {
                                compactNumber(value)
                            },
                            fraction = BurnLeaderboardMath.fraction(value, maxValue),
                            quotaPct = quotaPct,
                        ),
                        onClick = { onProviderClick(p.provider) },
                    )
                }
            }
        }
    }
}

private data class LeaderRowModel(
    val rank: Int,
    val provider: AgentProvider?,
    val fallbackName: String,
    val providerKey: String,
    val amount: String,
    val fraction: Float,
    val quotaPct: Int?,
)

@Composable
private fun LeaderRow(model: LeaderRowModel, onClick: () -> Unit) {
    val barColor = model.provider?.let { Color(it.brandColor) } ?: AuroraColors.ember
    Row(
        modifier = Modifier.fillMaxWidth().clickable { onClick() },
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = "${model.rank}",
            fontSize = AuroraTypography.caption.sp,
            fontWeight = FontWeight.Bold,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.width(18.dp),
        )
        Spacer(Modifier.width(AuroraSpacing.SM.dp))
        ProviderAvatar(providerKey = model.providerKey, size = 24)
        Spacer(Modifier.width(AuroraSpacing.SM.dp))
        LeaderRowBody(model = model, barColor = barColor)
        if (model.quotaPct != null) {
            Spacer(Modifier.width(AuroraSpacing.SM.dp))
            Text(
                text = "${model.quotaPct}%",
                fontSize = AuroraTypography.tiny.sp,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.width(34.dp),
            )
        }
    }
}

@Composable
private fun RowScope.LeaderRowBody(model: LeaderRowModel, barColor: Color) {
    Column(modifier = Modifier.weight(1f)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                text = model.provider?.displayName ?: model.fallbackName,
                fontSize = AuroraTypography.caption.sp,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurface,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f),
            )
            Text(
                text = model.amount,
                fontSize = AuroraTypography.caption.sp,
                fontWeight = FontWeight.Bold,
                color = MaterialTheme.colorScheme.onSurface,
            )
        }
        Spacer(Modifier.height(4.dp))
        LeaderRowProgressBar(fraction = model.fraction, barColor = barColor)
    }
}

@Composable
private fun LeaderRowProgressBar(fraction: Float, barColor: Color) {
    Box(
        modifier =
        Modifier
            .fillMaxWidth()
            .height(8.dp)
            .clip(CircleShape)
            .background(barColor.copy(alpha = 0.14f)),
    ) {
        Box(
            modifier =
            Modifier
                .fillMaxWidth(fraction)
                .fillMaxHeight()
                .clip(CircleShape)
                .background(
                    Brush.horizontalGradient(listOf(barColor, barColor.copy(alpha = 0.65f))),
                ),
        )
    }
}

// MARK: - Timeline

/** Per-provider burn over the window: a sparkline + window total per provider,
 *  sourced from the same `TrendDataDigest` the Pulse Atlas card uses. */
@Composable
fun BurnTimelineBody(digest: TrendDataDigest, displayMode: UsageDisplayMode, onProviderClick: (String) -> Unit, modifier: Modifier = Modifier) {
    val rows = digest.providers.filter { it.costUsd > 0 || it.tokens > 0 }
    AuroraGlassCard(modifier = modifier, cornerRadius = AuroraRadius.XL) {
        BurnSectionLabel("Burn trends", "${digest.windowDescription} · per provider")
        Spacer(Modifier.height(AuroraSpacing.MD.dp))
        if (rows.isEmpty() || digest.daily.size < 2) {
            BurnEmptyHint("Daily burn trends appear once there are at least two days of usage.")
        } else {
            Column(verticalArrangement = Arrangement.spacedBy(AuroraSpacing.MD.dp)) {
                rows.forEach { slice ->
                    val series = digest.daily.map { it.perProvider[slice.providerKey] ?: 0.0 }
                    TimelineRow(
                        slice = slice,
                        series = series,
                        total =
                        if (displayMode == UsageDisplayMode.CURRENCY) {
                            formatCost(slice.costUsd)
                        } else {
                            compactNumber(slice.tokens.toDouble())
                        },
                        onClick = { onProviderClick(slice.providerKey) },
                    )
                }
            }
        }
    }
}

@Composable
private fun TimelineRow(slice: TrendDataDigest.ProviderSlice, series: List<Double>, total: String, onClick: () -> Unit) {
    val provider = AgentProvider.fromKey(slice.providerKey)
    val accent = provider?.let { Color(it.brandColor) } ?: AuroraColors.ember
    Row(
        modifier = Modifier.fillMaxWidth().clickable { onClick() },
        verticalAlignment = Alignment.CenterVertically,
    ) {
        ProviderAvatar(providerKey = slice.providerKey, size = 26)
        Spacer(Modifier.width(AuroraSpacing.SM.dp))
        Column(modifier = Modifier.width(96.dp)) {
            Text(
                text = provider?.displayName ?: slice.provider,
                fontSize = AuroraTypography.caption.sp,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurface,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                text = total,
                fontSize = AuroraTypography.tiny.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        Spacer(Modifier.width(AuroraSpacing.SM.dp))
        Sparkline(values = series, accent = accent, modifier = Modifier.weight(1f).height(38.dp))
    }
}

/** A compact filled line sparkline drawn on a Canvas. */
@Composable
private fun Sparkline(values: List<Double>, accent: Color, modifier: Modifier) {
    Canvas(modifier = modifier) {
        if (values.size < 2) return@Canvas
        val maxV = (values.maxOrNull() ?: 0.0).coerceAtLeast(0.0001)
        val stepX = size.width / (values.size - 1)
        val line = Path()
        val fill = Path()
        values.forEachIndexed { i, v ->
            val x = stepX * i
            val y = size.height - (v / maxV).toFloat() * size.height
            if (i == 0) {
                line.moveTo(x, y)
                fill.moveTo(x, size.height)
                fill.lineTo(x, y)
            } else {
                line.lineTo(x, y)
                fill.lineTo(x, y)
            }
        }
        fill.lineTo(size.width, size.height)
        fill.close()
        drawPath(
            path = fill,
            brush = Brush.verticalGradient(listOf(accent.copy(alpha = 0.30f), Color.Transparent)),
        )
        drawPath(
            path = line,
            color = accent,
            style = Stroke(width = 3f, cap = StrokeCap.Round, join = StrokeJoin.Round),
        )
    }
}

// MARK: - Shared helpers

@Composable
private fun BurnSectionLabel(title: String, subtitle: String) {
    Column {
        Text(
            text = title,
            fontSize = AuroraTypography.title.sp,
            fontWeight = FontWeight.Bold,
            color = MaterialTheme.colorScheme.onSurface,
        )
        Text(
            text = subtitle,
            fontSize = AuroraTypography.caption.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun BurnEmptyHint(message: String) {
    Text(
        text = message,
        fontSize = AuroraTypography.caption.sp,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.padding(vertical = AuroraSpacing.LG.dp),
    )
}

private fun accentFor(avg: Double): Color = when {
    avg < 0.25 -> AuroraColors.error
    avg < 0.50 -> AuroraColors.warning
    else -> AuroraColors.success
}

private fun formatCost(v: Double): String {
    val m = abs(v)
    return if (m in 0.0..0.01 && m > 0.0) {
        "$" + String.format(java.util.Locale.US, "%.4f", m)
    } else {
        "$" + String.format(java.util.Locale.US, "%,.2f", m)
    }
}

private fun compactNumber(v: Double): String = when {
    v >= 1_000_000_000 -> String.format(java.util.Locale.US, "%.1fB", v / 1_000_000_000)
    v >= 1_000_000 -> String.format(java.util.Locale.US, "%.1fM", v / 1_000_000)
    v >= 1_000 -> String.format(java.util.Locale.US, "%.1fK", v / 1_000)
    else -> v.toLong().toString()
}
