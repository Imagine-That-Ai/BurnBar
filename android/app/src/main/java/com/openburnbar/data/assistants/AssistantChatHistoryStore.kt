package com.openburnbar.data.assistants

import android.content.Context
import android.util.Log
import com.google.firebase.Timestamp
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.auth.FirebaseUser
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.Query
import com.google.firebase.firestore.ktx.firestore
import com.google.firebase.ktx.Firebase
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.tasks.await
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.File
import java.util.Date
import java.util.UUID

/**
 * Persisted shape of a single assistant chat thread on Android. Matches the
 * iOS `MobileChatThread` so the same Firestore documents round-trip.
 */
@Serializable
data class AssistantChatThread(
    val id: String,
    val runtime: String,            // "hermes" or "pi"
    var title: String,
    var preview: String,
    var modelName: String? = null,
    var createdAtMillis: Long,
    var updatedAtMillis: Long,
    var messages: List<AssistantChatMessage> = emptyList()
) {
    val messageCount: Int get() = messages.size
}

@Serializable
data class AssistantChatMessage(
    val id: String = UUID.randomUUID().toString(),
    val role: String,              // "user" | "assistant" | "system"
    var text: String,
    var timestampMillis: Long,
    var modelName: String? = null,
    var isError: Boolean = false,
    var attachments: List<AssistantChatAttachment> = emptyList(),
    var hermes: AssistantChatHermesMetadata? = null
)

@Serializable
data class AssistantChatAttachment(
    val id: String,
    val kind: String,
    val displayName: String,
    val mimeType: String,
    val byteSize: Long,
    val workspaceRelativePath: String,
    val extractedTextPreview: String? = null
)

@Serializable
data class AssistantChatHermesMetadata(
    val requestedModelID: String? = null,
    val responseModelID: String? = null,
    val toolCalls: List<AssistantChatToolCall> = emptyList(),
    val usage: AssistantChatTokenUsage? = null
)

@Serializable
data class AssistantChatToolCall(
    val id: String,
    val name: String,
    val status: String
)

@Serializable
data class AssistantChatTokenUsage(
    val outputTokens: Int? = null,
    val totalTokens: Int? = null,
    val source: String? = null,
    val providerGenerationDurationSeconds: Double? = null,
    val providerTotalDurationSeconds: Double? = null,
    val responseStartedAtMillis: Long? = null,
    val firstResponseChunkAtMillis: Long? = null,
    val responseCompletedAtMillis: Long? = null
)

/**
 * Disk envelope: thread list + tombstones. Tombstones survive a cloud refresh
 * so a delete made offline isn't silently undone when the next sync pulls a
 * stale remote copy.
 */
@Serializable
data class AssistantChatHistorySnapshot(
    val threads: List<AssistantChatThread> = emptyList(),
    val tombstones: Map<String, Long> = emptyMap()
)

/**
 * Persistence boundary — splittable for tests.
 */
interface AssistantChatLocalStore {
    fun setActivePartition(key: String)
    fun load(): AssistantChatHistorySnapshot
    fun save(snapshot: AssistantChatHistorySnapshot)
}

interface AssistantChatCloudMirror {
    val isAvailable: Boolean
    val currentUserID: String?
    suspend fun upsert(thread: AssistantChatThread)
    suspend fun delete(threadID: String)
    suspend fun fetchAll(): List<AssistantChatThread>
}

/**
 * Owning store for Android's assistant chat history. Source of truth for the
 * list views; both `HermesService` and `PiService` write through `upsert` after
 * every send + after every streaming response completes.
 *
 * Per-uid partitioning, tombstone-based deletes, and offline backfill mirror
 * the iOS implementation so the same `users/{uid}/mobile_assistant_chats`
 * Firestore documents round-trip across surfaces.
 */
