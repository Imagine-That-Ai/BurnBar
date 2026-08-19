package com.openburnbar.data.fleet

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.google.firebase.FirebaseException
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.firestore.FirebaseFirestore
import com.openburnbar.data.cloud.AndroidCloudVaultKeyAccess
import com.openburnbar.data.cloud.CloudVaultAADContext
import com.openburnbar.data.cloud.CloudVaultCrypto
import com.openburnbar.data.firebase.FirestoreRepository
import com.openburnbar.data.inbox.epochMillis
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

// MARK: - Fleet Store (Android)
//
// Owns the single Firestore listener behind the fleet dashboard and nothing
// else: state derivation is pure (`FleetStoreParts`), payload decoding is pure
// (`FleetSnapshotParsing`). A `ViewModel` + `StateFlow` for the same reason
// `AIInboxStore` is one — the fleet is a top-level tab, so `viewModelScope`
// tears the listener down when the tab's back-stack entry goes away and the
// nav host's save/restore hands the same instance back on return.
//
// The mirror is read-only by design: orchestrator designation and directives
// stay Mac/daemon-local, so this store issues no writes at all.

/** Collection, document, and field names for the sealed fleet mirror. */
object FleetMirrorCodec {
    const val COLLECTION = "fleet_snapshot"
    const val DOCUMENT = "current"
    const val SEALED_PAYLOAD_FIELD = "sealedPayload"

    /** Plaintext envelope version this build can read. */
    const val CURRENT_ENVELOPE_SCHEMA_VERSION = 1
}

