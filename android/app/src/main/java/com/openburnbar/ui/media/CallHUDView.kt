package com.openburnbar.ui.media

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CallEnd
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.MicOff
import androidx.compose.material.icons.filled.Videocam
import androidx.compose.material.icons.filled.VideocamOff
import androidx.compose.material.icons.automirrored.outlined.ScreenShare
import androidx.compose.material.icons.automirrored.outlined.StopScreenShare
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.IconButtonDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
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

    val mercuryBrush = Brush.horizontalGradient(
        listOf(
            AuroraColors.hermesMercury.copy(alpha = 0.85f),
            AuroraColors.hermesAureate.copy(alpha = 0.7f),
        )
    )

    Box(modifier = modifier.fillMaxSize().background(Color.Black)) {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(1.dp)
                .background(mercuryBrush),
        )

        Column(
            modifier = Modifier.fillMaxSize().padding(top = 12.dp, bottom = 32.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Text(
                text = duration,
                fontFamily = FontFamily.Monospace,
                fontSize = 14.sp,
                fontWeight = FontWeight.Medium,
                color = Color.White,
            )

            Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.BottomCenter) {
                Row(
                    horizontalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(16.dp, Alignment.CenterHorizontally),
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    HudControl(
                        onClick = onMuteMic,
                        active = isMicMuted,
                        activeIcon = Icons.Filled.MicOff,
                        inactiveIcon = Icons.Filled.Mic,
                    )
                    HudControl(
                        onClick = onMuteCamera,
                        active = isCameraMuted,
                        activeIcon = Icons.Filled.VideocamOff,
                        inactiveIcon = Icons.Filled.Videocam,
                    )
                    HudControl(
                        onClick = onShareScreen,
                        active = isSharing,
                        activeIcon = Icons.AutoMirrored.Outlined.StopScreenShare,
                        inactiveIcon = Icons.AutoMirrored.Outlined.ScreenShare,
                    )
                    HudControl(
                        onClick = onEnd,
                        active = false,
                        activeIcon = Icons.Filled.CallEnd,
                        inactiveIcon = Icons.Filled.CallEnd,
                        accent = Color(0xFFD43030),
                    )
                }
            }
        }
    }
}

@Composable
private fun HudControl(
    onClick: () -> Unit,
    active: Boolean,
    activeIcon: androidx.compose.ui.graphics.vector.ImageVector,
    inactiveIcon: androidx.compose.ui.graphics.vector.ImageVector,
    accent: Color = AuroraColors.hermesAureate,
) {
    IconButton(
        onClick = onClick,
        modifier = Modifier.size(56.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.10f)),
        colors = IconButtonDefaults.iconButtonColors(contentColor = accent),
    ) {
        Icon(
            imageVector = if (active) activeIcon else inactiveIcon,
            contentDescription = null,
            modifier = Modifier.size(22.dp),
        )
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

    fun setMicMuted(muted: Boolean) { _isMicMuted.value = muted }
    fun setCameraMuted(muted: Boolean) { _isCameraMuted.value = muted }
    fun setSharingScreen(active: Boolean) { _isSharingScreen.value = active }
    fun updateDuration(formatted: String) { _formattedDuration.value = formatted }
}