class AssistantChatHistoryStore internal constructor(
    private val local: AssistantChatLocalStore,
    private val cloud: AssistantChatCloudMirror?,
    private val scope: CoroutineScope = CoroutineScope(Dispatchers.IO + SupervisorJob())
) {
    private val tag = "AssistantChatHistory"
    private val mutex = Mutex()

    private val _threads = MutableStateFlow<List<AssistantChatThread>>(emptyList())
    val threads: StateFlow<List<AssistantChatThread>> = _threads.asStateFlow()

    private val _lastSyncError = MutableStateFlow<String?>(null)
    val lastSyncError: StateFlow<String?> = _lastSyncError.asStateFlow()

    private var tombstones: MutableMap<String, Long> = mutableMapOf()
    private var didLoadFromDisk = false
    private var activePartition: String = ""

    private val pendingMirrors = mutableMapOf<String, Job>()
    private val pendingMirrorsLock = Any()

    init {
        switchPartition(cloud?.currentUserID)
    }

    fun threadsFor(runtime: String): List<AssistantChatThread> =
        _threads.value.filter { it.runtime == runtime }

    fun thread(id: String): AssistantChatThread? =
        _threads.value.firstOrNull { it.id == id }

    /** Idempotent — safe on every app launch. */
    fun bootstrap() {
        loadFromDiskIfNeeded()
        scope.launch { refreshFromCloud() }
    }

    fun loadFromDiskIfNeeded() {
        if (didLoadFromDisk) return
        didLoadFromDisk = true
        runCatching { local.load() }
            .onSuccess { snapshot ->
                tombstones = snapshot.tombstones.toMutableMap()
                _threads.value = sorted(snapshot.threads.filter { it.id !in tombstones })
            }
            .onFailure {
                Log.w(tag, "Failed to load chat history from disk", it)
                tombstones = mutableMapOf()
                _threads.value = emptyList()
            }
    }

    suspend fun refreshFromCloud() {
        val cloud = cloud ?: return
        if (!cloud.isAvailable) return

        val remote: List<AssistantChatThread> = try {
            cloud.fetchAll()
        } catch (e: Exception) {
            _lastSyncError.value = e.message
            Log.w(tag, "Refresh from cloud failed", e)
            return
        }

        mutex.withLock {
            val filteredRemote = remote.filter { it.id !in tombstones }
            val merged = merge(local = _threads.value, remote = filteredRemote)
            _threads.value = merged
            saveLocally()
            _lastSyncError.value = null

            val remoteIDs = remote.map { it.id }.toSet()
            for (thread in merged.filter { it.id !in remoteIDs }) {
                scheduleCloudMirror(thread, immediate = true)
            }

            val tombstonedRemote = remoteIDs.intersect(tombstones.keys)
            for (id in tombstonedRemote) {
                scope.launch {
                    try {
                        cloud.delete(id)
                        clearTombstone(id)
                    } catch (_: Exception) {
                        // Stays in the tombstone set; retried next refresh.
                    }
                }
            }
            val neverInCloud = tombstones.keys.filter { it !in remoteIDs }
            if (neverInCloud.isNotEmpty()) {
                for (id in neverInCloud) tombstones.remove(id)
                saveLocally()
            }
        }
    }

    fun upsert(thread: AssistantChatThread) {
        if (thread.id in tombstones) return  // Refuse resurrection.
        val updated = thread.copy(updatedAtMillis = System.currentTimeMillis())
        val current = _threads.value.toMutableList()
        val idx = current.indexOfFirst { it.id == updated.id }
        if (idx >= 0) current[idx] = updated else current.add(updated)
        _threads.value = sorted(current)
        saveLocally()
        scheduleCloudMirror(updated)
    }

    fun delete(threadID: String) {
        _threads.value = _threads.value.filterNot { it.id == threadID }
        tombstones[threadID] = System.currentTimeMillis()
        saveLocally()

        val cloud = cloud ?: return
        scope.launch {
            try {
                cloud.delete(threadID)
                clearTombstone(threadID)
            } catch (_: Exception) {
                // Tombstone retried on next bootstrap.
            }
        }
    }

    fun switchPartition(uid: String?) {
        val raw = if (uid.isNullOrEmpty()) "local" else uid
        val sanitized = sanitizePartitionKey(raw)
        if (sanitized == activePartition) return
        activePartition = sanitized
        local.setActivePartition(sanitized)
        didLoadFromDisk = false
        _threads.value = emptyList()
        tombstones = mutableMapOf()
        loadFromDiskIfNeeded()
    }

    /** Subscribe to Firebase auth changes so the partition follows the signed-in user. */
    fun attachAuthListener(auth: FirebaseAuth = FirebaseAuth.getInstance()) {
        auth.addAuthStateListener { state ->
            val user: FirebaseUser? = state.currentUser
            switchPartition(user?.uid)
            scope.launch { refreshFromCloud() }
        }
    }

    // MARK: - Internals

    private fun clearTombstone(id: String) {
        if (tombstones.remove(id) != null) saveLocally()
    }

    private fun saveLocally() {
        runCatching {
            local.save(AssistantChatHistorySnapshot(_threads.value, tombstones.toMap()))
        }.onFailure { Log.e(tag, "Failed to save chat history", it) }
    }

    private fun scheduleCloudMirror(thread: AssistantChatThread, immediate: Boolean = false) {
        val cloud = cloud ?: return
        val job = scope.launch {
            if (!immediate) delay(600)
            try {
                cloud.upsert(thread)
                synchronized(pendingMirrorsLock) { pendingMirrors.remove(thread.id) }
            } catch (e: Exception) {
                _lastSyncError.value = e.message
            }
        }
        synchronized(pendingMirrorsLock) {
            pendingMirrors[thread.id]?.cancel()
            pendingMirrors[thread.id] = job
        }
    }

    companion object {
        private val sanitizeRegex = Regex("[^A-Za-z0-9_-]")

        fun sanitizePartitionKey(raw: String): String {
            val cleaned = raw.replace(sanitizeRegex, "-").trim('-')
            return if (cleaned.isEmpty()) "local" else cleaned
        }

        fun sorted(threads: List<AssistantChatThread>): List<AssistantChatThread> =
            threads.sortedByDescending { it.updatedAtMillis }

        fun merge(
            local: List<AssistantChatThread>,
            remote: List<AssistantChatThread>
        ): List<AssistantChatThread> {
            val byID = local.associateBy { it.id }.toMutableMap()
            for (thread in remote) {
                val existing = byID[thread.id]
                byID[thread.id] = if (existing == null) {
                    thread
                } else if (existing.updatedAtMillis >= thread.updatedAtMillis) {
                    existing
                } else {
                    thread
                }
            }
            return sorted(byID.values.toList())
        }

        @Volatile private var INSTANCE: AssistantChatHistoryStore? = null

        /**
         * Process-wide singleton. The first call wires up the real
         * file + Firestore stores. Subsequent calls return the cached instance.
         */
        fun shared(context: Context): AssistantChatHistoryStore {
            val cached = INSTANCE
            if (cached != null) return cached
            synchronized(this) {
                val again = INSTANCE
                if (again != null) return again
                val store = AssistantChatHistoryStore(
                    local = AssistantChatFileLocalStore(context.applicationContext),
                    cloud = AssistantChatFirestoreMirror()
                )
                store.attachAuthListener()
                INSTANCE = store
                return store
            }
        }
    }
}

