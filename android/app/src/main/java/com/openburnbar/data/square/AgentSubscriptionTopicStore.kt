package com.openburnbar.data.square

import android.content.Context
import android.content.SharedPreferences
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONArray
import org.json.JSONObject

// MARK: - Agent Subscription Topic Store (Android parity)
//
// Port of the iOS `AgentSubscriptionTopicStore`. Persists per-agent topic
// subscriptions (cadence, muted state) so the brand-zone Subscribe sheet
// and the Hermes Square subscriptions list can write through to local
// storage immediately and reconcile against Firestore in the background.

enum class SubscriptionCadence(val token: String) {
    DAILY("daily"), WEEKLY("weekly"), MONTHLY("monthly");

    val displayLabel: String get() = when (this) {
        DAILY -> "Daily"; WEEKLY -> "Weekly"; MONTHLY -> "Monthly"
    }

    companion object {
        fun fromToken(token: String?): SubscriptionCadence =
            values().firstOrNull { it.token == token } ?: WEEKLY
    }
}

data class AgentSubscriptionTopic(
    val agentURI: String,
    val displayName: String,
    val cadence: SubscriptionCadence,
    val muted: Boolean,
    val createdAtEpoch: Long,
)

class AgentSubscriptionTopicStore private constructor(context: Context) {
    private val prefs: SharedPreferences = context.applicationContext
        .getSharedPreferences("square.subscriptions", Context.MODE_PRIVATE)

    private val _topics = MutableStateFlow<List<AgentSubscriptionTopic>>(emptyList())
    val topics: StateFlow<List<AgentSubscriptionTopic>> = _topics.asStateFlow()

    init { _topics.value = load() }

    fun topic(agentURI: String): AgentSubscriptionTopic? =
        _topics.value.firstOrNull { it.agentURI == agentURI }

    fun subscribe(agent: AgentIdentity, cadence: SubscriptionCadence): AgentSubscriptionTopic {
        val now = System.currentTimeMillis()
        val existing = topic(agent.id)
        val updated = AgentSubscriptionTopic(
            agentURI = agent.id,
            displayName = agent.displayName,
            cadence = cadence,
            muted = existing?.muted ?: false,
            createdAtEpoch = existing?.createdAtEpoch ?: now,
        )
        upsert(updated)
        return updated
    }

    fun unsubscribe(agentURI: String) {
        _topics.value = _topics.value.filterNot { it.agentURI == agentURI }
        save()
    }

    fun setMuted(agentURI: String, muted: Boolean): AgentSubscriptionTopic? {
        val existing = topic(agentURI) ?: return null
        val updated = existing.copy(muted = muted)
        upsert(updated)
        return updated
    }

    private fun upsert(topic: AgentSubscriptionTopic) {
        val list = _topics.value.toMutableList()
        val idx = list.indexOfFirst { it.agentURI == topic.agentURI }
        if (idx >= 0) list[idx] = topic else list.add(topic)
        _topics.value = list
        save()
    }

    private fun load(): List<AgentSubscriptionTopic> {
        val raw = prefs.getString(KEY_TOPICS, null) ?: return emptyList()
        return runCatching {
            val arr = JSONArray(raw)
            (0 until arr.length()).mapNotNull { i ->
                val obj = arr.getJSONObject(i)
                AgentSubscriptionTopic(
                    agentURI = obj.optString("agentURI").takeIf { it.isNotBlank() } ?: return@mapNotNull null,
                    displayName = obj.optString("displayName"),
                    cadence = SubscriptionCadence.fromToken(obj.optString("cadence")),
                    muted = obj.optBoolean("muted", false),
                    createdAtEpoch = obj.optLong("createdAt", System.currentTimeMillis()),
                )
            }
        }.getOrDefault(emptyList())
    }

    private fun save() {
        val arr = JSONArray()
        for (t in _topics.value) {
            val obj = JSONObject()
            obj.put("agentURI", t.agentURI)
            obj.put("displayName", t.displayName)
            obj.put("cadence", t.cadence.token)
            obj.put("muted", t.muted)
            obj.put("createdAt", t.createdAtEpoch)
            arr.put(obj)
        }
        prefs.edit().putString(KEY_TOPICS, arr.toString()).apply()
    }

    companion object {
        private const val KEY_TOPICS = "topics.v1"

        @Volatile private var instance: AgentSubscriptionTopicStore? = null

        fun shared(context: Context): AgentSubscriptionTopicStore =
            instance ?: synchronized(this) {
                instance ?: AgentSubscriptionTopicStore(context).also { instance = it }
            }
    }
}
