package com.openburnbar

import android.content.Intent
import com.openburnbar.data.policy.MobileNavigationDecision
import com.openburnbar.data.policy.MobileOsDestination
import com.openburnbar.data.policy.MobileOsIntegrationPolicy
import com.openburnbar.data.policy.MobileOsRouteDecision
import java.net.URI
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Parsed `burnbar://` destination for a deep link that MainActivity must route
 * itself, rather than leaving to the Navigation-Compose `navDeepLink` graph.
 *
 * Most `burnbar://` hosts are declared as `navDeepLink` patterns on their
 * composable (see `BurnBarNavHostSections.kt`), and Navigation matches those on
 * the launch intent automatically. That mechanism only covers destinations that
 * exist in the graph — a link whose target is not a nav route (or is not built
 * yet) silently lands on the start destination with no signal at all. This type
 * makes those routes explicit and, crucially, testable without an Activity.
 */
internal sealed interface BurnBarDeepLinkRoute {
    /**
     * `burnbar://inbox` (the list) or `burnbar://inbox/<itemId>` (one item).
     *
     * Produced by an AI Inbox P1 push. `itemId` is opaque: the push carries only
     * the id, and the item body is fetched and decrypted from the sealed
     * Firestore mirror after the link lands.
     */
    data class Inbox(val itemId: String?) : BurnBarDeepLinkRoute
}

/**
 * Parses the `burnbar://` links MainActivity routes directly.
 *
 * Returns `null` for anything else — including well-formed links to nav-graph
 * destinations — so the Navigation deep-link machinery keeps owning those and
 * this parser never has to be kept in sync with the tab catalog.
 */
internal object BurnBarDeepLink {
    private const val INBOX_HOST = "inbox"
    private const val SCHEME = "burnbar"

    /** Bounds an id before it becomes a lookup key or an Intent extra. */
    private const val MAX_ITEM_ID_LENGTH = 160

    // Control and bidi-override characters would let a hostile id spoof what a
    // UI renders; the same guard the FCM routing ids already use.
    private val CONTROL_OR_BIDI = Regex("[\\u0000-\\u001f\\u202a-\\u202e]")

    fun parse(rawURL: String?): BurnBarDeepLinkRoute? {
        val uri = runCatching { URI(rawURL) }.getOrNull() ?: return null
        if (!uri.scheme.equals(SCHEME, ignoreCase = true)) return null
        if (!uri.host.equals(INBOX_HOST, ignoreCase = true)) return null
        return BurnBarDeepLinkRoute.Inbox(itemId = normalizedItemId(uri.path))
    }

    // Deliberately not an overload of `parse`: `Intent?` and `String?` are both
    // nullable reference types, so `parse(null)` would be ambiguous at every
    // call site.
    fun parseIntent(intent: Intent?): BurnBarDeepLinkRoute? = parse(intent?.dataString)

    /** `burnbar://inbox/<itemId>` for a given item, or the bare list link. */
    fun inboxURL(itemId: String?): String {
        val normalized = itemId?.let(::sanitizeItemId)
        return if (normalized == null) "$SCHEME://$INBOX_HOST" else "$SCHEME://$INBOX_HOST/$normalized"
    }

    /** `/<itemId>` → `itemId`; a bare `burnbar://inbox` yields `null`. */
    private fun normalizedItemId(path: String?): String? {
        val segment = path?.trim('/')?.substringBefore('/') ?: return null
        return sanitizeItemId(segment)
    }

    private fun sanitizeItemId(raw: String): String? {
        val trimmed = raw.trim()
        if (trimmed.isEmpty() || trimmed.length > MAX_ITEM_ID_LENGTH) return null
        if (CONTROL_OR_BIDI.containsMatchIn(trimmed)) return null
        return trimmed
    }
}

/**
 * The inbox item a deep link asked for, handed from the Activity to whichever
 * composable owns the Inbox surface.
 *
 * Deliberately the same shape as [com.openburnbar.ui.navigation.HermesPendingPrompt]:
 * the notification tap and the app launch race each other, so the Activity
 * stashes the request and the surface claims it.
 *
 * It is a [StateFlow] rather than a plain field because the two ends are not
 * synchronized. On a COLD start the Activity stashes before the Inbox surface
 * exists; on a WARM start (`onNewIntent`) the surface is already composed and
 * would never re-read a plain field, so a second push while the app is open
 * would do nothing. Emitting makes both cases the same code path.
 *
 * `claim()` clears as it reads, so a configuration change cannot re-navigate
 * away from wherever the user has since gone.
 */
object InboxPendingItem {
    private val _pending = MutableStateFlow<String?>(null)

    /** Observed by the Inbox surface so a warm-start push is not missed. */
    val pending: StateFlow<String?> = _pending.asStateFlow()

    fun stash(itemId: String?) {
        _pending.value = itemId
    }

    /**
     * Reads the request WITHOUT consuming it.
     *
     * The push tap and the store's first Firestore snapshot race, so the Inbox
     * surface composes before the requested row exists. A consuming read there
     * would throw the request away on that first pass and the deep link would
     * silently do nothing; [peek] lets the surface wait until it can actually
     * honor the request, then [claim] it.
     */
    fun peek(): String? = _pending.value

