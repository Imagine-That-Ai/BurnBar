package com.openburnbar.data.stores

import android.content.Context
import android.util.Log
import androidx.credentials.CredentialManager
import androidx.credentials.CustomCredential
import androidx.credentials.GetCredentialRequest
import androidx.credentials.exceptions.GetCredentialCancellationException
import androidx.credentials.exceptions.GetCredentialException
import androidx.credentials.exceptions.NoCredentialException
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.google.android.libraries.identity.googleid.GetGoogleIdOption
import com.google.android.libraries.identity.googleid.GetSignInWithGoogleOption
import com.google.android.libraries.identity.googleid.GoogleIdTokenCredential
import com.google.firebase.auth.GoogleAuthProvider
import com.google.firebase.auth.OAuthProvider
import com.google.firebase.FirebaseException
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.auth.FirebaseUser
import com.google.firebase.auth.ktx.auth
import com.google.firebase.ktx.Firebase
import com.openburnbar.R
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
    val provider: String? = null,
)

data class AuthError(
    val message: String,
    val isTransient: Boolean = false,
)

class UserStore : ViewModel() {
    private val auth: FirebaseAuth = Firebase.auth

    private val _user = MutableStateFlow<AppUser>(AppUser())
    val user: StateFlow<AppUser> = _user.asStateFlow()

    private val _authError = MutableStateFlow<AuthError?>(null)
    val authError: StateFlow<AuthError?> = _authError.asStateFlow()

    private val _isSigningIn = MutableStateFlow(false)
    val isSigningIn: StateFlow<Boolean> = _isSigningIn.asStateFlow()

    private val authStateListener =
        FirebaseAuth.AuthStateListener { firebaseAuth ->
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
     * Modern Credential Manager flow for "Sign in with Google". Replaces the
     * deprecated `GoogleSignIn.getClient(...).signInIntent` activity-result dance
     * with a single suspend call. The web client ID comes from the generated
     * Firebase resource, so release builds cannot silently drift away from the
     * shipped `google-services.json`.
     */
    fun signInWithGoogle(activity: android.app.Activity) {
        viewModelScope.launch {
            _isSigningIn.value = true
            _authError.value = null
            val credentialManager = CredentialManager.create(activity)
            try {
                val serverClientId = googleServerClientId(activity) ?: return@launch
                val request =
                    GetCredentialRequest.Builder()
                        .addCredentialOption(
                            GetGoogleIdOption.Builder()
                                .setServerClientId(serverClientId)
                                .setFilterByAuthorizedAccounts(false)
                                .setAutoSelectEnabled(false)
                                .build(),
                        )
                        .addCredentialOption(
                            GetSignInWithGoogleOption.Builder(serverClientId).build(),
                        )
                        .build()
                val response =
                    credentialManager.getCredential(
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
            } catch (_: GetCredentialCancellationException) {
                // User dismissed picker — no error.
            } catch (_: NoCredentialException) {
                _authError.value =
                    AuthError(
                        "No Google account is available on this device. Add a Google account in Android Settings, then try again.",
                    )
            } catch (e: GetCredentialException) {
                _authError.value = AuthError(e.localizedMessage ?: "Google sign-in failed.")
                Log.w("BurnBar", "Credential Manager Google sign-in failed", e)
            } catch (e: FirebaseException) {
                _authError.value = AuthError(e.localizedMessage ?: "Google sign-in failed.")
                Log.w("BurnBar", "Google sign-in unexpected error", e)
            } finally {
                _isSigningIn.value = false
            }
        }
    }

    private fun googleServerClientId(context: Context): String? {
        val clientId = context.getString(R.string.default_web_client_id).trim()
        return when {
            clientId.isBlank() ||
                clientId.contains("YOUR_", ignoreCase = true) ||
                !clientId.endsWith(".apps.googleusercontent.com") -> {
                val msg =
                    "Google sign-in is not configured for this build. " +
                        "Install a build generated with the BurnBar Firebase Android config."
                _authError.value = AuthError(msg)
                Log.w("BurnBar", msg)
                null
            }
            else -> clientId
        }
    }

    // ═══ Apple ═══
    fun signInWithApple(activity: android.app.Activity) {
        _isSigningIn.value = true
        _authError.value = null
        val provider =
            OAuthProvider.newBuilder("apple.com")
                .setScopes(listOf("email", "name"))
                .addCustomParameter("locale", java.util.Locale.getDefault().language)
                .build()
        startProviderSignIn(activity, provider, "Apple")
    }

    // ═══ GitHub ═══
    fun signInWithGitHub(activity: android.app.Activity) {
        _isSigningIn.value = true
        _authError.value = null
        val provider = OAuthProvider.newBuilder("github.com").build()
        startProviderSignIn(activity, provider, "GitHub")
    }

    private fun startProviderSignIn(
        activity: android.app.Activity,
        provider: OAuthProvider,
        label: String,
    ) {
        // If a pending result already exists (e.g. activity recreated mid-flow),
        // prefer it so we don't kick off a second auth web sheet.
        val pending = auth.pendingAuthResult
        val task = pending ?: auth.startActivityForSignInWithProvider(activity, provider)
        task.addOnCompleteListener { completed ->
            _isSigningIn.value = false
            if (!completed.isSuccessful) {
                val e = completed.exception
                Log.w("BurnBar", "$label sign-in failed", e)
                val raw = e?.localizedMessage.orEmpty()
                val hint =
                    when {
                        raw.contains("invalid_client", ignoreCase = true) ||
                            raw.contains("CONFIGURATION_NOT_FOUND", ignoreCase = true) ->
                            "$label Sign-In isn't fully configured for this app yet. " +
                                "An admin needs to add the $label OAuth credentials in Firebase Console → Authentication → $label."
                        raw.contains("web-context-cancelled", ignoreCase = true) ||
                            raw.contains("cancelled", ignoreCase = true) -> ""
                        raw.isBlank() -> "$label sign-in failed."
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
            _isSigningIn.value = true
            _authError.value = null
            try {
                auth.createUserWithEmailAndPassword(email, password).await()
            } catch (
                e: FirebaseException,
            ) {
                _authError.value = AuthError(e.localizedMessage ?: "Sign-up failed")
            } finally {
                _isSigningIn.value = false
            }
        }
    }

    fun signInWithEmail(email: String, password: String) {
        viewModelScope.launch {
            _isSigningIn.value = true
            _authError.value = null
            try {
                auth.signInWithEmailAndPassword(email, password).await()
            } catch (
                e: FirebaseException,
            ) {
                _authError.value = AuthError(e.localizedMessage ?: "Sign-in failed")
            } finally {
                _isSigningIn.value = false
            }
        }
    }

    // ═══ Anonymous ═══
    fun signInAnonymously() {
        viewModelScope.launch {
            _isSigningIn.value = true
            _authError.value = null
            try {
                auth.signInAnonymously().await()
            } catch (e: FirebaseException) {
                _authError.value = AuthError(e.localizedMessage ?: "Sign-in failed")
            } finally {
                _isSigningIn.value = false
            }
        }
    }

    fun signOut() {
        auth.signOut()
        _user.value = AppUser()
    }

    fun clearError() {
        _authError.value = null
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
    isSignedIn = true,
    provider = providerData.firstOrNull()?.providerId,
)
