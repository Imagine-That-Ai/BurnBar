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
    /** Escrow trust identity (`android-<public-key-hash>`) when known for this physical device. */
    val escrowDeviceId: String? = null,
)

class DevicesStore(
    context: Context? = null,
) : ViewModel() {
    private val db: FirebaseFirestore = Firebase.firestore
    private val securityClient = ComputerUseSecurityCallableClient()
    private val escrowRegistry = AndroidEscrowDeviceRegistry()
    private var appContext: Context? = context?.applicationContext
    private var rawDevices: List<DeviceRecord> = emptyList()

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
        get() = _devices.value.filter { !it.isCurrentDevice }

    val staleDuplicates: List<DeviceRecord>
        get() {
            val raw = rawDevices.filter { !it.isCurrentDevice }
            val primaries = deduplicated(raw).map { it.id }.toSet()
            return raw.filter { it.id !in primaries }
        }

    val thisDeviceTrustState: DeviceTrustState get() = currentDevice?.trustState ?: DeviceTrustState.PENDING

    val bootstrapEligible: Boolean
        get() {
            val hasTrusted = rawDevices.any { it.trustState == DeviceTrustState.TRUSTED && !it.isCurrentDevice }
            return !hasTrusted && thisDeviceTrustState != DeviceTrustState.TRUSTED
        }

    fun initialize(context: Context) {
        appContext = context.applicationContext
    }

    fun load() {
        viewModelScope.launch {
            _isLoading.value = true
            _lastError.value = null
            try {
                val uid = com.google.firebase.auth.FirebaseAuth.getInstance().currentUser?.uid
                if (uid == null) {
                    rawDevices = emptyList()
                    _devices.value = emptyList()
                    return@launch
                }
                val deviceSnapshot =
                    db.collection("users").document(uid)
                        .collection("devices")
                        .get().await()

                val currentDeviceIds = currentDeviceIDs(appContext)
                val generalDevices =
                    deviceSnapshot.documents.mapNotNull { doc ->
                        val data = doc.data ?: return@mapNotNull null
                        generalDeviceRecord(doc.id, data, currentDeviceIds)
                    }
                val escrowDevices =
                    try {
                        db.collection("users").document(uid)
                            .collection("escrow_devices")
                            .get().await()
                            .documents
                            .mapNotNull { doc ->
                                val data = doc.data ?: return@mapNotNull null
                                escrowDeviceRecord(doc.id, data, currentDeviceIds)
                            }
                    } catch (e: FirebaseException) {
                        Log.w("BurnBar", "Escrow devices load failed; showing presence devices as pending", e)
                        emptyList()
                    }
                rawDevices = mergeDeviceRecords(generalDevices, escrowDevices)
                _devices.value = deduplicated(rawDevices)
                // RR-5 pickup-on-launch: finish any pending Cloud Vault rotation this device is a
                // survivor for (revoking device offline / unable to rotate). Once per store instance.
                if (!pendingRotationPickupDone) {
                    pendingRotationPickupDone = true
                    pickUpPendingCloudVaultRotations()
                }
            } catch (e: FirebaseException) {
                Log.e("BurnBar", "Devices load failed", e)
                _lastError.value = e.message
            } finally {
                _isLoading.value = false
            }
        }
    }

    private var pendingRotationPickupDone = false

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
                    .update(
                        mapOf(
                            "deviceName" to newName,
                            "displayName" to newName,
                            "updatedAt" to Date(),
                        ),
                    )
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
                // RR-5: pass THIS (surviving) device's escrow id so the server's
                // cloudVaultRotationRequired signal drives the local rotation chain (re-key, wrap to
                // survivors, rotateCloudVaultKey, document rewrap) instead of being discarded.
                val rotatingDeviceId =
                    runCatching { com.openburnbar.data.cloud.AndroidCloudVaultDeviceKeypair.loadOrCreate().deviceId }.getOrNull()
                // Merged presence+escrow records keep the presence document id; the escrow trust
                // API needs the escrow identity, so prefer it when the record carries one.
                val result =
                    securityClient.revokeEscrowDeviceTrust(
                        device.escrowDeviceId ?: device.id,
                        rotatingDeviceId = rotatingDeviceId,
                    )
                if (result.cloudVaultRotationRequired && !result.cloudVaultRotationCompleted) {
                    _lastError.value =
                        result.cloudVaultRotationFailureMessage
                            ?: result.cloudVaultRotationBlockedReason
                            ?: "Cloud Vault rotation is required but did not complete."
                }
                load()
            } catch (e: FirebaseException) {
                _lastError.value = e.message
            } catch (e: IllegalStateException) {
                _lastError.value = e.message
            } finally {
                _actionInFlightFor.value = null
            }
        }
    }

    /**
     * RR-5 pickup-on-launch — finishes any pending Cloud Vault rotation this device is a survivor
     * for, in case the revoking device was offline (or could not rotate). Best-effort and silent on
     * success; only a hard failure surfaces. Call from the devices surface's first load.
     */
    fun pickUpPendingCloudVaultRotations() {
        viewModelScope.launch {
            runCatching {
                val rotatingDeviceId =
                    com.openburnbar.data.cloud.AndroidCloudVaultDeviceKeypair.loadOrCreate().deviceId
                securityClient.pickUpPendingCloudVaultRotations(rotatingDeviceId)
            }.onFailure { _lastError.value = it.message }
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

    companion object {
        private const val CURRENT_DEVICE_PRIORITY = 3
        private const val ACTIVE_DEVICE_PRIORITY = 2
        private const val REVOKED_DEVICE_PRIORITY = 1

        internal fun currentAndroidDeviceID(context: Context?): String? = runCatching {
            Settings.Secure.getString(
                context?.contentResolver ?: return@runCatching null,
                Settings.Secure.ANDROID_ID,
            )
        }.getOrNull()

        /**
         * Every identity this installation is known by: the raw `ANDROID_ID`, the presence
         * document id (`AgentReplyNotificationState.stableDeviceId`, a SHA-256 of `ANDROID_ID`),
         * and the escrow trust id (`android-<public-key-hash>`). Presence and escrow use
         * different id schemes, so matching on the whole set is what lets the current phone's
         * two records reconcile into one.
         */
        internal fun currentDeviceIDs(context: Context?): Set<String> {
            val ids = mutableSetOf<String>()
            currentAndroidDeviceID(context)?.let { ids += it }
            context?.let { ctx ->
                runCatching {
                    com.openburnbar.services.media.AgentReplyNotificationState.stableDeviceId(ctx)
                }.getOrNull()?.let { ids += it }
            }
            runCatching {
                com.openburnbar.data.cloud.AndroidCloudVaultDeviceKeypair.loadOrCreate().deviceId
            }.getOrNull()?.let { ids += it }
            return ids
        }

        internal fun generalDeviceRecord(documentID: String, data: Map<String, Any?>, currentDeviceIDs: Set<String>): DeviceRecord {
            val id = deviceID(documentID, data)
            return DeviceRecord(
                id = id,
                displayName = deviceName(data),
                platform = devicePlatform(data),
                trustState = deviceTrustState(data),
                lastSeen = deviceActivityDate(data),
                isCurrentDevice = id in currentDeviceIDs,
                escrowDeviceId =
                (data["escrowDeviceId"] as? String)
                    ?.trim()
                    ?.takeIf { it.isNotEmpty() },
            )
        }

        internal fun escrowDeviceRecord(documentID: String, data: Map<String, Any?>, currentDeviceIDs: Set<String>): DeviceRecord {
            val id = deviceID(documentID, data)
            return DeviceRecord(
                id = id,
                displayName = deviceName(data),
                platform = devicePlatform(data),
                trustState = deviceTrustState(data),
                lastSeen = deviceActivityDate(data),
                isCurrentDevice = id in currentDeviceIDs,
                escrowDeviceId = id,
            )
        }

        internal fun mergeDeviceRecords(generalDevices: List<DeviceRecord>, escrowDevices: List<DeviceRecord>): List<DeviceRecord> {
            val records = generalDevices.associateByTo(linkedMapOf()) { it.id }
            for (escrow in escrowDevices) {
                // Presence documents key on a SHA-256 of ANDROID_ID while escrow documents key on
                // the public-key hash, so a direct id join only matches same-scheme records. The
                // presence document's published escrowDeviceId cross-reference joins the two
                // identity schemes for the same physical device.
                val matchKey =
                    when {
                        records.containsKey(escrow.id) -> escrow.id
                        else -> records.entries.firstOrNull { it.value.escrowDeviceId == escrow.id }?.key
                    }
                if (matchKey == null) {
                    records[escrow.id] = escrow
                } else {
                    val existing = records.getValue(matchKey)
                    records[matchKey] =
                        existing.copy(
                            displayName = preferredDeviceName(existing.displayName, escrow.displayName),
                            platform = preferredPlatform(existing.platform, escrow.platform),
                            trustState = escrow.trustState,
                            lastSeen = latestDate(existing.lastSeen, escrow.lastSeen),
                            isCurrentDevice = existing.isCurrentDevice || escrow.isCurrentDevice,
                            escrowDeviceId = escrow.escrowDeviceId ?: existing.escrowDeviceId,
                        )
                }
            }
            return coalesceCurrentDevice(records.values.toList())
        }

        /**
         * The current installation can still surface as two records (presence + escrow) when the
         * presence document predates the escrowDeviceId cross-reference. Both are identified as
         * the current device via [currentDeviceIDs], so fold them into a single record instead of
         * reporting one phone as one trusted and one pending device.
         */
        private fun coalesceCurrentDevice(records: List<DeviceRecord>): List<DeviceRecord> {
            val currentRecords = records.filter { it.isCurrentDevice }
            if (currentRecords.size <= 1) return records
            val merged =
                currentRecords.reduce { accumulated, record ->
                    accumulated.copy(
                        displayName = preferredDeviceName(accumulated.displayName, record.displayName),
                        platform = preferredPlatform(accumulated.platform, record.platform),
                        trustState = preferredTrustState(accumulated.trustState, record.trustState),
                        lastSeen = latestDate(accumulated.lastSeen, record.lastSeen),
                        escrowDeviceId = accumulated.escrowDeviceId ?: record.escrowDeviceId,
                    )
                }
            return listOf(merged) + records.filter { !it.isCurrentDevice }
        }

        internal fun deduplicated(records: List<DeviceRecord>): List<DeviceRecord> {
            val groups =
                records.groupBy {
                    "${it.displayName.lowercase().trim()}\u001F${it.platform.lowercase()}"
                }
            return groups.values
                .map { bucket -> bucket.maxWithOrNull(::compareDevicePriority) ?: bucket.first() }
                .sortedByDescending { it.lastSeen ?: Date(0) }
        }

        private fun deviceID(documentID: String, data: Map<String, Any?>): String = (data["deviceId"] as? String)
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
            ?: documentID

        private fun deviceName(data: Map<String, Any?>): String = listOf("deviceName", "displayName")
            .firstNotNullOfOrNull { field ->
                (data[field] as? String)?.trim()?.takeIf { it.isNotEmpty() }
            }
            ?: "Unknown"

        private fun devicePlatform(data: Map<String, Any?>): String = (data["platform"] as? String)
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
            ?: "unknown"

        private fun deviceTrustState(data: Map<String, Any?>): DeviceTrustState = when ((data["trustState"] as? String)?.lowercase()) {
            "trusted", "approved" -> DeviceTrustState.TRUSTED
            "revoked" -> DeviceTrustState.REVOKED
            else -> DeviceTrustState.PENDING
        }

        private fun deviceActivityDate(data: Map<String, Any?>): Date? {
            val timestampDates =
                listOf("lastActiveAt", "lastSeenAt", "lastSeen", "updatedAt")
                    .mapNotNull { field ->
                        when (val value = data[field]) {
                            is com.google.firebase.Timestamp -> value.toDate()
                            is Date -> value
                            else -> null
                        }
                    }
            val millisecondDates =
                listOf("lastSeenAtMillis", "updated_at_millis")
                    .mapNotNull { field ->
                        (data[field] as? Number)
                            ?.toLong()
                            ?.takeIf { it > 0L }
                            ?.let(::Date)
                    }
            return (timestampDates + millisecondDates).maxOrNull()
        }

        private fun preferredDeviceName(primary: String, fallback: String): String = primary.takeUnless { it.equals("Unknown", ignoreCase = true) }
            ?: fallback

        private fun preferredPlatform(primary: String, fallback: String): String = primary.takeUnless { it.equals("unknown", ignoreCase = true) }
            ?: fallback

        private fun latestDate(first: Date?, second: Date?): Date? = listOfNotNull(first, second).maxOrNull()

        private fun preferredTrustState(first: DeviceTrustState, second: DeviceTrustState): DeviceTrustState = when {
            first == DeviceTrustState.REVOKED || second == DeviceTrustState.REVOKED -> DeviceTrustState.REVOKED
            first == DeviceTrustState.TRUSTED || second == DeviceTrustState.TRUSTED -> DeviceTrustState.TRUSTED
            else -> DeviceTrustState.PENDING
        }

        /**
         * Trusted and pending records share the same priority tier so the freshest installation
         * wins the deduplication bucket. A reinstall starts pending while the abandoned identity
         * can remain trusted; preferring trust over recency would present the stale installation
         * and let [revokeStaleDuplicates] revoke the active one. Revoked records stay below both
         * so an explicit revocation never masks an active record.
         */
        private fun compareDevicePriority(first: DeviceRecord, second: DeviceRecord): Int {
            val tierComparison = devicePriority(first).compareTo(devicePriority(second))
            if (tierComparison != 0) return tierComparison
            return (first.lastSeen ?: Date(0)).compareTo(second.lastSeen ?: Date(0))
        }

        private fun devicePriority(device: DeviceRecord): Int = when {
            device.isCurrentDevice -> CURRENT_DEVICE_PRIORITY
            device.trustState == DeviceTrustState.REVOKED -> REVOKED_DEVICE_PRIORITY
            else -> ACTIVE_DEVICE_PRIORITY
        }
    }
}
