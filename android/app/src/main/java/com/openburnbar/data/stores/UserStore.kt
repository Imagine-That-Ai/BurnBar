package com.openburnbar.data.stores

import androidx.lifecycle.ViewModel
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.auth.FirebaseUser
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import com.google.firebase.auth.ktx.auth
import com.google.firebase.ktx.Firebase

data class AppUser(
    val uid: String = "",
    val displayName: String? = null,
    val email: String? = null,
    val photoUrl: String? = null,
    val isSignedIn: Boolean = false
)

class UserStore : ViewModel() {
    private val auth: FirebaseAuth = Firebase.auth

    private val _user = MutableStateFlow<AppUser>(AppUser())
    val user: StateFlow<AppUser> = _user.asStateFlow()

    private val authStateListener = FirebaseAuth.AuthStateListener { firebaseAuth ->
        val currentUser = firebaseAuth.currentUser
        _user.value = currentUser?.toAppUser() ?: AppUser()
    }

    init {
        auth.addAuthStateListener(authStateListener)
        // Set initial state
        _user.value = auth.currentUser?.toAppUser() ?: AppUser()
    }

    fun signInAnonymously(onComplete: (Boolean) -> Unit = {}) {
        auth.signInAnonymously()
            .addOnCompleteListener { task ->
                if (task.isSuccessful) {
                    _user.value = auth.currentUser?.toAppUser() ?: AppUser()
                    onComplete(true)
                } else {
                    onComplete(false)
                }
            }
    }

    fun signOut() {
        auth.signOut()
        _user.value = AppUser()
    }

    /** Returns the current user ID for Firestore paths, or a default dev ID. */
    fun currentUserId(): String {
        return _user.value.uid.ifEmpty { "mock-user" }
    }

    override fun onCleared() {
        super.onCleared()
        auth.removeAuthStateListener(authStateListener)
    }
}

private fun FirebaseUser.toAppUser(): AppUser = AppUser(
    uid = uid,
    displayName = displayName,
    email = email,
    photoUrl = photoUrl?.toString(),
    isSignedIn = true
)