class FleetStore(
    private val firestore: FirebaseFirestore = FirestoreRepository.database(),
    private val auth: FirebaseAuth = FirebaseAuth.getInstance(),
) : ViewModel() {
    private val _state = MutableStateFlow<FleetUiState>(FleetUiState.Loading)
    val state = _state.asStateFlow()

    /**
     * False when the Cloud Vault key is not available on this device. The
     * screen then renders an honest "approve this device" explainer, because a
     * sealed snapshot without a key would otherwise masquerade as a Mac that
     * never synced.
     */
    private val _isVaultReady = MutableStateFlow(true)
    val isVaultReady = _isVaultReady.asStateFlow()

    private val _error = MutableStateFlow<String?>(null)
    val error = _error.asStateFlow()

    private var hasLoadedOnce = false
    private var document: FleetSnapshotDocument? = null
    private var listenerJob: Job? = null

    fun startListening() {
        if (listenerJob != null) return
        val uid = auth.currentUser?.uid
        if (uid.isNullOrBlank()) {
            _error.value = "Sign in to see your fleet."
            return
        }
        listenerJob =
            viewModelScope.launch {
                // Listener errors must never reach the main dispatcher as
                // unhandled exceptions — the same guard AIInboxStore uses.
                listenToSnapshotDocument(uid)
                    .catch { e ->
                        _error.value = e.message ?: e::class.java.simpleName
                    }
                    .collect { parsed ->
                        document = parsed
                        hasLoadedOnce = true
                        _error.value = null
                        refreshDerivedState()
                    }
            }
    }

    fun stopListening() {
        listenerJob?.cancel()
        listenerJob = null
    }

    override fun onCleared() {
        stopListening()
        super.onCleared()
    }

    /**
     * Re-derives the UI state against the current clock. The screen calls this
     * on a slow ticker so a mirror that stops updating crosses into the
     * Mac-offline state without needing another Firestore event.
     */
    fun refreshDerivedState() {
        _state.value = deriveFleetUiState(hasLoadedOnce, document, System.currentTimeMillis())
    }

    // ── Listener ──

    private fun listenToSnapshotDocument(uid: String): Flow<FleetSnapshotDocument?> = callbackFlow {
        val latestData = AtomicReference<Map<String, Any?>?>(null)
        val userRef = firestore.collection("users").document(uid)
        val docRef = userRef.collection(FleetMirrorCodec.COLLECTION).document(FleetMirrorCodec.DOCUMENT)

        val listener =
            docRef.addSnapshotListener { snapshot, error ->
                if (error != null) {
                    close(error)
                    return@addSnapshotListener
                }
                val data = snapshot?.data
                latestData.set(data)
                // Re-resolve the key on every delivery: this picks up a device
                // approval that arrives while the tab is open and a vault
                // rotation that changes the wrapping key.
                launch { trySend(openDocument(uid, data)) }
            }
        // The mirror doc may not change when the vault rotates; observing the
        // authoritative vault-state doc re-opens the latest payload with the
        // newly wrapped key without waiting for the Mac's next publish.
        val vaultStateListener =
            userRef.collection("cloud_vault_state")
                .document("current")
                .addSnapshotListener { _, error ->
                    if (error != null) return@addSnapshotListener
                    launch { trySend(openDocument(uid, latestData.get())) }
                }
        awaitClose {
            listener.remove()
            vaultStateListener.remove()
        }
    }

    // ── Opening ──

    /** Opens the mirror doc: plaintext envelope fields plus the unsealed snapshot. */
    private suspend fun openDocument(uid: String, data: Map<String, Any?>?): FleetSnapshotDocument? {
        if (data == null) return null
        val envelopeVersion = (data["schemaVersion"] as? Number)?.toInt()
        val updatedAt = epochMillis(data["updatedAt"])
        val generatedAt = epochMillis(data["generatedAt"])
        val snapshot =
            if (envelopeVersion != null && envelopeVersion > FleetMirrorCodec.CURRENT_ENVELOPE_SCHEMA_VERSION) {
                // A mirror from the future: keep the staleness signal, drop the body.
                null
            } else {
                unsealSnapshot(uid, data)
            }
        return FleetSnapshotDocument(
            updatedAtEpoch = updatedAt,
            generatedAtEpoch = generatedAt,
            snapshot = snapshot,
        )
    }

    private suspend fun unsealSnapshot(uid: String, data: Map<String, Any?>): FleetSnapshot? {
        val key = resolveVaultKey(uid) ?: return null
        val envelope =
            CloudVaultCrypto.sealedPayloadFromMap(data[FleetMirrorCodec.SEALED_PAYLOAD_FIELD] as? Map<*, *>)
                ?: return null
        return runCatching {
            val bytes = CloudVaultCrypto.openPayload(envelope, key, fleetSealedPayloadAAD(uid))
            parseFleetSnapshot(bytes.toString(Charsets.UTF_8))
        }.getOrNull()
    }

    /**
     * Resolves the Cloud Vault key. A missing key is not an error — the device
     * has not been approved yet — but every sealed snapshot is then unopenable,
     * so the flag drives explicit UI rather than a fake offline state.
     */
    private suspend fun resolveVaultKey(uid: String): ByteArray? {
        val key =
            try {
                AndroidCloudVaultKeyAccess.keyForReading(uid = uid, firestore = firestore)?.keyData
            } catch (e: CancellationException) {
                throw e
            } catch (_: FirebaseException) {
                null
            } catch (_: IllegalStateException) {
                // Key id disagrees with `cloud_vault_state` — a real mismatch
                // this surface cannot resolve. Say "no key" instead of crashing.
                null
            }
        _isVaultReady.value = key != null
        return key
    }
}

/**
 * The AAD every sealed fleet payload is bound to — the exact `ai_inbox_items`
 * shape, so a payload relocated to another user, collection, or document fails
 * to open instead of rendering.
 */
internal fun fleetSealedPayloadAAD(uid: String) = CloudVaultAADContext(
    uid = uid,
    collection = FleetMirrorCodec.COLLECTION,
    docID = FleetMirrorCodec.DOCUMENT,
    field = FleetMirrorCodec.SEALED_PAYLOAD_FIELD,
)
