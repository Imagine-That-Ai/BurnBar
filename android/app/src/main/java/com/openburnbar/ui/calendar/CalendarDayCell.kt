// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.calendar

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.RoundRect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.models.AgentProvider
import kotlin.math.sqrt
import com.openburnbar.ui.theme.AuroraColors
import java.time.LocalDate

/**
 * One month-grid day cell. The heatmap intensity fill (ember wash scaled to
 * the visible month's peak day cost), selection ring, today outline, and the
 * up-to-3 provider dots are all drawn in a single Canvas; the day number is a
 * Text overlay so it stays crisp and accessible. Gesture handling lives on
 * the parent grid (tap + long-press-drag are resolved from grid coordinates),
 * so the cell itself is purely presentational.
 */
@Composable
fun CalendarDayCell(
    day: LocalDate,
    isCurrentMonth: Boolean,
    isToday: Boolean,
    isSelected: Boolean,
    /** 0..1 heatmap intensity (day cost ÷ month peak day cost). */
    heat: Float,
    /** Up to 3 providers, ranked by the day's cost. */
    providers: List<AgentProvider>,
    modifier: Modifier = Modifier,
) {
    val onSurface = MaterialTheme.colorScheme.onSurface
    Box(modifier = modifier.aspectRatio(1f)) {
        Canvas(modifier = Modifier.fillMaxSize().padding(2.dp)) {
            val w = size.width
            val h = size.height
            val corner = CornerRadius(w * 0.22f)
            val cellPath = Path().apply { addRoundRect(RoundRect(Rect(Offset.Zero, size), corner)) }

            // Heatmap fill — ember wash whose alpha tracks the day's intensity.
            // A faint floor keeps "any usage" days visible next to peak days.
            // sqrt matches CalendarDayCell.fillColor on macOS: it lifts the
            // mid-range so one monster day cannot wash the rest of the month out.
            if (heat > 0f) {
                val alpha = MIN_HEAT_ALPHA +
                    (MAX_HEAT_ALPHA - MIN_HEAT_ALPHA) * sqrt(heat.coerceIn(0f, 1f))
                drawPath(path = cellPath, color = AuroraColors.ember.copy(alpha = alpha * if (isCurrentMonth) 1f else 0.45f))
            }

            // Selection ring — filled wash + solid stroke.
            if (isSelected) {
                drawPath(path = cellPath, color = AuroraColors.ember.copy(alpha = 0.22f))
                drawPath(path = cellPath, color = AuroraColors.ember, style = Stroke(width = w * 0.045f))
            } else if (isToday) {
                drawPath(
                    path = cellPath,
                    color = onSurface.copy(alpha = 0.55f),
                    style = Stroke(width = w * 0.03f),
                )
            } else {
                drawPath(
                    path = cellPath,
                    color = onSurface.copy(alpha = 0.08f),
                    style = Stroke(width = w * 0.015f),
                )
            }

            // Provider dots — bottom edge, up to 3, ranked by the day's cost.
            val dotProviders = providers.take(MAX_PROVIDER_DOTS)
            if (dotProviders.isNotEmpty()) {
                val dotRadius = w * 0.05f
                val spacing = dotRadius * 2.6f
                val rowWidth = spacing * (dotProviders.size - 1)
                val startX = (w - rowWidth) / 2f
                val cy = h - dotRadius * 2.2f
                dotProviders.forEachIndexed { index, provider ->
                    drawCircle(
                        color = Color(provider.brandColor),
                        radius = dotRadius,
                        center = Offset(startX + index * spacing, cy),
                    )
                }
            }
        }
        Text(
            text = day.dayOfMonth.toString(),
            modifier = Modifier.align(Alignment.Center).padding(bottom = 6.dp),
            color =
            when {
                !isCurrentMonth -> onSurface.copy(alpha = 0.32f)
                isSelected -> onSurface
                else -> onSurface.copy(alpha = 0.85f)
            },
            fontSize = 12.sp,
            fontWeight = if (isSelected || isToday) FontWeight.Bold else FontWeight.Normal,
        )
    }
}

private const val MIN_HEAT_ALPHA = 0.10f
private const val MAX_HEAT_ALPHA = 0.65f
private const val MAX_PROVIDER_DOTS = 3