/**
 * JSON-on-disk persistence under the app's files dir. One file per partition
 * key (typically a Firebase uid, or `"local"` when signed out).
 */
internal class AssistantChatFileLocalStore(context: Context) : AssistantChatLocalStore {
    private val directory: File = File(context.filesDir, "assistant-chat-history").apply { mkdirs() }
    private var partitionKey: String = "local"
    private val json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
        prettyPrint = true
    }

    override fun setActivePartition(key: String) {
        partitionKey = key
    }

    override fun load(): AssistantChatHistorySnapshot {
        val file = fileFor(partitionKey)
        if (!file.exists()) return AssistantChatHistorySnapshot()
        return runCatching {
            json.decodeFromString<AssistantChatHistorySnapshot>(file.readText())
        }.getOrElse {
            // Legacy shape: a bare list of threads.
            runCatching {
                val threads = json.decodeFromString<List<AssistantChatThread>>(file.readText())
                AssistantChatHistorySnapshot(threads = threads)
            }.getOrDefault(AssistantChatHistorySnapshot())
        }
    }

    override fun save(snapshot: AssistantChatHistorySnapshot) {
        val tmp = File(directory, "${fileNameFor(partitionKey)}.tmp")
        tmp.writeText(json.encodeToString(snapshot))
        if (!tmp.renameTo(fileFor(partitionKey))) {
            // Some filesystems refuse rename if target exists.
            fileFor(partitionKey).delete()
            tmp.renameTo(fileFor(partitionKey))
        }
    }

    private fun fileNameFor(partition: String): String =
        "assistant-chat-history-${AssistantChatHistoryStore.sanitizePartitionKey(partition)}.json"

    private fun fileFor(partition: String): File = File(directory, fileNameFor(partition))
}

/**
 * Mirrors threads to `users/{uid}/mobile_assistant_chats/{threadId}` — same
 * Firestore documents the iOS app reads, so chats round-trip across surfaces.
 */
