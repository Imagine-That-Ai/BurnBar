package com.openburnbar.data.stores

import android.util.Log
import androidx.credentials.CredentialManager
import androidx.credentials.CustomCredential
import androidx.credentials.GetCredentialRequest
import androidx.credentials.exceptions.GetCredentialCancellationException
import androidx.credentials.exceptions.GetCredentialException
import androidx.credentials.exceptions.NoCredentialException
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.google.android.gms.auth.api.signin.GoogleSignIn
import com.google.android.gms.auth.api.signin.GoogleSignInClient
import com.google.android.gms.auth.api.signin.GoogleSignInOptions
import com.google.android.gms.common.api.ApiException
import com.google.android.libraries.identity.googleid.GetGoogleIdOption
import com.google.android.libraries.identity.googleid.GetSignInWithGoogleOption
import com.google.android.libraries.identity.googleid.GoogleIdTokenCredential
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
    companion object {
        /**
         * Web (type 3) OAuth client ID — same one Firebase Console →
         * Authentication → Google has configured. Required by both the
         * Credential Manager flow (`serverClientId`) and the legacy
         * `GoogleSignIn.requestIdToken(...)` flow so Firebase Auth
         * accepts the returned ID token.
         */
        const val WEB_CLIENT_ID =
            "246956661961-o8alph2ucvteqdfrrdnf41m8dmm8r6d7.apps.googleusercontent.com"
    }

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

    /**
     * Signals to the UI when Credential Manager couldn't surface a Google
     * credential (no Google account on device, Play Services missing, etc.).
     * UI flips this true → launches the legacy intent flow → flips false.
     */
    private val _needsLegacyGoogleFallback = MutableStateFlow(false)
    val needsLegacyGoogleFallback: StateFlow<Boolean> = _needsLegacyGoogleFallback.asStateFlow()

    /**
     * Modern Credential Manager flow for "Sign in with Google". Replaces the
     * deprecated `GoogleSignIn.getClient(...).signInIntent` activity-result
     * dance with a single suspend call. Gives clearer error codes and avoids
     * the most common DEVELOPER_ERROR (statusCode 10) confusion when no
     * Google account is set up on the device.
     *
     * When no credential is available it flips [needsLegacyGoogleFallback]
     * so the LoginScreen can launch the legacy account-picker intent via
     * its own ActivityResultLauncher.
     */
    fun signInWithGoogle(activity: android.app.Activity) {
        viewModelScope.launch {
            _isSigningIn.value = true
            _authError.value = null
            val credentialManager = CredentialManager.create(activity)
            val request = GetCredentialRequest.Builder()
                .addCredentialOption(
                    GetGoogleIdOption.Builder()
                        .setServerClientId(WEB_CLIENT_ID)
                        .setFilterByAuthorizedAccounts(false)
                        .setAutoSelectEnabled(false)
                        .build()
                )
                .addCredentialOption(
                    GetSignInWithGoogleOption.Builder(WEB_CLIENT_ID).build()
                )
                .build()
            try {
                val response = credentialManager.getCredential(
                    context = activity,
                    request = request,
                )
                val credential = response.credential
                if (credential is CustomCredential &&
                    credential.type == GoogleIdTokenCredential.TYPE_GOOGLE_ID_TOKEN_CREDENTIAL
                ) {
                    val googleIdTokenCredential = GoogleIdTokenCredential.createFrom(credential.data)
                    val firebaseCred = GoogleAuthProvider.getCredential(googleIdTokenCredential.idToken, null)
                    auth.signInWithCredential(firebaseCred).await()
                } else {
                    _authError.value = AuthError("Unexpected Google credential response.")
                }
            } catch (e: GetCredentialCancellationException) {
                // User dismissed picker — no error.
            } catch (e: NoCredentialException) {
                // No account on device. Trigger legacy account-picker.
                Log.d("BurnBar", "Credential Manager NoCredentialException — falling back to legacy flow")
                _needsLegacyGoogleFallback.value = true
            } catch (e: GetCredentialException) {
                _authError.value = AuthError(e.localizedMessage ?: "Google sign-in failed.")
                Log.w("BurnBar", "Credential Manager Google sign-in failed", e)
            } catch (e: Exception) {
                _authError.value = AuthError(e.localizedMessage ?: "Google sign-in failed.")
                Log.w("BurnBar", "Google sign-in unexpected error", e)
            } finally {
                _isSigningIn.value = false
            }
        }
    }

    /** Clear the legacy-fallback signal once the LoginScreen launches the intent. */
    fun consumeLegacyGoogleFallback() {
        _needsLegacyGoogleFallback.value = false
    }

    // ── Legacy Google Sign-In intent fallback ──

    fun getGoogleSignInIntent(context: android.content.Context): android.content.Intent {
        val gso = GoogleSignInOptions.Builder(GoogleSignInOptions.DEFAULT_SIGN_IN)
            .requestIdToken(WEB_CLIENT_ID)
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
                    val msg = "Google sign-in failed (status ${e.statusCode}). " +
                        "If this is a release build, register the upload key SHA-1 in Firebase Console."
                    _authError.value = AuthError(msg)
                    Log.w("BurnBar", msg, e)
                }
            } catch (e: Exception) {
                _authError.value = AuthError(e.localizedMessage ?: "Sign-in failed")
                Log.w("BurnBar", "Google sign-in exception", e)
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
            .setScopes(listOf("email", "name"))
            .addCustomParameter("locale", java.util.Locale.getDefault().language)
            .build()
        // If a pending result already exists (e.g. activity recreated mid-flow),
        // prefer it so we don't kick off a second auth web sheet.
        val pending = auth.pendingAuthResult
        val task = pending ?: auth.startActivityForSignInWithProvider(activity, provider)
        task.addOnCompleteListener { completed ->
            _isSigningIn.value = false
            if (!completed.isSuccessful) {
                val e = completed.exception
                Log.w("BurnBar", "Apple sign-in failed", e)
                val raw = e?.localizedMessage.orEmpty()
                val hint = when {
                    raw.contains("invalid_client", ignoreCase = true) ||
                        raw.contains("CONFIGURATION_NOT_FOUND", ignoreCase = true) ->
                        "Apple Sign-In isn't fully configured for this app yet. " +
                            "An admin needs to add the Apple Services ID + key in Firebase Console → Authentication → Apple."
                    raw.contains("web-context-cancelled", ignoreCase = true) ||
                        raw.contains("cancelled", ignoreCase = true) -> ""
                    raw.isBlank() -> "Apple sign-in failed."
                    else -> raw
                }
                if (hint.isNotEmpty()) {
                    _authError.value = AuthError(hint)
                }
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
