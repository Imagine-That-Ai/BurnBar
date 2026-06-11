package com.openburnbar.ui.navigation

import androidx.navigation.NavOptions
import androidx.navigation.navOptions

/**
 * Canonical bottom-nav options for tab switches (the androidx
 * navigation-compose pattern for Material bottom navigation / rails).
 *
 * - `popUpTo(startDestinationId) { saveState = true }` pops everything above
 *   the start destination on every switch while **saving** each tab's back
 *   stack (NavBackStackEntry-scoped ViewModels, scroll positions, sub-routes
 *   pushed above the tab). The back stack stays bounded to at most one tab
 *   entry above Pulse instead of growing with every switch — previously each
 *   revisit created a fresh entry, which spun up fresh stores, re-ran the
 *   full Pulse load (rollups + quota + 250-doc activity page), and stacked
 *   another set of live Firestore snapshot listeners that stayed registered
 *   until the stale entry was eventually popped.
 * - `restoreState = true` re-attaches that saved state when the user returns
 *   to a previously visited tab. Without the matching `saveState` above it
 *   was provably a no-op (nothing was ever saved), so tab returns showed the
 *   loading skeleton and refetched everything.
 * - `launchSingleTop = true` keeps re-selecting the current tab from pushing
 *   a duplicate copy of it.
 *
 * Intentional Back-behavior change (standard Material bottom-nav semantics,
 * approved 2026-06-10): system Back from any non-start tab now returns to the
 * start destination (Pulse) and then exits the app, instead of walking back
 * through every previously visited tab in visit order.
 */
fun burnBarTabNavOptions(startDestinationId: Int): NavOptions = navOptions {
    popUpTo(startDestinationId) { saveState = true }
    launchSingleTop = true
    restoreState = true
}
