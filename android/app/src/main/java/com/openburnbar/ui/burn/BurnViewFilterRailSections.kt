package com.openburnbar.ui.burn

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.models.label
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraSpacing

internal data class QuotaFilterRailState(
    val viewMode: BurnViewStyle,
    val sort: QuotaSortMode,
    val showInactive: Boolean,
    val isRefreshing: Boolean,
)

internal data class QuotaFilterRailActions(
    val onViewModeChange: (BurnViewStyle) -> Unit,
    val onSortChange: (QuotaSortMode) -> Unit,
    val onShowInactiveChange: (Boolean) -> Unit,
    val onRefreshAll: () -> Unit,
)

@Composable
internal fun QuotaFilterRail(state: QuotaFilterRailState, actions: QuotaFilterRailActions, modifier: Modifier = Modifier) {
    var sortMenuExpanded by remember { mutableStateOf(false) }

    Row(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = AuroraSpacing.LG.dp, vertical = AuroraSpacing.SM.dp),
        horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.MD.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        QuotaViewModeToggle(viewMode = state.viewMode, onViewModeChange = actions.onViewModeChange)
        QuotaSortMenu(
            sort = state.sort,
            expanded = sortMenuExpanded,
            onExpandedChange = { sortMenuExpanded = it },
            onSortChange = actions.onSortChange,
        )
        QuotaInactiveToggle(showInactive = state.showInactive, onShowInactiveChange = actions.onShowInactiveChange)
        Spacer(modifier = Modifier.weight(1f))
        QuotaRefreshAllButton(isRefreshing = state.isRefreshing, onRefreshAll = actions.onRefreshAll)
    }
}

@Composable
private fun QuotaViewModeToggle(viewMode: BurnViewStyle, onViewModeChange: (BurnViewStyle) -> Unit) {
    Row(
        modifier = Modifier
            .clip(RoundedCornerShape(16.dp))
            .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f))
            .border(0.5.dp, MaterialTheme.colorScheme.outline.copy(alpha = 0.3f), RoundedCornerShape(16.dp))
            .padding(2.dp),
        horizontalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        listOf(BurnViewStyle.CARDS, BurnViewStyle.LIST).forEach { mode ->
            QuotaViewModeChip(mode = mode, active = viewMode == mode, onClick = { onViewModeChange(mode) })
        }
    }
}

@Composable
private fun QuotaViewModeChip(mode: BurnViewStyle, active: Boolean, onClick: () -> Unit) {
    Box(
        modifier = Modifier
            .clip(RoundedCornerShape(14.dp))
            .background(if (active) AuroraColors.ember.copy(alpha = 0.18f) else Color.Transparent)
            .border(
                0.5.dp,
                if (active) AuroraColors.ember.copy(alpha = 0.4f) else Color.Transparent,
                RoundedCornerShape(14.dp),
            )
            .clickable { onClick() }
            .padding(horizontal = 10.dp, vertical = 4.5.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = mode.label,
            fontSize = 11.sp,
            fontWeight = if (active) FontWeight.SemiBold else FontWeight.Medium,
            color = if (active) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.85f),
        )
    }
}

@Composable
private fun QuotaSortMenu(sort: QuotaSortMode, expanded: Boolean, onExpandedChange: (Boolean) -> Unit, onSortChange: (QuotaSortMode) -> Unit) {
    Box {
        Row(
            modifier = Modifier
                .clip(RoundedCornerShape(16.dp))
                .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.35f))
                .border(0.5.dp, MaterialTheme.colorScheme.outline.copy(alpha = 0.4f), RoundedCornerShape(16.dp))
                .clickable { onExpandedChange(true) }
                .padding(horizontal = 10.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Text(
                text = "Sort · ${sort.label}",
                fontSize = 11.sp,
                fontWeight = FontWeight.Medium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Icon(
                imageVector = Icons.Default.ArrowDropDown,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f),
                modifier = Modifier.size(12.dp),
            )
        }
        DropdownMenu(expanded = expanded, onDismissRequest = { onExpandedChange(false) }) {
            QuotaSortMode.values().forEach { mode ->
                QuotaSortMenuItem(mode = mode, selected = sort == mode) {
                    onSortChange(mode)
                    onExpandedChange(false)
                }
            }
        }
    }
}

@Composable
private fun QuotaSortMenuItem(mode: QuotaSortMode, selected: Boolean, onClick: () -> Unit) {
    DropdownMenuItem(
        text = {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                if (selected) {
                    Icon(Icons.Default.Check, contentDescription = null, modifier = Modifier.size(14.dp))
                } else {
                    Spacer(modifier = Modifier.size(14.dp))
                }
                Text(mode.label, fontSize = 13.sp)
            }
        },
        onClick = onClick,
    )
}

@Composable
private fun QuotaInactiveToggle(showInactive: Boolean, onShowInactiveChange: (Boolean) -> Unit) {
    Row(
        modifier = Modifier
            .clip(RoundedCornerShape(16.dp))
            .background(
                if (showInactive) {
                    AuroraColors.ember.copy(alpha = 0.10f)
                } else {
                    MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.35f)
                },
            )
            .border(
                0.5.dp,
                if (showInactive) {
                    AuroraColors.ember.copy(alpha = 0.45f)
                } else {
                    MaterialTheme.colorScheme.outline.copy(alpha = 0.4f)
                },
                RoundedCornerShape(16.dp),
            )
            .clickable { onShowInactiveChange(!showInactive) }
            .padding(horizontal = 10.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Text(
            text = "Inactive plans",
            fontSize = 11.sp,
            fontWeight = FontWeight.Medium,
            color = if (showInactive) AuroraColors.ember else MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun QuotaRefreshAllButton(isRefreshing: Boolean, onRefreshAll: () -> Unit) {
    Row(
        modifier = Modifier
            .clip(RoundedCornerShape(16.dp))
            .background(AuroraColors.ember.copy(alpha = 0.18f))
            .border(0.5.dp, AuroraColors.ember.copy(alpha = 0.45f), RoundedCornerShape(16.dp))
            .clickable(enabled = !isRefreshing) { onRefreshAll() }
            .padding(horizontal = 12.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        if (isRefreshing) {
            Text(
                text = "Refreshing…",
                fontSize = 11.sp,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurface,
            )
        } else {
            Icon(
                imageVector = Icons.Default.Refresh,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurface,
                modifier = Modifier.size(10.dp),
            )
            Text(
                text = "Refresh all",
                fontSize = 11.sp,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurface,
            )
        }
    }
}
