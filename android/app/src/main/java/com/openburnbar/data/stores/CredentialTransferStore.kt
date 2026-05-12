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

enum class TransferStatus { IDLE, EXPORTING, IMPORTING, SUCCESS, ERROR }

class CredentialTransferStore : ViewModel() {
    private val db: FirebaseFirestore = Firebase.firestore

    private val _status = MutableStateFlow(TransferStatus.IDLE)
    val status: StateFlow<TransferStatus> = _status.asStateFlow()

    private val _lastError = MutableStateFlow<String?>(null)
    val lastError: StateFlow<String?> = _lastError.asStateFlow()

    private val _transferCode = MutableStateFlow<String?>(null)
    val transferCode: StateFlow<String?> = _transferCode.asStateFlow()

    fun exportCredentials(credentialsJson: String) {
        viewModelScope.launch {
            _status.value = TransferStatus.EXPORTING
            _lastError.value = null
            try {
                val uid = com.google.firebase.auth.FirebaseAuth.getInstance().currentUser?.uid
                if (uid == null) {
                    _lastError.value = "Not signed in"
                    _status.value = TransferStatus.ERROR
                    return@launch
                }
                val code = generateTransferCode()
                db.collection("credential_transfers").document(code)
                    .set(mapOf(
                        "ownerUid" to uid,
                        "payload" to credentialsJson,
                        "createdAt" to Date(),
                        "expiresAt" to Date(System.currentTimeMillis() + 24 * 60 * 60 * 1000),
                        "consumed" to false
                    )).await()
                _transferCode.value = code
                _status.value = TransferStatus.SUCCESS
            } catch (e: Exception) {
                Log.e("BurnBar", "Export failed", e)
                _lastError.value = e.message
                _status.value = TransferStatus.ERROR
            }
        }
    }

    fun importCredentials(code: String) {
        viewModelScope.launch {
            _status.value = TransferStatus.IMPORTING
            _lastError.value = null
            try {
                val doc = db.collection("credential_transfers").document(code).get().await()
                val data = doc.data
                if (data == null || data["consumed"] == true) {
                    _lastError.value = "Invalid or expired transfer code"
                    _status.value = TransferStatus.ERROR
                    return@launch
                }
                // Mark consumed
                db.collection("credential_transfers").document(code)
                    .update(mapOf("consumed" to true, "consumedAt" to Date()))
                    .await()
                _status.value = TransferStatus.SUCCESS
            } catch (e: Exception) {
                Log.e("BurnBar", "Import failed", e)
                _lastError.value = e.message
                _status.value = TransferStatus.ERROR
            }
        }
    }

    private fun generateTransferCode(): String {
        val chars = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
        return (1..8).map { chars.random() }.joinToString("")
    }

    fun reset() {
        _status.value = TransferStatus.IDLE
        _lastError.value = null
        _transferCode.value = null
    }
}
