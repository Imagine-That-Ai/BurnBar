package com.openburnbar.data.stores

import android.util.Log
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.google.firebase.FirebaseException
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.FirebaseFirestoreException
import com.google.firebase.firestore.ktx.firestore
import com.google.firebase.ktx.Firebase
import java.util.Date
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.tasks.await

/**
 * 8-state sync health enum matching iOS CloudSyncHealth.
 */
enum class CloudSyncHealth(val label: String) {
    UNKNOWN("Unknown"),
    HEALTHY("Cloud sync healthy"),
    SYNCING("Syncing"),
    DEGRADED("Cloud sync degraded"),
    OFFLINE("Offline"),
    PERMISSION_DENIED("Permission denied"),
    APP_CHECK_BLOCKED("App Check blocked"),
    FIREBASE_UNAVAILABLE("Firebase unavailable"),
    ;

    val isHealthy: Boolean get() = this == HEALTHY
    val isDegraded: Boolean get() = this in listOf(DEGRADED, OFFLINE, PERMISSION_DENIED, APP_CHECK_BLOCKED, FIREBASE_UNAVAILABLE)
}

data class CloudPublisherDevice(
    val displayName: String = "",
    val platform: String = "",
    val lastSeen: Date? = null,
)

object CloudSyncErrorClassifier {
    fun classify(error: Throwable): CloudSyncHealth {
        if (error is FirebaseFirestoreException) {
            return when (error.code) {
                FirebaseFirestoreException.Code.PERMISSION_DENIED -> permissionDeniedHealth(error.localizedMessage.orEmpty())
                FirebaseFirestoreException.Code.UNAVAILABLE -> CloudSyncHealth.FIREBASE_UNAVAILABLE
                FirebaseFirestoreException.Code.UNAUTHENTICATED -> CloudSyncHealth.OFFLINE
                else -> CloudSyncHealth.DEGRADED
            }
        }

        val message = error.localizedMessage.orEmpty()
        val normalized = message.replace(" ", "").lowercase()
        return when {
            normalized.contains("appcheck") || normalized.contains("attestation") -> CloudSyncHealth.APP_CHECK_BLOCKED
            normalized.contains("permission_denied") || normalized.contains("permissiondenied") -> CloudSyncHealth.PERMISSION_DENIED
            normalized.contains("unavailable") -> CloudSyncHealth.FIREBASE_UNAVAILABLE
            normalized.contains("network") -> CloudSyncHealth.OFFLINE
            else -> CloudSyncHealth.DEGRADED
        }
    }

    fun permissionDeniedHealth(message: String): CloudSyncHealth {
        val normalized = message.replace(" ", "").lowercase()
        return if (normalized.contains("appcheck") || normalized.contains("attestation")) {
            CloudSyncHealth.APP_CHECK_BLOCKED
        } else {
            CloudSyncHealth.PERMISSION_DENIED
        }
    }
}

class CloudSyncHealthStore : ViewModel() {
    companion object {
        private const val STALENESS_THRESHOLD_MS = 30 * 60 * 1000L // 30 minutes
    }

    private val db: FirebaseFirestore = Firebase.firestore

    private val _health = MutableStateFlow(CloudSyncHealth.UNKNOWN)
    val health: StateFlow<CloudSyncHealth> = _health.asStateFlow()

    private val _lastPublishedAt = MutableStateFlow<Date?>(null)
    val lastPublishedAt: StateFlow<Date?> = _lastPublishedAt.asStateFlow()

    private val _lastReadAt = MutableStateFlow<Date?>(null)
    val lastReadAt: StateFlow<Date?> = _lastReadAt.asStateFlow()

    private val _publisher = MutableStateFlow<CloudPublisherDevice?>(null)
    val publisher: StateFlow<CloudPublisherDevice?> = _publisher.asStateFlow()

    private val _isLoading = MutableStateFlow(false)
    val isLoading: StateFlow<Boolean> = _isLoading.asStateFlow()

    fun refresh() {
        viewModelScope.launch {
            _isLoading.value = true
            _health.value = CloudSyncHealth.SYNCING
            try {
                val uid = com.google.firebase.auth.FirebaseAuth.getInstance().currentUser?.uid
                if (uid == null) {
                    _health.value = CloudSyncHealth.OFFLINE
                    return@launch
                }

                val latestUsage =
                    db.collection("users").document(uid)
                        .collection("usage")
                        .orderBy("startTime", com.google.firebase.firestore.Query.Direction.DESCENDING)
                        .limit(1)
                        .get().await()
                        .documents
                        .firstOrNull()

                val macDevice =
                    db.collection("users").document(uid)
                        .collection("devices")
                        .whereEqualTo("platform", "macOS")
                        .get().await()
                        .documents
                        .maxByOrNull(::macDeviceLastActiveMillis)

                val macContext = resolveMacSyncDeviceContext(macDevice)
                if (macContext == null) {
                    applyUsageFallback(latestUsage?.data)
                    return@launch
                }

                val doc =
                    db.collection("users").document(uid)
                        .collection("sync_status").document(macContext.macDeviceId)
                        .get().await()

                val data = doc.data
                if (data != null) {
                    applySyncSnapshot(applySyncStatusDocument(data, macContext.macName, STALENESS_THRESHOLD_MS))
                } else {
                    applyUsageFallback(latestUsage?.data)
                }
            } catch (e: FirebaseException) {
                Log.e("BurnBar", "Sync health refresh failed", e)
                _health.value = CloudSyncErrorClassifier.classify(e)
            } finally {
                _isLoading.value = false
            }
        }
    }

    fun isStale(now: Date = Date()): Boolean {
        val published = _lastPublishedAt.value ?: return true
        return now.time - published.time > STALENESS_THRESHOLD_MS
    }

    private fun applySyncSnapshot(snapshot: CloudSyncHealthSnapshot) {
        _lastPublishedAt.value = snapshot.lastPublishedAt
        _lastReadAt.value = snapshot.lastReadAt
        _publisher.value = snapshot.publisher
        _health.value = snapshot.health
    }

    private fun applyUsageFallback(data: Map<String, Any>?) {
        applySyncSnapshot(applyUsageFallbackSnapshot(data, STALENESS_THRESHOLD_MS))
    }
}
