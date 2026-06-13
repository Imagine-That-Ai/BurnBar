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
import com.openburnbar.data.cloud.AndroidCloudVaultDeviceKeypair
import com.openburnbar.data.cloud.AndroidCloudVaultKeyAccess
import com.openburnbar.data.cloud.AndroidCloudVaultSignalPayloads
import com.openburnbar.data.cloud.AndroidSignalIdentityKeyStore
import com.openburnbar.data.cloud.AndroidSignalIdentityKeypair
import com.openburnbar.data.cloud.CloudVaultAADContext
import com.openburnbar.data.cloud.CloudVaultCrypto
import com.openburnbar.data.cloud.CloudVaultSealedPayload
import com.openburnbar.data.cloud.SignalAtRestFallbackPolicy
import java.io.File
import java.lang.IllegalStateException
import java.util.Date
import java.util.UUID
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
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

private const val CLOUD_THREAD_FETCH_LIMIT = 200
private const val CLOUD_MIRROR_DEBOUNCE_MS = 600
private const val THREAD_FILE_ESCAPE_RADIX = 16
private const val THREAD_FILE_ESCAPE_HEX_WIDTH = 4

/** Data-domain id whose sealingScheme gates at-rest Signal sealing for chat + CLI. */
private const val SIGNAL_CHAT_DOMAIN = "conversations_chat"

/**
 * Persisted shape of a single assistant chat thread on Android. Matches the
 * iOS `MobileChatThread` so the same Firestore documents round-trip.
 */
@Serializable
data class AssistantChatThread(
    val id: String,
    val runtime: String, // "hermes" or "pi"
    var title: String,
    var preview: String,
    var modelName: String? = null,
    var createdAtMillis: Long,
    var updatedAtMillis: Long,
    var messages: List<AssistantChatMessage> = emptyList(),
    var customTitle: String? = null,
    var labelColorHex: String? = null,
    var isPinned: Boolean = false,
    var priorityOrder: Int? = null,
) {
    val messageCount: Int get() = messages.size
}

@Serializable
data class AssistantChatMessage(
    val id: String = UUID.randomUUID().toString(),
    val role: String, // "user" | "assistant" | "system"
    var text: String,
    var timestampMillis: Long,
    var modelName: String? = null,
    var isError: Boolean = false,
    var attachments: List<AssistantChatAttachment> = emptyList(),
    var hermes: AssistantChatHermesMetadata? = null,
)

@Serializable
data class AssistantChatAttachment(
    val id: String,
    val kind: String,
    val displayName: String,
    val mimeType: String,
    val byteSize: Long,
    val workspaceRelativePath: String,
    val extractedTextPreview: String? = null,
)

@Serializable
data class AssistantChatHermesMetadata(
    val requestedModelID: String? = null,
    val responseModelID: String? = null,
    val toolCalls: List<AssistantChatToolCall> = emptyList(),
    val usage: AssistantChatTokenUsage? = null,
)

@Serializable
data class AssistantChatToolCall(
    val id: String,
    val name: String,
    val status: String,
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
    val responseCompletedAtMillis: Long? = null,
)

/**
 * Disk envelope: thread list + tombstones. Tombstones survive a cloud refresh
 * so a delete made offline isn't silently undone when the next sync pulls a
 * stale remote copy.
 */
