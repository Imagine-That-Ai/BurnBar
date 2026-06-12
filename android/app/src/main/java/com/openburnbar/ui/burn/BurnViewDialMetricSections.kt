package com.openburnbar.ui.burn

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.DateRange
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.models.AgentProvider
import com.openburnbar.data.models.IdealPace
import com.openburnbar.data.models.PaceSeverity
import com.openburnbar.data.models.QuotaBucket
import com.openburnbar.data.models.displayRemainingFraction
import com.openburnbar.data.models.idealPace
import com.openburnbar.data.models.label
import com.openburnbar.data.models.getRemainingText
import com.openburnbar.data.stores.QuotaWindowKind
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraTypography
import java.util.Locale
import kotlin.math.roundToInt

@Composable
fun QuotaArcDial(
    outer: QuotaBucket?,
    inner: QuotaBucket?,
    provider: AgentProvider,
    modifier: Modifier = Modifier,
    diameter: Dp = 138.dp
) {
    val state = quotaDialState(outer = outer, inner = inner, provider = provider)
    Box(contentAlignment = Alignment.Center, modifier = modifier.size(diameter)) {
        QuotaArcDialCanvas(state = state)
        QuotaArcDialCenter(state = state)
    }
}

private data class QuotaDialState(
    val outer: QuotaDialRing,
    val inner: QuotaDialRing,
    val centerText: String,
    val centerSubtitle: String,
    val centerColor: Color,
    val hasSignal: Boolean,
)

private data class QuotaDialRing(
    val bucket: QuotaBucket?,
    val remaining: Double,
    val pace: IdealPace?,
    val fillColor: Color,
    val emptyColor: Color,
    val lineWidth: Dp,
    val inset: Dp,
    val dashPattern: FloatArray,
)

private fun quotaDialState(
    outer: QuotaBucket?,
    inner: QuotaBucket?,
    provider: AgentProvider
): QuotaDialState {
    val primaryColor = Color(provider.brandColor)
    val accentColor = Color(provider.accentColor)
    val dominantBucket = outer ?: inner
    return QuotaDialState(
        outer =
            quotaDialRing(
                outer,
                primaryColor,
                primaryColor.copy(alpha = QUOTA_DIAL_OUTER_EMPTY_ALPHA),
                QUOTA_DIAL_OUTER_WIDTH_DP.dp,
                QUOTA_DIAL_OUTER_INSET_DP.dp,
                floatArrayOf(QUOTA_DIAL_OUTER_DASH_ON, QUOTA_DIAL_OUTER_DASH_OFF),
            ),
        inner =
            quotaDialRing(
                inner,
                accentColor,
                accentColor.copy(alpha = QUOTA_DIAL_INNER_EMPTY_ALPHA),
                QUOTA_DIAL_INNER_WIDTH_DP.dp,
                QUOTA_DIAL_INNER_INSET_DP.dp,
                floatArrayOf(QUOTA_DIAL_INNER_DASH_ON, QUOTA_DIAL_INNER_DASH_OFF),
            ),
        centerText = dominantBucket?.let { "${((it.displayRemainingFraction ?: 1.0) * 100).roundToInt()}%" } ?: "—",
        centerSubtitle = quotaDialCenterSubtitle(dominantBucket, outer, inner),
        centerColor = primaryColor,
        hasSignal = dominantBucket != null,
    )
}

private fun quotaDialRing(
    bucket: QuotaBucket?,
    baseColor: Color,
    emptyColor: Color,
    lineWidth: Dp,
    inset: Dp,
    dashPattern: FloatArray
): QuotaDialRing {
    val remaining = bucket?.displayRemainingFraction ?: 1.0
    return QuotaDialRing(
        bucket = bucket,
        remaining = remaining,
        pace = bucket?.idealPace(),
        fillColor = quotaDialFillColor(baseColor, remaining),
        emptyColor = emptyColor,
        lineWidth = lineWidth,
        inset = inset,
        dashPattern = dashPattern
    )
}

