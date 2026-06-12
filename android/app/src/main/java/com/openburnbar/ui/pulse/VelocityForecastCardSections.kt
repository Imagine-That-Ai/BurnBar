// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.pulse

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.LocalFireDepartment
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.models.TokenUsage
import com.openburnbar.data.models.UsageRollups
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraType
import com.openburnbar.util.Formatting

internal fun computeVelocityForecastState(rollups: UsageRollups, liveUsages: List<TokenUsage>): VelocityForecastState {
    val calendar = java.util.Calendar.getInstance()
    val hour =
        calendar.get(java.util.Calendar.HOUR_OF_DAY) +
            calendar.get(java.util.Calendar.MINUTE) / 60.0
    val dayFraction = (hour / 24.0).coerceIn(0.001, 1.0)

    val startOfDayMillis =
        calendar.clone().let { cal ->
            check(cal is java.util.Calendar) { "Calendar.clone returned ${cal::class.java.name}" }
            cal.apply {
                set(java.util.Calendar.HOUR_OF_DAY, 0)
                set(java.util.Calendar.MINUTE, 0)
                set(java.util.Calendar.SECOND, 0)
                set(java.util.Calendar.MILLISECOND, 0)
            }.timeInMillis
        }
    val liveDayCost =
        liveUsages
            .filter { maxOf(it.startTime, it.endTime) >= startOfDayMillis }
            .sumOf { maxOf(0.0, it.effectiveCost) }
    val bestTodayCost = maxOf(rollups.today, liveDayCost)
    val projected = bestTodayCost / dayFraction
    val sevenDayAvg = rollups.sevenDays / 7.0
    val aheadOfPace = projected > sevenDayAvg
    return VelocityForecastState(dayFraction = dayFraction, projected = projected, aheadOfPace = aheadOfPace)
}

@Composable
internal fun VelocityForecastCardHeader(aheadOfPace: Boolean) {
    SectionHeaderRow(label = "End-of-Day Forecast")
    Spacer(Modifier.height(4.dp))
    Text(
        text = if (aheadOfPace) "Ahead of pace" else "On pace",
        style = AuroraType.body,
        color = MaterialTheme.colorScheme.onSurface,
    )
    Spacer(Modifier.height(AuroraSpacing.sm.dp))
    HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.35f))
    Spacer(Modifier.height(AuroraSpacing.md.dp))
}

@Composable
internal fun RowScope.VelocityForecastProjectedColumn(projected: Double, aheadOfPace: Boolean) {
    Column(modifier = Modifier.weight(1f)) {
        Text(
            text = "PROJECTED",
            fontSize = 11.sp,
            fontWeight = FontWeight.SemiBold,
            letterSpacing = 1.6.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(Modifier.height(4.dp))
        GradientCurrency(text = Formatting.formatCurrency(projected), fontSize = 36)
        Spacer(Modifier.height(6.dp))
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(
                imageVector = Icons.Filled.LocalFireDepartment,
                contentDescription = null,
                tint = AuroraColors.amber,
                modifier = Modifier.size(14.dp),
            )
            Spacer(Modifier.width(4.dp))
            Text(
                text = if (aheadOfPace) "Ahead of pace" else "On pace",
                fontSize = 13.sp,
                fontWeight = FontWeight.SemiBold,
                color = AuroraColors.amber,
            )
        }
    }
}

@Composable
internal fun VelocityForecastCardBody(state: VelocityForecastState) {
    VelocityForecastCardHeader(aheadOfPace = state.aheadOfPace)
    Row(verticalAlignment = Alignment.CenterVertically) {
        VelocityForecastProjectedColumn(projected = state.projected, aheadOfPace = state.aheadOfPace)
        Spacer(Modifier.width(AuroraSpacing.md.dp))
        MiniRing(
            progress = state.dayFraction.toFloat(),
            accent = AuroraColors.amber,
            label = "${(state.dayFraction * 100).toInt()}%",
            sublabel = "of day",
            size = 96.dp,
            strokeWidth = 8.dp,
        )
    }
}
