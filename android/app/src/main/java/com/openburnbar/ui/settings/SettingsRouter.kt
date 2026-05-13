package com.openburnbar.ui.settings

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue

/**
 * Drives Settings search navigation on Android. Single source of truth for
 * the search query, current sub-screen, pending anchor, pending focus, and
 * highlight target.
 *
 * Lifecycle: scoped to the `SettingsRoot` composable via `remember`.
 */
class SettingsRouter {
    /** Free-form search query. */
    var query: String by mutableStateOf("")

    /** Current sub-screen the Settings tree is showing. */
    var page: SettingsPageRoute by mutableStateOf(SettingsPageRoute.ROOT)

    /** Anchor id the next composable should scroll to on appear. */
    var pendingAnchor: String? by mutableStateOf(null)

    /** Focus id the next composable should hand to its FocusRequester. */
    var pendingFocus: String? by mutableStateOf(null)

    /** Anchor that should paint a brief halo on arrival. */
    var highlightedAnchor: String? by mutableStateOf(null)

    val isSearching: Boolean
        get() = query.isNotBlank()

    /** Drive navigation to a search result row. */
    fun navigate(item: SettingsItem) {
        pendingAnchor = item.anchorId
        highlightedAnchor = item.anchorId
        pendingFocus = item.focusId
        page = item.pageRoute
        query = ""
    }

    /** Clear all transient routing state. */
    fun reset() {
        query = ""
        pendingAnchor = null
        pendingFocus = null
        highlightedAnchor = null
        page = SettingsPageRoute.ROOT
    }

    /** Destination calls this after it scrolls to the anchor. */
    fun consumePendingAnchor(anchor: String) {
        if (pendingAnchor == anchor) pendingAnchor = null
    }

    /** Destination calls this after it latches the focus state. */
    fun consumePendingFocus(focus: String) {
        if (pendingFocus == focus) pendingFocus = null
    }

    /** Destinations call this once the highlight animation completes. */
    fun clearHighlight(anchor: String) {
        if (highlightedAnchor == anchor) highlightedAnchor = null
    }
}
