@file:Suppress("MagicNumber")
// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.auth

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.lifecycle.viewmodel.compose.viewModel
import com.openburnbar.data.stores.UserStore
import com.openburnbar.ui.navigation.BurnBarNavHost

private const val AUTH_GATE_CROSSFADE_MS = 300

/**
 * Auth gate that shows either the auth flow or the main app content based on auth state.
 * If not signed in, shows the branded ember login screen — visual parity with iOS `SignInScene`.
 */
@Composable
fun AuthGateView(userStore: UserStore = viewModel()) {
    val user by userStore.user.collectAsState()
    val isSignedIn = user.isSignedIn

    Box(modifier = Modifier.fillMaxSize()) {
        AnimatedContent(
            targetState = isSignedIn,
            transitionSpec = {
                fadeIn(animationSpec = tween(AUTH_GATE_CROSSFADE_MS)) togetherWith
                    fadeOut(animationSpec = tween(AUTH_GATE_CROSSFADE_MS))
            },
            label = "authGate",
        ) { signedIn ->
            if (signedIn) {
                BurnBarNavHost()
            } else {
                val isSigningIn by userStore.isSigningIn.collectAsState()
                val authError by userStore.authError.collectAsState()
                LoginScreen(
                    userStore = userStore,
                    isSigningIn = isSigningIn,
                    authError = authError,
                    onDismissError = { userStore.clearError() },
                )
            }
        }
    }
}
