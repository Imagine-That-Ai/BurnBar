package com.openburnbar.ui.recap

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.automirrored.filled.TrendingDown
import androidx.compose.material.icons.automirrored.filled.TrendingUp
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.EmojiEvents
import androidx.compose.material.icons.filled.Share
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.recap.RecapCard
import com.openburnbar.data.recap.RecapComparison
import com.openburnbar.data.recap.RecapRankedEntry
import com.openburnbar.data.recap.RecapRuleSupport
import com.openburnbar.ui.theme.AuroraColors
import java.util.Locale
import kotlin.math.max

// ── Shared Card Surface / Chrome ──

@Composable
fun RecapCardChrome(card: RecapCard, modifier: Modifier = Modifier, onShare: ((RecapCard) -> Unit)? = null, content: @Composable () -> Unit) {
    val accent = RecapTheme.accentFor(card)
    val isProminent = card.size == com.openburnbar.data.recap.RecapCardSize.HERO ||
        card.size == com.openburnbar.data.recap.RecapCardSize.FULL_BLEED
    val cornerRadius = if (isProminent) RecapTheme.Layout.heroCornerRadius else RecapTheme.Layout.cardCornerRadius
    val padding = if (isProminent) RecapTheme.Layout.heroPadding else RecapTheme.Layout.cardPadding

    Box(
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(cornerRadius))
            .background(RecapTheme.wash(accent))
            .border(
                width = 1.dp,
                color = accent.copy(alpha = if (isProminent) 0.35f else 0.18f),
                shape = RoundedCornerShape(cornerRadius),
            )
            .padding(padding),
    ) {
        content()

        if (onShare != null && card.isShareable) {
            IconButton(
                onClick = { onShare(card) },
                modifier = Modifier
                    .align(Alignment.TopEnd)
                    .size(32.dp)
                    .clip(CircleShape)
                    .background(Color.Black.copy(alpha = 0.2f)),
            ) {
                Icon(
                    imageVector = Icons.Default.Share,
                    contentDescription = "Share card",
                    tint = AuroraColors.lightTextSecondary,
                    modifier = Modifier.size(16.dp),
                )
            }
        }
    }
}

// ── Eyebrow ──

@Composable
fun RecapEyebrow(text: String, accent: Color, modifier: Modifier = Modifier) {
    Text(
        text = text.uppercase(Locale.getDefault()),
        style = RecapTheme.Typography.eyebrow,
        color = accent.copy(alpha = 0.9f),
        modifier = modifier,
    )
}

// ── Copy ──

@Composable
fun RecapCopy(
    headline: String,
    message: String,
    modifier: Modifier = Modifier,
    headlineStyle: androidx.compose.ui.text.TextStyle = RecapTheme.Typography.cardHeadline,
) {
    Column(modifier = modifier) {
        Text(
            text = headline,
            style = headlineStyle,
            color = AuroraColors.lightTextPrimary,
        )
        if (message.isNotEmpty()) {
            Spacer(modifier = Modifier.height(4.dp))
            Text(
                text = message,
                style = RecapTheme.Typography.cardBody,
                color = AuroraColors.lightTextSecondary,
            )
        }
    }
}

// ── Delta Chip ──

@Composable
fun RecapDeltaChip(comparison: RecapComparison, modifier: Modifier = Modifier) {
    val tint = when (comparison.basis) {
        RecapComparison.Basis.FIRST_EVER -> AuroraColors.whimsy
        RecapComparison.Basis.ALL_TIME_RECORD -> AuroraColors.amber
        else -> if (comparison.isIncrease) AuroraColors.ember else AuroraColors.success
    }

    val labelText = when (comparison.basis) {
        RecapComparison.Basis.FIRST_EVER -> "First time"
        RecapComparison.Basis.UNIFORM -> "vs even week"
        RecapComparison.Basis.ALL_TIME_RECORD -> "Past ${comparison.referenceLabel}"
        else -> {
            val delta = comparison.deltaFraction
            if (delta != null) {
                "${RecapRuleSupport.deltaPhrase(delta)} vs ${comparison.referenceLabel}"
            } else {
                "vs ${comparison.referenceLabel}"
            }
        }
    }

    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
        modifier = modifier
            .clip(CircleShape)
            .background(tint.copy(alpha = 0.14f))
            .padding(horizontal = 8.dp, vertical = 4.dp),
    ) {
        RecapDeltaChipIcon(comparison, tint)
        Text(
            text = labelText,
            style = RecapTheme.Typography.eyebrow.copy(fontSize = 10.sp, letterSpacing = 0.5.sp),
            color = tint,
        )
    }
}