private fun quotaDialFillColor(baseColor: Color, remaining: Double): Color =
    when {
        remaining >= QUOTA_REMAINING_HEALTHY -> baseColor
        remaining >= QUOTA_REMAINING_WATCH -> baseColor.copy(alpha = QUOTA_DIAL_MUTED_ALPHA)
        remaining >= QUOTA_REMAINING_WARN -> AuroraColors.amber
        else -> AuroraColors.warning
    }

private fun quotaDialCenterSubtitle(dominantBucket: QuotaBucket?, outer: QuotaBucket?, inner: QuotaBucket?): String {
    if (dominantBucket == null) return "no signal"
    val outerLabel = quotaDialWindowLabel(outer)
    val displayLabel = if (outerLabel == "—") quotaDialWindowLabel(inner) else outerLabel
    return "left in $displayLabel"
}

private fun quotaDialWindowLabel(bucket: QuotaBucket?): String =
    when (bucket?.let { QuotaWindowKind.infer(it) }) {
        QuotaWindowKind.SEVEN_DAY -> "7d"
        QuotaWindowKind.MONTHLY -> "30d"
        QuotaWindowKind.DAILY -> "24h"
        QuotaWindowKind.FIVE_HOUR -> "5h"
        else -> bucket?.label?.take(QUOTA_DIAL_LABEL_LIMIT) ?: "—"
    }

private fun quotaDialTrackColor(isDark: Boolean): Color =
    if (isDark) AuroraColors.darkSurfaceElevated.copy(alpha = 0.85f) else AuroraColors.lightSurfaceElevated.copy(alpha = 0.85f)

@Composable
private fun QuotaArcDialCanvas(state: QuotaDialState) {
    val trackColor = quotaDialTrackColor(isSystemInDarkTheme())
    Canvas(modifier = Modifier.fillMaxSize()) {
        drawQuotaDialRing(ring = state.outer, trackColor = trackColor)
        drawQuotaDialRing(ring = state.inner, trackColor = trackColor)
    }
}

private fun DrawScope.drawQuotaDialRing(ring: QuotaDialRing, trackColor: Color) {
    val lineWidth = ring.lineWidth.toPx()
    val diameter = size.minDimension - lineWidth - ring.inset.toPx()
    val center = Offset(size.width / 2f, size.height / 2f)
    val topLeft = Offset(center.x - diameter / 2f, center.y - diameter / 2f)
    val arcSize = Size(diameter, diameter)
    drawCircle(color = trackColor, radius = diameter / 2f, style = Stroke(width = lineWidth))
    if (ring.bucket == null) {
        drawArc(
            color = ring.emptyColor,
            startAngle = 0f,
            sweepAngle = 360f,
            useCenter = false,
            topLeft = topLeft,
            size = arcSize,
            style = Stroke(width = lineWidth, pathEffect = PathEffect.dashPathEffect(ring.dashPattern))
        )
    } else {
        drawQuotaDialFilledArc(ring = ring, lineWidth = lineWidth, topLeft = topLeft, arcSize = arcSize)
        ring.pace?.let { drawQuotaDialPaceMarker(it, ring.fillColor, lineWidth, center, diameter) }
    }
}

private fun DrawScope.drawQuotaDialFilledArc(
    ring: QuotaDialRing,
    lineWidth: Float,
    topLeft: Offset,
    arcSize: Size
) {
    drawArc(
        color = ring.fillColor,
        startAngle = -90f,
        sweepAngle = 360f * ring.remaining.toFloat().coerceIn(0f, 1f),
        useCenter = false,
        topLeft = topLeft,
        size = arcSize,
        style = Stroke(width = lineWidth, cap = StrokeCap.Round)
    )
}

private fun DrawScope.drawQuotaDialPaceMarker(
    pace: IdealPace,
    fillColor: Color,
    lineWidth: Float,
    center: Offset,
    diameter: Float
) {
    val angle = QUOTA_DIAL_START_ANGLE_DEGREES + QUOTA_DIAL_FULL_CIRCLE_DEGREES * (1.0f - pace.elapsedFraction.toFloat())
    val angleRad = Math.toRadians(angle.toDouble())
    val radius = diameter / QUOTA_DIAL_RADIUS_DIVISOR
    val markerCenter = Offset(
        x = center.x + Math.cos(angleRad).toFloat() * radius,
        y = center.y + Math.sin(angleRad).toFloat() * radius
    )
    drawCircle(color = fillColor.copy(alpha = 0.25f), radius = (lineWidth + 4f) / 2f, center = markerCenter)
    drawCircle(color = Color.White, radius = (lineWidth - 2f) / 2f, center = markerCenter)
    drawCircle(color = fillColor.copy(alpha = 0.9f), radius = (lineWidth - 2f) / 2f, center = markerCenter, style = Stroke(width = 1.dp.toPx()))
}

