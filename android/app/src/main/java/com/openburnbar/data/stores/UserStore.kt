package com.openburnbar.data.stores

import android.util.Log
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.google.android.gms.auth.api.signin.GoogleSignIn
import com.google.android.gms.auth.api.signin.GoogleSignInClient
import com.google.android.gms.auth.api.signin.GoogleSignInOptions
import com.google.android.gms.common.api.ApiException
import com.google.firebase.auth.*
import com.google.firebase.auth.ktx.auth
import com.google.firebase.ktx.Firebase
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.tasks.await

data class AppUser(
    val uid: String = "",
    val displayName: String? = null,
    val email: String? = null,
    val photoUrl: String? = null,
    val isSignedIn: Boolean = false,
    val provider: String? = null
)

data class AuthError(
    val message: String,
    val isTransient: Boolean = false
)

class UserStore : ViewModel() {
    private val auth: FirebaseAuth = Firebase.auth

    private val _user = MutableStateFlow<AppUser>(AppUser())
    val user: StateFlow<AppUser> = _user.asStateFlow()

    private val _authError = MutableStateFlow<AuthError?>(null)
    val authError: StateFlow<AuthError?> = _authError.asStateFlow()

    private val _isSigningIn = MutableStateFlow(false)
    val isSigningIn: StateFlow<Boolean> = _isSigningIn.asStateFlow()

    private val authStateListener = FirebaseAuth.AuthStateListener { firebaseAuth ->
        val currentUser = firebaseAuth.currentUser
        _user.value = currentUser?.toAppUser() ?: AppUser()
        Log.d("BurnBar", "Auth state: uid=${currentUser?.uid ?: "null"}")
    }

    init {
        Log.d("BurnBar", "UserStore init: uid=${auth.currentUser?.uid ?: "null"}")
        auth.addAuthStateListener(authStateListener)
        _user.value = auth.currentUser?.toAppUser() ?: AppUser()
    }

    // ═══ Google ═══
    fun getGoogleSignInIntent(context: android.content.Context): android.content.Intent {
        val gso = GoogleSignInOptions.Builder(GoogleSignInOptions.DEFAULT_SIGN_IN)
            .requestIdToken("246956661961-o8alph2ucvteqdfrrdnf41m8dmm8r6d7.apps.googleusercontent.com")
            .requestEmail()
            .build()
        return GoogleSignIn.getClient(context, gso).signInIntent
    }

    fun handleGoogleSignInResult(data: android.content.Intent?) {
        viewModelScope.launch {
            _isSigningIn.value = true
            _authError.value = null
            try {
                val account = GoogleSignIn.getSignedInAccountFromIntent(data).getResult(ApiException::class.java)
                val cred = GoogleAuthProvider.getCredential(account.idToken, null)
                auth.signInWithCredential(cred).await()
            } catch (e: ApiException) {
                if (e.statusCode != 12501) {
                    _authError.value = AuthError(e.localizedMessage ?: "Google sign-in failed")
                }
            } catch (e: Exception) {
                _authError.value = AuthError(e.localizedMessage ?: "Sign-in failed")
            } finally {
                _isSigningIn.value = false
            }
        }
    }

    // ═══ Apple ═══
    fun signInWithApple(activity: android.app.Activity) {
        _isSigningIn.value = true
        _authError.value = null
        val provider = OAuthProvider.newBuilder("apple.com")
            .addCustomParameter("locale", java.util.Locale.getDefault().language)
            .build()
        auth.startActivityForSignInWithProvider(activity, provider)
            .addOnCompleteListener { task ->
                _isSigningIn.value = false
                if (!task.isSuccessful && task.exception != null) {
                    _authError.value = AuthError(task.exception?.localizedMessage ?: "Apple sign-in failed")
                }
            }
    }

    // ═══ Email ═══
    fun signUpWithEmail(email: String, password: String) {
        viewModelScope.launch {
            _isSigningIn.value = true; _authError.value = null
            try { auth.createUserWithEmailAndPassword(email, password).await() }
            catch (e: Exception) { _authError.value = AuthError(e.localizedMessage ?: "Sign-up failed") }
            finally { _isSigningIn.value = false }
        }
    }

    fun signInWithEmail(email: String, password: String) {
        viewModelScope.launch {
            _isSigningIn.value = true; _authError.value = null
            try { auth.signInWithEmailAndPassword(email, password).await() }
            catch (e: Exception) { _authError.value = AuthError(e.localizedMessage ?: "Sign-in failed") }
            finally { _isSigningIn.value = false }
        }
    }

    // ═══ Anonymous ═══
    fun signInAnonymously() {
        viewModelScope.launch {
            _isSigningIn.value = true; _authError.value = null
            try { auth.signInAnonymously().await() }
            catch (e: Exception) { _authError.value = AuthError(e.localizedMessage ?: "Sign-in failed") }
            finally { _isSigningIn.value = false }
        }
    }

    fun signOut() { auth.signOut(); _user.value = AppUser() }
    fun clearError() { _authError.value = null }

    override fun onCleared() {
        super.onCleared()
        auth.removeAuthStateListener(authStateListener)
    }
}

private fun FirebaseUser.toAppUser(): AppUser = AppUser(
    uid = uid, displayName = displayName, email = email,
    photoUrl = photoUrl?.toString(), isSignedIn = true,
    provider = providerData.firstOrNull()?.providerId
)
