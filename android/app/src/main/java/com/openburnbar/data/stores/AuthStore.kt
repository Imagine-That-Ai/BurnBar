package com.openburnbar.data.stores

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.google.firebase.auth.FirebaseAuth
import com.openburnbar.BurnBarApplication
import com.openburnbar.data.policy.MobileAuthErrorClass
import com.openburnbar.data.policy.MobileAuthSessionEpoch
import com.openburnbar.data.policy.MobileAuthSessionPolicy
import com.openburnbar.data.policy.MobileAuthSessionState
import com.openburnbar.data.policy.UidScopedCacheRegistry
import com.openburnbar.data.widget.BurnBarWidgetSyncWorker
import com.openburnbar.services.media.AgentReplyNotificationState
import com.openburnbar.services.media.bindConsumedEvents
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

class AuthStore(
    private val authProvider: () -> FirebaseAuth? = { FirebaseAuth.getInstance() },
    private val scopedCaches: UidScopedCacheRegistry = UidScopedCacheRegistry.shared,
    firebaseAvailableOverride: Boolean? = null,
) : ViewModel() {
    private val auth = runCatching { authProvider() }.getOrNull()
    private val firebaseAvailable = firebaseAvailableOverride ?: (auth != null)

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

    private val _lastErrorClass = MutableStateFlow(MobileAuthErrorClass.NONE)
    val lastErrorClass: StateFlow<MobileAuthErrorClass> = _lastErrorClass.asStateFlow()

    private val _isSignedIn = MutableStateFlow(_sessionState.value.isSignedIn)
    val isSignedIn: StateFlow<Boolean> = _isSignedIn

    private val _userDisplayName = MutableStateFlow(auth?.currentUser?.displayName)
    val userDisplayName: StateFlow<String?> = _userDisplayName

    private val _userEmail = MutableStateFlow(auth?.currentUser?.email)
    val userEmail: StateFlow<String?> = _userEmail

    fun signOut() {
        viewModelScope.launch {
            auth?.let { firebase ->
                if (BurnBarApplication.isAppContextInitialized && firebase.currentUser != null) {
                    AgentReplyNotificationState.tombstoneCurrentDevice(
                        BurnBarApplication.appContext,
                    )
                }
                BurnBarApplication.signOutSafely(firebase)
            }
            applyUid(null)
            _sessionState.value = MobileAuthSessionPolicy.stateAfterSignOut(firebaseAvailable)
            _isSignedIn.value = false
            _userDisplayName.value = null
            _userEmail.value = null
            _lastErrorClass.value = MobileAuthErrorClass.NONE
        }
    }

    fun refreshUser() {
        if (!firebaseAvailable) {
            _sessionState.value = MobileAuthSessionState.FIREBASE_UNAVAILABLE
            _isSignedIn.value = false
            _lastErrorClass.value = MobileAuthErrorClass.FIREBASE_UNAVAILABLE
            return
        }
        val user = auth?.currentUser
        applyUid(user?.uid)
        _sessionState.value = if (user != null) MobileAuthSessionState.SIGNED_IN else MobileAuthSessionState.SIGNED_OUT
        _isSignedIn.value = user != null
        _userDisplayName.value = user?.displayName
        _userEmail.value = user?.email
    }

    internal fun applyUid(nextUid: String?) {
        val current = _sessionEpoch.value
        if (!MobileAuthSessionPolicy.shouldReconcile(current.uid, nextUid)) return
        // Never write users/{previousUid} after Firebase Auth has switched.
        _sessionEpoch.value = current.advanced(nextUid)
        scopedCaches.clearAll()
        if (BurnBarApplication.isAppContextInitialized) {
            val app = BurnBarApplication.appContext
            if (current.uid != null && current.uid != nextUid) {
                viewModelScope.launch {
                    BurnBarWidgetSyncWorker.clearAndRefresh(app)
                }
            }
            AgentReplyNotificationState.bindConsumedEvents(nextUid, app)
        }
        if (current.uid != null && nextUid != null && current.uid != nextUid) {
            _lastErrorClass.value = MobileAuthErrorClass.ACCOUNT_SWITCH
        }
    }

    internal fun applyError(code: String, message: String? = null) {
        val classified = MobileAuthSessionPolicy.classify(code, message)
        _lastErrorClass.value = classified
        if (classified == MobileAuthErrorClass.FIREBASE_UNAVAILABLE) {
            _sessionState.value = MobileAuthSessionState.FIREBASE_UNAVAILABLE
            _isSignedIn.value = false
        }
    }
}
