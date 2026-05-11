package com.openburnbar.data.stores

import android.util.Log
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.ktx.firestore
import com.google.firebase.ktx.Firebase
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.tasks.await
import java.util.Date
import java.util.concurrent.TimeUnit

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
    FIREBASE_UNAVAILABLE("Firebase unavailable");

    val isHealthy: Boolean get() = this == HEALTHY
    val isDegraded: Boolean get() = this in listOf(DEGRADED, OFFLINE, PERMISSION_DENIED, APP_CHECK_BLOCKED, FIREBASE_UNAVAILABLE)
}

data class CloudPublisherDevice(
    val displayName: String = "",
    val platform: String = "",
    val lastSeen: Date? = null
)

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

                // Read sync_status document
                val doc = db.collection("users").document(uid)
                    .collection("sync_status").document("latest")
                    .get().await()

                val data = doc.data
                if (data != null) {
                    val publishedAt = (data["lastPublishedAt"] as? com.google.firebase.Timestamp)?.toDate()
                        ?: (data["lastPublishedAt"] as? java.util.Date)
                    val readAt = (data["lastReadAt"] as? com.google.firebase.Timestamp)?.toDate()
                        ?: (data["lastReadAt"] as? java.util.Date)

                    _lastPublishedAt.value = publishedAt
                    _lastReadAt.value = readAt

                    val pubData = data["publisher"] as? Map<String, Any>
                    _publisher.value = pubData?.let {
                        CloudPublisherDevice(
                            displayName = it["displayName"] as? String ?: "",
                            platform = it["platform"] as? String ?: "",
                            lastSeen = (it["lastSeen"] as? com.google.firebase.Timestamp)?.toDate()
                        )
                    }

                    val now = Date()
                    val stale = publishedAt?.let { now.time - it.time > STALENESS_THRESHOLD_MS } ?: true
                    val lastError = data["lastError"] as? String

                    _health.value = when {
                        lastError != null -> CloudSyncHealth.DEGRADED
                        stale -> CloudSyncHealth.DEGRADED
                        else -> CloudSyncHealth.HEALTHY
                    }
                } else {
                    _health.value = CloudSyncHealth.UNKNOWN
                }
            } catch (e: Exception) {
                Log.e("BurnBar", "Sync health refresh failed", e)
                _health.value = when {
                    e.message?.contains("PERMISSION_DENIED") == true -> CloudSyncHealth.PERMISSION_DENIED
                    e.message?.contains("UNAVAILABLE") == true -> CloudSyncHealth.FIREBASE_UNAVAILABLE
                    e.message?.contains("network") == true -> CloudSyncHealth.OFFLINE
                    else -> CloudSyncHealth.DEGRADED
                }
            } finally {
                _isLoading.value = false
            }
        }
    }

    fun isStale(now: Date = Date()): Boolean {
        val published = _lastPublishedAt.value ?: return true
        return now.time - published.time > STALENESS_THRESHOLD_MS
    }
}
