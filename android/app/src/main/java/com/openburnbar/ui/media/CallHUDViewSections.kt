// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.media

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ScreenShare
import androidx.compose.material.icons.automirrored.outlined.StopScreenShare
import androidx.compose.material.icons.filled.CallEnd
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.MicOff
import androidx.compose.material.icons.filled.Videocam
import androidx.compose.material.icons.filled.VideocamOff
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.IconButtonDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.ui.components.liquidGlassCircleButton
import com.openburnbar.ui.theme.AuroraColors

@Composable
internal fun CallHUDMercuryHairline(mercuryBrush: Brush) {
    Box(
        modifier =
        Modifier
            .fillMaxWidth()
            .height(1.dp)
            .background(mercuryBrush),
    )
}

@Composable
internal fun CallHUDDurationLabel(duration: String) {
    Text(
        text = duration,
        fontFamily = FontFamily.Monospace,
        fontSize = 14.sp,
        fontWeight = FontWeight.Medium,
        color = Color.White,
    )
}

internal data class CallHUDMediaState(
    val isMicMuted: Boolean,
    val isCameraMuted: Boolean,
    val isSharing: Boolean,
)

internal data class CallHUDControlCallbacks(
    val onMuteMic: () -> Unit,
    val onMuteCamera: () -> Unit,
    val onShareScreen: () -> Unit,
    val onEnd: () -> Unit,
)

@Composable
internal fun CallHUDControlStrip(
    media: CallHUDMediaState,
    callbacks: CallHUDControlCallbacks,
) {
    val isMicMuted = media.isMicMuted
    val isCameraMuted = media.isCameraMuted
    val isSharing = media.isSharing
    val onMuteMic = callbacks.onMuteMic
    val onMuteCamera = callbacks.onMuteCamera
    val onShareScreen = callbacks.onShareScreen
    val onEnd = callbacks.onEnd
    Row(
        horizontalArrangement = Arrangement.spacedBy(16.dp, Alignment.CenterHorizontally),
        modifier = Modifier.fillMaxWidth(),
    ) {
        CallHUDControl(
            onClick = onMuteMic,
            active = isMicMuted,
            activeIcon = Icons.Filled.MicOff,
            inactiveIcon = Icons.Filled.Mic,
        )
        CallHUDControl(
            onClick = onMuteCamera,
            active = isCameraMuted,
            activeIcon = Icons.Filled.VideocamOff,
            inactiveIcon = Icons.Filled.Videocam,
        )
        CallHUDControl(
            onClick = onShareScreen,
            active = isSharing,
            activeIcon = Icons.AutoMirrored.Outlined.StopScreenShare,
            inactiveIcon = Icons.AutoMirrored.Outlined.ScreenShare,
        )
        CallHUDControl(
            onClick = onEnd,
            active = false,
            activeIcon = Icons.Filled.CallEnd,
            inactiveIcon = Icons.Filled.CallEnd,
            accent = Color(0xFFD43030),
        )
    }
}

@Composable
private fun CallHUDControl(
    onClick: () -> Unit,
    active: Boolean,
    activeIcon: androidx.compose.ui.graphics.vector.ImageVector,
    inactiveIcon: androidx.compose.ui.graphics.vector.ImageVector,
    accent: Color = AuroraColors.hermesAureate,
) {
    IconButton(
        onClick = onClick,
        modifier = Modifier.liquidGlassCircleButton(diameter = 56.dp),
        colors = IconButtonDefaults.iconButtonColors(contentColor = accent),
    ) {
        Icon(
            imageVector = if (active) activeIcon else inactiveIcon,
            contentDescription = null,
            modifier = Modifier.size(22.dp),
        )
    }
}
