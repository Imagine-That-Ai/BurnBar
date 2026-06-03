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
import com.openburnbar.data.cloud.CloudVaultCryptoSearch
import com.openburnbar.data.firebase.CloudVaultSealedTextCodec
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec
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
        // The whole subscription graph is cloaked: seal `displayName`/`description`
        // (the behavioral fingerprint) AND the graph edge `agentURI`/`topicID`
        // (which tells the server which agents the user follows) with the Cloud
        // Vault key, and write under an opaque vault-keyed HMAC doc id. If the key
        // is unavailable (device not yet approved), keep the local preference
        // only; cloud writes are sealed-only.
        ioScope.launch {
            val vaultKey =
                runCatching {
                    AndroidCloudVaultKeyAccess.keyForWriting(uid = uid, firestore = firestore).keyData
                }.getOrNull() ?: return@launch
            val payload = sealedSubscriptionTopicPayload(topic, vaultKey)
            val collection = firestore.collection("users").document(uid)
                .collection("subscription_topics")
            val opaqueDocID = documentID(topic.agentURI, topic.topicID, vaultKey)
            collection.document(opaqueDocID).set(payload, com.google.firebase.firestore.SetOptions.merge())
            legacyCleartextDocumentIDs(topic.agentURI, topic.topicID)
                .filterNot { it == opaqueDocID }
                .forEach { collection.document(it).delete() }
        }
    }

    private fun deleteFirestore(agentURI: String, topicID: String) {
        val uid = auth.currentUser?.uid ?: return
        // The opaque doc id needs the vault key. Resolve the read key (the doc-id
        // key is deterministic for the active vault key) before recomputing the id.
        ioScope.launch {
            val vaultKey =
                runCatching {
                    AndroidCloudVaultKeyAccess.keyForReading(uid = uid, firestore = firestore)?.keyData
                }.getOrNull()
            val collection = firestore.collection("users").document(uid)
                .collection("subscription_topics")
            if (vaultKey != null) {
                collection.document(documentID(agentURI, topicID, vaultKey)).delete()
            }
            legacyCleartextDocumentIDs(agentURI, topicID).forEach { collection.document(it).delete() }
        }
    }

    private fun decodeFirestoreTopic(data: Map<String, Any>, vaultKey: ByteArray? = null): AgentSubscriptionTopic? {
        // Open the sealed graph edge, falling back to legacy plaintext for
        // pre-migration / in-flight docs. Without the key (and no legacy
        // plaintext) the edge cannot resolve and the row is dropped — the graph
        // stays invisible rather than surfacing an opaque doc id.
        val (agentURI, decodedTopicID) = decodeSubscriptionTopicGraph(data, vaultKey)
        if (agentURI.isNullOrBlank()) return null
        val topicID = decodedTopicID?.takeIf { it.isNotBlank() } ?: DEFAULT_TOPIC_ID
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

        private const val SUBSCRIPTION_DOC_ID_INFO = "subscription-topic"
        private const val SUBSCRIPTION_DOC_ID_BYTES = 16
        private const val HEX_BYTE_MASK = 0xff

        /**
         * Opaque, vault-keyed Firestore doc id for a topic. Replaces the legacy
         * human-readable `agentURI:topicID` (with `/`,`:`→`_`) so the server can no
         * longer enumerate which agents the user follows. Deterministic for a given
         * `(agentURI, topicID, vaultKey)` — unsubscribe-by-id and upsert
         * idempotency are preserved.
         *
         * Byte-for-byte parity with iOS `CloudVaultCrypto.subscriptionDocID`:
         * `HKDF<SHA256>(vaultKey, salt = ∅, info = "subscription-topic") →
         * HMAC<SHA256>("agentURI:topicID")`, then `"sub_"` + first 16 bytes as hex.
         */
        fun documentID(agentURI: String, topicID: String, vaultKey: ByteArray): String {
            val docKey =
                CloudVaultCryptoSearch.hkdfSha256(
                    vaultKey,
                    ByteArray(0),
                    SUBSCRIPTION_DOC_ID_INFO.toByteArray(),
                    32,
                )
            val mac = Mac.getInstance("HmacSHA256")
            mac.init(SecretKeySpec(docKey, "HmacSHA256"))
            val digest = mac.doFinal("$agentURI:$topicID".toByteArray(Charsets.UTF_8))
            val hex =
                digest.take(SUBSCRIPTION_DOC_ID_BYTES).joinToString("") {
                    "%02x".format(it.toInt() and HEX_BYTE_MASK)
                }
            return "sub_$hex"
        }

        fun legacyCleartextDocumentIDs(agentURI: String, topicID: String): Set<String> {
            val raw = "$agentURI:$topicID"
            val slashOnly = raw.replace("/", "_")
            val slashAndColon = slashOnly.replace(":", "_")
            val collapsed = Regex("[^A-Za-z0-9._-]+")
                .replace(raw, "_")
                .trim('_')
            return setOf(slashOnly, slashAndColon, collapsed)
                .filter { it.isNotBlank() && !it.contains("/") }
                .toSet()
        }

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
 * Resolves the topic display strings. A present sealed field is authoritative:
 * decrypt it or fail closed; legacy plaintext is used only when the sealed field
 * is absent.
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
        CloudVaultSealedTextCodec.openOrLegacy(data["sealedDisplayName"], vaultKey, data["displayName"] as? String)
    val description =
        CloudVaultSealedTextCodec.openOrLegacy(data["sealedDescription"], vaultKey, data["description"] as? String)
    return displayName to description
}

