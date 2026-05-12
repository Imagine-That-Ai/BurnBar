package com.openburnbar.ui.pulse

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.models.UsageDisplayMode
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraTypography

enum class PulseTimelineScope(
    val label: String,
    val headerLabel: String,
    val rollupKey: String,
    val trailingKey: String
) {
    MINUTE("1M", "LIVE · MINUTE", "today", "today"),
    HOUR("1H", "LAST HOUR · LIVE", "today", "today"),
    DAY("1D", "TODAY · LIVE", "today", "7d"),
    WEEK("7D", "7 DAYS", "7d", "30d"),
    MONTH("30D", "30 DAYS", "30d", "90d");
}

@Composable
fun TimelineScopePicker(
    selected: PulseTimelineScope,
    onSelect: (PulseTimelineScope) -> Unit,
    modifier: Modifier = Modifier
) {
    Box(
        modifier = modifier
            .clip(CircleShape)
            .background(MaterialTheme.colorScheme.surface.copy(alpha = 0.55f))
            .padding(3.dp)
    ) {
        Row(horizontalArrangement = Arrangement.spacedBy(0.dp)) {
            PulseTimelineScope.entries.forEach { scope ->
                val isSelected = scope == selected
                Box(
                    modifier = Modifier
                        .clip(CircleShape)
                        .background(
                            if (isSelected) {
                                androidx.compose.ui.graphics.Brush.horizontalGradient(
                                    listOf(AuroraColors.ember, AuroraColors.amber)
                                )
                            } else {
                                androidx.compose.ui.graphics.Brush.horizontalGradient(
                                    listOf(Color.Transparent, Color.Transparent)
                                )
                            }
                        )
                        .clickable { onSelect(scope) }
                        .padding(horizontal = 14.dp, vertical = 7.dp),
                    contentAlignment = Alignment.Center
                ) {
                    Text(
                        text = scope.label,
                        fontSize = AuroraTypography.tiny.sp,
                        fontWeight = FontWeight.Bold,
                        color = if (isSelected) Color.White else MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            }
        }
    }
}

// Currency / Tokens chip used by Pulse's top toolbar. Sits to the right of
// the timeline scope picker so the row reads identically on iOS and Android.
@Composable
fun PulseDisplayModeToggle(
    displayMode: UsageDisplayMode,
    onToggle: (UsageDisplayMode) -> Unit,
    modifier: Modifier = Modifier
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = modifier
            .clip(CircleShape)
            .background(AuroraColors.ember.copy(alpha = 0.18f))
            .border(0.5.dp, AuroraColors.ember.copy(alpha = 0.4f), CircleShape)
            .clickable {
                onToggle(
                    if (displayMode == UsageDisplayMode.CURRENCY) UsageDisplayMode.TOKENS
                    else UsageDisplayMode.CURRENCY
                )
            }
            .padding(horizontal = 10.dp, vertical = 7.dp)
    ) {
        Text(
            text = if (displayMode == UsageDisplayMode.CURRENCY) "$" else "#",
            fontSize = 10.sp,
            fontWeight = FontWeight.Bold,
            color = AuroraColors.ember
        )
        Spacer(modifier = Modifier.width(4.dp))
        Text(
            text = displayMode.label,
            fontSize = AuroraTypography.tiny.sp,
            fontWeight = FontWeight.SemiBold,
            color = AuroraColors.ember
        )
    }
}
