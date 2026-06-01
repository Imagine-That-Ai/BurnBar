package com.openburnbar.data.stores

import android.content.Context
import android.provider.Settings
import android.util.Log
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.google.firebase.FirebaseException
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.ktx.firestore
import com.google.firebase.ktx.Firebase
import com.openburnbar.BurnBarApplication
import com.openburnbar.data.cloud.AndroidEscrowDeviceRegistry
import com.openburnbar.data.computeruse.ComputerUseSecurityCallableClient
import java.util.Date
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.tasks.await

enum class DeviceTrustState { PENDING, TRUSTED, REVOKED }

data class DeviceRecord(
    val id: String = "",
    val displayName: String = "",
    val platform: String = "",
    val trustState: DeviceTrustState = DeviceTrustState.PENDING,
    val lastSeen: Date? = null,
    val isCurrentDevice: Boolean = false,
)

class DevicesStore(
    private val appContext: Context = BurnBarApplication.appContext,
) : ViewModel() {
    private val db: FirebaseFirestore = Firebase.firestore
    private val securityClient = ComputerUseSecurityCallableClient()
    private val escrowRegistry = AndroidEscrowDeviceRegistry()

    private val _devices = MutableStateFlow<List<DeviceRecord>>(emptyList())
    val devices: StateFlow<List<DeviceRecord>> = _devices.asStateFlow()

    private val _isLoading = MutableStateFlow(false)
    val isLoading: StateFlow<Boolean> = _isLoading.asStateFlow()

    private val _lastError = MutableStateFlow<String?>(null)
    val lastError: StateFlow<String?> = _lastError.asStateFlow()

    private val _actionInFlightFor = MutableStateFlow<String?>(null)
    val actionInFlightFor: StateFlow<String?> = _actionInFlightFor.asStateFlow()

    val currentDevice: DeviceRecord? get() = _devices.value.firstOrNull { it.isCurrentDevice }

    val otherDevices: List<DeviceRecord>
        get() = deduplicated(_devices.value.filter { !it.isCurrentDevice })

    val staleDuplicates: List<DeviceRecord>
        get() {
            val raw = _devices.value.filter { !it.isCurrentDevice }
            val primaries = deduplicated(raw).map { it.id }.toSet()
            return raw.filter { it.id !in primaries }
        }

    val thisDeviceTrustState: DeviceTrustState get() = currentDevice?.trustState ?: DeviceTrustState.PENDING

    val bootstrapEligible: Boolean
        get() {
            val hasTrusted = _devices.value.any { it.trustState == DeviceTrustState.TRUSTED && !it.isCurrentDevice }
            return !hasTrusted && thisDeviceTrustState != DeviceTrustState.TRUSTED
        }

    fun load() {
        viewModelScope.launch {
            _isLoading.value = true
            _lastError.value = null
            try {
                val uid = com.google.firebase.auth.FirebaseAuth.getInstance().currentUser?.uid
                if (uid == null) {
                    _devices.value = emptyList()
                    return@launch
                }
                val snapshot =
                    db.collection("users").document(uid)
                        .collection("devices")
                        .get().await()

                val currentDeviceId =
                    currentAndroidDeviceID(appContext)

                _devices.value =
                    snapshot.documents.mapNotNull { doc ->
                        val data = doc.data ?: return@mapNotNull null
                        DeviceRecord(
                            id = doc.id,
                            displayName = data["displayName"] as? String ?: "Unknown",
                            platform = data["platform"] as? String ?: "android",
                            trustState =
                            when (data["trustState"] as? String) {
                                "trusted" -> DeviceTrustState.TRUSTED
                                "revoked" -> DeviceTrustState.REVOKED
                                else -> DeviceTrustState.PENDING
                            },
                            lastSeen = (data["lastSeen"] as? com.google.firebase.Timestamp)?.toDate(),
                            isCurrentDevice = doc.id == currentDeviceId,
                        )
                    }
            } catch (e: FirebaseException) {
                Log.e("BurnBar", "Devices load failed", e)
                _lastError.value = e.message
            } finally {
                _isLoading.value = false
            }
        }
    }

    fun bootstrapApproveSelf() {
        viewModelScope.launch {
            _actionInFlightFor.value = currentDevice?.id
            try {
                val uid = com.google.firebase.auth.FirebaseAuth.getInstance().currentUser?.uid ?: return@launch
                escrowRegistry.trustSelf(uid = uid)
                load()
            } catch (e: FirebaseException) {
                _lastError.value = e.message
            } finally {
                _actionInFlightFor.value = null
            }
        }
    }

    fun renameSelf(newName: String) {
        viewModelScope.launch {
            _actionInFlightFor.value = currentDevice?.id
            try {
                val uid = com.google.firebase.auth.FirebaseAuth.getInstance().currentUser?.uid ?: return@launch
                val deviceId = currentDevice?.id ?: return@launch
                db.collection("users").document(uid)
                    .collection("devices").document(deviceId)
                    .update(mapOf("displayName" to newName, "updatedAt" to Date()))
                    .await()
                load()
            } catch (e: FirebaseException) {
                _lastError.value = e.message
            } finally {
                _actionInFlightFor.value = null
            }
        }
    }

    fun revoke(device: DeviceRecord) {
        viewModelScope.launch {
            _actionInFlightFor.value = device.id
            try {
                securityClient.revokeEscrowDeviceTrust(device.id)
                load()
            } catch (e: FirebaseException) {
                _lastError.value = e.message
            } finally {
                _actionInFlightFor.value = null
            }
        }
    }

    fun revokeStaleDuplicates() {
        viewModelScope.launch {
            val stale = staleDuplicates
            for (device in stale) {
                revoke(device)
            }
        }
    }

    private fun deduplicated(records: List<DeviceRecord>): List<DeviceRecord> {
        val groups =
            records.groupBy {
                "${it.displayName.lowercase().trim()}\u001F${it.platform.lowercase()}"
            }
        return groups.values.map { bucket ->
            bucket.maxByOrNull { it.lastSeen ?: Date(0) }
                ?: bucket.first()
        }.sortedByDescending { it.lastSeen ?: Date(0) }
    }

    companion object {
        internal fun currentAndroidDeviceID(context: Context): String? =
            runCatching {
                Settings.Secure.getString(
                    context.contentResolver,
                    Settings.Secure.ANDROID_ID,
                )
            }.getOrNull()
    }
}
