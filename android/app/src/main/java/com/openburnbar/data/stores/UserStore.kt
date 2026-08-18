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
import com.google.android.libraries.identity.googleid.GetSignInWithGoogleOption
import com.google.android.libraries.identity.googleid.GoogleIdTokenCredential
import com.google.android.libraries.identity.googleid.GoogleIdTokenParsingException
import com.google.firebase.FirebaseException
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.auth.FirebaseUser
import com.google.firebase.auth.GoogleAuthProvider
import com.google.firebase.auth.OAuthProvider
import com.google.firebase.auth.ktx.auth
import com.google.firebase.ktx.Firebase
import com.openburnbar.BurnBarApplication
import com.openburnbar.data.policy.MobileAuthErrorClass
import com.openburnbar.data.policy.MobileAuthSessionEpoch
import com.openburnbar.data.policy.MobileAuthSessionPolicy
import com.openburnbar.data.policy.MobileAuthSessionState
import com.openburnbar.data.policy.UidScopedCacheRegistry
import com.openburnbar.services.media.AgentReplyNotificationState
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.tasks.await

private const val DEFAULT_WEB_CLIENT_ID_RESOURCE = "default_web_client_id"
private const val GOOGLE_CREDENTIAL_UNAVAILABLE_MESSAGE =
    "Google sign-in isn't available on this device right now. " +
        "Add a Google account or update Google Play services, then try again."

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
    val classification: MobileAuthErrorClass = MobileAuthErrorClass.MALFORMED,
)