@Composable
private fun RecapDeltaChipIcon(comparison: RecapComparison, tint: Color) {
    when (comparison.basis) {
        RecapComparison.Basis.FIRST_EVER -> {
            Icon(
                imageVector = Icons.Default.AutoAwesome,
                contentDescription = null,
                tint = tint,
                modifier = Modifier.size(11.dp),
            )
        }
        RecapComparison.Basis.ALL_TIME_RECORD -> {
            Icon(
                imageVector = Icons.Default.EmojiEvents,
                contentDescription = null,
                tint = tint,
                modifier = Modifier.size(11.dp),
            )
        }
        else -> {
            val delta = comparison.deltaFraction
            if (delta != null && kotlin.math.abs(delta) >= 0.02) {
                Icon(
                    imageVector = if (delta > 0) Icons.AutoMirrored.Filled.TrendingUp else Icons.AutoMirrored.Filled.TrendingDown,
                    contentDescription = null,
                    tint = tint,
                    modifier = Modifier.size(11.dp),
                )
            }
        }
    }
}

// ── Sparkline ──

@Composable
fun RecapSparkline(values: List<Double>, accent: Color, modifier: Modifier = Modifier) {
    if (values.isEmpty()) return

    Canvas(modifier = modifier.fillMaxWidth().height(60.dp)) {
        val width = size.width
        val height = size.height
        val maxVal = values.maxOrNull()?.takeIf { it > 0.0 } ?: 1.0

        val stepX = if (values.size > 1) width / (values.size - 1) else width
        val path = Path()
        val fillPath = Path()

        values.forEachIndexed { index, v ->
            val x = index * stepX
            val y = height - (v / maxVal * (height - 8f)).toFloat() - 4f
            if (index == 0) {
                path.moveTo(x, y)
                fillPath.moveTo(x, height)
                fillPath.lineTo(x, y)
            } else {
                val prevX = (index - 1) * stepX
                val prevY = height - (values[index - 1] / maxVal * (height - 8f)).toFloat() - 4f
                val cx1 = prevX + (x - prevX) / 2f
                val cx2 = cx1
                path.cubicTo(cx1, prevY, cx2, y, x, y)
                fillPath.cubicTo(cx1, prevY, cx2, y, x, y)
            }
        }
        fillPath.lineTo(width, height)
        fillPath.close()

        drawPath(
            path = fillPath,
            brush = Brush.verticalGradient(
                colors = listOf(accent.copy(alpha = 0.32f), accent.copy(alpha = 0.02f)),
            ),
        )
        drawPath(
            path = path,
            color = accent,
            style = Stroke(width = 2.5f, cap = StrokeCap.Round),
        )
    }
}

// ── Dual Sparkline ──

@Composable
fun RecapDualSparkline(current: List<Double>, reference: List<Double>, accent: Color, modifier: Modifier = Modifier) {
    Canvas(modifier = modifier.fillMaxWidth().height(60.dp)) {
        val width = size.width
        val height = size.height
        val maxVal = max(
            current.maxOrNull() ?: 1.0,
            reference.maxOrNull() ?: 1.0,
        ).coerceAtLeast(1.0)

        fun drawSeries(values: List<Double>, color: Color, strokeWidth: Float, isDashed: Boolean) {
            if (values.isEmpty()) return
            val stepX = if (values.size > 1) width / (values.size - 1) else width
            val path = Path()
            values.forEachIndexed { index, v ->
                val x = index * stepX
                val y = height - (v / maxVal * (height - 8f)).toFloat() - 4f
                if (index == 0) {
                    path.moveTo(x, y)
                } else {
                    val prevX = (index - 1) * stepX
                    val prevY = height - (values[index - 1] / maxVal * (height - 8f)).toFloat() - 4f
                    val cx1 = prevX + (x - prevX) / 2f
                    val cx2 = cx1
                    path.cubicTo(cx1, prevY, cx2, y, x, y)
                }
            }
            drawPath(
                path = path,
                color = color,
                style = Stroke(
                    width = strokeWidth,
                    cap = StrokeCap.Round,
                    pathEffect = if (isDashed) PathEffect.dashPathEffect(floatArrayOf(8f, 8f), 0f) else null,
                ),
            )
        }

        drawSeries(reference, AuroraColors.lightTextMuted.copy(alpha = 0.55f), 1.5f, isDashed = true)
        drawSeries(current, accent, 2.5f, isDashed = false)
    }
}

