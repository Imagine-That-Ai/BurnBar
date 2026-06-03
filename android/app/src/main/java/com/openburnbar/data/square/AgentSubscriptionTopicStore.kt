package com.openburnbar.data.square

import android.content.Context
import android.content.SharedPreferences
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.firestore.FieldValue
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.ListenerRegistration
import com.openburnbar.data.assistants.SkillRunDeliveryMode
import com.openburnbar.data.assistants.SkillRunEventImportance
import com.openburnbar.data.cloud.AndroidCloudVaultKeyAccess
import com.openburnbar.data.cloud.CloudVaultCrypto
import com.openburnbar.data.firebase.CloudVaultSealedTextCodec
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject

// MARK: - Agent Subscription Topic Store (Android parity)
//
// Port of the iOS `AgentSubscriptionTopicStore`. Persists per-agent topic
// subscriptions (cadence, muted state) so the brand-zone Subscribe sheet
// and the Hermes Square subscriptions list can write through to local
// storage immediately and reconcile against Firestore in the background.

enum class SubscriptionCadence(val token: String) {
    ON_DEMAND("on_demand"),
    DAILY("daily"),
    WEEKLY("weekly"),
    MONTHLY("monthly"),
    ;

    val displayLabel: String get() =
        when (this) {
            ON_DEMAND -> "On demand"
            DAILY -> "Daily"
            WEEKLY -> "Weekly"
            MONTHLY -> "Monthly"
        }

    companion object {
        fun fromToken(token: String?): SubscriptionCadence = values().firstOrNull { it.token == token } ?: WEEKLY
    }
}

data class AgentSubscriptionTopic(
    val agentURI: String,
    val topicID: String,
    val displayName: String,
    val description: String,
    val cadence: SubscriptionCadence,
    val muted: Boolean,
    val deliveryMode: SkillRunDeliveryMode,
    val minimumEventImportance: SkillRunEventImportance,
    val createdAtEpoch: Long,
)

class AgentSubscriptionTopicStore private constructor(context: Context) {
    private val prefs: SharedPreferences =
        context.applicationContext
            .getSharedPreferences("square.subscriptions", Context.MODE_PRIVATE)

    private val _topics = MutableStateFlow<List<AgentSubscriptionTopic>>(emptyList())
    val topics: StateFlow<List<AgentSubscriptionTopic>> = _topics.asStateFlow()

    private val auth = FirebaseAuth.getInstance()
    private val firestore = FirebaseFirestore.getInstance()
    private var authListener: FirebaseAuth.AuthStateListener? = null
    private var firestoreListener: ListenerRegistration? = null
    private val ioScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    init {
        _topics.value = load()
        start()
    }

    fun start() {
        if (authListener != null) return
        val listener =
            FirebaseAuth.AuthStateListener { firebase ->
                restartFirestoreListener(firebase.currentUser?.uid)
            }
        authListener = listener
        auth.addAuthStateListener(listener)
        restartFirestoreListener(auth.currentUser?.uid)
    }

    fun topic(agentURI: String): AgentSubscriptionTopic? = _topics.value.firstOrNull { it.agentURI == agentURI }

    fun subscribe(
        agent: AgentIdentity,
        cadence: SubscriptionCadence,
        deliveryMode: SkillRunDeliveryMode = SkillRunDeliveryMode.ACTION_ONLY,
    ): AgentSubscriptionTopic {
        val now = System.currentTimeMillis()
        val existing = topic(agent.id)
        val updated =
            AgentSubscriptionTopic(
                agentURI = agent.id,
                topicID = DEFAULT_TOPIC_ID,
                displayName = agent.displayName,
                description = "Mission and thread activity digests from ${agent.displayName}.",
                cadence = cadence,
                muted = existing?.muted ?: false,
                deliveryMode = deliveryMode,
                minimumEventImportance = minimumImportance(forMode = deliveryMode),
                createdAtEpoch = existing?.createdAtEpoch ?: now,
            )
        upsert(updated)
        return updated
    }

    fun unsubscribe(agentURI: String) {
        val existing = topic(agentURI)
        _topics.value = _topics.value.filterNot { it.agentURI == agentURI }
        save()
        deleteFirestore(agentURI, existing?.topicID ?: DEFAULT_TOPIC_ID)
    }

    fun setMuted(agentURI: String, muted: Boolean): AgentSubscriptionTopic? {
        val existing = topic(agentURI) ?: return null
        val mode =
            if (muted) {
                SkillRunDeliveryMode.MUTED
            } else if (existing.deliveryMode == SkillRunDeliveryMode.MUTED) {
                SkillRunDeliveryMode.ACTION_ONLY
            } else {
                existing.deliveryMode
            }
        val updated =
            existing.copy(
                muted = muted,
                deliveryMode = mode,
                minimumEventImportance = minimumImportance(forMode = mode),
            )
        upsert(updated)
        return updated
    }

