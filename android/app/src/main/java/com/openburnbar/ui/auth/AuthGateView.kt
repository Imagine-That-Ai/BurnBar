package com.openburnbar.ui.auth

import androidx.compose.animation.*
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.openburnbar.data.stores.UserStore
import com.openburnbar.ui.navigation.BurnBarNavHost
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraTheme

/**
 * Auth gate that shows either the auth flow or the main app content based on auth state.
 * If not signed in, shows a simple sign-in screen (Google, Apple, Anonymous).
 */

@Composable
fun AuthGateView(
    userStore: UserStore = viewModel()
) {
    val user by userStore.user.collectAsState()
    val isSignedIn = user.isSignedIn

    Box(modifier = Modifier.fillMaxSize()) {
        AnimatedContent(
            targetState = isSignedIn,
            transitionSpec = {
                fadeIn(animationSpec = tween(300)) togetherWith
                fadeOut(animationSpec = tween(300))
            },
            label = "authGate"
        ) { signedIn ->
            if (signedIn) {
                BurnBarNavHost()
            } else {
                SimpleAuthScreen(userStore = userStore)
            }
        }
    }
}

@Composable
private fun SimpleAuthScreen(
    userStore: UserStore
) {
    val isDark = androidx.compose.foundation.isSystemInDarkTheme()
    val context = LocalContext.current

    val isSigningIn by userStore.isSigningIn.collectAsState()
    val authError by userStore.authError.collectAsState()

    val bgBrush = if (isDark) {
        Brush.verticalGradient(listOf(Color(0xFF0D0D0D), Color(0xFF1A1A2E), Color(0xFF16213E)))
    } else {
        Brush.verticalGradient(listOf(Color(0xFFF8F9FA), Color(0xFFE8ECEF), Color(0xFFD5DDE5)))
    }
    val cardColor = if (isDark) Color(0xFF1C1C1E) else Color.White
    val subtitleColor = if (isDark) Color(0xFFA0A0A0) else Color(0xFF666666)

    // Google Sign-In launcher
    val googleLauncher = androidx.activity.compose.rememberLauncherForActivityResult(
        contract = androidx.activity.result.contract.ActivityResultContracts.StartActivityForResult()
    ) { result ->
        if (result.resultCode == android.app.Activity.RESULT_OK) {
            userStore.handleGoogleSignInResult(result.data)
        }
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(bgBrush),
        contentAlignment = Alignment.Center
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 32.dp),
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            Text(text = "🔥", fontSize = 56.sp)
            Spacer(modifier = Modifier.height(8.dp))
            Text(
                text = "BurnBar",
                fontSize = 36.sp,
                fontWeight = FontWeight.Bold,
                color = if (isDark) Color.White else Color(0xFF1A1A2E)
            )
            Text(
                text = "Track your agent spend",
                fontSize = 14.sp,
                color = subtitleColor
            )

            Spacer(modifier = Modifier.height(40.dp))

            AnimatedVisibility(
                visible = authError != null,
                enter = fadeIn() + expandVertically(),
                exit = fadeOut() + shrinkVertically()
            ) {
                Surface(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(bottom = 16.dp),
                    shape = androidx.compose.foundation.shape.RoundedCornerShape(12.dp),
                    color = Color(0x33FF453A)
                ) {
                    Row(
                        modifier = Modifier.padding(12.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Text(
                            text = authError?.message ?: "",
                            color = Color(0xFFFF453A),
                            fontSize = 13.sp,
                            modifier = Modifier.weight(1f)
                        )
                        IconButton(
                            onClick = { userStore.clearError() },
                            modifier = Modifier.size(24.dp)
                        ) {
                            Text("✕", color = Color(0xFFFF453A), fontSize = 14.sp)
                        }
                    }
                }
            }

            Surface(
                modifier = Modifier.fillMaxWidth(),
                shape = androidx.compose.foundation.shape.RoundedCornerShape(20.dp),
                color = cardColor,
                shadowElevation = 8.dp
            ) {
                Column(
                    modifier = Modifier.padding(24.dp),
                    horizontalAlignment = Alignment.CenterHorizontally
                ) {
                    Text(
                        text = "Sign In",
                        fontSize = 20.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = if (isDark) Color.White else Color(0xFF1A1A2E)
                    )

                    Spacer(modifier = Modifier.height(24.dp))

                    // Google
                    SocialAuthButton(
                        text = "Continue with Google",
                        icon = "G",
                        iconBg = Color.White,
                        onClick = {
                            googleLauncher.launch(userStore.getGoogleSignInIntent(context))
                        },
                        enabled = !isSigningIn
                    )

                    Spacer(modifier = Modifier.height(12.dp))

                    // Apple
                    SocialAuthButton(
                        text = "Continue with Apple",
                        icon = "🍎",
                        iconBg = Color.Black,
                        onClick = {
                            userStore.signInWithApple(context as android.app.Activity)
                        },
                        enabled = !isSigningIn
                    )

                    Spacer(modifier = Modifier.height(16.dp))

                    HorizontalDivider(modifier = Modifier.fillMaxWidth())

                    Spacer(modifier = Modifier.height(16.dp))

                    // Anonymous
                    OutlinedButton(
                        onClick = { userStore.signInAnonymously() },
                        enabled = !isSigningIn,
                        modifier = Modifier.fillMaxWidth(),
                        shape = androidx.compose.foundation.shape.RoundedCornerShape(12.dp)
                    ) {
                        if (isSigningIn) {
                            CircularProgressIndicator(
                                modifier = Modifier.size(20.dp),
                                strokeWidth = 2.dp
                            )
                        } else {
                            Text("Continue Anonymously", fontSize = 14.sp, fontWeight = FontWeight.Medium)
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun SocialAuthButton(
    text: String,
    icon: String,
    iconBg: Color,
    onClick: () -> Unit,
    enabled: Boolean
) {
    OutlinedButton(
        onClick = onClick,
        enabled = enabled,
        modifier = Modifier
            .fillMaxWidth()
            .height(48.dp),
        shape = androidx.compose.foundation.shape.RoundedCornerShape(12.dp)
    ) {
        Box(
            modifier = Modifier
                .size(28.dp)
                .clip(androidx.compose.foundation.shape.RoundedCornerShape(6.dp))
                .background(iconBg),
            contentAlignment = Alignment.Center
        ) {
            Text(text = icon, fontSize = 16.sp)
        }
        Spacer(modifier = Modifier.width(12.dp))
        Text(text = text, fontSize = 14.sp, fontWeight = FontWeight.Medium)
    }
}
