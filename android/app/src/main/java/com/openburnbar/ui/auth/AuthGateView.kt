// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.auth

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.openburnbar.data.policy.MobileAuthErrorClass
import com.openburnbar.data.policy.MobileAuthSessionState
import com.openburnbar.data.stores.UserStore
import com.openburnbar.ui.navigation.BurnBarNavHost

private const val AUTH_GATE_CROSSFADE_MS = 300

/**
 * Auth gate that shows either the auth flow or the main app content based on auth state.
 * If not signed in, shows the branded ember login screen — visual parity with iOS `SignInScene`.
 */
@Composable
fun AuthGateView(userStore: UserStore = viewModel()) {
    val sessionState by userStore.sessionState.collectAsState()
    val user by userStore.user.collectAsState()
    val isSignedIn = sessionState.isSignedIn && user.isSignedIn

    Box(modifier = Modifier.fillMaxSize()) {
        AnimatedContent(
            targetState = sessionState,
            transitionSpec = {
                fadeIn(animationSpec = tween(AUTH_GATE_CROSSFADE_MS)) togetherWith
                    fadeOut(animationSpec = tween(AUTH_GATE_CROSSFADE_MS))
            },
            label = "authGate",
        ) { state ->
            when (state) {
                MobileAuthSessionState.FIREBASE_UNAVAILABLE,
                MobileAuthSessionState.FIRESTORE_UNAVAILABLE,
                -> FirebaseUnavailableScreen()
                MobileAuthSessionState.SIGNED_IN,
                MobileAuthSessionState.DELETING_ACCOUNT,
                -> if (isSignedIn) {
                    BurnBarNavHost()
                } else {
                    SignInContent(userStore)
                }
                MobileAuthSessionState.SIGNED_OUT,
                MobileAuthSessionState.SIGNING_IN,
                -> SignInContent(userStore)
            }
        }
    }
}

@Composable
private fun SignInContent(userStore: UserStore) {
    val isSigningIn by userStore.isSigningIn.collectAsState()
    val authError by userStore.authError.collectAsState()
    LoginScreen(
        userStore = userStore,
        isSigningIn = isSigningIn,
        authError = authError,
        onDismissError = { userStore.clearError() },
    )
}

@Composable
private fun FirebaseUnavailableScreen() {
    Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.padding(32.dp)) {
            Text(
                text = MobileAuthErrorClass.FIREBASE_UNAVAILABLE.userVisibleLabel,
                fontSize = 22.sp,
            )
            Text(
                text = "This build is missing its Firebase configuration. Reinstall from the official channel.",
                fontSize = 14.sp,
                modifier = Modifier.padding(top = 12.dp),
            )
        }
    }
}
