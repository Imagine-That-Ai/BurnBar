package com.openburnbar.ui.control

import com.google.firebase.functions.FirebaseFunctions
import com.google.firebase.functions.ktx.functions
import com.google.firebase.ktx.Firebase
import kotlinx.coroutines.tasks.await

/**
 * Thin, self-contained callable hub for the Data & Privacy Control Center.
 *
 * Mirrors `data/firebase/FunctionsRepository`'s conventions exactly (Firebase
 * onCall, `getHttpsCallable(name).call(payload).await()`, `Map<String, Any>`
 * decode) but stays inside the control-surface tree so the primary agent only
 * has to fold these methods into the shared `FunctionsRepository` if they want
 * one canonical hub — see the integration handoff. All callables are
 * region us-central1, App Check enforced, auth-gated server-side.
 *
 * No callable mutates Firestore directly from the client — every action routes
 * through the named onCall functions.
 */
internal class ControlCenterFunctions(
    private val functions: FirebaseFunctions = Firebase.functions,
) {
    // ── Usage snapshot (already implemented server-side: dataDomainUsage.ts) ──
    suspend fun getDataDomainUsage(): Map<String, Any> = callMap("getDataDomainUsage", emptyMap())

    // ── Export (plaintext inline; E2E as signed-URL refs) ──
    suspend fun exportUserData(domains: List<String>? = null): Map<String, Any> {
        val payload = mutableMapOf<String, Any>()
        if (!domains.isNullOrEmpty()) payload["domains"] = domains
        return callMap("exportUserData", payload)
    }

    // ── Scoped per-domain delete ──
    suspend fun deleteDomainData(domainId: String): Map<String, Any> = callMap("deleteDomainData", mapOf("domainId" to domainId, "confirm" to true))

    // ── Recovery (forced before zero-knowledge mode) ──
    suspend fun setupRecovery(method: String, payload: Map<String, Any>): Map<String, Any> =
        callMap("setupRecovery", mapOf("method" to method, "payload" to payload))

    suspend fun confirmRecovery(recoveryId: String): Map<String, Any> = callMap("confirmRecovery", mapOf("recoveryId" to recoveryId))

    suspend fun listRecovery(): Map<String, Any> = callMap("listRecovery", emptyMap())

    // ── Panic — revoke everything ──
    suspend fun revokeAllAccess(scope: String): Map<String, Any> = callMap("revokeAllAccess", mapOf("scope" to scope))

    // ── Tamper-evident audit log ──
    suspend fun getAuditLog(cursor: String? = null, limit: Int? = null): Map<String, Any> {
        val payload = mutableMapOf<String, Any>()
        cursor?.takeIf { it.isNotBlank() }?.let { payload["cursor"] = it }
        limit?.let { payload["limit"] = it }
        return callMap("getAuditLog", payload)
    }

    suspend fun verifyAuditLog(): Map<String, Any> = callMap("verifyAuditLog", emptyMap())

    private suspend fun callMap(name: String, payload: Map<String, Any>): Map<String, Any> {
        val result = functions.getHttpsCallable(name).call(payload).await()
        return result.getData().asStringAnyMap() ?: emptyMap()
    }
}

internal fun Any?.asStringAnyMap(): Map<String, Any>? {
    val raw = this as? Map<*, *> ?: return null
    val typed = LinkedHashMap<String, Any>(raw.size)
    for ((key, value) in raw) {
        val stringKey = key as? String ?: return null
        if (value != null) typed[stringKey] = value
    }
    return typed
}

internal fun Any?.asStringAnyMapList(): List<Map<String, Any>>? {
    val raw = this as? List<*> ?: return null
    return raw.mapNotNull { it.asStringAnyMap() }
}
