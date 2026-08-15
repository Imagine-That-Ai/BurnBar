package com.openburnbar.data.stores

import androidx.lifecycle.ViewModel
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.ListenerRegistration
import com.openburnbar.data.firebase.FirestoreRepository
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Live Memory Boost wallet cache. Cloud Functions are the sole writer;
 * this listener only reads `users/{uid}/memoryWallet/current`.
 */
class MemoryWalletStore(
    initialFirestore: FirebaseFirestore? = null,
    initialFirebaseAuth: FirebaseAuth? = null,
) : ViewModel() {
    private val firestore = initialFirestore ?: FirestoreRepository.database()
    private val firebaseAuth = initialFirebaseAuth ?: FirebaseAuth.getInstance()

    private val _textTokens = MutableStateFlow(0L)
    val textTokens: StateFlow<Long> = _textTokens.asStateFlow()

    private val _multimodalTokens = MutableStateFlow(0L)
    val multimodalTokens: StateFlow<Long> = _multimodalTokens.asStateFlow()

    private val _pendingTextTokens = MutableStateFlow(0L)
    val pendingTextTokens: StateFlow<Long> = _pendingTextTokens.asStateFlow()

    private val _pendingMultimodalTokens = MutableStateFlow(0L)
    val pendingMultimodalTokens: StateFlow<Long> = _pendingMultimodalTokens.asStateFlow()

    private val _loadFailed = MutableStateFlow(false)
    val loadFailed: StateFlow<Boolean> = _loadFailed.asStateFlow()

    private var authListener: FirebaseAuth.AuthStateListener? = null
    private var walletListener: ListenerRegistration? = null

    fun start() {
        if (authListener != null) return
        val listener =
            FirebaseAuth.AuthStateListener { auth ->
                listen(auth.currentUser?.uid)
            }
        firebaseAuth.addAuthStateListener(listener)
        authListener = listener
        listen(firebaseAuth.currentUser?.uid)
    }

    fun stop() {
        walletListener?.remove()
        walletListener = null
        authListener?.let { firebaseAuth.removeAuthStateListener(it) }
        authListener = null
        resetBalances()
        _loadFailed.value = false
    }

    override fun onCleared() {
        stop()
        super.onCleared()
    }

    private fun listen(uid: String?) {
        walletListener?.remove()
        walletListener = null
        if (uid == null) {
            resetBalances()
            _loadFailed.value = false
            return
        }
        walletListener =
            firestore.collection("users")
                .document(uid)
                .collection("memoryWallet")
                .document("current")
                .addSnapshotListener { snap, error ->
                    if (error != null) {
                        _loadFailed.value = true
                        return@addSnapshotListener
                    }
                    _loadFailed.value = false
                    val data = snap?.data
                    _textTokens.value = longValue(data?.get("textTokens"))
                    _multimodalTokens.value = longValue(data?.get("multimodalTokens"))
                    _pendingTextTokens.value = longValue(data?.get("pendingTextTokens"))
                    _pendingMultimodalTokens.value = longValue(data?.get("pendingMultimodalTokens"))
                }
    }

    private fun resetBalances() {
        _textTokens.value = 0
        _multimodalTokens.value = 0
        _pendingTextTokens.value = 0
        _pendingMultimodalTokens.value = 0
    }

    private fun longValue(raw: Any?): Long {
        return when (raw) {
            is Number -> raw.toLong()
            else -> 0L
        }
    }
}
