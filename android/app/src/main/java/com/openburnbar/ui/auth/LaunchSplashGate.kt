package com.openburnbar.ui.auth

import android.provider.Settings
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.EnterTransition
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay

/**
 * A one-shot, full-bleed branded launch splash.
 *
 * Plays the BurnBar logo-formation animation over a dark backdrop on cold
 * start, then crossfades to reveal [content] underneath. Mount it once at the
 * app root, wrapping the nav host.
 *
 * The auth state resolves almost instantly, so there is no real "loading"
 * gate to hang on - this is a deliberate brand moment: dots converge into the
 * flame, the flame solidifies inside the glass cube, then we hand off to the
 * app. When the system animator scale is 0 (the Android "remove animations"
 * accessibility setting) the splash is skipped and the app is shown at once.
 */
@Composable
fun LaunchSplashGate(durationMillis: Long = 4200L, content: @Composable () -> Unit) {
    val context = LocalContext.current
    val animationsEnabled = remember {
        Settings.Global.getFloat(
            context.contentResolver,
            Settings.Global.ANIMATOR_DURATION_SCALE,
            1f,
        ) != 0f
    }

    var showSplash by remember { mutableStateOf(animationsEnabled) }

    Box(modifier = Modifier.fillMaxSize()) {
        content()

        AnimatedVisibility(
            visible = showSplash,
            enter = EnterTransition.None,
            exit = fadeOut(animationSpec = tween(durationMillis = 600)),
        ) {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(Color(0xFF07070A)),
                contentAlignment = Alignment.Center,
            ) {
                BurnBarLogoFormation(
                    modifier = Modifier
                        .fillMaxSize()
                        .padding(24.dp),
                )
            }
        }
    }

    if (animationsEnabled) {
        LaunchedEffect(Unit) {
            delay(durationMillis)
            showSplash = false
        }
    }
}