internal class AssistantChatFirestoreMirror(
    private val firestore: FirebaseFirestore = Firebase.firestore,
    private val auth: FirebaseAuth = FirebaseAuth.getInstance()
) : AssistantChatCloudMirror {

    override val isAvailable: Boolean
        get() = auth.currentUser != null

    override val currentUserID: String?
        get() = auth.currentUser?.uid

    private fun collection(uid: String) =
        firestore.collection("users").document(uid).collection("mobile_assistant_chats")

    private fun requireUID(): String =
        auth.currentUser?.uid ?: throw IllegalStateException("Not signed in")

    override suspend fun upsert(thread: AssistantChatThread) {
        val uid = requireUID()
        val payload = mutableMapOf<String, Any?>(
            "id" to thread.id,
            "runtime" to thread.runtime,
            "title" to thread.title,
            "preview" to thread.preview,
            "modelName" to thread.modelName,
            "createdAt" to Timestamp(Date(thread.createdAtMillis)),
            "updatedAt" to Timestamp(Date(thread.updatedAtMillis)),
            "messageCount" to thread.messageCount,
            "messages" to thread.messages.map(::encodeMessage)
        )
        collection(uid).document(thread.id).set(payload).await()
    }

    override suspend fun delete(threadID: String) {
        val uid = requireUID()
        collection(uid).document(threadID).delete().await()
    }

    override suspend fun fetchAll(): List<AssistantChatThread> {
        val uid = requireUID()
        val snapshot = collection(uid)
            .orderBy("updatedAt", Query.Direction.DESCENDING)
            .limit(200)
            .get()
            .await()
        return snapshot.documents.mapNotNull { document ->
            decodeThread(document.id, document.data ?: return@mapNotNull null)
        }
    }

    private fun encodeMessage(message: AssistantChatMessage): Map<String, Any?> {
        val map = mutableMapOf<String, Any?>(
            "id" to message.id,
            "role" to message.role,
            "text" to message.text,
            "timestamp" to Timestamp(Date(message.timestampMillis)),
            "modelName" to message.modelName,
            "isError" to message.isError
        )
        if (message.attachments.isNotEmpty()) {
            map["attachments"] = message.attachments.map { attachment ->
                mapOf(
                    "id" to attachment.id,
                    "kind" to attachment.kind,
                    "displayName" to attachment.displayName,
                    "mimeType" to attachment.mimeType,
                    "byteSize" to attachment.byteSize,
                    "workspaceRelativePath" to attachment.workspaceRelativePath,
                    "extractedTextPreview" to attachment.extractedTextPreview
                )
            }
        }
        message.hermes?.let { hermes ->
            val dict = mutableMapOf<String, Any?>()
            hermes.requestedModelID?.let { dict["requestedModelID"] = it }
            hermes.responseModelID?.let { dict["responseModelID"] = it }
            if (hermes.toolCalls.isNotEmpty()) {
                dict["toolCalls"] = hermes.toolCalls.map { mapOf("id" to it.id, "name" to it.name, "status" to it.status) }
            }
            hermes.usage?.let { usage ->
                val u = mutableMapOf<String, Any?>()
                usage.outputTokens?.let { u["outputTokens"] = it }
                usage.totalTokens?.let { u["totalTokens"] = it }
                usage.source?.let { u["source"] = it }
                usage.providerGenerationDurationSeconds?.let { u["providerGenerationDurationSeconds"] = it }
                usage.providerTotalDurationSeconds?.let { u["providerTotalDurationSeconds"] = it }
                usage.responseStartedAtMillis?.let { u["responseStartedAt"] = Timestamp(Date(it)) }
                usage.firstResponseChunkAtMillis?.let { u["firstResponseChunkAt"] = Timestamp(Date(it)) }
                usage.responseCompletedAtMillis?.let { u["responseCompletedAt"] = Timestamp(Date(it)) }
                if (u.isNotEmpty()) dict["usage"] = u
            }
            map["hermes"] = dict
        }
        return map
    }

    @Suppress("UNCHECKED_CAST")
    internal fun decodeThread(documentID: String, data: Map<String, Any?>): AssistantChatThread? {
        val runtime = data["runtime"] as? String ?: return null
        val id = (data["id"] as? String) ?: documentID
        val title = (data["title"] as? String) ?: "Chat"
        val preview = (data["preview"] as? String) ?: ""
        val modelName = data["modelName"] as? String
        val createdAt = (data["createdAt"] as? Timestamp)?.toDate()?.time ?: System.currentTimeMillis()
        val updatedAt = (data["updatedAt"] as? Timestamp)?.toDate()?.time ?: createdAt
        val rawMessages = data["messages"] as? List<Map<String, Any?>> ?: emptyList()
        val messages = rawMessages.mapNotNull(::decodeMessage)
        return AssistantChatThread(
            id = id,
            runtime = runtime,
            title = title,
            preview = preview,
            modelName = modelName,
            createdAtMillis = createdAt,
            updatedAtMillis = updatedAt,
            messages = messages
        )
    }

    @Suppress("UNCHECKED_CAST")
    private fun decodeMessage(raw: Map<String, Any?>): AssistantChatMessage? {
        val role = raw["role"] as? String ?: return null
        val text = raw["text"] as? String ?: return null
        val id = (raw["id"] as? String) ?: UUID.randomUUID().toString()
        val timestamp = (raw["timestamp"] as? Timestamp)?.toDate()?.time ?: System.currentTimeMillis()
        val modelName = raw["modelName"] as? String
        val isError = (raw["isError"] as? Boolean) ?: false

        val attachmentDicts = raw["attachments"] as? List<Map<String, Any?>> ?: emptyList()
        val attachments = attachmentDicts.mapNotNull(::decodeAttachment)

        val hermesDict = raw["hermes"] as? Map<String, Any?>
        val hermes = hermesDict?.let(::decodeHermesMetadata)

        return AssistantChatMessage(
            id = id,
            role = role,
            text = text,
            timestampMillis = timestamp,
            modelName = modelName,
            isError = isError,
            attachments = attachments,
            hermes = hermes
        )
    }

    private fun decodeAttachment(raw: Map<String, Any?>): AssistantChatAttachment? {
        val id = raw["id"] as? String ?: return null
        val kind = raw["kind"] as? String ?: return null
        val displayName = raw["displayName"] as? String ?: return null
        val mimeType = raw["mimeType"] as? String ?: return null
        val byteSize = (raw["byteSize"] as? Number)?.toLong() ?: return null
        val path = raw["workspaceRelativePath"] as? String ?: return null
        return AssistantChatAttachment(
            id = id,
            kind = kind,
            displayName = displayName,
            mimeType = mimeType,
            byteSize = byteSize,
            workspaceRelativePath = path,
            extractedTextPreview = raw["extractedTextPreview"] as? String
        )
    }

    @Suppress("UNCHECKED_CAST")
    private fun decodeHermesMetadata(raw: Map<String, Any?>): AssistantChatHermesMetadata? {
        val requested = raw["requestedModelID"] as? String
        val response = raw["responseModelID"] as? String
        val toolCallDicts = raw["toolCalls"] as? List<Map<String, Any?>> ?: emptyList()
        val toolCalls = toolCallDicts.mapNotNull { tc ->
            val id = tc["id"] as? String ?: return@mapNotNull null
            val name = tc["name"] as? String ?: return@mapNotNull null
            val status = tc["status"] as? String ?: return@mapNotNull null
            AssistantChatToolCall(id, name, status)
        }
        val usageDict = raw["usage"] as? Map<String, Any?>
        val usage = usageDict?.let { dict ->
            AssistantChatTokenUsage(
                outputTokens = (dict["outputTokens"] as? Number)?.toInt(),
                totalTokens = (dict["totalTokens"] as? Number)?.toInt(),
                source = dict["source"] as? String,
                providerGenerationDurationSeconds = (dict["providerGenerationDurationSeconds"] as? Number)?.toDouble(),
                providerTotalDurationSeconds = (dict["providerTotalDurationSeconds"] as? Number)?.toDouble(),
                responseStartedAtMillis = (dict["responseStartedAt"] as? Timestamp)?.toDate()?.time,
                firstResponseChunkAtMillis = (dict["firstResponseChunkAt"] as? Timestamp)?.toDate()?.time,
                responseCompletedAtMillis = (dict["responseCompletedAt"] as? Timestamp)?.toDate()?.time
            )
        }
        if (requested == null && response == null && toolCalls.isEmpty() && usage == null) return null
        return AssistantChatHermesMetadata(requested, response, toolCalls, usage)
    }
}
