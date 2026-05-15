package com.openburnbar.data.stores

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.google.firebase.Timestamp
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.firestore.ListenerRegistration
import com.google.firebase.firestore.Query
import com.google.firebase.firestore.ktx.firestore
import com.google.firebase.ktx.Firebase
import com.openburnbar.data.firebase.FunctionsRepository
import java.util.Date
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

data class RemoteMcpClientRecord(
    val id: String,
    val displayName: String,
    val clientType: String,
    val allowedScopes: List<String>,
    val grantMode: String,
    val createdAt: Date?,
    val lastUsedAt: Date?,
    val revokedAt: Date?
) {
    val isRevoked: Boolean get() = revokedAt != null

    val displayType: String get() = clientType.ifBlank { "generic MCP" }

    val scopeSummary: String
        get() = allowedScopes.takeIf { it.isNotEmpty() }?.sorted()?.joinToString(", ")
            ?: "No scopes recorded"

    val modeSummary: String
        get() = when (grantMode) {
            "sealed_only" -> "Sealed only"
            "local_decrypt_shim" -> "Local decrypt shim"
            "remote_readable_explicit_opt_in" -> "Remote readable opt-in"
            else -> grantMode.ifBlank { "Local decrypt shim" }.replace("_", " ")
        }
}

class RemoteMcpClientStore : ViewModel() {
    private val db = Firebase.firestore
    private val functions = FunctionsRepository()
    private var listener: ListenerRegistration? = null

    private val _clients = MutableStateFlow<List<RemoteMcpClientRecord>>(emptyList())
    val clients: StateFlow<List<RemoteMcpClientRecord>> = _clients.asStateFlow()

    private val _isLoading = MutableStateFlow(false)
    val isLoading: StateFlow<Boolean> = _isLoading.asStateFlow()

    private val _error = MutableStateFlow<String?>(null)
    val error: StateFlow<String?> = _error.asStateFlow()

    private val _revokingClientId = MutableStateFlow<String?>(null)
    val revokingClientId: StateFlow<String?> = _revokingClientId.asStateFlow()

    fun startListening() {
        val uid = FirebaseAuth.getInstance().currentUser?.uid
        listener?.remove()
        listener = null
        _error.value = null

        if (uid == null) {
            _clients.value = emptyList()
            _isLoading.value = false
            _error.value = "Sign in to view connected MCP clients."
            return
        }

        _isLoading.value = true
        listener = db.collection("users").document(uid)
            .collection("remote_mcp_clients")
            .orderBy("updatedAt", Query.Direction.DESCENDING)
            .addSnapshotListener { snapshot, error ->
                _isLoading.value = false
                if (error != null) {
                    _clients.value = emptyList()
                    _error.value = error.localizedMessage
                    return@addSnapshotListener
                }
                _clients.value = snapshot?.documents
                    ?.mapNotNull { doc -> decode(doc.id, doc.data.orEmpty()) }
                    ?.sortedByDescending { it.lastUsedAt ?: it.createdAt ?: Date(0) }
                    .orEmpty()
            }
    }

    fun stopListening() {
        listener?.remove()
        listener = null
        _isLoading.value = false
    }

    fun revoke(client: RemoteMcpClientRecord) {
        if (client.isRevoked) return
        viewModelScope.launch {
            _revokingClientId.value = client.id
            _error.value = null
            try {
                functions.revokeRemoteMcpClient(client.id)
            } catch (e: Exception) {
                _error.value = e.localizedMessage
            } finally {
                _revokingClientId.value = null
            }
        }
    }

    override fun onCleared() {
        listener?.remove()
        listener = null
        super.onCleared()
    }

    private fun decode(documentId: String, data: Map<String, Any>): RemoteMcpClientRecord {
        val clientId = (data["clientId"] as? String)?.trim().orEmpty().ifBlank { documentId }
        val displayName = (data["displayName"] as? String)?.trim().orEmpty().ifBlank {
            "OpenBurnBar MCP client"
        }
        val clientType = (data["clientType"] as? String)?.trim().orEmpty()
        val scopes = (data["allowedScopes"] as? List<*>)?.filterIsInstance<String>().orEmpty()
        val grantMode = (data["grantMode"] as? String)?.trim().orEmpty().ifBlank {
            "local_decrypt_shim"
        }

        return RemoteMcpClientRecord(
            id = clientId,
            displayName = displayName,
            clientType = clientType,
            allowedScopes = scopes,
            grantMode = grantMode,
            createdAt = dateValue(data["createdAt"]),
            lastUsedAt = dateValue(data["lastUsedAt"]),
            revokedAt = dateValue(data["revokedAt"])
        )
    }

    private fun dateValue(value: Any?): Date? = when (value) {
        is Timestamp -> value.toDate()
        is Date -> value
        is Number -> Date(value.toLong() * 1000L)
        is String -> runCatching {
            java.time.Instant.parse(value).let(Date::from)
        }.getOrNull()
        else -> null
    }
}
