package com.openburnbar.ui.pulse

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowDownward
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material.icons.filled.LocalFireDepartment
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraType

/**
 * Visual primitives that mirror the iOS Pulse screen. Centralized here so the
 * BurnHeroCard / EndOfDayCard / QuotaCard / TrendAtlasCard can share the same
 * small section header, gradient currency text, delta badge, and mini ring.
 */

/** Standard `BURN` / `QUOTA` / `END-OF-DAY FORECAST` style header — ember dot + uppercase label, optional trailing slot. */
@Composable
fun SectionHeaderRow(
    label: String,
    modifier: Modifier = Modifier,
    trailing: (@Composable () -> Unit)? = null
) {
    Row(
        modifier = modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Box(
            modifier = Modifier
                .size(6.dp)
                .clip(CircleShape)
                .background(AuroraColors.ember)
        )
        Spacer(Modifier.width(8.dp))
        Text(
            text = label.uppercase(),
            fontSize = 11.sp,
            fontWeight = FontWeight.SemiBold,
            letterSpacing = 1.6.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.weight(1f)
        )
        trailing?.invoke()
    }
}

/** Gradient currency / metric headline — `$379.98` rendered red→amber→ember. */
@Composable
fun GradientCurrency(
    text: String,
    modifier: Modifier = Modifier,
    fontSize: Int = 56
) {
    Text(
        text = text,
        modifier = modifier,
        style = TextStyle(
            brush = Brush.linearGradient(
                colors = listOf(
                    AuroraColors.ember,
                    AuroraColors.amber,
                    AuroraColors.blaze
                )
            ),
            fontSize = fontSize.sp,
            fontWeight = FontWeight.Bold,
            letterSpacing = (-0.5).sp
        ),
        maxLines = 1,
        softWrap = false,
        overflow = TextOverflow.Ellipsis
    )
}

/** Small inline metric label like `1.53B tokens · 152 requests`. */
@Composable
fun MetaRow(text: String, modifier: Modifier = Modifier) {
    Text(
        text = text,
        modifier = modifier,
        style = AuroraType.body,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        maxLines = 1,
        overflow = TextOverflow.Ellipsis
    )
}

/** Capsule delta pill — green for "Below average", amber for "Ahead". */
@Composable
fun DeltaBadge(
    percent: Double,
    isBelow: Boolean,
    modifier: Modifier = Modifier
) {
    val color = if (isBelow) AuroraColors.successDark else AuroraColors.amber
    Surface(
        modifier = modifier,
        shape = CircleShape,
        color = color.copy(alpha = 0.16f),
        border = BorderStroke(0.5.dp, color.copy(alpha = 0.45f))
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 10.dp, vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(4.dp)
        ) {
            Icon(
                imageVector = if (isBelow) Icons.Filled.ArrowDownward else Icons.Filled.ArrowUpward,
                contentDescription = null,
                tint = color,
                modifier = Modifier.size(12.dp)
            )
            Text(
                text = "%.1f%%".format(percent),
                fontSize = 12.sp,
                fontWeight = FontWeight.SemiBold,
                color = color
            )
        }
    }
}

/** Live-stream marker — `🔥 Streaming live from your Mac` */
@Composable
fun StreamingLine(modifier: Modifier = Modifier) {
    Row(
        modifier = modifier,
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp)
    ) {
        Icon(
            imageVector = Icons.Filled.LocalFireDepartment,
            contentDescription = null,
            tint = AuroraColors.amber,
            modifier = Modifier.size(14.dp)
        )
        Text(
            text = "Streaming live from your Mac",
            style = AuroraType.caption,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
    }
}