/**
 * Resolves the subscription graph edge. A present sealed field is authoritative:
 * decrypt it or fail closed; legacy plaintext is used only when the sealed field
 * is absent. Lifted to
 * a top-level `internal` seam so the cloak round-trip is unit-testable without the
 * Firestore listener / Android keystore. Returns `(agentURI, topicID)` — either
 * may be null when neither the sealed nor the legacy field is present/openable
 * (e.g. a sealed doc read before the vault key resolves).
 */
internal fun decodeSubscriptionTopicGraph(
    data: Map<String, Any?>,
    vaultKey: ByteArray?,
): Pair<String?, String?> {
    val agentURI =
        CloudVaultSealedTextCodec.openOrLegacy(data["sealedAgentURI"], vaultKey, data["agentURI"] as? String)
    val topicID =
        CloudVaultSealedTextCodec.openOrLegacy(data["sealedTopicID"], vaultKey, data["topicID"] as? String)
    return agentURI to topicID
}

internal fun sealedSubscriptionTopicPayload(
    topic: AgentSubscriptionTopic,
    vaultKey: ByteArray,
): MutableMap<String, Any> =
    mutableMapOf(
        // The whole subscription graph is cloaked: the graph edge
        // (`agentURI`/`topicID`) and the display text are sealed, and merge
        // writes actively delete any legacy plaintext copies. `cadence`/
        // `consentGivenAt` stay cleartext — server order/filter inputs only.
        "sealedAgentURI" to CloudVaultSealedTextCodec.toMap(CloudVaultCrypto.sealText(topic.agentURI, vaultKey)),
        "sealedTopicID" to CloudVaultSealedTextCodec.toMap(CloudVaultCrypto.sealText(topic.topicID, vaultKey)),
        "cadence" to topic.cadence.token,
        "consentGivenAt" to topic.createdAtEpoch,
        "isMuted" to topic.muted,
        "deliveryMode" to topic.deliveryMode.wire,
        "minimumEventImportance" to topic.minimumEventImportance.wire,
        "deliveryCountThisMonth" to 0,
        "updatedAt" to FieldValue.serverTimestamp(),
        "sealedDisplayName" to CloudVaultSealedTextCodec.toMap(CloudVaultCrypto.sealText(topic.displayName, vaultKey)),
        "sealedDescription" to CloudVaultSealedTextCodec.toMap(CloudVaultCrypto.sealText(topic.description, vaultKey)),
        "agentURI" to FieldValue.delete(),
        "topicID" to FieldValue.delete(),
        "displayName" to FieldValue.delete(),
        "description" to FieldValue.delete(),
    )
