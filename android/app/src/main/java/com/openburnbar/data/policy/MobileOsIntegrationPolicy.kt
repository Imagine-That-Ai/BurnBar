package com.openburnbar.data.policy

import java.net.URI

enum class MobileOsDestination(val wire: String) {
    PULSE("pulse"),
    BURN("burn"),
    STREAMS("streams"),
    SETTINGS("settings"),
    COMPUTER_USE("computer-use"),
    HERMES("hermes"),
    PI("pi"),
    ASSISTANTS("assistants"),
    INSIGHTS("insights"),
    INBOX("inbox"),
    MERCURY_CALL("mercury-call"),
    MISSION("mission"),
    UNKNOWN("unknown"),
    ;

    companion object {
        fun fromWire(wire: String): MobileOsDestination = entries.firstOrNull { it.wire == wire } ?: UNKNOWN
    }
}

enum class MobileNotificationDelivery(val wire: String) {
    DELIVERED("delivered"),
    SUPPRESSED("suppressed"),
}

enum class MobileNavigationDecision(val wire: String) {
    NAVIGATE("navigate"),
    IGNORE_STALE("ignoreStale"),
    IGNORE_ACCOUNT_MISMATCH("ignoreAccountMismatch"),
    IGNORE_EXPIRED("ignoreExpired"),
    IGNORE_DUPLICATE("ignoreDuplicate"),
    IGNORE_DENIED("ignoreDenied"),
    IGNORE_UNKNOWN("ignoreUnknown"),
}

data class MobileOsRouteDecision(
    val destination: MobileOsDestination,
    val deepLink: String? = null,
    val threadId: String? = null,
    val itemId: String? = null,
    val connectionId: String? = null,
    val missionId: String? = null,
    val runtime: String? = null,
    val slug: String? = null,
)

data class MobilePushEnvelope(
    val type: String,
    val eventId: String,
    val uid: String? = null,
    val expiresAtMs: Long? = null,
    val threadId: String? = null,
    val itemId: String? = null,
    val connectionId: String? = null,
    val missionId: String? = null,
    val runtime: String? = null,
    val deepLink: String? = null,
)

data class MobileWidgetPrivacyScan(
    val hasRawUid: Boolean,
    val hasSecret: Boolean,
    val hasConversationText: Boolean,
) {
    val isPrivacySafe: Boolean get() = !hasRawUid && !hasSecret && !hasConversationText
}

/** Push, deep-link, permission, widget, and retry decisions for VAL-MOB-013. */
object MobileOsIntegrationPolicy {
    const val WIDGET_REFRESH_CADENCE_SECONDS: Long = 15L * 60L
    const val WIDGET_APP_GROUP = "group.com.openburnbar.app"
    const val MAX_BACKGROUND_RETRY_ATTEMPTS = 3
    val allowlistedHosts: Set<String> =
        setOf(
            "dashboard", "pulse", "burn", "quota", "streams", "search", "settings",
            "agent-watch", "agent-live", "computer-use", "chat", "hermes", "pi",
            "assistants", "insights", "inbox", "mercury", "mission",
        )

    val pushTypes: Map<String, MobileOsDestination> =
        mapOf(
            "agent_reply" to MobileOsDestination.ASSISTANTS,
            "ai_inbox_item" to MobileOsDestination.INBOX,
            "quota" to MobileOsDestination.BURN,
            "quota_alert" to MobileOsDestination.BURN,
            "quota_pressure" to MobileOsDestination.BURN,
            "media_incoming_call" to MobileOsDestination.MERCURY_CALL,
            "mission" to MobileOsDestination.MISSION,
            "mission_update" to MobileOsDestination.MISSION,
        )

    fun delivery(permissionGranted: Boolean): MobileNotificationDelivery =
        if (permissionGranted) MobileNotificationDelivery.DELIVERED else MobileNotificationDelivery.SUPPRESSED

    fun mayDeliver(permissionGranted: Boolean): Boolean = delivery(permissionGranted) == MobileNotificationDelivery.DELIVERED