    fun setDeliveryMode(agentURI: String, deliveryMode: SkillRunDeliveryMode): AgentSubscriptionTopic? {
        val existing = topic(agentURI) ?: return null
        val updated =
            existing.copy(
                muted = deliveryMode == SkillRunDeliveryMode.MUTED,
                deliveryMode = deliveryMode,
                minimumEventImportance = minimumImportance(forMode = deliveryMode),
            )
        upsert(updated)
        return updated
    }

    private fun upsert(topic: AgentSubscriptionTopic) {
        val list = _topics.value.toMutableList()
        val idx = list.indexOfFirst { it.agentURI == topic.agentURI }
        if (idx >= 0) list[idx] = topic else list.add(topic)
        _topics.value = list
        save()
        writeFirestore(topic)
    }

    private fun restartFirestoreListener(uid: String?) {
        firestoreListener?.remove()
        firestoreListener = null
        if (uid == null) return
        // Topic display text seals `sealedDisplayName`/`sealedDescription`. Resolve
        // the read key once so the decoder can open them; legacy plaintext docs fall
        // back inside `decodeFirestoreTopic`. The listener is registered after the
        // key resolves so the very first snapshot already decrypts.
        ioScope.launch {
            val vaultKey =
                runCatching {
                    AndroidCloudVaultKeyAccess.keyForReading(uid = uid, firestore = firestore)?.keyData
                }.getOrNull()
            // A newer auth change may have replaced the listener while we resolved;
            // only install if nothing else claimed the slot.
            if (firestoreListener != null) return@launch
            firestoreListener =
                firestore.collection("users").document(uid)
                    .collection("subscription_topics")
                    .orderBy("consentGivenAt")
                    .addSnapshotListener { snapshot, error ->
                        if (error != null || snapshot == null) return@addSnapshotListener
                        val decoded =
                            snapshot.documents.mapNotNull { doc ->
                                val data = doc.data ?: return@mapNotNull null
                                decodeFirestoreTopic(data, vaultKey)
                            }
                        _topics.value = decoded.sortedByDescending { it.createdAtEpoch }
                        save()
                    }
        }
    }

    private fun writeFirestore(topic: AgentSubscriptionTopic) {
        val uid = auth.currentUser?.uid ?: return
        // The display strings echo which agent the user follows (a behavioral
        // fingerprint), so seal `displayName` → `sealedDisplayName` and
        // `description` → `sealedDescription` with the Cloud Vault key before the
        // write, mirroring the budget-rule writer. `agentURI`/`topicID` stay
        // plaintext — they are the routing key and the doc ID is derived from them.
        // If the key is unavailable (device not yet approved) the write degrades to
        // legacy plaintext so subscriptions still sync; a key-holding peer re-seals
        // on its next write.
        ioScope.launch {
            val vaultKey =
                runCatching {
                    AndroidCloudVaultKeyAccess.keyForReading(uid = uid, firestore = firestore)?.keyData
                }.getOrNull()
            val payload =
                mutableMapOf<String, Any>(
                    "agentURI" to topic.agentURI,
                    "topicID" to topic.topicID,
                    "cadence" to topic.cadence.token,
                    "consentGivenAt" to topic.createdAtEpoch,
                    "isMuted" to topic.muted,
                    "deliveryMode" to topic.deliveryMode.wire,
                    "minimumEventImportance" to topic.minimumEventImportance.wire,
                    "deliveryCountThisMonth" to 0,
                    "updatedAt" to FieldValue.serverTimestamp(),
                )
            if (vaultKey != null) {
                payload["sealedDisplayName"] = CloudVaultSealedTextCodec.toMap(CloudVaultCrypto.sealText(topic.displayName, vaultKey))
                payload["sealedDescription"] = CloudVaultSealedTextCodec.toMap(CloudVaultCrypto.sealText(topic.description, vaultKey))
                // Strip any legacy plaintext a prior client merged in.
                payload["displayName"] = FieldValue.delete()
                payload["description"] = FieldValue.delete()
            } else {
                payload["displayName"] = topic.displayName
                payload["description"] = topic.description
            }
            firestore.collection("users").document(uid)
                .collection("subscription_topics")
                .document(documentID(topic.agentURI, topic.topicID))
                .set(payload, com.google.firebase.firestore.SetOptions.merge())
        }
    }

    private fun deleteFirestore(agentURI: String, topicID: String) {
        val uid = auth.currentUser?.uid ?: return
        firestore.collection("users").document(uid)
            .collection("subscription_topics")
            .document(documentID(agentURI, topicID))
            .delete()
    }

