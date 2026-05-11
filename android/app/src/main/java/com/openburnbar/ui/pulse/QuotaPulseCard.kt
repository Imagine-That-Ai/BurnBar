package com.openburnbar.ui.pulse

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
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
import com.openburnbar.ui.burn.ProviderAuroraAvatar
import com.openburnbar.ui.burn.buildQuotaRingItems
import com.openburnbar.ui.components.AuroraGlassCard
import com.openburnbar.ui.components.EmptyStateView
import com.openburnbar.ui.theme.*

@Composable
fun QuotaPulseCard(
    snapshots: List<ProviderQuotaSnapshot>,
    onSelect: (String) -> Unit,
    onOpenBurn: () -> Unit
) {
    val items = buildQuotaRingItems(snapshots)
    val hasUrgent = snapshots.flatMap { it.buckets }.any { bucket ->
        bucket.limit > 0 && maxOf(0.0, bucket.remaining) / bucket.limit < 0.25
    }
    val fleetHealth = if (items.isNotEmpty()) {
        items.map { it.pressureRemaining }.average()
    } else 1.0
    val fleetPct = (fleetHealth * 100).toInt()
    val statusColor = when {
        hasUrgent -> AuroraColors.warning
        fleetHealth < 0.5 -> AuroraColors.amber
        else -> AuroraColors.success
    }
    val urgentCount = items.count { it.pressureRemaining < 0.25 }
    val providerWord = if (items.size == 1) "provider" else "providers"
    val fleetSubtitle = if (hasUrgent) {
        "${items.size} $providerWord · $urgentCount under pressure"
    } else {
        "${items.size} $providerWord · all healthy"
    }

    AuroraGlassCard(
        modifier = Modifier.padding(horizontal = AuroraSpacing.lg.dp),
        cornerRadius = AuroraRadius.xl
    ) {
        Column(modifier = Modifier.padding(AuroraSpacing.lg.dp)) {
            // Header
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Box(
                        modifier = Modifier
                            .size(6.dp)
                            .clip(CircleShape)
                            .background(statusColor)
                    )
                    Spacer(modifier = Modifier.width(AuroraSpacing.sm.dp))
                    Text(
                        text = "QUOTA",
                        fontSize = AuroraTypography.tiny.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        letterSpacing = 1.6.sp
                    )
                }
                Text(
                    text = "Open ›",
                    fontSize = AuroraTypography.tiny.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = AuroraColors.ember,
                    modifier = Modifier.clickable { onOpenBurn() }
                )
            }

            Spacer(modifier = Modifier.height(AuroraSpacing.lg.dp))

            if (items.isEmpty()) {
                EmptyStateView(
                    title = "No quota signal yet",
                    message = "Connect a provider on your Mac to start tracking quota."
                )
            } else {
                // Fleet hero
                Row(verticalAlignment = Alignment.CenterVertically) {
                    FleetGauge(
                        progress = fleetHealth,
                        accent = statusColor,
                        modifier = Modifier.size(72.dp)
                    )
                    Spacer(modifier = Modifier.width(AuroraSpacing.lg.dp))
                    Column {
                        Text(
                            text = "$fleetPct% remaining",
                            fontSize = 22.sp,
                            fontWeight = FontWeight.Bold,
                            color = MaterialTheme.colorScheme.onSurface
                        )
                        Text(
                            text = fleetSubtitle,
                            fontSize = AuroraTypography.caption.sp,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }

                Spacer(modifier = Modifier.height(AuroraSpacing.md.dp))

                androidx.compose.material3.Divider(
                    color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.5f)
                )

                Spacer(modifier = Modifier.height(AuroraSpacing.md.dp))

                // Provider rows
                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    items.take(5).forEach { item ->
                        QuotaProviderRow(
                            item = item,
                            onClick = { onSelect(item.providerKey) }
                        )
                    }
                    if (items.size > 5) {
                        Text(
                            text = "${items.size - 5} more · See all",
                            fontSize = AuroraTypography.caption.sp,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.clickable { onOpenBurn() }
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun FleetGauge(
    progress: Double,
    accent: Color,
    modifier: Modifier = Modifier
) {
    val animatedProgress by animateFloatAsState(
        targetValue = progress.coerceIn(0.0, 1.0).toFloat(),
        animationSpec = tween(600),
        label = "fleet_gauge"
    )
    val trackColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.35f)
    Box(contentAlignment = Alignment.Center, modifier = modifier) {
        Canvas(modifier = Modifier.fillMaxSize()) {
            val strokeWidth = 7f
            val diameter = size.minDimension - strokeWidth
            val topLeft = Offset((size.width - diameter) / 2, (size.height - diameter) / 2)
            drawCircle(
                color = trackColor,
                radius = diameter / 2,
                style = Stroke(width = strokeWidth)
            )
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
                style = Stroke(width = 8f, cap = StrokeCap.Round)
            )
        }
        Text(text = "\uD83D\uDD25", fontSize = 22.sp)
    }
}

@Composable
private fun QuotaProviderRow(
    item: com.openburnbar.ui.burn.QuotaRingItem,
    onClick: () -> Unit
) {
    val primary = Color(item.provider.brandColor)
    val statusColor = when {
        item.pressureRemaining < 0.25 -> AuroraColors.error
        item.pressureRemaining < 0.50 -> AuroraColors.warning
        else -> AuroraColors.success
    }
    val pct = (item.pressureRemaining * 100).toInt()

    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(MaterialTheme.colorScheme.surface.copy(alpha = 0.45f))
            .clickable { onClick() }
            .padding(vertical = 6.dp, horizontal = 8.dp)
    ) {
        // Status indicator rail
        Box(
            modifier = Modifier
                .width(3.dp)
                .height(28.dp)
                .clip(CircleShape)
                .background(statusColor)
        )
        Spacer(modifier = Modifier.width(AuroraSpacing.sm.dp))
        ProviderAuroraAvatar(providerKey = item.providerKey, size = 26, showHalo = false)
        Spacer(modifier = Modifier.width(AuroraSpacing.sm.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = item.label,
                fontSize = AuroraTypography.caption.sp,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurface
            )
            LinearProgressIndicator(
                progress = { item.pressureRemaining.toFloat().coerceIn(0f, 1f) },
                modifier = Modifier
                    .fillMaxWidth()
                    .height(5.dp)
                    .clip(CircleShape),
                color = primary.copy(alpha = 0.85f),
                trackColor = Color.Black.copy(alpha = 0.42f)
            )
        }
        Spacer(modifier = Modifier.width(8.dp))
        Text(
            text = "$pct%",
            fontSize = AuroraTypography.caption.sp,
            fontWeight = FontWeight.SemiBold,
            color = statusColor
        )
    }
}
