package com.openburnbar.services.media

import android.app.Notification
import android.app.PendingIntent
import android.content.Intent
import android.net.Uri
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.openburnbar.BurnBarDeepLink
import com.openburnbar.MainActivity

/**
 * AI Inbox P1 alerts, delivered as `type=ai_inbox_item` FCM data messages by
 * `functions/src/aiInboxNotifications.ts`.
 *
 * ## What the push does and does not contain
 *
 * The mirrored inbox document is sealed with the Cloud Vault, so the Cloud
 * Function that fires this push cannot read the item's title or summary and
 * therefore cannot put them in the payload. What arrives is an opaque `item_id`
 * plus two bounded enums (`kind`, `priority`). The notification body is
 * deliberately generic; tapping it deep-links into the app, which fetches and
 * decrypts the real content locally.
 *
 * That means this file must never try to render item text from the payload —
 * there is none to render, and treating a future server-supplied string as
 * content would quietly turn the alert into a plaintext leak channel.
 */
internal data class AIInboxNotificationRouting(
    val itemId: String,
    val kind: String,
    val title: String,
    val body: String,
    val deepLink: String,
    val eventId: String? = null,
    val uid: String? = null,
    val expiresAtMillis: String? = null,
    val type: String? = null,
)

/** `BurnBarInboxItemKind` raw values, mirrored from the Kernel contract. */
private val INBOX_KIND_TITLES =
    mapOf(
        "ci_waste" to "Wasted CI",
        "promised_not_landed" to "Promised, not landed",
        "uncommitted_work" to "Uncommitted work",
        "cost_anomaly" to "Cost anomaly",
        "stuck_pr" to "Stuck pull request",
        "index_health" to "Index health",
        "brief" to "Brief",
        "budget" to "Budget",
        "system" to "OpenBurnBar",
    )

private const val FALLBACK_KIND = "system"
private const val GENERIC_BODY = "Open OpenBurnBar to see what needs you."
private const val MAX_ITEM_ID_LENGTH = 160

// Control/bidi characters in an id would let a hostile payload spoof the
// rendered notification; the same guard the Mercury routing ids use.
private val CONTROL_OR_BIDI = Regex("[\\u0000-\\u001f\\u202a-\\u202e]")

/**
 * Resolves an `ai_inbox_item` payload into what the notification should show.
 *
 * Returns `null` when the payload cannot address a real item, because a
 * notification the user cannot act on is worse than none: the tap would land on
 * an empty surface with no way back to what fired it.
 *
 * Pure and internal so the dispatch contract is unit-testable without an
 * emulator — the push shape is a cross-repo contract with the Cloud Function,
 * and a silent drift in it produces no crash, just notifications that stop
 * arriving.
 */
internal fun aiInboxNotificationRouting(data: Map<String, String>): AIInboxNotificationRouting? {
    val itemId = normalizedItemId(data["item_id"]) ?: return null
    val rawKind = data["kind"]?.trim().orEmpty()
    val kind = if (INBOX_KIND_TITLES.containsKey(rawKind)) rawKind else FALLBACK_KIND
    return AIInboxNotificationRouting(
        itemId = itemId,
        kind = kind,
        // Server-supplied `title` is only ever a kind label, so prefer the local
        // table: it keeps the string translatable and makes it impossible for a
        // payload field to become a content channel.
        title = INBOX_KIND_TITLES.getValue(kind),
        body = GENERIC_BODY,
        deepLink = BurnBarDeepLink.inboxURL(itemId),
        eventId = data["event_id"]?.trim()?.takeIf { it.isNotBlank() },
        uid = data["uid"]?.trim()?.takeIf { it.isNotBlank() },
        expiresAtMillis = data["expires_at_millis"]?.trim()?.takeIf { it.isNotBlank() },
        type = data["type"]?.trim()?.takeIf { it.isNotBlank() },
    )
}

private fun normalizedItemId(raw: String?): String? {
    val trimmed = raw?.trim()?.takeIf { it.isNotBlank() } ?: return null
    if (trimmed.length > MAX_ITEM_ID_LENGTH) return null
    if (CONTROL_OR_BIDI.containsMatchIn(trimmed)) return null
    return trimmed
}

internal fun MercuryFcmService.buildAIInboxNotification(routing: AIInboxNotificationRouting): Notification {
    ensureInboxChannel()
    val openIntent =
        Intent(this, MainActivity::class.java).apply {
            action = Intent.ACTION_VIEW
            data = Uri.parse(routing.deepLink)
            routing.eventId?.let { putExtra(MainActivity.EXTRA_EVENT_ID, it) }
            routing.uid?.let { putExtra(MainActivity.EXTRA_UID, it) }
            routing.expiresAtMillis?.let { putExtra(MainActivity.EXTRA_EXPIRES_AT_MILLIS, it) }
            routing.type?.let { putExtra(MainActivity.EXTRA_PUSH_TYPE, it) }
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        }
    // Pinned on its own line, outside the `apply` block, matching
    // MercuryFcmServiceSupport: the explicit-PendingIntent gate verifies the
    // package pin as a directly greppable statement per intent variable.
    openIntent.setPackage(packageName)
    val openPending =
        PendingIntent.getActivity(
            this,
            routing.itemId.hashCode(),
            openIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

    return NotificationCompat.Builder(this, MercuryFcmService.INBOX_CHANNEL_ID)
        .setSmallIcon(android.R.drawable.stat_sys_warning)
        .setContentTitle(routing.title)
        .setContentText(routing.body)
        .setContentIntent(openPending)
        .setAutoCancel(true)
        .setCategory(NotificationCompat.CATEGORY_REMINDER)
        .setPriority(NotificationCompat.PRIORITY_HIGH)
        // No public version: even the kind label describes the user's own work,
        // so a locked screen shows the channel name and nothing else.
        .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
        .setLocalOnly(true)
        .build()
}

internal fun MercuryFcmService.postAIInboxNotification(data: Map<String, String>) {
    val routing = aiInboxNotificationRouting(data) ?: return
    try {
        NotificationManagerCompat.from(this).notify(routing.itemId.hashCode(), buildAIInboxNotification(routing))
    } catch (error: SecurityException) {
        // Missing POST_NOTIFICATIONS — record the real (revoked) permission
        // state so the cloud fan-out stops targeting this device rather than
        // counting silently-dropped pushes as delivered.
        Log.w("BurnBar", "ai_inbox_notification_post_denied kind=${routing.kind} reason=${error.message}")
        AgentReplyNotificationState.recordPermissionResult(applicationContext, granted = false)
    }
}
