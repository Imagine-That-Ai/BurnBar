// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.settings

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import com.openburnbar.ui.navigation.BurnBarTab

// MARK: - Navigation customization (Android)
//
// Settings → Navigation: reorder, remove, and add bottom-tray tabs (including
// the addable Fleet dashboard) and toggle the root content swipe. Follows the
// `QuotaCustomizationScreen` scaffold/actions pattern; the guard rules live in
// `NavigationCustomizationModel` and the read-side merge in
// `BurnBarTab.resolveCustomizedTabs`, both unit-tested.

@Composable
fun NavigationCustomizationScreen(onBack: () -> Unit) {
    val haptic = LocalHapticFeedback.current
    val isDark = isSystemInDarkTheme()

    // Reading `BurnBarTab.all` subscribes to the tab-order settings states, so
    // every mutation below recomposes the list immediately.
    val visibleTabs = BurnBarTab.all
    val visibleRoutes = visibleTabs.map { it.route }
    val swipeEnabled by rememberSwipeNavigationEnabled()

    val actions =
        NavigationCustomizationActions(
            onBack = onBack,
            onMove = { index, delta ->
                commitTabOrder(NavigationCustomizationModel.moved(visibleRoutes, index, delta))
            },
            onRemove = { route ->
                if (NavigationCustomizationModel.canRemove(visibleRoutes, route)) {
                    commitTabOrder(NavigationCustomizationModel.removed(visibleRoutes, route))
                    GlobalVisualSettings.addRemovedTab(route)
                }
            },
            onAdd = { route ->
                commitTabOrder(NavigationCustomizationModel.added(visibleRoutes, route))
                GlobalVisualSettings.clearRemovedTab(route)
            },
            onSwipeEnabled = { GlobalVisualSettings.setSwipeNavigationEnabled(it) },
            onHaptic = { haptic.performHapticFeedback(HapticFeedbackType.LongPress) },
        )

    Box(modifier = Modifier.fillMaxSize()) {
        NavigationCustomizationScaffold(isDark = isDark, actions = actions) {
            NavigationCustomizationContent(
                state =
                NavigationCustomizationUiState(
                    visibleTabs = visibleTabs,
                    addableTabs = NavigationCustomizationModel.addableTabs(visibleRoutes),
                    swipeEnabled = swipeEnabled,
                ),
                actions = actions,
            )
        }
    }
}

/**
 * Writes the full visible order into the primary pref. Primary is the single
 * order source from here on; the legacy secondary string stays untouched (the
 * resolver ignores routes already placed by primary).
 */
private fun commitTabOrder(routes: List<String>) {
    GlobalVisualSettings.setPrimaryTabs(routes.joinToString(","))
}

internal data class NavigationCustomizationActions(
    val onBack: () -> Unit,
    val onMove: (index: Int, delta: Int) -> Unit,
    val onRemove: (route: String) -> Unit,
    val onAdd: (route: String) -> Unit,
    val onSwipeEnabled: (Boolean) -> Unit,
    val onHaptic: () -> Unit,
)

internal data class NavigationCustomizationUiState(
    val visibleTabs: List<BurnBarTab>,
    val addableTabs: List<BurnBarTab>,
    val swipeEnabled: Boolean,
)
