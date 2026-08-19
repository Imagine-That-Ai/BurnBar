// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.settings

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.AddCircleOutline
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.filled.RemoveCircleOutline
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.ui.components.AuroraNavIcon
import com.openburnbar.ui.navigation.BurnBarTab
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraRadius
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraType
import com.openburnbar.ui.theme.AuroraTypography

@Composable
internal fun NavigationCustomizationScaffold(isDark: Boolean, actions: NavigationCustomizationActions, content: @Composable () -> Unit) {
    Column(
        modifier =
        Modifier
            .fillMaxSize()
            .background(if (isDark) AuroraColors.darkBackground else AuroraColors.lightBackground)
            .padding(horizontal = AuroraSpacing.LG.dp),
        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.MD.dp),
    ) {
        Spacer(modifier = Modifier.height(AuroraSpacing.LG.dp))
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
            IconButton(onClick = actions.onBack) {
                Icon(
                    imageVector = Icons.AutoMirrored.Filled.ArrowBack,
                    contentDescription = "Back",
                    tint = MaterialTheme.colorScheme.onSurface,
                )
            }
            Spacer(modifier = Modifier.width(AuroraSpacing.SM.dp))
            Text(
                text = "Navigation",
                style = AuroraType.displayLarge,
                color = MaterialTheme.colorScheme.onSurface,
            )
        }
        content()
    }
}

@Composable
internal fun NavigationCustomizationContent(state: NavigationCustomizationUiState, actions: NavigationCustomizationActions) {
    LazyColumn(
        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.SM.dp),
        modifier = Modifier.fillMaxSize(),
    ) {
        item(key = "tabs-label") { NavigationSectionLabel("YOUR TABS") }
        item(key = "tabs") { NavigationVisibleTabsCard(state = state, actions = actions) }
        if (state.addableTabs.isNotEmpty()) {
            item(key = "add-label") { NavigationSectionLabel("ADD A TAB") }
            item(key = "add") { NavigationAddTabsCard(state = state, actions = actions) }
        }
        item(key = "gestures-label") { NavigationSectionLabel("GESTURES") }
        item(key = "swipe") { NavigationSwipeToggleCard(state = state, actions = actions) }
        item(key = "footer") {
            Text(
                text =
                "Tabs apply everywhere the tray shows. The Store tab hosts Settings, so it always " +
                    "stays; the tray keeps at least ${BurnBarTab.MINIMUM_TAB_COUNT} tabs.",
                fontSize = AuroraTypography.tiny.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(bottom = AuroraSpacing.LG.dp),
            )
        }
    }
}

@Composable
internal fun NavigationSectionLabel(text: String) {
    Text(
        text = text,
        fontWeight = FontWeight.Bold,
        fontSize = AuroraTypography.tiny.sp,
        letterSpacing = 1.2.sp,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
    )
}

@Composable
private fun NavigationCardSurface(content: @Composable () -> Unit) {
    Surface(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(AuroraRadius.LG.dp),
        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.6f),
    ) {
        Column(modifier = Modifier.padding(AuroraSpacing.SM.dp)) { content() }
    }
}

@Composable
internal fun NavigationVisibleTabsCard(state: NavigationCustomizationUiState, actions: NavigationCustomizationActions) {
    NavigationCardSurface {
        state.visibleTabs.forEachIndexed { index, tab ->
            NavigationVisibleTabRow(
                tab = tab,
                index = index,
                count = state.visibleTabs.size,
                canRemove = NavigationCustomizationModel.canRemove(state.visibleTabs.map { it.route }, tab.route),
                actions = actions,
            )
        }
    }
}

@Composable
private fun NavigationVisibleTabRow(tab: BurnBarTab, index: Int, count: Int, canRemove: Boolean, actions: NavigationCustomizationActions) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 2.dp),
    ) {
        AuroraNavIcon(destination = tab.destination, size = 22, isSelected = false)
        Spacer(modifier = Modifier.width(AuroraSpacing.SM.dp))
        Text(
            text = tab.label,
            fontSize = AuroraTypography.body.sp,
            color = MaterialTheme.colorScheme.onSurface,
            modifier = Modifier.weight(1f),
        )
        NavigationMoveButton(
            enabled = index > 0,
            icon = Icons.Filled.KeyboardArrowUp,
            label = "Move ${tab.label} up",
        ) {
            actions.onMove(index, -1)
            actions.onHaptic()
        }
        NavigationMoveButton(
            enabled = index < count - 1,
            icon = Icons.Filled.KeyboardArrowDown,
            label = "Move ${tab.label} down",
        ) {
            actions.onMove(index, 1)
            actions.onHaptic()
        }
        IconButton(
            enabled = canRemove,
            onClick = {
                actions.onRemove(tab.route)
                actions.onHaptic()
            },
        ) {
            Icon(
                imageVector = Icons.Filled.RemoveCircleOutline,
                contentDescription = if (canRemove) "Remove ${tab.label}" else "${tab.label} cannot be removed",
                tint = if (canRemove) AuroraColors.warning else MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.35f),
                modifier = Modifier.size(20.dp),
            )
        }
    }
}

@Composable
private fun NavigationMoveButton(enabled: Boolean, icon: androidx.compose.ui.graphics.vector.ImageVector, label: String, onClick: () -> Unit) {
    IconButton(enabled = enabled, onClick = onClick) {
        Icon(
            imageVector = icon,
            contentDescription = label,
            tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = if (enabled) 1f else 0.35f),
            modifier = Modifier.size(20.dp),
        )
    }
}

@Composable
internal fun NavigationAddTabsCard(state: NavigationCustomizationUiState, actions: NavigationCustomizationActions) {
    NavigationCardSurface {
        state.addableTabs.forEach { tab ->
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(vertical = 2.dp),
            ) {
                AuroraNavIcon(destination = tab.destination, size = 22, isSelected = false)
                Spacer(modifier = Modifier.width(AuroraSpacing.SM.dp))
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = tab.label,
                        fontSize = AuroraTypography.body.sp,
                        color = MaterialTheme.colorScheme.onSurface,
                    )
                    if (tab == BurnBarTab.FLEET) {
                        Text(
                            text = "Your Mac's live agent fleet, synced to this phone",
                            fontSize = AuroraTypography.tiny.sp,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
                IconButton(onClick = {
                    actions.onAdd(tab.route)
                    actions.onHaptic()
                }) {
                    Icon(
                        imageVector = Icons.Filled.AddCircleOutline,
                        contentDescription = "Add ${tab.label}",
                        tint = AuroraColors.success,
                        modifier = Modifier.size(20.dp),
                    )
                }
            }
        }
    }
}

@Composable
internal fun NavigationSwipeToggleCard(state: NavigationCustomizationUiState, actions: NavigationCustomizationActions) {
    NavigationCardSurface {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .fillMaxWidth()
                .padding(vertical = 2.dp),
        ) {
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = "Swipe between tabs",
                    fontSize = AuroraTypography.body.sp,
                    color = MaterialTheme.colorScheme.onSurface,
                )
                Text(
                    text = "Swipe left or right on a screen to move one tab over",
                    fontSize = AuroraTypography.tiny.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            Switch(
                checked = state.swipeEnabled,
                onCheckedChange = { actions.onSwipeEnabled(it) },
                modifier = Modifier.semantics { contentDescription = "Swipe between tabs" },
            )
        }
    }
}
