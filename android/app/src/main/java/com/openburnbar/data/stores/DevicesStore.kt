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
import com.openburnbar.data.cloud.AndroidCloudVaultDeviceKeypair
import com.openburnbar.data.cloud.AndroidEscrowDeviceRegistry
import com.openburnbar.data.cloud.AndroidEscrowDeviceSafetyCode
import com.openburnbar.data.computeruse.ComputerUseSecurityCallableClient
import java.security.MessageDigest
import java.util.Date
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.tasks.await

enum class DeviceTrustState { PENDING, TRUSTED, REVOKED }

data class DeviceRecord(
    val id: String = "",
    val presenceID: String? = null,
    val escrowID: String? = null,
    val displayName: String = "",
    val platform: String = "",
    val trustState: DeviceTrustState = DeviceTrustState.PENDING,
    val lastSeen: Date? = null,
    val isCurrentDevice: Boolean = false,
    val keyVersion: Int? = null,
    val publicKeyFingerprint: String? = null,
    val publicKeyData: String? = null,
) {
    /**
     * Durable registration identity used for list diffing and destructive actions. Names and
     * platforms are user-visible metadata and are never unique enough to identify a registration.
     */
    val stableIdentity: String
        get() = escrowID?.takeIf { it.isNotBlank() }
            ?: presenceID?.takeIf { it.isNotBlank() }
            ?: id

    val revocationDeviceID: String
        get() = escrowID?.takeIf { it.isNotBlank() } ?: id

    val safetyCode: String?
        get() = AndroidEscrowDeviceSafetyCode.format(publicKeyData)

    val hasVerifiedSafetyCode: Boolean
        get() = AndroidEscrowDeviceSafetyCode.isFingerprintBoundTo(publicKeyFingerprint, publicKeyData)
}

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
            return raw.filter { it.escrowID != null && it.id !in primaries }
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

                val currentPresenceDeviceID = appContext?.let { currentAndroidDeviceID(it) }
                val currentEscrowDeviceID =
                    runCatching { AndroidCloudVaultDeviceKeypair.loadOrCreate().deviceId }
                        .getOrNull()
                val generalDevices =
                    deviceSnapshot.documents.mapNotNull { doc ->
                        val data = doc.data ?: return@mapNotNull null
                        generalDeviceRecord(doc.id, data, currentPresenceDeviceID)
                    }
                val escrowDevices = loadEscrowDevices(uid = uid, currentEscrowDeviceID = currentEscrowDeviceID)
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

    private suspend fun loadEscrowDevices(uid: String, currentEscrowDeviceID: String?): List<DeviceRecord> = try {
        val userRef = db.collection("users").document(uid)
        val escrowSnapshot = userRef
            .collection("escrow_devices")
            .get().await()
        val escrowPublicKeys =
            runCatching {
                userRef.collection("escrow_public_keys")
                    .get().await()
                    .documents
                    .associate { document ->
                        document.id to (document.getString("publicKeyData") ?: "")
                    }
            }.getOrElse { error ->
                Log.w("BurnBar", "Escrow public-key load failed; approval stays disabled", error)
                emptyMap()
            }
        escrowSnapshot.documents.mapNotNull { doc ->
            val data = doc.data ?: return@mapNotNull null
            val keyVersion = (data["keyVersion"] as? Number)?.toInt()
            val publicKeyData =
                keyVersion?.let { escrowPublicKeys["${doc.id}_$it"] }
                    ?.takeIf { it.isNotBlank() }
            escrowDeviceRecord(
                documentID = doc.id,
                data = data,
                currentEscrowDeviceID = currentEscrowDeviceID,
                publicKeyData = publicKeyData,
            )
        }
    } catch (e: FirebaseException) {
        Log.w("BurnBar", "Escrow devices load failed; showing presence devices as pending", e)
        emptyList()
    }

    fun bootstrapApproveSelf() {
        viewModelScope.launch {
            _actionInFlightFor.value = currentDevice?.stableIdentity
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

    fun approve(device: DeviceRecord) {
        viewModelScope.launch {
            _actionInFlightFor.value = device.stableIdentity
            _lastError.value = null
            try {
                require(!device.isCurrentDevice && device.trustState == DeviceTrustState.PENDING) {
                    "Only a different pending device can be approved."
                }
                require(device.hasVerifiedSafetyCode) {
                    "This device has not published a verified safety code yet."
                }
                val uid = com.google.firebase.auth.FirebaseAuth.getInstance().currentUser?.uid
                    ?: error("Sign in before approving a device.")
                escrowRegistry.approveDevice(
                    uid = uid,
                    targetDeviceId = device.escrowID ?: device.id,
                )
                load()
            } catch (error: FirebaseException) {
                _lastError.value = error.message
            } catch (error: IllegalArgumentException) {
                _lastError.value = error.message
            } catch (error: IllegalStateException) {
                _lastError.value = error.message
            } finally {
                _actionInFlightFor.value = null
            }
        }
    }

    fun renameSelf(newName: String) {
        viewModelScope.launch {
            _actionInFlightFor.value = currentDevice?.stableIdentity
            try {
                val uid = com.google.firebase.auth.FirebaseAuth.getInstance().currentUser?.uid ?: return@launch
                val deviceId = currentDevice?.presenceID ?: return@launch
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
            _actionInFlightFor.value = device.stableIdentity
            _lastError.value = null
            try {
                revokeDeviceAndRotate(device)
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

    private suspend fun revokeDeviceAndRotate(device: DeviceRecord) {
        // RR-5: pass THIS (surviving) device's escrow id so the server's
        // cloudVaultRotationRequired signal drives the local rotation chain (re-key, wrap to
        // survivors, rotateCloudVaultKey, document rewrap) instead of being discarded.
        val rotatingDeviceId =
            runCatching { AndroidCloudVaultDeviceKeypair.loadOrCreate().deviceId }.getOrNull()
        val result =
            securityClient.revokeEscrowDeviceTrust(
                device.revocationDeviceID,
                rotatingDeviceId = rotatingDeviceId,
            )
        if (result.cloudVaultRotationRequired && !result.cloudVaultRotationCompleted) {
            throw IllegalStateException(
                result.cloudVaultRotationFailureMessage
                    ?: result.cloudVaultRotationBlockedReason
                    ?: "Cloud Vault rotation is required but did not complete.",
            )
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
            _lastError.value = null
            try {
                revokeSequentially(stale) { device ->
                    _actionInFlightFor.value = device.stableIdentity
                    revokeDeviceAndRotate(device)
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

    companion object {
        private const val CURRENT_DEVICE_PRIORITY = 4
        private const val TRUSTED_DEVICE_PRIORITY = 3
        private const val PENDING_DEVICE_PRIORITY = 2
        private const val REVOKED_DEVICE_PRIORITY = 1
        private const val UNSIGNED_BYTE_MASK = 0xFF

        internal fun currentAndroidDeviceID(context: Context?): String? = runCatching {
            Settings.Secure.getString(
                context?.contentResolver ?: return@runCatching null,
                Settings.Secure.ANDROID_ID,
            )
        }.getOrNull()
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
            ?.let(::presenceDeviceID)

        internal fun presenceDeviceID(androidID: String): String {
            val digest = MessageDigest.getInstance("SHA-256").digest(androidID.toByteArray(Charsets.UTF_8))
            return digest.joinToString(separator = "") { byte -> "%02x".format(byte.toInt() and UNSIGNED_BYTE_MASK) }
        }

        internal fun generalDeviceRecord(documentID: String, data: Map<String, Any?>, currentPresenceDeviceID: String?): DeviceRecord {
            val id = deviceID(documentID, data)
            return DeviceRecord(
                id = id,
                presenceID = id,
                escrowID = escrowDeviceID(data),
                displayName = deviceName(data),
                platform = devicePlatform(data),
                trustState = deviceTrustState(data),
                lastSeen = deviceActivityDate(data),
                isCurrentDevice = id == currentPresenceDeviceID,
            )
        }

        internal fun escrowDeviceRecord(
            documentID: String,
            data: Map<String, Any?>,
            currentEscrowDeviceID: String?,
            publicKeyData: String? = null,
        ): DeviceRecord {
            val id = deviceID(documentID, data)
            return DeviceRecord(
                id = id,
                escrowID = id,
                displayName = deviceName(data),
                platform = devicePlatform(data),
                trustState = deviceTrustState(data),
                lastSeen = deviceActivityDate(data),
                isCurrentDevice = id == currentEscrowDeviceID,
                keyVersion = (data["keyVersion"] as? Number)?.toInt(),
                publicKeyFingerprint = data["publicKeyFingerprint"] as? String,
                publicKeyData = publicKeyData,
            )
        }

        internal fun mergeDeviceRecords(generalDevices: List<DeviceRecord>, escrowDevices: List<DeviceRecord>): List<DeviceRecord> {
            val records = generalDevices.associateByTo(linkedMapOf()) { it.id }
            for (escrow in escrowDevices) {
                val presenceEntry =
                    records.entries.firstOrNull { entry ->
                        entry.key == escrow.id || entry.value.escrowID == escrow.id
                    }
                if (presenceEntry == null) {
                    records[escrow.id] = escrow
                } else {
                    records.remove(presenceEntry.key)
                    val merged = mergePresenceAndEscrow(presenceEntry.value, escrow)
                    records[merged.id] = merged
                }
            }

            val currentPresence =
                records.values
                    .filter { it.isCurrentDevice && it.presenceID != null && it.escrowID == null }
                    .maxWithOrNull(::compareDevicePriority)
            val currentEscrow =
                records.values
                    .filter { it.isCurrentDevice && it.escrowID != null && it.presenceID == null }
                    .maxWithOrNull(::compareDevicePriority)
            if (currentPresence != null && currentEscrow != null && currentPresence.id != currentEscrow.id) {
                records.remove(currentPresence.id)
                records.remove(currentEscrow.id)
                val mergedCurrent = mergePresenceAndEscrow(currentPresence, currentEscrow)
                records[mergedCurrent.id] = mergedCurrent
            }

            val escrowPlatforms =
                records.values
                    .filter { it.escrowID != null }
                    .map { normalizedPlatform(it.platform) }
                    .toSet()
            return records.values.filterNot { record ->
                record.presenceID != null &&
                    record.escrowID == null &&
                    !record.isCurrentDevice &&
                    record.displayName.equals("Unknown", ignoreCase = true) &&
                    normalizedPlatform(record.platform) in escrowPlatforms
            }
        }

        internal fun deduplicated(records: List<DeviceRecord>): List<DeviceRecord> {
            val groups =
                records.groupBy(DeviceRecord::stableIdentity)
            return groups.values
                .map { bucket -> bucket.maxWithOrNull(::compareDevicePriority) ?: bucket.first() }
                .sortedByDescending { it.lastSeen ?: Date(0) }
        }

        internal suspend fun revokeSequentially(devices: List<DeviceRecord>, revokeOne: suspend (DeviceRecord) -> Unit) {
            for (device in devices) {
                revokeOne(device)
            }
        }

        private fun deviceID(documentID: String, data: Map<String, Any?>): String = (data["deviceId"] as? String)
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
            ?: documentID

        private fun escrowDeviceID(data: Map<String, Any?>): String? = (data["escrowDeviceId"] as? String)
            ?.trim()
            ?.takeIf { it.isNotEmpty() }

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

        private fun mergePresenceAndEscrow(presence: DeviceRecord, escrow: DeviceRecord): DeviceRecord {
            return escrow.copy(
                id = escrow.escrowID ?: escrow.id,
                presenceID = presence.presenceID ?: presence.id,
                escrowID = escrow.escrowID ?: escrow.id,
                displayName = preferredDeviceName(presence.displayName, escrow.displayName),
                platform = preferredPlatform(presence.platform, escrow.platform),
                trustState = escrow.trustState,
                lastSeen = latestDate(presence.lastSeen, escrow.lastSeen),
                isCurrentDevice = presence.isCurrentDevice || escrow.isCurrentDevice,
                keyVersion = escrow.keyVersion,
                publicKeyFingerprint = escrow.publicKeyFingerprint,
                publicKeyData = escrow.publicKeyData,
            )
        }

        private fun compareDevicePriority(first: DeviceRecord, second: DeviceRecord): Int {
            val currentComparison = first.isCurrentDevice.compareTo(second.isCurrentDevice)
            if (currentComparison != 0) return currentComparison
            val activityComparison = (first.lastSeen ?: Date(0)).compareTo(second.lastSeen ?: Date(0))
            if (activityComparison != 0) return activityComparison
            return devicePriority(first).compareTo(devicePriority(second))
        }

        private fun devicePriority(device: DeviceRecord): Int = when {
            device.isCurrentDevice -> CURRENT_DEVICE_PRIORITY
            device.trustState == DeviceTrustState.TRUSTED -> TRUSTED_DEVICE_PRIORITY
            device.trustState == DeviceTrustState.PENDING -> PENDING_DEVICE_PRIORITY
            else -> REVOKED_DEVICE_PRIORITY
        }

        private fun normalizedPlatform(platform: String): String = platform.trim().lowercase()
    }
}
