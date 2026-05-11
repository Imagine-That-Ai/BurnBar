package com.openburnbar.data.stores

import android.util.Log
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.auth.FirebaseUser
import com.openburnbar.data.firebase.FirestoreRepository
import com.openburnbar.data.models.ProviderAccount
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

data class BurnBarProfile(
    val id: String,
    val displayName: String,
    val email: String? = null,
    val photoUrl: String? = null,
    val isActive: Boolean = false
)

class AccountStore(
    private val firestore: FirestoreRepository = FirestoreRepository()
) : ViewModel() {
    private val auth: FirebaseAuth = FirebaseAuth.getInstance()

    private val _user = MutableStateFlow<FirebaseUser?>(auth.currentUser)
    val user: StateFlow<FirebaseUser?> = _user.asStateFlow()

    private val _isSignedIn = MutableStateFlow(auth.currentUser != null)
    val isSignedIn: StateFlow<Boolean> = _isSignedIn.asStateFlow()

    private val _isLoading = MutableStateFlow(false)
    val isLoading: StateFlow<Boolean> = _isLoading.asStateFlow()

    private val _error = MutableStateFlow<String?>(null)
    val error: StateFlow<String?> = _error.asStateFlow()

    private val _providerAccounts = MutableStateFlow<List<ProviderAccount>>(emptyList())
    val providerAccounts: StateFlow<List<ProviderAccount>> = _providerAccounts.asStateFlow()

    private val _profiles = MutableStateFlow<List<BurnBarProfile>>(emptyList())
    val profiles: StateFlow<List<BurnBarProfile>> = _profiles.asStateFlow()

    private val _activeProfile = MutableStateFlow<BurnBarProfile?>(null)
    val activeProfile: StateFlow<BurnBarProfile?> = _activeProfile.asStateFlow()

    private val authStateListener = FirebaseAuth.AuthStateListener { firebaseAuth ->
        val currentUser = firebaseAuth.currentUser
        _user.value = currentUser
        _isSignedIn.value = currentUser != null
        if (currentUser != null) {
            viewModelScope.launch { fetchConnections() }
        } else {
            resetSessionState()
        }
    }

    init {
        auth.addAuthStateListener(authStateListener)
        loadProfiles()
    }

    fun fetchConnections() {
        viewModelScope.launch {
            _isLoading.value = true
            _error.value = null
            try {
                _providerAccounts.value = firestore.fetchProviderAccounts()
            } catch (e: Exception) {
                Log.e("BurnBar", "Fetch connections failed", e)
                _error.value = e.message
            } finally {
                _isLoading.value = false
            }
        }
    }

    fun loadConnections() {
        fetchConnections()
    }

    fun signOut() {
        auth.signOut()
        resetSessionState()
    }

    private fun resetSessionState() {
        _providerAccounts.value = emptyList()
        _profiles.value = emptyList()
        _activeProfile.value = null
    }

    fun loadProfiles() {
        val loaded = mutableListOf<BurnBarProfile>()
        auth.currentUser?.let { user ->
            loaded.add(
                BurnBarProfile(
                    id = user.uid,
                    displayName = user.displayName ?: user.email ?: "Current Account",
                    email = user.email,
                    photoUrl = user.photoUrl?.toString(),
                    isActive = true
                )
            )
        }
        _profiles.value = loaded
        _activeProfile.value = loaded.firstOrNull { it.isActive }
    }

    fun switchTo(profile: BurnBarProfile) {
        _profiles.value = _profiles.value.map {
            it.copy(isActive = it.id == profile.id)
        }
        _activeProfile.value = profile
    }

    override fun onCleared() {
        super.onCleared()
        auth.removeAuthStateListener(authStateListener)
    }
}
