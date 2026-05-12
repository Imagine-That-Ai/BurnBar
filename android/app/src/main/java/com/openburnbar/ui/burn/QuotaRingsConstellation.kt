package com.openburnbar.ui.burn

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.models.AgentProvider
import com.openburnbar.data.models.ProviderQuotaSnapshot
import com.openburnbar.data.models.QuotaBucket
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraRadius
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraTypography

/** Grouped quota data for a single provider. */
data class QuotaRingItem(
    val provider: AgentProvider,
    val providerKey: String,
    val pressureRemaining: Double,
    val label: String
)

/** Build ring items from quota snapshots, matching iOS QuotaRingsConstellation logic. */
fun buildQuotaRingItems(snapshots: List<ProviderQuotaSnapshot>): List<QuotaRingItem> {
    val grouped = snapshots.groupBy { it.provider }
    return grouped.mapNotNull { (key, snaps) ->
        val provider = AgentProvider.fromKey(key) ?: return@mapNotNull null
        val pressure = snaps
            .flatMap { it.buckets }
            .filter { it.limit > 0 }
            .map { maxOf(0.0, it.remaining) / it.limit }
            .minOrNull() ?: 1.0
        QuotaRingItem(
            provider = provider,
            providerKey = key,
            pressureRemaining = pressure,
            label = provider.displayName
        )
    }.sortedWith(compareBy<QuotaRingItem> { it.pressureRemaining }.thenBy { it.providerKey })
}

/** Horizontal strip of provider quota chips with rings. */
@Composable
fun QuotaRingsConstellation(
    items: List<QuotaRingItem>,
    onProviderClick: (String) -> Unit,
    modifier: Modifier = Modifier
) {
    LazyRow(
        modifier = modifier,
        horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.md.dp)
    ) {
        items(items, key = { it.providerKey }) { item ->
            ProviderQuotaChip(
                item = item,
                onClick = { onProviderClick(item.providerKey) }
            )
        }
    }
}

@Composable
fun ProviderQuotaChip(
    item: QuotaRingItem,
    onClick: () -> Unit,
    modifier: Modifier = Modifier
) {
    val primary = Color(item.provider.brandColor)
    val statusColor = when {
        item.pressureRemaining < 0.25 -> AuroraColors.error
        item.pressureRemaining < 0.50 -> AuroraColors.warning
        else -> AuroraColors.success
    }
    val pct = (item.pressureRemaining * 100).toInt()

    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier = modifier
            .width(64.dp)
            .clickable { onClick() }
    ) {
        Box(contentAlignment = Alignment.Center, modifier = Modifier.size(56.dp)) {
            // Soft halo
            Box(
                modifier = Modifier
                    .size(56.dp)
                    .clip(CircleShape)
                    .background(primary.copy(alpha = 0.16f))
            )
            // Track ring
            Canvas(modifier = Modifier.size(52.dp)) {
                drawCircle(
                    color = primary.copy(alpha = 0.18f),
                    radius = size.minDimension / 2,
                    style = Stroke(width = 3f)
                )
            }
            // Progress ring
            val animatedProgress by animateFloatAsState(
                targetValue = item.pressureRemaining.toFloat().coerceIn(0f, 1f),
                animationSpec = tween(600),
                label = "quota_progress"
            )
            Canvas(modifier = Modifier.size(52.dp)) {
                val strokeWidth = 4f
                val diameter = size.minDimension - strokeWidth
                val topLeft = Offset(strokeWidth / 2, strokeWidth / 2)
                drawArc(
                    color = primary,
                    startAngle = -90f,
                    sweepAngle = 360f * animatedProgress,
                    useCenter = false,
                    topLeft = topLeft,
                    size = Size(diameter, diameter),
                    style = Stroke(width = strokeWidth, cap = StrokeCap.Round)
                )
            }
            // Logo glass disc
            Box(
                modifier = Modifier
                    .size(36.dp)
                    .clip(CircleShape)
                    .background(MaterialTheme.colorScheme.surface.copy(alpha = 0.85f))
                    .border(0.5.dp, primary.copy(alpha = 0.35f), CircleShape),
                contentAlignment = Alignment.Center
            ) {
                Text(
                    text = item.provider.displayName.take(2).uppercase(),
                    fontSize = 12.sp,
                    fontWeight = FontWeight.Bold,
                    color = primary
                )
            }
        }
        Spacer(modifier = Modifier.height(4.dp))
        Text(
            text = "$pct%",
            fontSize = AuroraTypography.caption.sp,
            fontWeight = FontWeight.SemiBold,
            color = statusColor
        )
    }
}

/** Fleet-level health gauge — a single readable ring. */
@Composable
fun FleetHealthGauge(
    progress: Double,
    accent: Color,
    modifier: Modifier = Modifier
) {
    val animatedProgress by animateFloatAsState(
        targetValue = progress.coerceIn(0.0, 1.0).toFloat(),
        animationSpec = tween(600),
        label = "fleet_gauge"
    )
    val trackColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.4f)

    Box(contentAlignment = Alignment.Center, modifier = modifier) {
        Canvas(modifier = Modifier.fillMaxWidth().height(96.dp)) {
            val strokeWidth = 10f
            val diameter = minOf(size.width, size.height) - strokeWidth
            val topLeft = Offset(
                (size.width - diameter) / 2,
                (size.height - diameter) / 2
            )
            // Track
            drawCircle(
                color = trackColor,
                radius = diameter / 2,
                style = Stroke(width = strokeWidth)
            )
            // Progress arc
            drawArc(
                brush = Brush.sweepGradient(
                    colors = listOf(accent, accent.copy(alpha = 0.85f), AuroraColors.amber, accent),
                    center = Offset(size.width / 2, size.height / 2)
                ),
                startAngle = -90f,
                sweepAngle = 360f * animatedProgress,
                useCenter = false,
                topLeft = topLeft,
                size = Size(diameter, diameter),
                style = Stroke(width = strokeWidth, cap = StrokeCap.Round)
            )
        }
        Text(
            text = "\uD83D\uDD25", // fire emoji
            fontSize = 26.sp
        )
    }
}