@Serializable
data class AssistantChatHistorySnapshot(
    val threads: List<AssistantChatThread> = emptyList(),
    val tombstones: Map<String, Long> = emptyMap(),
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
    private val scope: CoroutineScope = CoroutineScope(Dispatchers.IO + SupervisorJob()),
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

    fun threadsFor(runtime: String): List<AssistantChatThread> = _threads.value.filter { it.runtime == runtime }

    fun thread(id: String): AssistantChatThread? = _threads.value.firstOrNull { it.id == id }

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

        val remote: List<AssistantChatThread> =
            try {
                cloud.fetchAll()
            } catch (e: IllegalStateException) {
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
        if (thread.id in tombstones) return // Refuse resurrection.
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

    fun updateThreadMetadata(id: String, customTitle: String? = null, labelColorHex: String? = null, isPinned: Boolean? = null, priorityOrder: Int? = null) {
        val thread = thread(id) ?: return
        if (customTitle != null) {
            thread.customTitle = customTitle.takeIf { it.isNotEmpty() }
        }
        if (labelColorHex != null) {
            thread.labelColorHex = labelColorHex.takeIf { it != "#NONE#" }
        }
        if (isPinned != null) {
            thread.isPinned = isPinned
        }
        if (priorityOrder != null) {
            thread.priorityOrder = priorityOrder.takeIf { it > 0 }
        }
        upsert(thread)
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

    // Cloud-mirror coroutine converts any producer/Firestore failure into _lastSyncError.
    private fun scheduleCloudMirror(thread: AssistantChatThread, immediate: Boolean = false) {
        val cloud = cloud ?: return
        val job =
            scope.launch {
                if (!immediate) delay(CLOUD_MIRROR_DEBOUNCE_MS.toLong())
                try {
                    cloud.upsert(thread)
                    synchronized(pendingMirrorsLock) { pendingMirrors.remove(thread.id) }
                } catch (e: Exception) {
                    // Surface (not crash) any cloud-mirror error — incl. Signal producer throws
                    // (atRestRecipients fail-closed) and Firestore exceptions — on this
                    // SupervisorJob IO coroutine. Matches the delete/tombstone coroutines.
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

        fun sorted(threads: List<AssistantChatThread>): List<AssistantChatThread> = threads.sortedByDescending { it.updatedAtMillis }

        fun merge(local: List<AssistantChatThread>, remote: List<AssistantChatThread>): List<AssistantChatThread> {
            val byID = local.associateBy { it.id }.toMutableMap()
            for (thread in remote) {
                val existing = byID[thread.id]
                byID[thread.id] =
                    if (existing == null) {
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
                val store =
                    AssistantChatHistoryStore(
                        local = AssistantChatFileLocalStore(context.applicationContext),
                        cloud = AssistantChatFirestoreMirror(),
                    )
                store.attachAuthListener()
                INSTANCE = store
                return store
            }
        }
    }
}

/**
 * Compact metadata index persisted alongside the per-thread body files. Holds
 * only what the conversation list and offline-delete bookkeeping need, so it
 * stays small even as history grows.
 */
@Serializable
private data class AssistantChatHistoryIndex(
    val threadIDs: List<String> = emptyList(),
    val tombstones: Map<String, Long> = emptyMap(),
)

private data class DecodedThreadFile(
    val thread: AssistantChatThread,
    val digest: Int,
)

/**
 * JSON-on-disk persistence under the app's files dir.
 *
 * Storage layout (finding-178 — per-thread split): instead of one monolithic
 * `assistant-chat-history-<partition>.json` rewritten in full on *every* chat
 * turn (O(total history) per turn, single-file blast radius), each partition
 * gets a directory holding:
 *
 *   * `index.json` — a compact metadata index (thread id list + tombstones).
 *   * `thread-<sanitizedID>.json` — one compact file per thread body.
 *
 * A [save] only rewrites the thread files whose serialized body actually
 * changed plus the index, so a streaming turn touches a single small file
 * rather than the whole history. JSON is compact (no `prettyPrint`) to keep the
 * bytes — and the encode cost — minimal. A one-time idempotent migration
 * explodes the legacy single-file snapshot into the new layout. The
 * [AssistantChatLocalStore] protocol surface is unchanged.
 */
internal class AssistantChatFileLocalStore(context: Context) : AssistantChatLocalStore {
    private val root: File = File(context.filesDir, "assistant-chat-history").apply { mkdirs() }
    private var partitionKey: String = "local"
    private val json =
        Json {
            ignoreUnknownKeys = true
            encodeDefaults = true
        }

    /** Per-partition cache of the last-written content hash per thread id, so a
     * [save] can skip rewriting unchanged bodies. Keyed by partition so
     * switching users never cross-contaminates. */
    private val digestCache = mutableMapOf<String, MutableMap<String, Int>>()
    private val migratedPartitions = mutableSetOf<String>()

    override fun setActivePartition(key: String) {
        partitionKey = key
    }

    override fun load(): AssistantChatHistorySnapshot {
        migrateLegacyFileIfNeeded(partitionKey)
        return loadSnapshot(partitionKey)
    }

    override fun save(snapshot: AssistantChatHistorySnapshot) {
        migrateLegacyFileIfNeeded(partitionKey)
        saveSnapshot(snapshot, partitionKey)
    }

    private fun loadSnapshot(partition: String): AssistantChatHistorySnapshot {
        val dir = partitionDir(partition)
        if (!dir.exists()) {
            digestCache[partition] = mutableMapOf()
            return AssistantChatHistorySnapshot()
        }
        val index = loadIndex(partition)
        val threads = mutableListOf<AssistantChatThread>()
        val digests = mutableMapOf<String, Int>()
        for (decoded in index.threadIDs.mapNotNull { loadThreadFile(partition, it) }) {
            threads.add(decoded.thread)
            digests[decoded.thread.id] = decoded.digest
        }
        digestCache[partition] = digests
        return AssistantChatHistorySnapshot(threads = threads, tombstones = index.tombstones)
    }

    private fun loadThreadFile(partition: String, threadID: String): DecodedThreadFile? {
        val file = threadFile(partition, threadID)
        if (!file.exists()) return null
        val text = runCatching { file.readText() }.getOrNull() ?: return null
        val thread = runCatching { json.decodeFromString<AssistantChatThread>(text) }.getOrNull() ?: return null
        return DecodedThreadFile(thread = thread, digest = text.hashCode())
    }

    private fun saveSnapshot(snapshot: AssistantChatHistorySnapshot, partition: String) {
        val dir = partitionDir(partition).apply { mkdirs() }
        val previousDigests = digestCache[partition] ?: loadDigestsFromDisk(partition)
        val nextDigests = mutableMapOf<String, Int>()
        val liveIDs = snapshot.threads.map { it.id }.toSet()

        // 1. Write only the thread bodies whose serialized content changed.
        for (thread in snapshot.threads) {
            val text = json.encodeToString(thread)
            val digest = text.hashCode()
            nextDigests[thread.id] = digest
            val file = threadFile(partition, thread.id)
            if (previousDigests[thread.id] == digest && file.exists()) continue
            atomicWrite(dir, file, text)
        }

        // 2. Remove thread files no longer part of the snapshot.
        for (staleID in previousDigests.keys) {
            if (staleID !in liveIDs) threadFile(partition, staleID).delete()
        }

        // 3. Rewrite the small index (cheap regardless of history size).
        val index = AssistantChatHistoryIndex(threadIDs = snapshot.threads.map { it.id }, tombstones = snapshot.tombstones)
        atomicWrite(dir, indexFile(partition), json.encodeToString(index))

        digestCache[partition] = nextDigests
    }

    private fun loadIndex(partition: String): AssistantChatHistoryIndex {
        val file = indexFile(partition)
        if (!file.exists()) {
            // No index but the directory exists — recover by scanning thread files.
            return AssistantChatHistoryIndex(threadIDs = scanThreadIDs(partition))
        }
        return runCatching { json.decodeFromString<AssistantChatHistoryIndex>(file.readText()) }
            .getOrElse { AssistantChatHistoryIndex(threadIDs = scanThreadIDs(partition)) }
    }

    private fun loadDigestsFromDisk(partition: String): MutableMap<String, Int> {
        val dir = partitionDir(partition)
        if (!dir.exists()) return mutableMapOf()
        val digests = mutableMapOf<String, Int>()
        val ids = loadIndex(partition).threadIDs.ifEmpty { scanThreadIDs(partition) }
        for (threadID in ids) {
            val text = runCatching { threadFile(partition, threadID).readText() }.getOrNull() ?: continue
            digests[threadID] = text.hashCode()
        }
        return digests
    }

    private fun scanThreadIDs(partition: String): List<String> {
        val dir = partitionDir(partition)
        val names = dir.list() ?: return emptyList()
        return names.mapNotNull { name ->
            if (name.startsWith("thread-") && name.endsWith(".json")) {
                name.removePrefix("thread-").removeSuffix(".json")
            } else {
                null
            }
        }
    }

    /**
     * One-time idempotent migration: explode the legacy single-file snapshot
     * (`assistant-chat-history-<partition>.json`, either the envelope shape or a
     * bare thread array) into the per-thread directory layout. Safe to run twice
     * — the legacy file is consumed after the new layout is durably written, and
     * a partition that already has an index treats the legacy file as stale.
     */
    private fun migrateLegacyFileIfNeeded(partition: String) {
        if (partition in migratedPartitions) return
        migratedPartitions.add(partition)

        val legacy = legacyFile(partition)
        if (!legacy.exists()) return

        // New layout already authoritative — drop the stale legacy file.
        if (indexFile(partition).exists()) {
            legacy.delete()
            return
        }

        val text = runCatching { legacy.readText() }.getOrNull() ?: return
        val snapshot =
            runCatching { json.decodeFromString<AssistantChatHistorySnapshot>(text) }
                .getOrElse {
                    runCatching {
                        AssistantChatHistorySnapshot(threads = json.decodeFromString<List<AssistantChatThread>>(text))
                    }.getOrNull()
                } ?: run {
                    // Unreadable legacy file: leave it rather than lose data.
                    digestCache[partition] = mutableMapOf()
                    return
                }

        digestCache[partition] = mutableMapOf()
        saveSnapshot(snapshot, partition)
        legacy.delete()
    }

    private fun atomicWrite(dir: File, target: File, text: String) {
        val tmp = File(dir, "${target.name}.tmp")
        tmp.writeText(text)
        if (!tmp.renameTo(target)) {
            // Some filesystems refuse rename if the target exists.
            target.delete()
            tmp.renameTo(target)
        }
    }

    private fun partitionDir(partition: String): File =
        File(root, "partition-${AssistantChatHistoryStore.sanitizePartitionKey(partition)}")

    private fun indexFile(partition: String): File = File(partitionDir(partition), "index.json")

    private fun threadFile(partition: String, threadID: String): File =
        File(partitionDir(partition), "thread-${sanitizeThreadFileComponent(threadID)}.json")

    private fun legacyFile(partition: String): File =
        File(root, "assistant-chat-history-${AssistantChatHistoryStore.sanitizePartitionKey(partition)}.json")

    companion object {
        /** Filesystem-safe, 1:1-reversible-via-index thread file component. */
        fun sanitizeThreadFileComponent(raw: String): String {
            val out =
                buildString {
                    for (ch in raw) {
                        if (isSafeThreadFileChar(ch)) {
                            append(ch)
                        } else {
                            append("_").append(
                                ch.code.toString(THREAD_FILE_ESCAPE_RADIX).padStart(THREAD_FILE_ESCAPE_HEX_WIDTH, '0'),
                            )
                        }
                    }
                }
            return out.ifEmpty { "_thread" }
        }

        private fun isSafeThreadFileChar(ch: Char): Boolean =
            isAsciiAlphanumeric(ch) || ch == '_' || ch == '-'

        private fun isAsciiAlphanumeric(ch: Char): Boolean =
            ch in 'A'..'Z' || ch in 'a'..'z' || ch in '0'..'9'
    }
}

/**
 * Mirrors threads to `users/{uid}/mobile_assistant_chats/{threadId}` — same
 * Firestore documents the iOS app reads, so chats round-trip across surfaces.
 */
internal class AssistantChatFirestoreMirror(
    private val firestore: FirebaseFirestore = Firebase.firestore,
    private val auth: FirebaseAuth = FirebaseAuth.getInstance(),
) : AssistantChatCloudMirror {
    private val json =
        Json {
            ignoreUnknownKeys = true
            encodeDefaults = true
        }

    override val isAvailable: Boolean
        get() = auth.currentUser != null

    override val currentUserID: String?
        get() = auth.currentUser?.uid

    private fun collection(uid: String) = firestore.collection("users").document(uid).collection("mobile_assistant_chats")

    private fun requireUID(): String = auth.currentUser?.uid ?: error("Not signed in")

    override suspend fun upsert(thread: AssistantChatThread) {
        val uid = requireUID()
        val resolvedKey = AndroidCloudVaultKeyAccess.keyForWriting(uid = uid, firestore = firestore)
        val plaintextBytes = json.encodeToString(thread).toByteArray(Charsets.UTF_8)
        // RR-8 cross-platform parity: bind the payload to its Firestore path with the SAME AAD
        // context iOS/macOS use (uid|mobile_assistant_chats|threadId|sealedPayload|2|sealedPayload),
        // so a doc written on one platform decrypts on the others. Without this Android wrote a
        // global AAD that iOS path-bound readers — and now this writer's readers — would reject.
        val aadContext =
            CloudVaultAADContext(
                uid = uid,
                collection = "mobile_assistant_chats",
                docID = thread.id,
                field = "sealedPayload",
            )
        val sealedPayload =
            CloudVaultCrypto.sealPayload(
                plaintextBytes,
                resolvedKey.keyData,
                resolvedKey.vaultKeyID,
                aadContext = aadContext,
            )
        val payload = firestorePayload(thread, resolvedKey.vaultKeyID, sealedPayload)
        addSignalEnvelopeIfAvailable(uid, thread.id, plaintextBytes, payload)
        collection(uid).document(thread.id).set(payload).await()
    }

    private fun firestorePayload(
        thread: AssistantChatThread,
        vaultKeyID: String,
        sealedPayload: CloudVaultSealedPayload,
    ): MutableMap<String, Any?> {
        val payload =
            mutableMapOf<String, Any?>(
                "id" to thread.id,
                "runtime" to thread.runtime,
                "createdAt" to Timestamp(Date(thread.createdAtMillis)),
                "updatedAt" to Timestamp(Date(thread.updatedAtMillis)),
                "messageCount" to thread.messageCount,
                "contentSealed" to true,
                "sealedSchemaVersion" to 2,
                "vaultKeyID" to vaultKeyID,
                "sealedPayload" to CloudVaultCrypto.sealedPayloadMap(sealedPayload),
            )
        thread.messages.lastOrNull()?.let { payload["lastMessageRole"] = it.role }
        thread.messages.lastOrNull { it.role == "assistant" }?.let { payload["lastAssistantMessageID"] = it.id }
        if (thread.labelColorHex != null) {
            payload["labelColorHex"] = thread.labelColorHex
        }
        payload["isPinned"] = thread.isPinned
        if (thread.priorityOrder != null) {
            payload["priorityOrder"] = thread.priorityOrder
        }
        return payload
    }

    private suspend fun addSignalEnvelopeIfAvailable(
        uid: String,
        threadID: String,
        plaintextBytes: ByteArray,
        payload: MutableMap<String, Any?>,
    ) {
        // L41/at-rest Signal dual-write (item 3). The legacy AES-GCM "sealedPayload" already
        // in `payload` is the FLOOR; the additive "signalEnvelope" is gated by the
        // conversations_chat sealingScheme and is BEST-EFFORT. On ANY seal failure (e.g. a
        // trusted device without a published identity) log and write legacy-only rather than
        // abort the whole write — legacy is already end-to-end so no confidentiality is lost.
        // (.set() below fully overwrites the doc, so an omitted envelope is implicitly cleared.)
        runCatching {
            if (AndroidCloudVaultSignalPayloads.signalSealingIsEnabled(SIGNAL_CHAT_DOMAIN)) {
                val escrow = AndroidCloudVaultDeviceKeypair.loadOrCreate()
                val identity = AndroidSignalIdentityKeyStore.loadOrCreate(escrow.deviceId, escrow.keyVersion)
                AndroidSignalIdentityKeyStore.publishIfNeeded(
                    uid = uid, deviceId = escrow.deviceId, identity = identity, firestore = firestore,
                )
                val recipients =
                    AndroidCloudVaultSignalPayloads.atRestRecipients(uid = uid, firestore = firestore, localIdentity = identity)
                AndroidCloudVaultSignalPayloads.signalEnvelopeMapIfEnabled(
                    AndroidCloudVaultSignalPayloads.SignalEnvelopeMapRequest(
                        domainID = SIGNAL_CHAT_DOMAIN,
                        uid = uid,
                        collection = "mobile_assistant_chats",
                        docId = threadID,
                        plaintext = plaintextBytes,
                        localIdentity = identity,
                        otherRecipients = recipients,
                    ),
                )?.let { payload["signalEnvelope"] = it }
            }
        }.onFailure { Log.w("AssistantChatFirestoreMirror", "Signal at-rest seal failed; writing chat legacy-only", it) }
    }

    override suspend fun delete(threadID: String) {
        val uid = requireUID()
        collection(uid).document(threadID).delete().await()
    }

    override suspend fun fetchAll(): List<AssistantChatThread> {
        val uid = requireUID()
        val key = AndroidCloudVaultKeyAccess.keyForReading(uid = uid, firestore = firestore)
        // Local-only (no network): null until the device has generated a Signal identity,
        // which only happens once at-rest Signal sealing is activated.
        val signalIdentity =
            runCatching {
                val escrow = AndroidCloudVaultDeviceKeypair.loadOrCreate()
                AndroidSignalIdentityKeyStore.load(escrow.deviceId, escrow.keyVersion)
            }.getOrNull()
        // RR-7a sender-auth: resolve the PINNED trusted-sender public keys once (local identity +
        // every trusted escrow device's published identity) so cross-device envelopes verify their
        // sender signature fail-closed. Best-effort — local identity always present; a partial set
        // is treated as `senderSetComplete = false` by the fallback policy.
        val trustedSenders =
            signalIdentity?.let {
                runCatching { AndroidCloudVaultSignalPayloads.trustedSenderPublicKeys(uid = uid, firestore = firestore, localIdentity = it) }.getOrNull()
            } ?: emptyMap()
        val snapshot =
            collection(uid)
                .orderBy("updatedAt", Query.Direction.DESCENDING)
                .limit(CLOUD_THREAD_FETCH_LIMIT.toLong())
                .get()
                .await()
        return snapshot.documents.mapNotNull { document ->
            decodeThread(document.id, document.data ?: return@mapNotNull null, key?.keyData, uid, signalIdentity, trustedSenders)
        }
    }

    /** Outcome of the Signal-first decode: a decoded thread, a fail-closed drop, or fall through to legacy. */
    private sealed interface SignalFirstDecode {
        data class Decoded(val thread: AssistantChatThread) : SignalFirstDecode

        object FailClosed : SignalFirstDecode

        object FallThrough : SignalFirstDecode
    }

    /**
     * Signal-first open (item 3). Rollout compatibility: direct client writes carry the legacy
     * AES-GCM "sealedPayload" alongside the optional Signal envelope until Phase-E. RR-7a sender-auth:
     * a sender-auth failure (stripped/forged/untrusted block) or a relocated binding must NOT
     * downgrade to the unauthenticated legacy payload — route every failure through
     * [SignalAtRestFallbackPolicy] and fall through only when it permits. `senderSetComplete` is true
     * once the local identity resolved at least one cross-device sender (a non-trivial set).
     */
    private fun decodeSignalThread(
        documentID: String,
        data: Map<String, Any?>,
        uid: String?,
        signalIdentity: AndroidSignalIdentityKeypair?,
        trustedSenderPublicKeys: Map<String, ByteArray>,
    ): SignalFirstDecode {
        if (data["signalEnvelope"] == null || uid == null) return SignalFirstDecode.FallThrough
        val senderSetComplete = trustedSenderPublicKeys.size > 1
        val result =
            runCatching {
                AndroidCloudVaultSignalPayloads.openSignalPayloadIfPresent(
                    data = data,
                    uid = uid,
                    collection = "mobile_assistant_chats",
                    docId = documentID,
                    localIdentity = signalIdentity,
                    trustedSenderPublicKeys = trustedSenderPublicKeys,
                )?.let { json.decodeFromString<AssistantChatThread>(it.toString(Charsets.UTF_8)) }
            }
        result.getOrNull()?.let { return SignalFirstDecode.Decoded(it) }
        val error = result.exceptionOrNull() ?: return SignalFirstDecode.FallThrough
        if (!SignalAtRestFallbackPolicy.allowsLegacyAtRestFallback(error, senderSetComplete)) {
            Log.w("AssistantChatFirestoreMirror", "Signal at-rest open failed closed; dropping thread", error)
            return SignalFirstDecode.FailClosed
        }
        return SignalFirstDecode.FallThrough
    }

    // Sequential guard clauses; single-exit rewrite obscures the precedence order.
    internal fun decodeThread(
        documentID: String,
        data: Map<String, Any?>,
        vaultKey: ByteArray? = null,
        uid: String? = null,
        signalIdentity: AndroidSignalIdentityKeypair? = null,
        trustedSenderPublicKeys: Map<String, ByteArray> = emptyMap(),
    ): AssistantChatThread? {
        when (val signalFirst = decodeSignalThread(documentID, data, uid, signalIdentity, trustedSenderPublicKeys)) {
            is SignalFirstDecode.Decoded -> return signalFirst.thread
            SignalFirstDecode.FailClosed -> return null
            SignalFirstDecode.FallThrough -> Unit
        }
        if (data["contentSealed"] == true || data["sealedPayload"] != null) {
            val sealedPayload = CloudVaultCrypto.sealedPayloadFromMap(data["sealedPayload"] as? Map<*, *>) ?: return null
            val key = vaultKey ?: return null
            // RR-8: pass the path-bound AAD context so path-AAD envelopes (written by iOS/macOS, or
            // by this app post-fix) open. openPayload ignores the context for legacy global-AAD docs
            // (it branches on envelope.aad first), so this is safe for old and new documents alike.
            val aadContext =
                uid?.let {
                    runCatching {
                        CloudVaultAADContext(
                            uid = it,
                            collection = "mobile_assistant_chats",
                            docID = documentID,
                            field = "sealedPayload",
                        )
                    }.getOrNull()
                }
            return runCatching {
                json.decodeFromString<AssistantChatThread>(
                    CloudVaultCrypto.openPayload(sealedPayload, key, aadContext = aadContext).toString(Charsets.UTF_8),
                )
            }.getOrNull()
        }
        val runtime = data["runtime"] as? String ?: return null
        val id = data["id"] as? String ?: documentID
        val title = data["title"] as? String ?: "Chat"
        val preview = data["preview"] as? String ?: ""
        val modelName = data["modelName"] as? String
        val createdAt = (data["createdAt"] as? Timestamp)?.toDate()?.time ?: System.currentTimeMillis()
        val updatedAt = (data["updatedAt"] as? Timestamp)?.toDate()?.time ?: createdAt
        val rawMessages = data["messages"].asStringAnyNullableMapList()
        val messages = rawMessages.mapNotNull(::decodeMessage)
        val customTitle = data["customTitle"] as? String
        val labelColorHex = data["labelColorHex"] as? String
        val isPinned = data["isPinned"] as? Boolean ?: false
        val priorityOrder = (data["priorityOrder"] as? Number)?.toInt()
        return AssistantChatThread(
            id = id,
            runtime = runtime,
            title = title,
            preview = preview,
            modelName = modelName,
            createdAtMillis = createdAt,
            updatedAtMillis = updatedAt,
            messages = messages,
            customTitle = customTitle,
            labelColorHex = labelColorHex,
            isPinned = isPinned,
            priorityOrder = priorityOrder,
        )
    }

    private fun decodeMessage(raw: Map<String, Any?>): AssistantChatMessage? {
        val role = raw["role"] as? String ?: return null
        val text = raw["text"] as? String ?: return null
        val id = raw["id"] as? String ?: UUID.randomUUID().toString()
        val timestamp = (raw["timestamp"] as? Timestamp)?.toDate()?.time ?: System.currentTimeMillis()
        val modelName = raw["modelName"] as? String
        val isError = raw["isError"] as? Boolean ?: false

        val attachmentDicts = raw["attachments"].asStringAnyNullableMapList()
        val attachments = attachmentDicts.mapNotNull(::decodeAttachment)

        val hermesDict = raw["hermes"].asStringAnyNullableMap()
        val hermes = hermesDict?.let(::decodeHermesMetadata)

        return AssistantChatMessage(
            id = id,
            role = role,
            text = text,
            timestampMillis = timestamp,
            modelName = modelName,
            isError = isError,
            attachments = attachments,
            hermes = hermes,
        )
    }

    private fun decodeAttachment(raw: Map<String, Any?>): AssistantChatAttachment? {
        val id = raw["id"] as? String
        val kind = raw["kind"] as? String
        val displayName = raw["displayName"] as? String
        val mimeType = raw["mimeType"] as? String
        val byteSize = (raw["byteSize"] as? Number)?.toLong()
        val path = raw["workspaceRelativePath"] as? String
        val hasRequiredAttachmentFields =
            id != null &&
                kind != null &&
                displayName != null &&
                mimeType != null &&
                byteSize != null &&
                path != null
        if (!hasRequiredAttachmentFields) {
            return null
        }
        return AssistantChatAttachment(
            id = id,
            kind = kind,
            displayName = displayName,
            mimeType = mimeType,
            byteSize = byteSize,
            workspaceRelativePath = path,
            extractedTextPreview = raw["extractedTextPreview"] as? String,
        )
    }

    private fun decodeHermesMetadata(raw: Map<String, Any?>): AssistantChatHermesMetadata? {
        val requested = raw["requestedModelID"] as? String
        val response = raw["responseModelID"] as? String
        val toolCallDicts = raw["toolCalls"].asStringAnyNullableMapList()
        val toolCalls =
            toolCallDicts.mapNotNull { tc ->
                val id = tc["id"] as? String ?: return@mapNotNull null
                val name = tc["name"] as? String ?: return@mapNotNull null
                val status = tc["status"] as? String ?: return@mapNotNull null
                AssistantChatToolCall(id, name, status)
            }
        val usageDict = raw["usage"].asStringAnyNullableMap()
        val usage =
            usageDict?.let { dict ->
                AssistantChatTokenUsage(
                    outputTokens = (dict["outputTokens"] as? Number)?.toInt(),
                    totalTokens = (dict["totalTokens"] as? Number)?.toInt(),
                    source = dict["source"] as? String,
                    providerGenerationDurationSeconds = (dict["providerGenerationDurationSeconds"] as? Number)?.toDouble(),
                    providerTotalDurationSeconds = (dict["providerTotalDurationSeconds"] as? Number)?.toDouble(),
                    responseStartedAtMillis = (dict["responseStartedAt"] as? Timestamp)?.toDate()?.time,
                    firstResponseChunkAtMillis = (dict["firstResponseChunkAt"] as? Timestamp)?.toDate()?.time,
                    responseCompletedAtMillis = (dict["responseCompletedAt"] as? Timestamp)?.toDate()?.time,
                )
            }
        val hasHermesMetadata =
            requested != null || response != null || toolCalls.isNotEmpty() || usage != null
        if (!hasHermesMetadata) return null
        return AssistantChatHermesMetadata(requested, response, toolCalls, usage)
    }
}

private fun Any?.asStringAnyNullableMap(): Map<String, Any?>? {
    val raw = this as? Map<*, *> ?: return null
    val typed = LinkedHashMap<String, Any?>(raw.size)
    for ((key, value) in raw) {
        typed[key as? String ?: return null] = value
    }
    return typed
}

private fun Any?.asStringAnyNullableMapList(): List<Map<String, Any?>> {
    val raw = this as? List<*> ?: return emptyList()
    return raw.mapNotNull { it.asStringAnyNullableMap() }
}
