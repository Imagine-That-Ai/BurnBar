@file:Suppress("MagicNumber")
// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.auth

import android.app.Activity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.stores.UserStore

@Composable
internal fun SimpleAuthScreen(userStore: UserStore) {
    val isDark = isSystemInDarkTheme()
    val context = LocalContext.current
    val isSigningIn by userStore.isSigningIn.collectAsState()
    val authError by userStore.authError.collectAsState()
    val googleLauncher =
        rememberLauncherForActivityResult(
            contract = ActivityResultContracts.StartActivityForResult(),
        ) { result ->
            if (result.resultCode == Activity.RESULT_OK) {
                userStore.handleGoogleSignInResult(result.data)
            }
        }

    Box(
        modifier =
        Modifier
            .fillMaxSize()
            .background(simpleAuthBackgroundBrush(isDark)),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            modifier =
            Modifier
                .fillMaxWidth()
                .padding(horizontal = 32.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            SimpleAuthHeader(isDark = isDark)
            Spacer(modifier = Modifier.height(40.dp))
            SimpleAuthErrorBanner(
                authError = authError,
                onDismiss = userStore::clearError,
            )
            SimpleAuthSignInCard(
                isDark = isDark,
                isSigningIn = isSigningIn,
                onGoogleSignIn = { googleLauncher.launch(userStore.getGoogleSignInIntent(context)) },
                onAppleSignIn = { (context as? Activity)?.let(userStore::signInWithApple) },
                onAnonymousSignIn = userStore::signInAnonymously,
            )
        }
    }
}

@Composable
private fun SimpleAuthHeader(isDark: Boolean) {
    val subtitleColor = if (isDark) Color(0xFFA0A0A0) else Color(0xFF666666)
    Text(text = "🔥", fontSize = 56.sp)
    Spacer(modifier = Modifier.height(8.dp))
    Text(
        text = "BurnBar",
        fontSize = 36.sp,
        fontWeight = FontWeight.Bold,
        color = if (isDark) Color.White else Color(0xFF1A1A2E),
    )
    Text(
        text = "Track your agent spend",
        fontSize = 14.sp,
        color = subtitleColor,
    )
}

@Composable
private fun SimpleAuthErrorBanner(authError: com.openburnbar.data.stores.AuthError?, onDismiss: () -> Unit) {
    AnimatedVisibility(
        visible = authError != null,
        enter = fadeIn() + expandVertically(),
        exit = fadeOut() + shrinkVertically(),
    ) {
        Surface(
            modifier =
            Modifier
                .fillMaxWidth()
                .padding(bottom = 16.dp),
            shape = RoundedCornerShape(12.dp),
            color = Color(0x33FF453A),
        ) {
            Row(
                modifier = Modifier.padding(12.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    text = authError?.message ?: "",
                    color = Color(0xFFFF453A),
                    fontSize = 13.sp,
                    modifier = Modifier.weight(1f),
                )
                IconButton(onClick = onDismiss, modifier = Modifier.size(24.dp)) {
                    Text("✕", color = Color(0xFFFF453A), fontSize = 14.sp)
                }
            }
        }
    }
}

@Composable
private fun SimpleAuthSignInCard(
    isDark: Boolean,
    isSigningIn: Boolean,
    onGoogleSignIn: () -> Unit,
    onAppleSignIn: () -> Unit,
    onAnonymousSignIn: () -> Unit,
) {
    val cardColor = if (isDark) Color(0xFF1C1C1E) else Color.White
    Surface(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(20.dp),
        color = cardColor,
        shadowElevation = 8.dp,
    ) {
        Column(
            modifier = Modifier.padding(24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Text(
                text = "Sign In",
                fontSize = 20.sp,
                fontWeight = FontWeight.SemiBold,
                color = if (isDark) Color.White else Color(0xFF1A1A2E),
            )
            Spacer(modifier = Modifier.height(24.dp))
            SocialAuthButton(
                text = "Continue with Google",
                icon = "G",
                iconBg = Color.White,
                onClick = onGoogleSignIn,
                enabled = !isSigningIn,
            )
            Spacer(modifier = Modifier.height(12.dp))
            SocialAuthButton(
                text = "Continue with Apple",
                icon = "🍎",
                iconBg = Color.Black,
                onClick = onAppleSignIn,
                enabled = !isSigningIn,
            )
            Spacer(modifier = Modifier.height(16.dp))
            HorizontalDivider(modifier = Modifier.fillMaxWidth())
            Spacer(modifier = Modifier.height(16.dp))
            OutlinedButton(
                onClick = onAnonymousSignIn,
                enabled = !isSigningIn,
                modifier = Modifier.fillMaxWidth(),
                shape = RoundedCornerShape(12.dp),
            ) {
                if (isSigningIn) {
                    CircularProgressIndicator(modifier = Modifier.size(20.dp), strokeWidth = 2.dp)
                } else {
                    Text("Continue Anonymously", fontSize = 14.sp, fontWeight = FontWeight.Medium)
                }
            }
        }
    }
}

@Composable
internal fun SocialAuthButton(text: String, icon: String, iconBg: Color, onClick: () -> Unit, enabled: Boolean) {
    OutlinedButton(
        onClick = onClick,
        enabled = enabled,
        modifier =
        Modifier
            .fillMaxWidth()
            .height(48.dp),
        shape = RoundedCornerShape(12.dp),
    ) {
        Box(
            modifier =
            Modifier
                .size(28.dp)
                .clip(RoundedCornerShape(6.dp))
                .background(iconBg),
            contentAlignment = Alignment.Center,
        ) {
            Text(text = icon, fontSize = 16.sp)
        }
        Spacer(modifier = Modifier.width(12.dp))
        Text(text = text, fontSize = 14.sp, fontWeight = FontWeight.Medium)
    }
}

private fun simpleAuthBackgroundBrush(isDark: Boolean): Brush =
    if (isDark) {
        Brush.verticalGradient(listOf(Color(0xFF0D0D0D), Color(0xFF1A1A2E), Color(0xFF16213E)))
    } else {
        Brush.verticalGradient(listOf(Color(0xFFF8F9FA), Color(0xFFE8ECEF), Color(0xFFD5DDE5)))
    }