class UserStore(
    private val authProvider: () -> FirebaseAuth? = { runCatching { Firebase.auth }.getOrNull() },
    private val scopedCaches: UidScopedCacheRegistry = UidScopedCacheRegistry.shared,
    firebaseAvailableOverride: Boolean? = null,
) : ViewModel() {
    private val auth = authProvider()
    private val firebaseAvailable = firebaseAvailableOverride ?: (auth != null)

    private val _user = MutableStateFlow<AppUser>(AppUser())
    val user: StateFlow<AppUser> = _user.asStateFlow()

    private val _authError = MutableStateFlow<AuthError?>(null)
    val authError: StateFlow<AuthError?> = _authError.asStateFlow()

    private val _isSigningIn = MutableStateFlow(false)
    val isSigningIn: StateFlow<Boolean> = _isSigningIn.asStateFlow()

    private val _sessionState = MutableStateFlow(
        if (!firebaseAvailable) {
            MobileAuthSessionState.FIREBASE_UNAVAILABLE
        } else if (auth?.currentUser != null) {
            MobileAuthSessionState.SIGNED_IN
        } else {
            MobileAuthSessionState.SIGNED_OUT
        },
    )
    val sessionState: StateFlow<MobileAuthSessionState> = _sessionState.asStateFlow()

    private val _sessionEpoch = MutableStateFlow(
        MobileAuthSessionEpoch(uid = auth?.currentUser?.uid, generation = if (auth?.currentUser != null) 1 else 0),
    )
    val sessionEpoch: StateFlow<MobileAuthSessionEpoch> = _sessionEpoch.asStateFlow()

    /** Tracks the prior signed-in edge so the auth-state listener can emit the
     *  sign-in / sign-out conversion events exactly once per real transition. */
    private var wasSignedIn: Boolean = auth?.currentUser != null

    private val authStateListener =
        FirebaseAuth.AuthStateListener { firebaseAuth ->
            applyObservedUser(firebaseAuth.currentUser)
        }

    init {
        if (!firebaseAvailable) {
            _sessionState.value = MobileAuthSessionPolicy.stateWhenFirebaseUnavailable()
            _authError.value = AuthError(
                message = MobileAuthErrorClass.FIREBASE_UNAVAILABLE.userVisibleLabel,
                classification = MobileAuthErrorClass.FIREBASE_UNAVAILABLE,
            )
        } else {
            auth?.addAuthStateListener(authStateListener)
            applyObservedUser(auth?.currentUser)
        }
    }

    internal fun applyObservedUser(currentUser: FirebaseUser?) {
        if (!firebaseAvailable) {
            reconcileEpoch(null)
            _sessionState.value = MobileAuthSessionState.FIREBASE_UNAVAILABLE
            _user.value = AppUser()
            return
        }
        val nextUid = currentUser?.uid
        reconcileEpoch(nextUid)
        _user.value = currentUser?.toAppUser() ?: AppUser()
        _sessionState.value = if (currentUser != null) {
            MobileAuthSessionState.SIGNED_IN
        } else {
            MobileAuthSessionState.SIGNED_OUT
        }
        trackAuthTransition(currentUser != null, currentUser?.providerData?.lastOrNull()?.providerId)
    }

    private fun reconcileEpoch(nextUid: String?) {
        val current = _sessionEpoch.value
        if (!MobileAuthSessionPolicy.shouldReconcile(current.uid, nextUid)) return
        // Never write users/{previousUid} after Firebase Auth has switched.
        _sessionEpoch.value = current.advanced(nextUid)
        scopedCaches.clearAll()
        if (BurnBarApplication.isAppContextInitialized) {
            AgentReplyNotificationState.bindConsumedEvents(nextUid, BurnBarApplication.appContext)
        }
        if (current.uid != null && nextUid != null && current.uid != nextUid) {
            _authError.value = AuthError(
                message = MobileAuthErrorClass.ACCOUNT_SWITCH.userVisibleLabel,
                classification = MobileAuthErrorClass.ACCOUNT_SWITCH,
            )
        }
    }

    /**
     * Emit `auth.sign_in.completed` (success) on a signed-out → signed-in edge,
     * and `auth.signed_out` on the reverse. Catches every provider path in one
     * place. Sends only the bounded `method` enum + `outcome` — no uid, email,
     * token, or name. Dropped entirely until analytics consent is granted.
     */
    private fun trackAuthTransition(isSignedIn: Boolean, providerId: String?) {
        if (isSignedIn == wasSignedIn) return
        wasSignedIn = isSignedIn
        if (isSignedIn) {
            com.openburnbar.analytics.AnalyticsManager.track(
                com.openburnbar.analytics.AnalyticsEvent.AUTH_SIGN_IN_COMPLETED,
                mapOf(
                    "method" to com.openburnbar.analytics.AnalyticsValue.Str(signInMethod(providerId)),
                    "outcome" to com.openburnbar.analytics.AnalyticsValue.Str("success"),
                ),
            )
        } else {
            com.openburnbar.analytics.AnalyticsManager.track(
                com.openburnbar.analytics.AnalyticsEvent.AUTH_SIGNED_OUT,
                mapOf("outcome" to com.openburnbar.analytics.AnalyticsValue.Str("success")),
            )
        }
    }

    /** Map a Firebase provider id to the taxonomy's bounded `method` enum. */
    private fun signInMethod(providerId: String?): String = when (providerId) {
        "google.com" -> "google"
        "apple.com" -> "apple"
        "github.com" -> "github"
        "password" -> "email"
        else -> "email"
    }

    // ═══ Google ═══

    /**
     * Credential Manager flow for the explicit "Sign in with Google" button.
     * The web client ID comes from the generated Firebase resource, so release
     * builds cannot silently drift away from the shipped `google-services.json`.
     */
    fun signInWithGoogle(activity: android.app.Activity) {
        viewModelScope.launch {
            val firebaseAuth = beginSignIn() ?: return@launch
            val credentialManager = CredentialManager.create(activity)
            try {
                val serverClientId = googleServerClientId(activity) ?: return@launch
                val request =
                    GetCredentialRequest.Builder()
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
                    tombstoneIfSwitchingThenAuth {
                        firebaseAuth.signInWithCredential(firebaseCred).await()
                    }
                } else {
                    _authError.value = AuthError(
                        "Unexpected Google credential response.",
                        classification = MobileAuthErrorClass.MALFORMED,
                    )
                }
            } catch (_: GetCredentialCancellationException) {
                // User dismissed picker — no error.
            } catch (_: NoCredentialException) {
                _authError.value = AuthError(
                    GOOGLE_CREDENTIAL_UNAVAILABLE_MESSAGE,
                    classification = MobileAuthErrorClass.MALFORMED,
                )
                Log.w("BurnBar", "Credential Manager returned no Google credential")
            } catch (e: GoogleIdTokenParsingException) {
                _authError.value =
                    AuthError(
                        "Google returned an invalid sign-in response. Update BurnBar and try again.",
                        classification = MobileAuthErrorClass.MALFORMED,
                    )
                Log.w("BurnBar", "Credential Manager returned an invalid Google ID token", e)
            } catch (e: GetCredentialException) {
                applyAuthFailure(e)
                Log.w("BurnBar", "Credential Manager Google sign-in failed", e)
            } catch (e: FirebaseException) {
                applyAuthFailure(e)
                Log.w("BurnBar", "Google sign-in unexpected error", e)
            } finally {
                _isSigningIn.value = false
                if (_sessionState.value == MobileAuthSessionState.SIGNING_IN) {
                    _sessionState.value = settledSessionState()
                }
            }
        }
    }

    private fun googleServerClientId(context: Context): String? {
        val resourceId =
            context.resources.getIdentifier(
                DEFAULT_WEB_CLIENT_ID_RESOURCE,
                "string",
                context.packageName,
            )
        val clientId =
            if (resourceId == 0) {
                ""
            } else {
                context.getString(resourceId).trim()
            }
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
        val provider =
            OAuthProvider.newBuilder("apple.com")
                .setScopes(listOf("email", "name"))
                .addCustomParameter("locale", java.util.Locale.getDefault().language)
                .build()
        startProviderSignIn(activity, provider, "Apple")
    }

    // ═══ GitHub ═══
    fun signInWithGitHub(activity: android.app.Activity) {
        startProviderSignIn(activity, OAuthProvider.newBuilder("github.com").build(), "GitHub")
    }

    private fun startProviderSignIn(activity: android.app.Activity, provider: OAuthProvider, label: String) {
        val firebaseAuth = beginSignIn() ?: return
        viewModelScope.launch {
            try {
                // Apple/GitHub have no public credential-first API on Android.
                // Tombstone A immediately before the Auth task that changes uid
                // (fresh sheet or pendingAuthResult after activity recreate).
                // Cancel/failure restores. Heartbeats will not write fcm_token
                // onto the tombstone.
                tombstoneIfSwitchingThenAuth {
                    val pending = firebaseAuth.pendingAuthResult
                    if (pending != null) {
                        pending.await()
                    } else {
                        firebaseAuth.startActivityForSignInWithProvider(activity, provider).await()
                    }
                }
            } catch (e: Exception) {
                val raw = e.localizedMessage.orEmpty()
                if (raw.contains("web-context-cancelled", ignoreCase = true) ||
                    raw.contains("cancelled", ignoreCase = true)
                ) {
                    _sessionState.value = settledSessionState()
                    return@launch
                }
                Log.w("BurnBar", "$label sign-in failed", e)
                applyAuthFailure(e)
            } finally {
                _isSigningIn.value = false
            }
        }
    }

    // ═══ Email ═══
    fun signUpWithEmail(email: String, password: String) {
        viewModelScope.launch {
            val firebaseAuth = beginSignIn() ?: return@launch
            try {
                tombstoneIfSwitchingThenAuth {
                    firebaseAuth.createUserWithEmailAndPassword(email, password).await()
                }
            } catch (e: FirebaseException) {
                applyAuthFailure(e)
            } finally {
                _isSigningIn.value = false
            }
        }
    }

    fun signInWithEmail(email: String, password: String) {
        viewModelScope.launch {
            val firebaseAuth = beginSignIn() ?: return@launch
            try {
                tombstoneIfSwitchingThenAuth {
                    firebaseAuth.signInWithEmailAndPassword(email, password).await()
                }
            } catch (e: FirebaseException) {
                applyAuthFailure(e)
            } finally {
                _isSigningIn.value = false
            }
        }
    }

    // ═══ Anonymous ═══
    fun signInAnonymously() {
        viewModelScope.launch {
            val firebaseAuth = beginSignIn() ?: return@launch
            try {
                firebaseAuth.signInAnonymously().await()
            } catch (e: FirebaseException) {
                applyAuthFailure(e)
            } finally {
                _isSigningIn.value = false
            }
        }
    }

    private suspend fun tombstoneIfSwitchingThenAuth(perform: suspend () -> Unit) {
        val current = auth?.currentUser
        val switchingAway = current != null && !current.isAnonymous
        if (switchingAway && BurnBarApplication.isAppContextInitialized) {
            AgentReplyNotificationState.tombstoneCurrentDevice(BurnBarApplication.appContext)
        }
        try {
            perform()
        } catch (error: Throwable) {
            if (switchingAway && BurnBarApplication.isAppContextInitialized) {
                AgentReplyNotificationState.restoreDeviceAfterFailedSwitch(BurnBarApplication.appContext)
            }
            throw error
        }
    }

    fun signOut() {
        viewModelScope.launch {
            if (BurnBarApplication.isAppContextInitialized && auth?.currentUser != null) {
                AgentReplyNotificationState.tombstoneCurrentDevice(BurnBarApplication.appContext)
            }
            auth?.let { BurnBarApplication.signOutSafely(it) }
            reconcileEpoch(null)
            _user.value = AppUser()
            _sessionState.value = MobileAuthSessionPolicy.stateAfterSignOut(firebaseAvailable)
            _authError.value = null
        }
    }

    /**
     * Opens a sign-in attempt: refuses when Firebase is unavailable, otherwise
     * lands in `SIGNING_IN` and hands back the auth the caller must use.
     */
    private fun beginSignIn(): FirebaseAuth? {
        val firebaseAuth = auth
        if (!firebaseAvailable || firebaseAuth == null) {
            applyFirebaseUnavailable()
            return null
        }
        _isSigningIn.value = true
        _sessionState.value = MobileAuthSessionState.SIGNING_IN
        _authError.value = null
        return firebaseAuth
    }

    /** Where an attempt lands once it stops running, per the live Firebase user. */
    private fun settledSessionState(): MobileAuthSessionState =
        if (auth?.currentUser != null) {
            MobileAuthSessionState.SIGNED_IN
        } else {
            MobileAuthSessionState.SIGNED_OUT
        }

    private fun applyFirebaseUnavailable() {
        reconcileEpoch(null)
        _sessionState.value = MobileAuthSessionState.FIREBASE_UNAVAILABLE
        _authError.value = AuthError(
            message = MobileAuthErrorClass.FIREBASE_UNAVAILABLE.userVisibleLabel,
            classification = MobileAuthErrorClass.FIREBASE_UNAVAILABLE,
        )
    }

    private fun applyAuthFailure(error: Throwable) {
        val classification = MobileAuthSessionPolicy.classify(
            code = error.javaClass.simpleName,
            message = error.localizedMessage,
        )
        _authError.value = AuthError(
            message = classification.userVisibleLabel.ifBlank { error.localizedMessage ?: "Sign-in failed" },
            classification = classification,
        )
        _sessionState.value = if (classification == MobileAuthErrorClass.FIREBASE_UNAVAILABLE) {
            MobileAuthSessionState.FIREBASE_UNAVAILABLE
        } else {
            MobileAuthSessionState.SIGNED_OUT
        }
    }

    fun clearError() {
        _authError.value = null
    }

    override fun onCleared() {
        super.onCleared()
        auth?.removeAuthStateListener(authStateListener)
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
