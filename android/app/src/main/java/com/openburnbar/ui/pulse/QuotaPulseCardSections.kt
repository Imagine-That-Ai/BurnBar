// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.pulse

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
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
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Percent
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
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
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.stores.QuotaPreferences
import com.openburnbar.ui.burn.ProviderAuroraAvatar
import com.openburnbar.ui.burn.QuotaRingItem
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraTypography

@Composable
internal fun QuotaPulseCardHeader(
    isJiggling: Boolean,
    statusColor: Color,
    percentageDisplayMode: String,
    prefs: QuotaPreferences,
    onOpenBurn: () -> Unit,
    onDoneJiggling: () -> Unit,
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(
                modifier =
                Modifier
                    .size(6.dp)
                    .clip(CircleShape)
                    .background(statusColor),
            )
            Spacer(modifier = Modifier.width(AuroraSpacing.sm.dp))
            Text(
                text = if (isJiggling) "CUSTOMIZE QUOTA" else "QUOTA",
                fontSize = AuroraTypography.tiny.sp,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                letterSpacing = 1.6.sp,
            )
        }
        if (isJiggling) {
            QuotaJiggleToolbar(
                percentageDisplayMode = percentageDisplayMode,
                prefs = prefs,
                onDone = onDoneJiggling,
            )
        } else {
            Text(
                text = "Open ›",
                fontSize = AuroraTypography.tiny.sp,
                fontWeight = FontWeight.SemiBold,
                color = AuroraColors.ember,
                modifier = Modifier.clickable { onOpenBurn() },
            )
        }
    }
}

@Composable
private fun QuotaJiggleToolbar(
    percentageDisplayMode: String,
    prefs: QuotaPreferences,
    onDone: () -> Unit,
) {
    val haptic = LocalHapticFeedback.current
    Row(verticalAlignment = Alignment.CenterVertically) {
        IconButton(
            onClick = {
                haptic.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                val modes = listOf("remainingPercent", "usedPercent", "absoluteValues", "fractional")
                val idx = modes.indexOf(percentageDisplayMode).takeIf { it >= 0 } ?: 0
                prefs.setPercentageDisplayMode(modes[(idx + 1) % modes.size])
            },
            modifier = Modifier.size(32.dp),
        ) {
            Icon(Icons.Filled.Percent, "Display Mode", tint = AuroraColors.ember, modifier = Modifier.size(16.dp))
        }
        IconButton(
            onClick = {
                haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                onDone()
            },
            modifier = Modifier.size(32.dp),
        ) {
            Icon(Icons.Filled.Check, "Done", tint = AuroraColors.success, modifier = Modifier.size(18.dp))
        }
    }
}

@Composable
internal fun QuotaPulseFleetHero(
    fleetHealth: Double,
    statusColor: Color,
    fleetSubtitle: String,
) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        FleetGauge(progress = fleetHealth, accent = statusColor, modifier = Modifier.size(72.dp))
        Spacer(modifier = Modifier.width(AuroraSpacing.lg.dp))
        Column {
            Text(
                text = "${(fleetHealth * 100).toInt()}% remaining",
                fontSize = 22.sp,
                fontWeight = FontWeight.Bold,
                color = MaterialTheme.colorScheme.onSurface,
            )
            Text(
                text = fleetSubtitle,
                fontSize = AuroraTypography.caption.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
internal fun QuotaPulseProviderList(
    items: List<QuotaRingItem>,
    onSelect: (String) -> Unit,
    onOpenBurn: () -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        items.take(5).forEach { item ->
            QuotaProviderRow(item = item, onClick = { onSelect(item.providerKey) })
        }
        if (items.size > 5) {
            Text(
                text = "${items.size - 5} more · See all",
                fontSize = AuroraTypography.caption.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.clickable { onOpenBurn() },
            )
        }
    }
}

@Composable
internal fun FleetGauge(progress: Double, accent: Color, modifier: Modifier = Modifier) {
    val animatedProgress by animateFloatAsState(
        targetValue = progress.coerceIn(0.0, 1.0).toFloat(),
        animationSpec = tween(600),
        label = "fleet_gauge",
    )
    val trackColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.35f)
    Box(contentAlignment = Alignment.Center, modifier = modifier) {
        Canvas(modifier = Modifier.fillMaxSize()) {
            val strokeWidth = 7f
            val diameter = size.minDimension - strokeWidth
            val topLeft = Offset((size.width - diameter) / 2, (size.height - diameter) / 2)
            drawCircle(color = trackColor, radius = diameter / 2, style = Stroke(width = strokeWidth))
            drawArc(
                brush =
                Brush.sweepGradient(
                    colors = listOf(accent, accent.copy(alpha = 0.85f), AuroraColors.amber, accent),
                    center = Offset(size.width / 2, size.height / 2),
                ),
                startAngle = -90f,
                sweepAngle = 360f * animatedProgress,
                useCenter = false,
                topLeft = topLeft,
                size = Size(diameter, diameter),
                style = Stroke(width = 8f, cap = StrokeCap.Round),
            )
        }
        Text(text = "\uD83D\uDD25", fontSize = 22.sp)
    }
}

@Composable
internal fun QuotaProviderRow(item: QuotaRingItem, onClick: () -> Unit) {
    val primary = Color(item.provider.brandColor)
    val statusColor =
        when {
            item.pressureRemaining < 0.25 -> AuroraColors.error
            item.pressureRemaining < 0.50 -> AuroraColors.warning
            else -> AuroraColors.success
        }
    val pct = (item.pressureRemaining * 100).toInt()

    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier =
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(MaterialTheme.colorScheme.surface.copy(alpha = 0.45f))
            .clickable { onClick() }
            .padding(vertical = 6.dp, horizontal = 8.dp),
    ) {
        Box(
            modifier =
            Modifier
                .width(3.dp)
                .height(28.dp)
                .clip(CircleShape)
                .background(statusColor),
        )
        Spacer(modifier = Modifier.width(AuroraSpacing.sm.dp))
        ProviderAuroraAvatar(providerKey = item.providerKey, size = 32, showHalo = false)
        Spacer(modifier = Modifier.width(AuroraSpacing.sm.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = item.label,
                fontSize = AuroraTypography.caption.sp,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurface,
            )
            LinearProgressIndicator(
                progress = { item.pressureRemaining.toFloat().coerceIn(0f, 1f) },
                modifier =
                Modifier
                    .fillMaxWidth()
                    .height(5.dp)
                    .clip(CircleShape),
                color = primary.copy(alpha = 0.85f),
                trackColor = Color.Black.copy(alpha = 0.42f),
            )
        }
        Spacer(modifier = Modifier.width(8.dp))
        Text(
            text = "$pct%",
            fontSize = AuroraTypography.caption.sp,
            fontWeight = FontWeight.SemiBold,
            color = statusColor,
        )
    }
}