/** Green comparison line — `↘ Below 34% your 7-day average` */
@Composable
fun ComparisonLine(
    text: String,
    isBelow: Boolean,
    modifier: Modifier = Modifier
) {
    val color = if (isBelow) AuroraColors.successDark else AuroraColors.amber
    Row(
        modifier = modifier,
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp)
    ) {
        Icon(
            imageVector = if (isBelow) Icons.Filled.ArrowDownward else Icons.Filled.ArrowUpward,
            contentDescription = null,
            tint = color,
            modifier = Modifier.size(13.dp)
        )
        Text(
            text = text,
            fontSize = 13.sp,
            fontWeight = FontWeight.SemiBold,
            color = color
        )
    }
}

/** Compact ring chart — gradient stroke arc + percentage in center. Used for the "of day" forecast ring. */
@Composable
fun MiniRing(
    progress: Float,
    accent: Color,
    label: String,
    sublabel: String,
    size: Dp = 96.dp,
    strokeWidth: Dp = 8.dp,
    modifier: Modifier = Modifier
) {
    Box(modifier = modifier.size(size), contentAlignment = Alignment.Center) {
        Canvas(modifier = Modifier.fillMaxSize()) {
            val sw = strokeWidth.toPx()
            val arcSize = Size(this.size.width - sw, this.size.height - sw)
            val topLeft = Offset(sw / 2f, sw / 2f)
            // Track
            drawArc(
                color = accent.copy(alpha = 0.18f),
                startAngle = 0f,
                sweepAngle = 360f,
                useCenter = false,
                size = arcSize,
                topLeft = topLeft,
                style = Stroke(width = sw, cap = StrokeCap.Round)
            )
            // Progress
            val sweep = progress.coerceIn(0f, 1f) * 360f
            if (sweep > 0f) {
                drawArc(
                    brush = Brush.sweepGradient(
                        colors = listOf(
                            accent.copy(alpha = 0.6f),
                            accent,
                            accent.copy(alpha = 0.8f)
                        ),
                        center = Offset(this.size.width / 2f, this.size.height / 2f)
                    ),
                    startAngle = -90f,
                    sweepAngle = sweep,
                    useCenter = false,
                    size = arcSize,
                    topLeft = topLeft,
                    style = Stroke(width = sw, cap = StrokeCap.Round)
                )
            }
        }
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Text(
                text = label,
                fontSize = 20.sp,
                fontWeight = FontWeight.Bold,
                color = MaterialTheme.colorScheme.onSurface
            )
            Text(
                text = sublabel,
                fontSize = 10.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
    }
}

/** Larger ring with a flame icon at the center — the Quota card hero ring. */
@Composable
fun FlameRing(
    progress: Float,
    accent: Color,
    size: Dp = 96.dp,
    strokeWidth: Dp = 8.dp,
    modifier: Modifier = Modifier
) {
    Box(modifier = modifier.size(size), contentAlignment = Alignment.Center) {
        Canvas(modifier = Modifier.fillMaxSize()) {
            val sw = strokeWidth.toPx()
            val arcSize = Size(this.size.width - sw, this.size.height - sw)
            val topLeft = Offset(sw / 2f, sw / 2f)
            drawArc(
                color = accent.copy(alpha = 0.20f),
                startAngle = 0f,
                sweepAngle = 360f,
                useCenter = false,
                size = arcSize,
                topLeft = topLeft,
                style = Stroke(width = sw, cap = StrokeCap.Round)
            )
            val sweep = progress.coerceIn(0f, 1f) * 360f
            if (sweep > 0f) {
                drawArc(
                    brush = Brush.sweepGradient(
                        colors = listOf(
                            accent.copy(alpha = 0.55f),
                            accent,
                            accent.copy(alpha = 0.75f)
                        ),
                        center = Offset(this.size.width / 2f, this.size.height / 2f)
                    ),
                    startAngle = -90f,
                    sweepAngle = sweep,
                    useCenter = false,
                    size = arcSize,
                    topLeft = topLeft,
                    style = Stroke(width = sw, cap = StrokeCap.Round)
                )
            }
        }
        Icon(
            imageVector = Icons.Filled.LocalFireDepartment,
            contentDescription = null,
            tint = accent,
            modifier = Modifier.size(size * 0.35f)
        )
    }
}