// ── Ranked Bars ──

@Composable
fun RecapRankedBars(entries: List<RecapRankedEntry>, accent: Color, modifier: Modifier = Modifier) {
    Column(
        verticalArrangement = Arrangement.spacedBy(8.dp),
        modifier = modifier.fillMaxWidth(),
    ) {
        entries.forEach { entry ->
            val tint = entry.colorSeed?.let { RecapTheme.colorForModelSeed(it) } ?: accent
            Column(modifier = Modifier.fillMaxWidth()) {
                Text(
                    text = entry.label,
                    style = RecapTheme.Typography.caption,
                    color = AuroraColors.lightTextPrimary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Spacer(modifier = Modifier.height(4.dp))
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(6.dp)
                        .clip(CircleShape)
                        .background(AuroraColors.lightTextMuted.copy(alpha = 0.12f)),
                ) {
                    Box(
                        modifier = Modifier
                            .fillMaxWidth(entry.fraction.toFloat().coerceIn(0.04f, 1f))
                            .fillMaxHeight()
                            .clip(CircleShape)
                            .background(tint.copy(alpha = 0.85f)),
                    )
                }
            }
        }
    }
}

// ── Donut Chart ──

@Composable
fun RecapDonut(entries: List<RecapRankedEntry>, accent: Color, modifier: Modifier = Modifier) {
    if (entries.isEmpty()) return

    val total = entries.sumOf { it.value }.coerceAtLeast(0.001)

    Canvas(modifier = modifier.size(100.dp)) {
        val strokeWidth = 14.dp.toPx()
        val diameter = minOf(size.width, size.height) - strokeWidth
        val topLeft = Offset((size.width - diameter) / 2f, (size.height - diameter) / 2f)
        val arcSize = Size(diameter, diameter)

        var startAngle = -90f
        entries.forEach { entry ->
            val sweepAngle = (entry.value / total * 360f).toFloat()
            val tint = entry.colorSeed?.let { RecapTheme.colorForModelSeed(it) } ?: accent

            drawArc(
                color = tint,
                startAngle = startAngle,
                sweepAngle = sweepAngle - 2f,
                useCenter = false,
                topLeft = topLeft,
                size = arcSize,
                style = Stroke(width = strokeWidth, cap = StrokeCap.Round),
            )
            startAngle += sweepAngle
        }
    }
}

// ── Heatmap (7x24 grid) ──

@Composable
fun RecapHeatmap(matrix: List<List<Double>>, accent: Color, modifier: Modifier = Modifier) {
    if (matrix.isEmpty()) return

    val peak = matrix.flatMap { it }.maxOrNull()?.takeIf { it > 0.0 } ?: 1.0

    Column(
        verticalArrangement = Arrangement.spacedBy(2.dp),
        modifier = modifier.fillMaxWidth(),
    ) {
        matrix.forEach { row ->
            Row(
                horizontalArrangement = Arrangement.spacedBy(2.dp),
                modifier = Modifier.fillMaxWidth(),
            ) {
                row.forEach { value ->
                    val alpha = if (peak > 0.0) (0.08f + 0.82f * (value / peak).toFloat()).coerceIn(0.08f, 0.9f) else 0.08f
                    Box(
                        modifier = Modifier
                            .weight(1f)
                            .height(8.dp)
                            .clip(RoundedCornerShape(2.dp))
                            .background(accent.copy(alpha = alpha)),
                    )
                }
            }
        }
    }
}

// ── Progress Ring ──

