package com.openburnbar.ui.settings

import com.openburnbar.ui.navigation.BurnBarTab

// MARK: - Navigation customization pure model
//
// The reorder/remove/add rules behind Settings → Navigation, as pure functions
// over route lists so the guards are unit-tested without Compose. The screen
// writes results through `GlobalVisualSettings`; `BurnBarTab.resolveCustomizedTabs`
// re-applies the same guards on every read, so a hand-edited pref can never
// smuggle an invalid tray past them.

internal object NavigationCustomizationModel {
    /** Moves the route at [index] by [delta] positions, clamped to the list. */
    fun moved(routes: List<String>, index: Int, delta: Int): List<String> {
        if (index !in routes.indices) return routes
        val target = (index + delta).coerceIn(routes.indices)
        if (target == index) return routes
        val reordered = routes.toMutableList()
        val route = reordered.removeAt(index)
        reordered.add(target, route)
        return reordered
    }

    /**
     * Whether [route] may be removed from [routes]: never the permanent `you`
     * tab, and never below the minimum tray size.
     */
    fun canRemove(routes: List<String>, route: String): Boolean {
        if (route == BurnBarTab.PERMANENT_ROUTE) return false
        if (route !in routes) return false
        return routes.size > BurnBarTab.MINIMUM_TAB_COUNT
    }

    /** [routes] without [route]; unchanged when [canRemove] says no. */
    fun removed(routes: List<String>, route: String): List<String> {
        if (!canRemove(routes, route)) return routes
        return routes.filter { it != route }
    }

    /** [routes] with [route] appended (once). */
    fun added(routes: List<String>, route: String): List<String> {
        if (route in routes) return routes
        return routes + route
    }

    /** Tabs available to add: every addable candidate not currently visible. */
    fun addableTabs(visibleRoutes: List<String>): List<BurnBarTab> = BurnBarTab.addableCandidates.filter { it.route !in visibleRoutes }
}
