package com.openburnbar.ui.widget

import android.graphics.Bitmap
import android.graphics.BlurMaskFilter
import android.graphics.Canvas
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.Path
import android.graphics.Shader
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.GlanceModifier
import androidx.glance.Image
import androidx.glance.ImageProvider
import androidx.glance.appwidget.cornerRadius
import androidx.glance.background
import androidx.glance.color.ColorProvider
import androidx.glance.layout.Alignment
import androidx.glance.layout.Box
import androidx.glance.layout.Column
import androidx.glance.layout.ContentScale
import androidx.glance.layout.Row
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.fillMaxWidth
import androidx.glance.layout.height
import androidx.glance.layout.padding
import androidx.glance.layout.size
import androidx.glance.layout.width
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextStyle
import com.openburnbar.R
import com.openburnbar.data.models.AgentProvider
import com.openburnbar.data.models.logoRes
import kotlin.math.max
import kotlin.math.min
import androidx.glance.unit.ColorProvider as GlanceColorProvider

/**
 * Glance composables and Bitmap helpers used across all five widget surfaces.
 * Kept light: each tries to render in <16dp of cumulative padding so even the
 * smallest 2×2 home-screen tile has room for content.
 */

@androidx.compose.runtime.Composable
fun WidgetProviderPill(
    name: String,
    tokens: Long?
) {
    val provider = AgentProvider.fromKey(name) ?: AgentProvider.fromKey(name.lowercase())
    val color = provider?.let { Color(it.brandColor) } ?: WidgetTheme.ember
    val tokenLabel = tokens?.let { formatTokensCompact(it) }
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = GlanceModifier
            .background(GlanceColorProvider(color.copy(alpha = 0.14f)))
            .cornerRadius(10.dp)
            .padding(horizontal = 8.dp, vertical = 3.dp)
    ) {
        if (provider != null) {
            Image(
                provider = ImageProvider(provider.logoRes),
                contentDescription = null,
                modifier = GlanceModifier.size(12.dp),
                contentScale = ContentScale.Fit
            )
            Spacer(modifier = GlanceModifier.width(4.dp))
        }
        Text(
            text = provider?.displayName ?: name,
            style = TextStyle(
                fontSize = 11.sp,
                fontWeight = FontWeight.Medium,
                color = GlanceColorProvider(color)
            ),
            maxLines = 1
        )
        if (tokenLabel != null) {
            Spacer(modifier = GlanceModifier.width(4.dp))
            Text(
                text = "· $tokenLabel",
                style = TextStyle(
                    fontSize = 10.sp,
                    color = GlanceColorProvider(color.copy(alpha = 0.78f))
                ),
                maxLines = 1
            )
        }
    }
}

@androidx.compose.runtime.Composable
fun WidgetMetricBadge(
    label: String,
    value: String
) {
    Column(
        modifier = GlanceModifier
            .background(GlanceColorProvider(Color.White.copy(alpha = 0.08f)))
            .cornerRadius(8.dp)
            .padding(horizontal = 8.dp, vertical = 4.dp)
    ) {
        Text(
            text = value,
            style = TextStyle(
                fontSize = 13.sp,
                fontWeight = FontWeight.Bold,
                color = WidgetTheme.text
            ),
            maxLines = 1
        )
        Text(
            text = label.uppercase(),
            style = TextStyle(
                fontSize = 9.sp,
                fontWeight = FontWeight.Medium,
                color = WidgetTheme.textFaint
            ),
            maxLines = 1
        )
    }
}

@androidx.compose.runtime.Composable
fun WidgetModelChip(model: String) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = GlanceModifier
            .background(GlanceColorProvider(WidgetTheme.amber.copy(alpha = 0.14f)))
            .cornerRadius(9.dp)
            .padding(horizontal = 6.dp, vertical = 2.dp)
    ) {
        Text(
            text = model,
            style = TextStyle(
                fontSize = 10.sp,
                fontWeight = FontWeight.Medium,
                color = GlanceColorProvider(WidgetTheme.amber)
            ),
            maxLines = 1
        )
    }
}

/**
 * Glance can't draw a true bar via composables — but a Box with a colored
 * width fraction inside a track works at small sizes. Width is computed in
 * pixels using the [trackWidthDp] parameter so we don't depend on host-side
 * fractional sizing (Glance's modifier system is more limited than Compose's).
 */
@androidx.compose.runtime.Composable
fun WidgetProgressBar(
    progress: Float,
    accent: Color,
    trackWidthDp: Int = 140
) {
    val clamped = progress.coerceIn(0f, 1f)
    val filledDp = (trackWidthDp * clamped).toInt().coerceAtLeast(2)
    Box(
        modifier = GlanceModifier
            .width(trackWidthDp.dp)
            .height(6.dp)
            .background(GlanceColorProvider(accent.copy(alpha = 0.18f)))
            .cornerRadius(3.dp)
    ) {
        Box(
            modifier = GlanceModifier
                .width(filledDp.dp)
                .height(6.dp)
                .background(GlanceColorProvider(accent))
                .cornerRadius(3.dp)
        ) {}
    }
}

// ── Sparkline as a Bitmap (Glance can render Bitmaps via ImageProvider) ──

