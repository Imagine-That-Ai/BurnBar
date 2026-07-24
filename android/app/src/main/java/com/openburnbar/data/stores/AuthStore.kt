package com.openburnbar.data.stores

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.google.firebase.auth.FirebaseAuth
import com.openburnbar.BurnBarApplication
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch

class AuthStore(
    private val authProvider: () -> FirebaseAuth? = { FirebaseAuth.getInstance() },
) : ViewModel() {
    private val auth = runCatching { authProvider() }.getOrNull()

    private val _isSignedIn = MutableStateFlow(auth?.currentUser != null)
    val isSignedIn: StateFlow<Boolean> = _isSignedIn

    private val _userDisplayName = MutableStateFlow(auth?.currentUser?.displayName)
    val userDisplayName: StateFlow<String?> = _userDisplayName

    private val _userEmail = MutableStateFlow(auth?.currentUser?.email)
    val userEmail: StateFlow<String?> = _userEmail

    fun signOut() {
        viewModelScope.launch {
            auth?.let { BurnBarApplication.signOutSafely(it) }
            _isSignedIn.value = false
            _userDisplayName.value = null
            _userEmail.value = null
        }
    }

    fun refreshUser() {
        val user = auth?.currentUser
        _isSignedIn.value = user != null
        _userDisplayName.value = user?.displayName
        _userEmail.value = user?.email
    }
}