    fun acceptedDeepLink(raw: String?): String? {
        val value = firstNonEmpty(raw) ?: return null
        val uri = runCatching { URI(value) }.getOrNull() ?: return null
        if (!uri.scheme.equals("burnbar", ignoreCase = true)) return null
        val host = uri.host.orEmpty().lowercase()
        if (host !in allowlistedHosts) return null
        return uri.toString()
    }

    fun envelope(payload: Map<String, String>): MobilePushEnvelope {
        val expiresRaw = firstNonEmpty(payload["expires_at_millis"], payload["expiresAtMs"])
        val expires = expiresRaw?.toLongOrNull()
        return MobilePushEnvelope(
            type = payload["type"].orEmpty(),
            eventId = firstNonEmpty(payload["event_id"], payload["eventId"]).orEmpty(),
            uid = firstNonEmpty(payload["uid"], payload["account_uid"], payload["accountUid"]),
            expiresAtMs = expires,
            threadId = firstNonEmpty(payload["thread_id"], payload["threadId"]),
            itemId = firstNonEmpty(payload["item_id"], payload["itemId"]),
            connectionId = firstNonEmpty(payload["connection_id"], payload["connectionId"]),
            missionId = firstNonEmpty(payload["mission_id"], payload["missionId"]),
            runtime = firstNonEmpty(payload["runtime"]),
            deepLink = firstNonEmpty(payload["deep_link"], payload["deepLink"]),
        )
    }

    fun route(payload: Map<String, String>): MobileOsRouteDecision = route(envelope(payload))

    fun route(envelope: MobilePushEnvelope): MobileOsRouteDecision {
        val destination = pushTypes[envelope.type] ?: MobileOsDestination.UNKNOWN
        return when (destination) {
            MobileOsDestination.ASSISTANTS -> {
                val runtime = firstNonEmpty(envelope.runtime) ?: "hermes"
                val thread = envelope.threadId.orEmpty()
                MobileOsRouteDecision(
                    destination = MobileOsDestination.ASSISTANTS,
                    deepLink = acceptedDeepLink(envelope.deepLink)
                        ?: "burnbar://assistants/$runtime?threadId=$thread",
                    threadId = envelope.threadId,
                    runtime = runtime,
                )
            }
            MobileOsDestination.INBOX -> {
                val item = envelope.itemId
                MobileOsRouteDecision(
                    destination = MobileOsDestination.INBOX,
                    deepLink = acceptedDeepLink(envelope.deepLink)
                        ?: item?.let { "burnbar://inbox/$it" }
                        ?: "burnbar://inbox",
                    itemId = item,
                )
            }
            MobileOsDestination.BURN ->
                MobileOsRouteDecision(
                    destination = MobileOsDestination.BURN,
                    deepLink = acceptedDeepLink(envelope.deepLink) ?: "burnbar://quota",
                )
            MobileOsDestination.MERCURY_CALL ->
                MobileOsRouteDecision(
                    destination = MobileOsDestination.MERCURY_CALL,
                    deepLink = acceptedDeepLink(envelope.deepLink)
                        ?: "burnbar://mercury/call/${envelope.connectionId.orEmpty()}",
                    connectionId = envelope.connectionId,
                )
            MobileOsDestination.MISSION ->
                MobileOsRouteDecision(
                    destination = MobileOsDestination.MISSION,
                    deepLink = acceptedDeepLink(envelope.deepLink)
                        ?: "burnbar://mission/${envelope.missionId.orEmpty()}",
                    missionId = envelope.missionId,
                )
            else -> MobileOsRouteDecision(destination = MobileOsDestination.UNKNOWN)
        }
    }

