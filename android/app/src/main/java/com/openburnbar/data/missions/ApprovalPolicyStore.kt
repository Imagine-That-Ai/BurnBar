package com.openburnbar.data.missions

import android.content.Context
import android.content.SharedPreferences
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant

// MARK: - Approval Policy Store (Android parity, Hermes Square §6.9)
//
// Port of the iOS `ApprovalPolicyStore`. Stores `ApprovalPolicy` decisions
// per `(agentUri, scopeKey)` so a "yes always for this class" choice
// persists across launches.
//
// Persistence is `SharedPreferences`-backed (the rest of the app uses
// SharedPreferences for square config; mirrors the iOS UserDefaults
// path). Cloud mirror is omitted on Android — the iOS path attaches a
// per-uid Firestore listener; that lands in a follow-up.

enum class ApprovalDecision(val token: String) {
    ALLOW_ONCE("allow_once"),
    ALLOW_FOR_SESSION("allow_for_session"),
    DENY("deny"),
    REMEMBER_ALLOW("remember_allow"),
    REMEMBER_DENY("remember_deny");

    companion object {
        fun fromToken(token: String?): ApprovalDecision? =
            values().firstOrNull { it.token == token }
    }
}

data class ApprovalPolicy(
    val id: String,
    val agentURI: String?,
    val scopeKey: String,
    val missionKind: String?,
    val toolName: String?,
    val fileGlob: String?,
    val runtimeID: String?,
    val targetProject: String?,
    val decision: ApprovalDecision,
    val displayLabel: String,
    val createdAtEpoch: Long = System.currentTimeMillis(),
    val expiresAtEpoch: Long? = null,
    val matchCount: Int = 0,
)

class ApprovalPolicyStore private constructor(context: Context) {
    private val prefs: SharedPreferences = context.applicationContext
        .getSharedPreferences("hermes.approval_policies", Context.MODE_PRIVATE)

    private val _policies = MutableStateFlow<List<ApprovalPolicy>>(emptyList())
    val policies: StateFlow<List<ApprovalPolicy>> = _policies.asStateFlow()

    init {
        _policies.value = load()
    }

    fun record(policy: ApprovalPolicy) {
        val current = _policies.value.toMutableList()
        val idx = current.indexOfFirst { it.id == policy.id }
        if (idx >= 0) current[idx] = policy else current.add(policy)
        _policies.value = current
        save()
    }

    fun remove(id: String) {
        _policies.value = _policies.value.filterNot { it.id == id }
        save()
    }

    /** Resolve a policy by `(agentURI, scopeKey)`; returns null if no
     *  policy matches and bumps matchCount on a hit. */
    fun resolve(agentURI: String?, scopeKey: String): ApprovalPolicy? {
        val match = _policies.value.firstOrNull {
            it.agentURI == agentURI && it.scopeKey == scopeKey &&
                (it.expiresAtEpoch == null || it.expiresAtEpoch > System.currentTimeMillis())
        } ?: return null
        val bumped = match.copy(matchCount = match.matchCount + 1)
        record(bumped)
        return bumped
    }

    private fun load(): List<ApprovalPolicy> {
        val raw = prefs.getString(KEY_POLICIES, null) ?: return emptyList()
        return runCatching {
            val arr = JSONArray(raw)
            (0 until arr.length()).mapNotNull { i ->
                val obj = arr.getJSONObject(i)
                ApprovalPolicy(
                    id = obj.optString("id").takeIf { it.isNotBlank() } ?: return@mapNotNull null,
                    agentURI = obj.optString("agentURI").takeIf { it.isNotBlank() },
                    scopeKey = obj.optString("scopeKey"),
                    missionKind = obj.optString("missionKind").takeIf { it.isNotBlank() },
                    toolName = obj.optString("toolName").takeIf { it.isNotBlank() },
                    fileGlob = obj.optString("fileGlob").takeIf { it.isNotBlank() },
                    runtimeID = obj.optString("runtimeID").takeIf { it.isNotBlank() },
                    targetProject = obj.optString("targetProject").takeIf { it.isNotBlank() },
                    decision = ApprovalDecision.fromToken(obj.optString("decision"))
                        ?: ApprovalDecision.ALLOW_ONCE,
                    displayLabel = obj.optString("displayLabel"),
                    createdAtEpoch = obj.optLong("createdAt", System.currentTimeMillis()),
                    expiresAtEpoch = obj.optLong("expiresAt").takeIf { it > 0 },
                    matchCount = obj.optInt("matchCount", 0),
                )
            }
        }.getOrDefault(emptyList())
    }

    private fun save() {
        val arr = JSONArray()
        for (p in _policies.value) {
            val obj = JSONObject()
            obj.put("id", p.id)
            p.agentURI?.let { obj.put("agentURI", it) }
            obj.put("scopeKey", p.scopeKey)
            p.missionKind?.let { obj.put("missionKind", it) }
            p.toolName?.let { obj.put("toolName", it) }
            p.fileGlob?.let { obj.put("fileGlob", it) }
            p.runtimeID?.let { obj.put("runtimeID", it) }
            p.targetProject?.let { obj.put("targetProject", it) }
            obj.put("decision", p.decision.token)
            obj.put("displayLabel", p.displayLabel)
            obj.put("createdAt", p.createdAtEpoch)
            p.expiresAtEpoch?.let { obj.put("expiresAt", it) }
            obj.put("matchCount", p.matchCount)
            arr.put(obj)
        }
        prefs.edit().putString(KEY_POLICIES, arr.toString()).apply()
    }

    companion object {
        private const val KEY_POLICIES = "policies.v1"

        @Volatile private var instance: ApprovalPolicyStore? = null

        fun shared(context: Context): ApprovalPolicyStore =
            instance ?: synchronized(this) {
                instance ?: ApprovalPolicyStore(context).also { instance = it }
            }

        /** Stable class hash for `(agentURI, scopeKey)`. */
        fun classKey(agentURI: String?, scopeKey: String): String =
            "${agentURI ?: ""}|$scopeKey"
    }
}