    fun claim(): String? {
        val value = _pending.value
        _pending.value = null
        return value
    }

    /** Test seam: the process-wide stash must not leak between test cases. */
    internal fun reset() {
        _pending.value = null
    }
}

/**
 * A request to move the nav host to the Inbox tab, raised for a WARM deep link.
 *
 * Navigation-Compose only matches `navDeepLink` patterns against the LAUNCH
 * intent. When the app is already running, `onNewIntent` re-routes the link
 * here but nothing re-runs the deep-link match, so [InboxPendingItem] gets
 * stashed while the user stays parked on whatever tab was open and the tap
 * appears to do nothing. The Activity raises this request instead and
 * `BurnBarNavHost` claims it once composed, navigating with the same tab nav
 * options a bottom-bar tap would use.
 *
 * `claim()` clears as it reads, so recomposition or a configuration change
 * cannot re-navigate away from wherever the user has since gone.
 */
object InboxPendingNavigation {
    private val _requested = MutableStateFlow(false)

    /** Observed by the nav host so a warm-start push is not missed. */
    val requested: StateFlow<Boolean> = _requested.asStateFlow()

    fun request() {
        _requested.value = true
    }

    /** Reads AND consumes the request; `true` exactly once per [request]. */
    fun claim(): Boolean {
        val value = _requested.value
        _requested.value = false
        return value
    }

    /** Test seam: the process-wide request must not leak between test cases. */
    internal fun reset() {
        _requested.value = false
    }
}

/**
 * Warm-start navigation for policy destinations that Navigation-Compose cannot
 * rematch after [android.app.Activity.onNewIntent]. Inbox stays on its own
 * stash; quota / mission / mercury land here.
 */
object OsPendingNavigation {
    data class Request(
        val destination: MobileOsDestination,
        val route: String,
        val itemId: String? = null,
        val missionId: String? = null,
        val connectionId: String? = null,
        val eventId: String? = null,
    )

    private val _pending = MutableStateFlow<Request?>(null)
    val pending: StateFlow<Request?> = _pending.asStateFlow()

    fun request(routed: MobileOsRouteDecision, eventId: String? = null) {
        val route = when (routed.destination) {
            MobileOsDestination.BURN -> "burn"
            MobileOsDestination.INBOX -> "inbox"
            MobileOsDestination.MISSION ->
                routed.missionId?.takeIf { it.isNotBlank() }?.let { "mission/$it" } ?: "mission"
            MobileOsDestination.MERCURY_CALL ->
                routed.connectionId?.takeIf { it.isNotBlank() }?.let { "mercury/call/$it" } ?: "mercury/call"
            else -> return
        }
        _pending.value = Request(
            destination = routed.destination,
            route = route,
            itemId = routed.itemId,
            missionId = routed.missionId,
            connectionId = routed.connectionId,
            eventId = eventId,
        )
    }

    fun claim(): Request? {
        val value = _pending.value
        _pending.value = null
        return value
    }

    internal fun reset() {
        _pending.value = null
    }
}

/** Tray-tap / warm-start envelope extras. Run navigation() with original uid/expiry. */
object MobileOsIntentNavigation {
    /** Envelope payload key ↔ Intent extra name; [payloadFrom] and [putEnvelopeExtras] are inverses. */
    private val ENVELOPE_EXTRAS = mapOf(
        "event_id" to MainActivity.EXTRA_EVENT_ID,
        "uid" to MainActivity.EXTRA_UID,
        "expires_at_millis" to MainActivity.EXTRA_EXPIRES_AT_MILLIS,
        "type" to MainActivity.EXTRA_PUSH_TYPE,
    )

    fun payloadFrom(intent: Intent?): Map<String, String> {
        if (intent == null) return emptyMap()
        val payload = mutableMapOf<String, String>()
        intent.dataString?.takeIf { it.isNotBlank() }?.let { payload["deep_link"] = it }
        for ((key, extra) in ENVELOPE_EXTRAS) {
            intent.getStringExtra(extra)?.takeIf { it.isNotBlank() }?.let { payload[key] = it }
        }
        return payload
    }

    fun hasPushEnvelope(payload: Map<String, String>): Boolean = !payload["event_id"].isNullOrBlank() ||
        !payload["uid"].isNullOrBlank() ||
        !payload["expires_at_millis"].isNullOrBlank()

    fun navigation(
        payload: Map<String, String>,
        activeUid: String?,
        lastConsumedEventId: String?,
        nowMs: Long = System.currentTimeMillis(),
        permissionGranted: Boolean = true,
    ): MobileNavigationDecision = MobileOsIntegrationPolicy.navigation(
        envelope = MobileOsIntegrationPolicy.envelope(payload),
        activeUid = activeUid,
        nowMs = nowMs,
        lastConsumedEventId = lastConsumedEventId,
        permissionGranted = permissionGranted,
    )

    fun putEnvelopeExtras(intent: Intent, data: Map<String, String>): Intent {
        for ((key, extra) in ENVELOPE_EXTRAS) {
            data[key]?.takeIf { it.isNotBlank() }?.let { intent.putExtra(extra, it) }
        }
        return intent
    }
}
