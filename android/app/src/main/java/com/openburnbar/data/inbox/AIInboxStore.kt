package com.openburnbar.data.inbox

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.google.firebase.FirebaseException
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.firestore.FieldValue
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.Query
import com.google.firebase.firestore.SetOptions
import com.openburnbar.data.cloud.AndroidCloudVaultDeviceKeypair
import com.openburnbar.data.cloud.AndroidCloudVaultKeyAccess
import com.openburnbar.data.firebase.FirestoreRepository
import com.openburnbar.data.policy.MobileInboxSelectionPolicy
import com.openburnbar.data.policy.MobileInboxSelectionState
import java.util.Date
import java.util.TimeZone
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.launch
import kotlinx.coroutines.tasks.await

// MARK: - AI Inbox Store (Android)
//
// Owns the two Firestore listeners behind the inbox and nothing else: every
// decision about what the user sees lives in `AIInboxRefreshParts` as pure
// functions. This is a `ViewModel` + `StateFlow` (the `DashboardStore` /
// `ActivityStore` shape) rather than a `mutableStateOf` singleton like
// `ThreadInboxStore`, because the inbox is a top-level tab: it needs
// `viewModelScope` to tear its listeners down when the tab's back-stack entry
// goes away, and the nav host's `saveState`/`restoreState` options then hand the
// same instance back on return. A process-wide singleton would keep both
// listeners registered for the life of the app.

private const val INBOX_ITEM_FETCH_LIMIT = 200L
private const val INBOX_STATE_FETCH_LIMIT = 400L

/** Snooze durations offered in the UI, matching the Mac's menu. */
enum class AIInboxSnoozeInterval(val label: String, val millis: Long) {
    HOUR("Snooze for an hour", 60L * 60L * 1000L),
    TOMORROW("Snooze until tomorrow", 24L * 60L * 60L * 1000L),
    WEEK("Snooze for a week", 7L * 24L * 60L * 60L * 1000L),
}