@Composable
fun RecapRing(progress: Double, caption: String, accent: Color, modifier: Modifier = Modifier) {
    Box(
        contentAlignment = Alignment.Center,
        modifier = modifier.size(68.dp),
    ) {
        Canvas(modifier = Modifier.fillMaxSize()) {
            val strokeWidth = 8.dp.toPx()
            val diameter = minOf(size.width, size.height) - strokeWidth
            val topLeft = Offset((size.width - diameter) / 2f, (size.height - diameter) / 2f)
            val arcSize = Size(diameter, diameter)

            drawArc(
                color = accent.copy(alpha = 0.16f),
                startAngle = 0f,
                sweepAngle = 360f,
                useCenter = false,
                topLeft = topLeft,
                size = arcSize,
                style = Stroke(width = strokeWidth),
            )

            val sweepAngle = (progress.coerceIn(0.001, 1.0) * 360f).toFloat()
            drawArc(
                brush = RecapTheme.numeralFill(accent),
                startAngle = -90f,
                sweepAngle = sweepAngle,
                useCenter = false,
                topLeft = topLeft,
                size = arcSize,
                style = Stroke(width = strokeWidth, cap = StrokeCap.Round),
            )
        }
        Text(
            text = caption,
            style = RecapTheme.Typography.caption.copy(fontWeight = FontWeight.Bold),
            color = AuroraColors.lightTextPrimary,
        )
    }
}

// ── Streak Dots (7 across) ──

@Composable
fun RecapStreakDots(flags: List<Boolean>, accent: Color, modifier: Modifier = Modifier) {
    val rows = flags.chunked(7)
    Column(
        verticalArrangement = Arrangement.spacedBy(4.dp),
        modifier = modifier.fillMaxWidth(),
    ) {
        rows.forEach { row ->
            Row(
                horizontalArrangement = Arrangement.spacedBy(4.dp),
                modifier = Modifier.fillMaxWidth(),
            ) {
                row.forEach { active ->
                    Box(
                        modifier = Modifier
                            .weight(1f)
                            .aspectRatio(1f)
                            .clip(RoundedCornerShape(3.dp))
                            .background(if (active) accent.copy(alpha = 0.9f) else accent.copy(alpha = 0.10f)),
                    )
                }
                // Pad incomplete weeks
                if (row.size < 7) {
                    repeat(7 - row.size) {
                        Spacer(modifier = Modifier.weight(1f))
                    }
                }
            }
        }
    }
}

// ── Before / After Comparative Bars ──

@Composable
fun RecapBeforeAfter(before: Double, after: Double, accent: Color, modifier: Modifier = Modifier) {
    val peak = max(before, after).coerceAtLeast(0.001)
    val beforePct = (before / peak).toFloat().coerceIn(0.1f, 1f)
    val afterPct = (after / peak).toFloat().coerceIn(0.1f, 1f)

    Row(
        verticalAlignment = Alignment.Bottom,
        horizontalArrangement = Arrangement.spacedBy(16.dp),
        modifier = modifier.height(80.dp),
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Bottom,
            modifier = Modifier.fillMaxHeight(),
        ) {
            Box(
                modifier = Modifier
                    .width(32.dp)
                    .height((60 * beforePct).dp)
                    .clip(RoundedCornerShape(6.dp))
                    .background(AuroraColors.lightTextMuted.copy(alpha = 0.45f)),
            )
            Spacer(modifier = Modifier.height(4.dp))
            Text(
                text = "${(before * 100).toInt()}%",
                style = RecapTheme.Typography.caption,
                color = AuroraColors.lightTextSecondary,
            )
        }

        Icon(
            imageVector = Icons.AutoMirrored.Filled.ArrowForward,
            contentDescription = null,
            tint = AuroraColors.lightTextMuted,
            modifier = Modifier.padding(bottom = 20.dp).size(16.dp),
        )

        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Bottom,
            modifier = Modifier.fillMaxHeight(),
        ) {
            Box(
                modifier = Modifier
                    .width(32.dp)
                    .height((60 * afterPct).dp)
                    .clip(RoundedCornerShape(6.dp))
                    .background(accent),
            )
            Spacer(modifier = Modifier.height(4.dp))
            Text(
                text = "${(after * 100).toInt()}%",
                style = RecapTheme.Typography.caption,
                color = AuroraColors.lightTextPrimary,
            )
        }
    }
}
