@file:Suppress("MagicNumber")
// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.auth

import androidx.compose.runtime.Composable
import com.openburnbar.data.stores.AuthError
import com.openburnbar.data.stores.UserStore

/**
 * First-impression sign-in. Visual parity with iOS `SignInScene`.
 */
@Composable
fun LoginScreen(userStore: UserStore, isSigningIn: Boolean, authError: AuthError?, onDismissError: () -> Unit) {
    LoginScreenRoot(
        userStore = userStore,
        isSigningIn = isSigningIn,
        authError = authError,
        onDismissError = onDismissError,
    )
}