class AIInboxStore(
    private val firestore: FirebaseFirestore = FirestoreRepository.database(),
    private val auth: FirebaseAuth = FirebaseAuth.getInstance(),
    private val timeZone: TimeZone = TimeZone.getDefault(),
) : ViewModel() {
    private val _parts = MutableStateFlow(AIInboxRefreshParts(emptyList(), emptyList(), 0, 0))
    val parts = _parts.asStateFlow()

    private val _filter = MutableStateFlow(AIInboxFilter.ACTIVE)
    val filter = _filter.asStateFlow()

    private val _selectedID = MutableStateFlow<String?>(null)
    val selectedID = _selectedID.asStateFlow()

    private val _focusRequestToken = MutableStateFlow(0)
    val focusRequestToken = _focusRequestToken.asStateFlow()

    private var pendingFocusID: String? = null
    private var inboxSearchQuery: String = ""

    private val _isLoading = MutableStateFlow(false)
    val isLoading = _isLoading.asStateFlow()

    private val _error = MutableStateFlow<String?>(null)
    val error = _error.asStateFlow()

    /**
     * True once at least one item snapshot has been delivered. Distinguishes
     * "nothing to show" from "nothing loaded yet", which deserve different copy.
     */
    private val _hasLoadedOnce = MutableStateFlow(false)
    val hasLoadedOnce = _hasLoadedOnce.asStateFlow()

    /**
     * False when the Cloud Vault key is not available on this device. The inbox
     * then renders an honest "approve this device" explainer instead of an empty
     * list, because unopenable items are dropped and would otherwise look like
     * an inbox with nothing in it.
     */
    private val _isVaultReady = MutableStateFlow(true)
    val isVaultReady = _isVaultReady.asStateFlow()

    private var items: List<AIInboxItem> = emptyList()

    /** Last state snapshot the server delivered. */
    private var serverStates: Map<String, AIInboxItemUserState> = emptyMap()

    /**
     * Local edits the server has not yet echoed back. Kept apart from
     * [serverStates] so an unrelated snapshot arriving mid-tap cannot roll a
     * just-tapped row back to unread; drained by [mergeAIInboxPendingStates] as
     * soon as the server reports the same edit or newer.
     */
    private var pendingStates: Map<String, AIInboxItemUserState> = emptyMap()

    private var itemsJob: Job? = null
    private var statesJob: Job? = null

    fun startListening() {
        if (itemsJob != null || statesJob != null) return
        val uid = auth.currentUser?.uid
        if (uid.isNullOrBlank()) {
            _error.value = "Sign in to see your inbox."
            return
        }
        _isLoading.value = true
        itemsJob =
            viewModelScope.launch {
                // Firestore listener errors must never reach the main dispatcher
                // as unhandled exceptions — a PERMISSION_DENIED would crash the
                // host activity. Same guard ActivityStore/DashboardStore use.
                listenToItems(uid)
                    .catch { e -> reportListenerFailure(e) }
                    .collect { parsed ->
                        items = parsed
                        _hasLoadedOnce.value = true
                        _isLoading.value = false
                        recompute()
                    }
            }
        statesJob =
            viewModelScope.launch {
                listenToItemStates(uid)
                    .catch { e -> reportListenerFailure(e) }
                    .collect { parsed ->
                        serverStates = parsed
                        recompute()
                    }
            }
    }

    fun stopListening() {
        itemsJob?.cancel()
        itemsJob = null
        statesJob?.cancel()
        statesJob = null
    }

    override fun onCleared() {
        stopListening()
        super.onCleared()
    }

    fun setFilter(value: AIInboxFilter) {
        if (_filter.value == value) return
        _filter.value = value
        recompute()
    }

    /**
     * Cold/warm focus. Matches iOS `AIInboxStore.focus`: widen to Active,
     * clear search, hold a not-yet-synced id so an intervening snapshot cannot
     * steal the selection.
     */
    fun focus(itemID: String?) {
        val next = MobileInboxSelectionPolicy.focus(
            selectionState(),
            itemID,
            items.map { it.id },
        )
        _filter.value = AIInboxFilter.ACTIVE
        inboxSearchQuery = next.searchQuery
        pendingFocusID = next.pendingFocusID
        _selectedID.value = next.selectedID
        _focusRequestToken.value = next.focusRequestToken
        recompute()
    }

    /**
     * Selecting is reading: the unread dot clears immediately and the write
     * follows, so a tap never waits on a Firestore round trip.
     */
    fun select(id: String?) {
        _selectedID.value = id
        if (id == null) return
        val row = _parts.value.rows.firstOrNull { it.id == id } ?: return
        if (row.isUnread()) markRead(id, read = true)
    }

    fun markRead(id: String, read: Boolean) {
        val now = System.currentTimeMillis()
        applyOptimistic(id) { it.copy(readAtEpoch = if (read) now else null, updatedAtEpoch = now) }
        writeState(id) { mutableMapOf<String, Any>("readAt" to if (read) FieldValue.serverTimestamp() else FieldValue.delete()) }
    }

    fun setArchived(id: String, archived: Boolean) {
        val now = System.currentTimeMillis()
        applyOptimistic(id) { it.copy(archivedAtEpoch = if (archived) now else null, updatedAtEpoch = now) }
        if (archived && _selectedID.value == id) {
            _selectedID.value = _parts.value.rows.firstOrNull { it.id != id }?.id
        }
        writeState(id) { mutableMapOf<String, Any>("archivedAt" to if (archived) FieldValue.serverTimestamp() else FieldValue.delete()) }
    }

    fun snooze(id: String, interval: AIInboxSnoozeInterval) {
        val now = System.currentTimeMillis()
        val until = now + interval.millis
        applyOptimistic(id) { it.copy(snoozedUntilEpoch = until, updatedAtEpoch = now) }
        if (_selectedID.value == id) {
            _selectedID.value = _parts.value.rows.firstOrNull { it.id != id }?.id
        }
        writeState(id) { mutableMapOf<String, Any>("snoozedUntil" to Date(until)) }
    }

    fun clearSnooze(id: String) {
        val now = System.currentTimeMillis()
        applyOptimistic(id) { it.copy(snoozedUntilEpoch = null, updatedAtEpoch = now) }
        writeState(id) { mutableMapOf<String, Any>("snoozedUntil" to FieldValue.delete()) }
    }

    /**
     * Records whether an item earned its interruption. [value] must be one of
     * the rules-allowlisted tokens; `null` clears it (tapping the active choice
     * again).
     */
    fun setFeedback(id: String, value: String?) {
        if (value != null && value !in AIInboxMirrorCodec.ALLOWED_FEEDBACK_VALUES) return
        val now = System.currentTimeMillis()
        applyOptimistic(id) { it.copy(feedback = value, updatedAtEpoch = now) }
        writeState(id) { mutableMapOf<String, Any>("feedback" to (value ?: FieldValue.delete())) }
    }

    /**
     * Marks every visible unread row read in one batch.
     *
     * Batched rather than looped through [markRead]: clearing a full inbox is
     * the one action that can touch a hundred documents at once, and a hundred
     * independent `set` calls would be a hundred round trips. One batch is safe
     * without chunking because [INBOX_ITEM_FETCH_LIMIT] caps the visible list
     * well under Firestore's 500-write batch ceiling.
     */
    fun markEverythingRead() {
        val unread = _parts.value.rows.filter { it.isUnread() }
        if (unread.isEmpty()) return
        val now = System.currentTimeMillis()
        for (row in unread) {
            applyOptimistic(row.id) { it.copy(readAtEpoch = now, updatedAtEpoch = now) }
        }
        val uid = auth.currentUser?.uid
        if (uid.isNullOrBlank()) return
        val deviceID = runCatching { AndroidCloudVaultDeviceKeypair.loadOrCreate().deviceId }.getOrNull()
        viewModelScope.launch {
            val collection =
                firestore.collection("users").document(uid).collection(AIInboxMirrorCodec.STATE_COLLECTION)
            val batch = firestore.batch()
            for (row in unread) {
                val payload = mutableMapOf<String, Any>("id" to row.id, "readAt" to FieldValue.serverTimestamp(), "updatedAt" to FieldValue.serverTimestamp())
                deviceID?.let { payload["updatedByDeviceID"] = it }
                batch.set(collection.document(row.id), payload, SetOptions.merge())
            }
            try {
                batch.commit().await()
            } catch (e: CancellationException) {
                throw e
            } catch (e: FirebaseException) {
                _error.value = e.message ?: e::class.java.simpleName
            }
        }
    }

    // ── Listeners ──

    private fun listenToItems(uid: String): Flow<List<AIInboxItem>> = callbackFlow {
        val vaultKey = AtomicReference(resolveVaultKey(uid))
        data class RawItemDocument(val id: String, val data: Map<String, Any>)
        val latestDocuments = AtomicReference<List<RawItemDocument>>(emptyList())
        val userRef = firestore.collection("users").document(uid)
        fun parseDocuments(documents: List<RawItemDocument>, key: ByteArray?): List<AIInboxItem> = documents.mapNotNull { document ->
            parseAIInboxDocument(document.data, document.id, uid, key)
        }

        val listener =
            userRef
                .collection(AIInboxMirrorCodec.COLLECTION)
                .orderBy("lastSeenAt", Query.Direction.DESCENDING)
                .limit(INBOX_ITEM_FETCH_LIMIT)
                .addSnapshotListener { snapshot, error ->
                    if (error != null) {
                        close(error)
                        return@addSnapshotListener
                    }
                    val documents = snapshot?.documents.orEmpty().map { document ->
                        RawItemDocument(document.id, document.data.orEmpty())
                    }
                    latestDocuments.set(documents)
                    // Re-resolve on every item snapshot. This handles a device
                    // approval that arrives while the tab is open and a vault
                    // rotation that changes the key used to open later items.
                    launch {
                        val refreshed = resolveVaultKey(uid)
                        vaultKey.set(refreshed)
                        trySend(parseDocuments(documents, refreshed))
                    }
                }
        // Item documents may not change when the vault rotates. Observe the
        // authoritative state document too, then re-open the latest item
        // snapshot with the newly wrapped key without waiting for another item
        // write or forcing the user to leave and re-enter Inbox.
        val vaultStateListener =
            userRef.collection("cloud_vault_state")
                .document("current")
                .addSnapshotListener { _, error ->
                    if (error != null) return@addSnapshotListener
                    launch {
                        val refreshed = resolveVaultKey(uid)
                        vaultKey.set(refreshed)
                        trySend(parseDocuments(latestDocuments.get(), refreshed))
                    }
                }
        awaitClose {
            listener.remove()
            vaultStateListener.remove()
        }
    }

    private fun listenToItemStates(uid: String): Flow<Map<String, AIInboxItemUserState>> = callbackFlow {
        val listener =
            firestore.collection("users")
                .document(uid)
                .collection(AIInboxMirrorCodec.STATE_COLLECTION)
                // Newest-first so the fetch cap drops the STALEST state docs. An
                // unordered `limit` would let Firestore pick which 400 survive,
                // and a recently read/archived item could render as unread.
                .orderBy("updatedAt", Query.Direction.DESCENDING)
                .limit(INBOX_STATE_FETCH_LIMIT)
                .addSnapshotListener { snapshot, error ->
                    if (error != null) {
                        close(error)
                        return@addSnapshotListener
                    }
                    val parsed =
                        snapshot?.documents.orEmpty().mapNotNull { document ->
                            parseAIInboxItemState(document.data.orEmpty(), document.id)
                        }.associateBy { it.id }
                    trySend(parsed)
                }
        awaitClose { listener.remove() }
    }

    /**
     * Resolves the Cloud Vault key: once at listener attach, then again on each
     * snapshot delivery while it is still missing. A missing key is not an
     * error — it means this device has not been approved from a Mac or iPhone
     * yet — but it does mean every sealed item is unopenable, so the flag
     * drives explicit UI rather than a silently empty list.
     */
    private suspend fun resolveVaultKey(uid: String): ByteArray? {
        // Explicit try/catch rather than `runCatching`: this is a suspend call,
        // and swallowing its CancellationException would keep the key lookup
        // alive after the listener's scope was torn down.
        val key =
            try {
                AndroidCloudVaultKeyAccess.keyForReading(uid = uid, firestore = firestore)?.keyData
            } catch (e: CancellationException) {
                throw e
            } catch (_: FirebaseException) {
                null
            } catch (_: IllegalStateException) {
                // `keyForReading` rejects a key whose id disagrees with the
                // account's `cloud_vault_state` — a real mismatch, not an error
                // this surface can resolve. Treat it as "no key" so the UI says
                // so instead of crashing the tab.
                null
            }
        _isVaultReady.value = key != null
        return key
    }

    // ── Writes ──

    /**
     * Merges one field into the item's state document.
     *
     * `id` and `updatedAt` ride along on every write because the rules require
     * them, and `updatedByDeviceID` is stamped so a last-writer-wins conflict is
     * debuggable after the fact. The whole write is best-effort: the optimistic
     * local edit already landed, and the listener reconciles either way.
     */
    private fun writeState(id: String, fields: () -> MutableMap<String, Any>) {
        val uid = auth.currentUser?.uid
        if (uid.isNullOrBlank()) return
        viewModelScope.launch {
            val payload = fields()
            payload["id"] = id
            payload["updatedAt"] = FieldValue.serverTimestamp()
            runCatching { AndroidCloudVaultDeviceKeypair.loadOrCreate().deviceId }
                .getOrNull()
                ?.let { payload["updatedByDeviceID"] = it }
            try {
                firestore.collection("users")
                    .document(uid)
                    .collection(AIInboxMirrorCodec.STATE_COLLECTION)
                    .document(id)
                    .set(payload, SetOptions.merge())
                    .await()
            } catch (e: CancellationException) {
                throw e
            } catch (e: FirebaseException) {
                _error.value = e.message ?: e::class.java.simpleName
            }
        }
    }

    // ── Derivation ──

    /**
     * Applies a local state edit immediately so the UI never waits on a
     * round trip for a tap; the listener reconciles when the write lands.
     */
    private fun applyOptimistic(id: String, transform: (AIInboxItemUserState) -> AIInboxItemUserState) {
        val existing =
            pendingStates[id]
                ?: serverStates[id]
                ?: AIInboxItemUserState(id = id, updatedAtEpoch = System.currentTimeMillis())
        pendingStates = pendingStates + (id to transform(existing))
        recompute()
    }

    private fun recompute() {
        val (merged, stillPending) = mergeAIInboxPendingStates(serverStates, pendingStates)
        pendingStates = stillPending
        _parts.value =
            buildAIInboxRefreshParts(
                items = items,
                states = merged,
                filter = _filter.value,
                nowEpoch = System.currentTimeMillis(),
                timeZone = timeZone,
            )
        val next = MobileInboxSelectionPolicy.reconcile(
            selectionState(),
            _parts.value.rows.map { it.id },
            items.map { it.id },
        )
        pendingFocusID = next.pendingFocusID
        _selectedID.value = next.selectedID
    }

    private fun selectionState() = MobileInboxSelectionState(
        selectedID = _selectedID.value,
        pendingFocusID = pendingFocusID,
        filter = _filter.value.name.lowercase(),
        searchQuery = inboxSearchQuery,
        focusRequestToken = _focusRequestToken.value,
    )

    private fun reportListenerFailure(cause: Throwable) {
        _isLoading.value = false
        _error.value = cause.message ?: cause::class.java.simpleName
    }
}
