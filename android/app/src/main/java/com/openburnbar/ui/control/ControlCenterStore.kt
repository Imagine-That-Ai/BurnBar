package com.openburnbar.ui.control

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.google.firebase.functions.FirebaseFunctionsException
import com.openburnbar.data.domains.DataDomains
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/**
 * ViewModel backing the Data & Privacy Control Center.
 *
 * Pulls the read-only usage snapshot (`getDataDomainUsage`), joins it with the
 * canonical [DataDomains] registry, and drives the mutating callables
 * (export / scoped delete / recovery / panic / audit verify). Mirrors
 * `RemoteMcpClientStore` and `AccountStore` for flow shape and error handling
 * (FirebaseFunctionsException → localized message).
 *
 * Server is authoritative: this store never writes Firestore; it reflects what
 * the callables return.
 */
internal class ControlCenterStore(
    private val functions: ControlCenterFunctions = ControlCenterFunctions(),
) : ViewModel() {
    private val _snapshot = MutableStateFlow(ControlCenterSnapshot.empty)
    val snapshot: StateFlow<ControlCenterSnapshot> = _snapshot.asStateFlow()

    private val _isLoading = MutableStateFlow(false)
    val isLoading: StateFlow<Boolean> = _isLoading.asStateFlow()

    private val _error = MutableStateFlow<String?>(null)
    val error: StateFlow<String?> = _error.asStateFlow()

    // ── Per-domain action state ──
    private val _deletingDomainId = MutableStateFlow<String?>(null)
    val deletingDomainId: StateFlow<String?> = _deletingDomainId.asStateFlow()

    private val _exportingDomainId = MutableStateFlow<String?>(null)
    val exportingDomainId: StateFlow<String?> = _exportingDomainId.asStateFlow()

    private val _lastDeleteResult = MutableStateFlow<DeleteOutcome?>(null)
    val lastDeleteResult: StateFlow<DeleteOutcome?> = _lastDeleteResult.asStateFlow()

    // ── Recovery ──
    private val _recoveryMethods = MutableStateFlow<List<RecoveryMethod>>(emptyList())
    val recoveryMethods: StateFlow<List<RecoveryMethod>> = _recoveryMethods.asStateFlow()

    private val _recoveryBusy = MutableStateFlow(false)
    val recoveryBusy: StateFlow<Boolean> = _recoveryBusy.asStateFlow()

    // ── Panic ──
    private val _panicBusy = MutableStateFlow(false)
    val panicBusy: StateFlow<Boolean> = _panicBusy.asStateFlow()

    private val _lastPanicResult = MutableStateFlow<PanicOutcome?>(null)
    val lastPanicResult: StateFlow<PanicOutcome?> = _lastPanicResult.asStateFlow()

    // ── Audit ──
    private val _auditEvents = MutableStateFlow<List<AuditEvent>>(emptyList())
    val auditEvents: StateFlow<List<AuditEvent>> = _auditEvents.asStateFlow()

    private val _auditCursor = MutableStateFlow<String?>(null)
    val auditCursor: StateFlow<String?> = _auditCursor.asStateFlow()

    private val _auditLoading = MutableStateFlow(false)
    val auditLoading: StateFlow<Boolean> = _auditLoading.asStateFlow()

    private val _auditVerification = MutableStateFlow<AuditVerification?>(null)
    val auditVerification: StateFlow<AuditVerification?> = _auditVerification.asStateFlow()

    data class DeleteOutcome(val domainId: String, val firestoreDocs: Long, val storageObjects: Long)

    data class PanicOutcome(val mcpClients: Long, val devices: Long, val escrowDevices: Long, val providers: Long)

    fun row(domainId: String): DomainRow? = _snapshot.value.rows.firstOrNull { it.domain.id == domainId }

    fun clearError() {
        _error.value = null
    }

    /** Load the read-only usage snapshot and merge it with the registry. */
    fun refresh() {
        viewModelScope.launch {
            _isLoading.value = true
            _error.value = null
            try {
                val data = functions.getDataDomainUsage()
                _snapshot.value = decodeSnapshot(data)
            } catch (e: FirebaseFunctionsException) {
                _error.value = e.localizedMessage
            } finally {
                _isLoading.value = false
            }
        }
    }

    /** Export one domain (or the whole account when [domainId] is null). */
    fun export(domainId: String?, onResult: (Map<String, Any>) -> Unit = {}) {
        viewModelScope.launch {
            _exportingDomainId.value = domainId ?: ALL_DOMAINS
            _error.value = null
            try {
                val result = functions.exportUserData(domainId?.let { listOf(it) })
                onResult(result)
            } catch (e: FirebaseFunctionsException) {
                _error.value = e.localizedMessage
            } finally {
                _exportingDomainId.value = null
            }
        }
    }

    /** Scoped delete of one domain's firestorePaths + storagePaths. */
    fun deleteDomain(domainId: String) {
        viewModelScope.launch {
            _deletingDomainId.value = domainId
            _error.value = null
            try {
                val result = functions.deleteDomainData(domainId)
                val deleted = result["deleted"].asStringAnyMap()
                _lastDeleteResult.value =
                    DeleteOutcome(
                        domainId = domainId,
                        firestoreDocs = (deleted?.get("firestoreDocs") as? Number)?.toLong() ?: 0L,
                        storageObjects = (deleted?.get("storageObjects") as? Number)?.toLong() ?: 0L,
                    )
                refresh()
            } catch (e: FirebaseFunctionsException) {
                _error.value = e.localizedMessage
            } finally {
                _deletingDomainId.value = null
            }
        }
    }

    // ── Recovery ──
    fun loadRecovery() {
        viewModelScope.launch {
            _recoveryBusy.value = true
            _error.value = null
            try {
                val data = functions.listRecovery()
                _recoveryMethods.value =
                    data["methods"].asStringAnyMapList()?.mapNotNull { decodeRecovery(it) }.orEmpty()
            } catch (e: FirebaseFunctionsException) {
                _error.value = e.localizedMessage
            } finally {
                _recoveryBusy.value = false
            }
        }
    }

    fun setupRecovery(method: String, payload: Map<String, Any>, onDone: (String?) -> Unit = {}) {
        viewModelScope.launch {
            _recoveryBusy.value = true
            _error.value = null
            try {
                val result = functions.setupRecovery(method, payload)
                val recoveryId = result["recoveryId"] as? String
                loadRecovery()
                onDone(recoveryId)
            } catch (e: FirebaseFunctionsException) {
                _error.value = e.localizedMessage
                onDone(null)
            } finally {
                _recoveryBusy.value = false
            }
        }
    }

    fun confirmRecovery(recoveryId: String) {
        viewModelScope.launch {
            _recoveryBusy.value = true
            _error.value = null
            try {
                functions.confirmRecovery(recoveryId)
                loadRecovery()
            } catch (e: FirebaseFunctionsException) {
                _error.value = e.localizedMessage
            } finally {
                _recoveryBusy.value = false
            }
        }
    }

    // ── Panic ──
    fun revokeAllAccess(scope: String) {
        viewModelScope.launch {
            _panicBusy.value = true
            _error.value = null
            try {
                val result = functions.revokeAllAccess(scope)
                val revoked = result["revoked"].asStringAnyMap()
                _lastPanicResult.value =
                    PanicOutcome(
                        mcpClients = (revoked?.get("mcpClients") as? Number)?.toLong() ?: 0L,
                        devices = (revoked?.get("devices") as? Number)?.toLong() ?: 0L,
                        escrowDevices = (revoked?.get("escrowDevices") as? Number)?.toLong() ?: 0L,
                        providers = (revoked?.get("providers") as? Number)?.toLong() ?: 0L,
                    )
                refresh()
            } catch (e: FirebaseFunctionsException) {
                _error.value = e.localizedMessage
            } finally {
                _panicBusy.value = false
            }
        }
    }

    // ── Audit ──
    fun loadAudit(reset: Boolean = false) {
        viewModelScope.launch {
            _auditLoading.value = true
            _error.value = null
            try {
                val cursor = if (reset) null else _auditCursor.value
                val data = functions.getAuditLog(cursor = cursor, limit = AUDIT_PAGE)
                val page = data["events"].asStringAnyMapList()?.mapNotNull { decodeAudit(it) }.orEmpty()
                _auditEvents.value = if (reset) page else _auditEvents.value + page
                _auditCursor.value = data["nextCursor"] as? String
            } catch (e: FirebaseFunctionsException) {
                _error.value = e.localizedMessage
            } finally {
                _auditLoading.value = false
            }
        }
    }

    fun verifyAudit() {
        viewModelScope.launch {
            _auditLoading.value = true
            _error.value = null
            try {
                val data = functions.verifyAuditLog()
                _auditVerification.value =
                    AuditVerification(
                        valid = data["valid"] as? Boolean ?: false,
                        brokenAt = (data["brokenAt"] as? Number)?.toLong(),
                    )
            } catch (e: FirebaseFunctionsException) {
                _error.value = e.localizedMessage
            } finally {
                _auditLoading.value = false
            }
        }
    }

    // ── Decoders ──
    private fun decodeSnapshot(data: Map<String, Any>): ControlCenterSnapshot {
        val tier = DataTier.from(data["tier"] as? String)
        val pensieve = data["limits"].asStringAnyMap()?.get("pensieve").asStringAnyMap()
        val limits =
            pensieve?.let {
                PensieveLimits(
                    sources = (it["sources"] as? Number)?.toLong() ?: 0L,
                    chunks = (it["chunks"] as? Number)?.toLong() ?: 0L,
                    bytes = (it["bytes"] as? Number)?.toLong() ?: 0L,
                )
            }
        val usageById =
            data["domains"].asStringAnyMapList()
                ?.mapNotNull { entry ->
                    val id = entry["id"] as? String ?: return@mapNotNull null
                    id to DomainUsage(
                        id = id,
                        count = (entry["count"] as? Number)?.toLong() ?: 0L,
                        bytes = (entry["bytes"] as? Number)?.toLong() ?: 0L,
                    )
                }
                ?.toMap()
                .orEmpty()
        val rows = DataDomains.all.map { domain -> DomainRow(domain = domain, usage = usageById[domain.id]) }
        return ControlCenterSnapshot(tier = tier, pensieveLimits = limits, rows = rows)
    }

    private fun decodeRecovery(map: Map<String, Any>): RecoveryMethod? {
        val recoveryId = map["recoveryId"] as? String ?: return null
        return RecoveryMethod(
            recoveryId = recoveryId,
            kind = map["kind"] as? String ?: "",
            createdAt = (map["createdAt"] as? Number)?.toLong() ?: parseIsoMs(map["createdAt"]),
            confirmed = map["confirmed"] as? Boolean ?: false,
        )
    }

    private fun decodeAudit(map: Map<String, Any>): AuditEvent? {
        val seq = (map["seq"] as? Number)?.toLong() ?: return null
        return AuditEvent(
            seq = seq,
            ts = (map["ts"] as? Number)?.toLong() ?: parseIsoMs(map["ts"]),
            actor = map["actor"] as? String ?: "unknown",
            action = map["action"] as? String ?: "",
            domain = map["domain"] as? String,
            prevHash = map["prevHash"] as? String,
            hash = map["hash"] as? String,
        )
    }

    private fun parseIsoMs(value: Any?): Long? {
        val raw = value as? String ?: return null
        return runCatching { java.time.Instant.parse(raw).toEpochMilli() }.getOrNull()
    }

    companion object {
        const val ALL_DOMAINS = "__all__"
        private const val AUDIT_PAGE = 50
    }
}