    fun route(url: String?): MobileOsRouteDecision {
        val uri = runCatching { URI(url) }.getOrNull() ?: return MobileOsRouteDecision(MobileOsDestination.UNKNOWN)
        if (!uri.scheme.equals("burnbar", ignoreCase = true)) {
            return MobileOsRouteDecision(MobileOsDestination.UNKNOWN)
        }
        val host = uri.host.orEmpty().lowercase()
        val pathParts = uri.path.orEmpty().split('/').filter { it.isNotEmpty() }
        val first = pathParts.firstOrNull()
        val firstLower = first?.lowercase()
        val query = parseQuery(uri.rawQuery)
        val thread = firstNonEmpty(query["threadId"], query["threadID"], query["thread_id"])
        val runtimeQuery = firstNonEmpty(query["runtime"])
        return when (host) {
            "dashboard", "pulse" -> MobileOsRouteDecision(MobileOsDestination.PULSE, url)
            "burn", "quota" -> MobileOsRouteDecision(MobileOsDestination.BURN, url)
            "streams", "search" -> MobileOsRouteDecision(MobileOsDestination.STREAMS, url)
            "settings" -> MobileOsRouteDecision(MobileOsDestination.SETTINGS, url)
            "agent-watch", "agent-live", "computer-use" ->
                MobileOsRouteDecision(MobileOsDestination.COMPUTER_USE, url)
            "chat", "hermes" ->
                MobileOsRouteDecision(MobileOsDestination.HERMES, url, threadId = thread, runtime = "hermes")
            "pi" -> MobileOsRouteDecision(MobileOsDestination.PI, url, threadId = thread, runtime = "pi")
            "assistants" ->
                MobileOsRouteDecision(
                    destination = MobileOsDestination.ASSISTANTS,
                    deepLink = url,
                    threadId = thread,
                    runtime = runtimeQuery ?: firstLower ?: "hermes",
                )
            "insights" -> MobileOsRouteDecision(MobileOsDestination.INSIGHTS, url, slug = first)
            "inbox" -> MobileOsRouteDecision(MobileOsDestination.INBOX, url, itemId = first)
            "mercury" ->
                if (firstLower == "call") {
                    MobileOsRouteDecision(
                        destination = MobileOsDestination.MERCURY_CALL,
                        deepLink = url,
                        connectionId = pathParts.getOrNull(1),
                    )
                } else {
                    MobileOsRouteDecision(MobileOsDestination.UNKNOWN)
                }
            "mission" -> MobileOsRouteDecision(MobileOsDestination.MISSION, url, missionId = first)
            else -> MobileOsRouteDecision(MobileOsDestination.UNKNOWN)
        }
    }

    fun navigation(
        envelope: MobilePushEnvelope,
        activeUid: String?,
        nowMs: Long,
        lastConsumedEventId: String?,
        permissionGranted: Boolean,
    ): MobileNavigationDecision {
        if (!permissionGranted) return MobileNavigationDecision.IGNORE_DENIED
        if (route(envelope).destination == MobileOsDestination.UNKNOWN) {
            return MobileNavigationDecision.IGNORE_UNKNOWN
        }
        val uid = firstNonEmpty(envelope.uid) ?: return MobileNavigationDecision.IGNORE_STALE
        val active = firstNonEmpty(activeUid)
        if (active == null || uid != active) return MobileNavigationDecision.IGNORE_ACCOUNT_MISMATCH
        val expires = envelope.expiresAtMs ?: return MobileNavigationDecision.IGNORE_STALE
        if (nowMs > expires) return MobileNavigationDecision.IGNORE_EXPIRED
        if (!envelope.eventId.isBlank() && lastConsumedEventId != null && lastConsumedEventId == envelope.eventId) {
            return MobileNavigationDecision.IGNORE_DUPLICATE
        }
        return MobileNavigationDecision.NAVIGATE
    }

    fun shouldConsumeTap(eventId: String, lastConsumedEventId: String?): Boolean {
        val clean = eventId.trim()
        if (clean.isEmpty()) return false
        return lastConsumedEventId != clean
    }

