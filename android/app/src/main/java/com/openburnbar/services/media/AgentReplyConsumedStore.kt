package com.openburnbar.services.media

import android.content.Context

/**
 * Process-local last-consumed agent-reply event ids, keyed by UID.
 *
 * Presence heartbeats and FCM routing read [lastConsumedEventId]; this store
 * is the only writer besides tombstone cleanup on [AgentReplyNotificationState].
 */
internal object AgentReplyConsumedStore {
    private const val PREF_NAME = "burnbar.notifications"

    @Volatile
    var lastConsumedEventId: String? = null

    fun consumedKey(uid: String) = "last_consumed_$uid"

    fun bindConsumedEvents(uid: String?, context: Context) {
        bindConsumedFrom(prefsMap(context), uid)
    }

    fun persistConsumed(eventId: String, uid: String?, context: Context) {
        lastConsumedEventId = eventId
        if (uid == null) return
        context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
            .edit()
            .putString(consumedKey(uid), eventId)
            .apply()
    }

    fun persistConsumedTo(store: MutableMap<String, String>, eventId: String, uid: String?) {
        lastConsumedEventId = eventId
        if (uid == null) return
        store[consumedKey(uid)] = eventId
    }

    fun shouldClearLastConsumed(tombstonedUid: String, boundUid: String?): Boolean = boundUid == tombstonedUid

    fun bindConsumedFrom(store: Map<String, String>, uid: String?): String? {
        lastConsumedEventId = uid?.let { store[consumedKey(it)] }
        return lastConsumedEventId
    }

    fun prefsMap(context: Context): Map<String, String> {
        val prefs = context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
        return prefs.all.mapNotNull { (key, value) ->
            (value as? String)?.let { key to it }
        }.toMap()
    }
}

fun AgentReplyNotificationState.bindConsumedEvents(uid: String?, context: Context) = AgentReplyConsumedStore.bindConsumedEvents(uid, context)

fun AgentReplyNotificationState.persistConsumed(eventId: String, uid: String?, context: Context) =
    AgentReplyConsumedStore.persistConsumed(eventId, uid, context)

fun AgentReplyNotificationState.persistConsumedTo(store: MutableMap<String, String>, eventId: String, uid: String?) =
    AgentReplyConsumedStore.persistConsumedTo(store, eventId, uid)

fun AgentReplyNotificationState.shouldClearLastConsumed(tombstonedUid: String, boundUid: String?): Boolean =
    AgentReplyConsumedStore.shouldClearLastConsumed(tombstonedUid, boundUid)

fun AgentReplyNotificationState.bindConsumedFrom(store: Map<String, String>, uid: String?): String? = AgentReplyConsumedStore.bindConsumedFrom(store, uid)