    private fun decodeFirestoreTopic(data: Map<String, Any>, vaultKey: ByteArray? = null): AgentSubscriptionTopic? {
        val agentURI = (data["agentURI"] as? String)?.takeIf { it.isNotBlank() } ?: return null
        val topicID = (data["topicID"] as? String)?.takeIf { it.isNotBlank() } ?: DEFAULT_TOPIC_ID
        val mode = SkillRunDeliveryMode.fromWire(data["deliveryMode"] as? String)
        val (displayName, description) = decodeSubscriptionTopicDisplay(data, vaultKey)
        return AgentSubscriptionTopic(
            agentURI = agentURI,
            topicID = topicID,
            displayName = displayName?.takeIf { it.isNotBlank() } ?: agentURI,
            description = description ?: "",
            cadence = SubscriptionCadence.fromToken(data["cadence"] as? String),
            muted = data["isMuted"] as? Boolean ?: (mode == SkillRunDeliveryMode.MUTED),
            deliveryMode = mode,
            minimumEventImportance = SkillRunEventImportance.fromWire(data["minimumEventImportance"] as? String),
            createdAtEpoch = decodeEpoch(data["consentGivenAt"]) ?: System.currentTimeMillis(),
        )
    }

    private fun load(): List<AgentSubscriptionTopic> {
        val raw = prefs.getString(KEY_TOPICS, null) ?: return emptyList()
        return runCatching {
            val arr = JSONArray(raw)
            (0 until arr.length()).mapNotNull { i ->
                val obj = arr.getJSONObject(i)
                AgentSubscriptionTopic(
                    agentURI = obj.optString("agentURI").takeIf { it.isNotBlank() } ?: return@mapNotNull null,
                    topicID = obj.optString("topicID").takeIf { it.isNotBlank() } ?: DEFAULT_TOPIC_ID,
                    displayName = obj.optString("displayName"),
                    description = obj.optString("description"),
                    cadence = SubscriptionCadence.fromToken(obj.optString("cadence")),
                    muted = obj.optBoolean("muted", false),
                    deliveryMode = SkillRunDeliveryMode.fromWire(obj.optString("deliveryMode")),
                    minimumEventImportance = SkillRunEventImportance.fromWire(obj.optString("minimumEventImportance")),
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
            obj.put("topicID", t.topicID)
            obj.put("displayName", t.displayName)
            obj.put("description", t.description)
            obj.put("cadence", t.cadence.token)
            obj.put("muted", t.muted)
            obj.put("deliveryMode", t.deliveryMode.wire)
            obj.put("minimumEventImportance", t.minimumEventImportance.wire)
            obj.put("createdAt", t.createdAtEpoch)
            arr.put(obj)
        }
        prefs.edit().putString(KEY_TOPICS, arr.toString()).apply()
    }

    companion object {
        private const val KEY_TOPICS = "topics.v1"
        const val DEFAULT_TOPIC_ID = "agent-updates"

        @Volatile private var instance: AgentSubscriptionTopicStore? = null

        fun shared(context: Context): AgentSubscriptionTopicStore = instance ?: synchronized(this) {
            instance ?: AgentSubscriptionTopicStore(context).also { instance = it }
        }

        fun documentID(agentURI: String, topicID: String): String = "$agentURI:$topicID"
            .replace("/", "_")
            .replace(":", "_")

        private fun minimumImportance(forMode: SkillRunDeliveryMode): SkillRunEventImportance = if (forMode == SkillRunDeliveryMode.FULL_STREAM) {
            SkillRunEventImportance.NORMAL
        } else {
            SkillRunEventImportance.ACTION_REQUIRED
        }

        private fun decodeEpoch(raw: Any?): Long? = when (raw) {
            is Number -> raw.toLong()
            is com.google.firebase.Timestamp -> raw.toDate().time
            is java.util.Date -> raw.time
            is String -> raw.toLongOrNull()
            else -> null
        }
    }
}

/**
 * Resolves the topic display strings sealed-first: open `sealedDisplayName` /
 * `sealedDescription` with the Cloud Vault key, then fall back to legacy plaintext
 * `displayName` / `description` for in-flight docs (CONTRACT legacy fallback).
 * Lifted to a top-level `internal` seam so the privacy round-trip is unit-testable
 * without the Firestore listener / Android keystore. Returns `(displayName,
 * description)` — either may be null when neither the sealed nor the legacy field
 * is present/openable.
 */
internal fun decodeSubscriptionTopicDisplay(
    data: Map<String, Any?>,
    vaultKey: ByteArray?,
): Pair<String?, String?> {
    val displayName =
        CloudVaultSealedTextCodec.open(data["sealedDisplayName"], vaultKey)
            ?: data["displayName"] as? String
    val description =
        CloudVaultSealedTextCodec.open(data["sealedDescription"], vaultKey)
            ?: data["description"] as? String
    return displayName to description
}