    fun scanWidgetFields(fields: Map<String, String>): MobileWidgetPrivacyScan {
        var hasUid = false
        var hasSecret = false
        var hasConversation = false
        for ((rawKey, rawValue) in fields) {
            val key = rawKey.lowercase()
            val value = rawValue.trim()
            if (key in UID_KEYS || looksLikeFirebaseUid(value)) hasUid = true
            if (key in SECRET_KEYS || looksLikeSecret(value)) hasSecret = true
            if (key in CONVERSATION_KEYS || looksLikeConversation(value)) hasConversation = true
        }
        return MobileWidgetPrivacyScan(hasUid, hasSecret, hasConversation)
    }

    fun widgetSnapshotIsPrivacySafe(
        heroTotalCost: Double,
        heroTotalTokens: Int,
        topProviders: List<String>,
        extraFields: Map<String, String> = emptyMap(),
    ): Boolean {
        val fields = extraFields.toMutableMap()
        fields["heroTotalCost"] = heroTotalCost.toString()
        fields["heroTotalTokens"] = heroTotalTokens.toString()
        topProviders.forEachIndexed { index, provider ->
            fields["topProvider.$index"] = provider
        }
        return scanWidgetFields(fields).isPrivacySafe
    }

    fun shouldRetryBackground(attempt: Int, cancelled: Boolean): Boolean {
        if (cancelled) return false
        return attempt >= 0 && attempt < MAX_BACKGROUND_RETRY_ATTEMPTS
    }

    fun shouldSuppressForegroundSameThread(
        foreground: Boolean,
        activeRuntime: String?,
        activeThreadId: String?,
        payloadRuntime: String?,
        payloadThreadId: String?,
    ): Boolean {
        if (!foreground) return false
        val activeThread = firstNonEmpty(activeThreadId) ?: return false
        val payloadThread = firstNonEmpty(payloadThreadId) ?: return false
        if (activeThread != payloadThread) return false
        val activeRuntimeValue = firstNonEmpty(activeRuntime)
        val payloadRuntimeValue = firstNonEmpty(payloadRuntime)
        return if (activeRuntimeValue != null && payloadRuntimeValue != null) {
            activeRuntimeValue == payloadRuntimeValue
        } else {
            true
        }
    }

    private val UID_KEYS = setOf("uid", "userid", "user_id", "accountuid", "account_uid", "firebaseuid")
    private val SECRET_KEYS = setOf("secret", "apikey", "api_key", "token", "fcm_token", "password", "privatekey")
    private val CONVERSATION_KEYS = setOf("conversation", "conversationtext", "messagebody", "replytext", "preview")

    private const val FIREBASE_UID_LENGTH = 28
    private const val SECRET_HEX_MIN_LENGTH = 40
    private const val CONVERSATION_MIN_LENGTH = 40

    private fun looksLikeFirebaseUid(value: String): Boolean =
        value.matches(Regex("^[A-Za-z0-9]{$FIREBASE_UID_LENGTH}$"))

    private fun looksLikeSecret(value: String): Boolean = value.startsWith("sk-") ||
        value.startsWith("AIza") ||
        (
            value.length >= SECRET_HEX_MIN_LENGTH &&
                value.all { it.isDigit() || it in 'a'..'f' || it in 'A'..'F' }
            )

    private fun looksLikeConversation(value: String): Boolean =
        value.contains(' ') && value.length > CONVERSATION_MIN_LENGTH

    private fun decodeQueryComponent(raw: String): String = runCatching { java.net.URLDecoder.decode(raw.replace("+", "%20"), Charsets.UTF_8.name()) }
        .getOrDefault(raw)

    private fun parseQuery(raw: String?): Map<String, String> {
        if (raw.isNullOrBlank()) return emptyMap()
        return raw.split('&').mapNotNull { pair ->
            val parts = pair.split('=', limit = 2)
            if (parts.isEmpty()) {
                null
            } else {
                decodeQueryComponent(parts[0]) to decodeQueryComponent(parts.getOrElse(1) { "" })
            }
        }.toMap()
    }

    private fun firstNonEmpty(vararg values: String?): String? {
        for (value in values) {
            val trimmed = value?.trim().orEmpty()
            if (trimmed.isNotEmpty()) return trimmed
        }
        return null
    }
}
