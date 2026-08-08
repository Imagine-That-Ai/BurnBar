package com.openburnbar.ui.inbox

import com.openburnbar.data.inbox.AIInboxSnoozeInterval

/**
 * What the detail surface can do to the item it is showing.
 *
 * Bundled so `InboxDetail` takes one parameter instead of four, and so the
 * screen wires the store to the view in one place — the detail itself never
 * learns that an `AIInboxStore` exists.
 */
internal data class InboxDetailCallbacks(
    val onArchive: () -> Unit,
    val onSnooze: (AIInboxSnoozeInterval) -> Unit,
    /** One of the rules-allowlisted feedback tokens, or `null` to clear it. */
    val onFeedback: (String?) -> Unit,
    /** A `burnbar://`-relative route an evidence row or action wants opened. */
    val onOpenRoute: (String) -> Unit,
)