/**
 * Render a smooth sparkline (Catmull-Rom interpolation, gradient fill +
 * accent stroke) into an off-screen Bitmap so Glance can show it via
 * `ImageProvider(bitmap)`. Matches the look of `AuroraSparkline` from the
 * in-app dashboard, just baked to pixels.
 */
fun renderSparklineBitmap(
    values: List<Double>,
    widthPx: Int,
    heightPx: Int,
    accent: Color = WidgetTheme.amber,
    fillAlpha: Float = 0.30f
): Bitmap {
    val bitmap = Bitmap.createBitmap(max(widthPx, 8), max(heightPx, 8), Bitmap.Config.ARGB_8888)
    val canvas = Canvas(bitmap)
    if (values.size < 2) return bitmap

    val padding = 4f
    val plotW = bitmap.width - padding * 2
    val plotH = bitmap.height - padding * 2
    val minV = values.min().coerceAtMost(0.0)
    val maxV = values.max()
    val range = (maxV - minV).coerceAtLeast(0.0001)
    val stepX = plotW / (values.size - 1)

    val points = values.mapIndexed { i, v ->
        val x = padding + i * stepX
        val normalized = ((v - minV) / range).toFloat().coerceIn(0f, 1f)
        val y = padding + plotH - normalized * plotH
        x to y
    }

    val linePath = Path().apply {
        moveTo(points.first().first, points.first().second)
        appendCatmullRom(this, points)
    }

    val fillPath = Path(linePath).apply {
        lineTo(points.last().first, padding + plotH)
        lineTo(points.first().first, padding + plotH)
        close()
    }

    val accentArgb = accent.toArgb()
    val transparentArgb = accent.copy(alpha = 0f).toArgb()
    val fillPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        shader = LinearGradient(
            0f, padding,
            0f, padding + plotH,
            accent.copy(alpha = fillAlpha).toArgb(),
            transparentArgb,
            Shader.TileMode.CLAMP
        )
        style = Paint.Style.FILL
    }
    canvas.drawPath(fillPath, fillPaint)

    val strokePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = accentArgb
        style = Paint.Style.STROKE
        strokeWidth = 2f
        strokeCap = Paint.Cap.ROUND
        strokeJoin = Paint.Join.ROUND
    }
    canvas.drawPath(linePath, strokePaint)

    return bitmap
}

private fun appendCatmullRom(path: Path, points: List<Pair<Float, Float>>) {
    for (i in 0 until points.size - 1) {
        val p0 = points.getOrNull(i - 1) ?: points[i]
        val p1 = points[i]
        val p2 = points[i + 1]
        val p3 = points.getOrNull(i + 2) ?: points[i + 1]
        val cp1x = p1.first + (p2.first - p0.first) / 6f
        val cp1y = p1.second + (p2.second - p0.second) / 6f
        val cp2x = p2.first - (p3.first - p1.first) / 6f
        val cp2y = p2.second - (p3.second - p1.second) / 6f
        path.cubicTo(cp1x, cp1y, cp2x, cp2y, p2.first, p2.second)
    }
}

/**
 * Render a progress ring into a Bitmap for the lock-screen circular widget.
 */
fun renderRingBitmap(
    progress: Float,
    sizePx: Int,
    accent: Color = WidgetTheme.ember,
    strokeWidthPx: Float = 6f
): Bitmap {
    val bitmap = Bitmap.createBitmap(max(sizePx, 16), max(sizePx, 16), Bitmap.Config.ARGB_8888)
    val canvas = Canvas(bitmap)
    val pad = strokeWidthPx
    val rect = android.graphics.RectF(pad, pad, bitmap.width - pad, bitmap.height - pad)

    val trackPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = accent.copy(alpha = 0.18f).toArgb()
        style = Paint.Style.STROKE
        strokeWidth = strokeWidthPx
        strokeCap = Paint.Cap.ROUND
    }
    canvas.drawArc(rect, 0f, 360f, false, trackPaint)

    val arcPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = accent.toArgb()
        style = Paint.Style.STROKE
        strokeWidth = strokeWidthPx
        strokeCap = Paint.Cap.ROUND
    }
    val sweep = 360f * progress.coerceIn(0f, 1f)
    canvas.drawArc(rect, -90f, sweep, false, arcPaint)
    return bitmap
}

// ── Formatting helpers ──────────────────────────────────────────────────────

fun formatCost(value: Double): String =
    if (value >= 100) "$${"%.0f".format(value)}" else "$${"%.2f".format(value)}"

fun formatCostCompact(value: Double): String = when {
    value >= 1_000_000 -> "$${"%.1fM".format(value / 1_000_000)}"
    value >= 1_000    -> "$${"%.1fk".format(value / 1_000)}"
    value >= 100      -> "$${"%.0f".format(value)}"
    else              -> "$${"%.2f".format(value)}"
}

fun formatTokensCompact(n: Long): String = when {
    n >= 1_000_000_000 -> "%.1fB".format(n / 1_000_000_000.0)
    n >= 1_000_000     -> "%.1fM".format(n / 1_000_000.0)
    n >= 1_000         -> "%.1fK".format(n / 1_000.0)
    else               -> n.toString()
}
