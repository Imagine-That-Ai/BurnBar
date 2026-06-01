@file:Suppress("MagicNumber")
// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.media

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import com.openburnbar.ui.theme.AuroraColors
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/**
 * Compose port of iOS `CallHUDView.swift`. Mercury 1:1 call HUD: top
 * timer, bottom strip with mic / camera / share / hang-up controls.
 * Black canvas, mercury-stroked top hairline.
 */
@Composable
fun CallHUDView(
    state: CallHUDState,
    onMuteMic: () -> Unit,
    onMuteCamera: () -> Unit,
    onShareScreen: () -> Unit,
    onEnd: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val isMicMuted by state.isMicMuted.collectAsState()
    val isCameraMuted by state.isCameraMuted.collectAsState()
    val isSharing by state.isSharingScreen.collectAsState()
    val duration by state.formattedDuration.collectAsState()

    val mercuryBrush =
        Brush.horizontalGradient(
            listOf(
                AuroraColors.hermesMercury.copy(alpha = 0.85f),
                AuroraColors.hermesAureate.copy(alpha = 0.7f),
            ),
        )

    Box(modifier = modifier.fillMaxSize().background(Color.Black)) {
        CallHUDMercuryHairline(mercuryBrush)

        Column(
            modifier = Modifier.fillMaxSize().padding(top = 12.dp, bottom = 32.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            CallHUDDurationLabel(duration)

            Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.BottomCenter) {
                CallHUDControlStrip(
                    media = CallHUDMediaState(isMicMuted, isCameraMuted, isSharing),
                    callbacks = CallHUDControlCallbacks(onMuteMic, onMuteCamera, onShareScreen, onEnd),
                )
            }
        }
    }
}

/** State holder driving `CallHUDView`. Wire from `CallSessionCoordinator`. */
class CallHUDState {
    private val _isMicMuted = MutableStateFlow(false)
    val isMicMuted: StateFlow<Boolean> = _isMicMuted

    private val _isCameraMuted = MutableStateFlow(false)
    val isCameraMuted: StateFlow<Boolean> = _isCameraMuted

    private val _isSharingScreen = MutableStateFlow(false)
    val isSharingScreen: StateFlow<Boolean> = _isSharingScreen

    private val _formattedDuration = MutableStateFlow("00:00")
    val formattedDuration: StateFlow<String> = _formattedDuration

    fun setMicMuted(muted: Boolean) {
        _isMicMuted.value = muted
    }

    fun setCameraMuted(muted: Boolean) {
        _isCameraMuted.value = muted
    }

    fun setSharingScreen(active: Boolean) {
        _isSharingScreen.value = active
    }

    fun updateDuration(formatted: String) {
        _formattedDuration.value = formatted
    }
}