@Composable
private fun QuotaArcDialCenter(state: QuotaDialState) {
    Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
        Text(
            text = state.centerText,
            fontSize = 28.sp,
            fontWeight = FontWeight.Bold,
            fontFamily = FontFamily.Monospace,
            color = if (state.hasSignal) state.centerColor else MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.5f)
        )
        Text(
            text = state.centerSubtitle,
            fontSize = AuroraTypography.tiny.sp,
            fontFamily = FontFamily.Monospace,
            color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f)
        )
    }
}

@Composable
fun MetricRow(
    glyph: String,
    label: String,
    bucket: QuotaBucket?,
    fallback: String,
    provider: AgentProvider
) {
    val primaryColor = Color(provider.brandColor)

    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp)
    ) {
        MetricIcon(glyph = glyph, tint = primaryColor)

        Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
            Text(
                text = label.uppercase(Locale.getDefault()),
                fontSize = 8.sp,
                fontFamily = FontFamily.Monospace,
                color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f),
                letterSpacing = 0.8.sp
            )

            MetricBucketContent(bucket = bucket, fallback = fallback)
        }
    }
}

@Composable
private fun MetricIcon(glyph: String, tint: Color) {
    Box(modifier = Modifier.width(14.dp), contentAlignment = Alignment.Center) {
        Icon(
            imageVector = when (glyph) {
                "clock.fill" -> Icons.Default.Schedule
                "calendar" -> Icons.Default.DateRange
                else -> Icons.Default.DateRange
            },
            contentDescription = null,
            tint = tint,
            modifier = Modifier.size(11.dp)
        )
    }
}

@Composable
private fun MetricBucketContent(bucket: QuotaBucket?, fallback: String) {
    if (bucket == null) {
        Text(
            text = fallback,
            fontSize = 11.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.5f)
        )
        return
    }
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(
            text = bucket.metricRemainingText(),
            fontSize = 14.sp,
            fontWeight = FontWeight.SemiBold,
            fontFamily = FontFamily.Monospace,
            color = MaterialTheme.colorScheme.onSurface
        )
        Text(
            text = "·",
            fontSize = AuroraTypography.tiny.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.5f)
        )
        Text(
            text = quotaUsageText(bucket),
            fontSize = AuroraTypography.tiny.sp,
            fontFamily = FontFamily.Monospace,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
        val pace = bucket.idealPace()
        if (pace != null && pace.severity != PaceSeverity.ON_PACE) PaceBadge(pace = pace)
    }
}

private fun QuotaBucket.metricRemainingText(): String =
    if (meta?.get("unit")?.toString()?.lowercase() == "unlimited") {
        "Unlimited"
    } else {
        getRemainingText("absoluteValues")
    }

@Composable
fun PaceBadge(pace: IdealPace) {
    val tint = when (pace.severity) {
        PaceSeverity.ON_PACE -> MaterialTheme.colorScheme.onSurfaceVariant
        PaceSeverity.AHEAD_OF_BUDGET -> AuroraColors.warning
        PaceSeverity.BEHIND_BUDGET -> AuroraColors.success
    }

    Box(
        modifier = Modifier
            .clip(RoundedCornerShape(8.dp))
            .background(tint.copy(alpha = 0.10f))
            .border(0.5.dp, tint.copy(alpha = 0.18f), RoundedCornerShape(8.dp))
            .padding(horizontal = 6.dp, vertical = 2.dp)
    ) {
        Text(
            text = pace.humanLabel,
            fontSize = 9.sp,
            fontWeight = FontWeight.SemiBold,
            color = tint
        )
    }
}
