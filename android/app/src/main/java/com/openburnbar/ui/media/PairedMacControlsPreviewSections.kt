// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.media

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.media.MediaControlStreamCoordinator
import com.openburnbar.ui.components.auroraGlass
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraShadows
import com.openburnbar.ui.theme.AuroraType

@Composable
internal fun MacScreenPreviewCard(
    phase: MediaControlStreamCoordinator.Phase,
    recoveringMercury: Boolean,
    pendingRequestID: String?,
    modifier: Modifier = Modifier,
) {
    val isPulsing = pairedMacPreviewIsPulsing(phase, recoveringMercury)
    val cameraColor = pairedMacPreviewCameraColor(phase, recoveringMercury)
    val pulse = rememberMacScreenPreviewPulse(isPulsing)
    val infiniteTransition = rememberInfiniteTransition(label = "live_radar")

    Box(
        modifier =
        modifier
            .fillMaxWidth()
            .aspectRatio(1.6f)
            .auroraGlass(cornerRadius = 24.dp, tintAlpha = 0.15f, shadow = AuroraShadows.large)
            .background(Color(0xFF0D1117))
            .padding(bottom = 12.dp),
    ) {
        MacScreenPreviewCameraBezel(
            isPulsing = isPulsing,
            phase = phase,
            cameraColor = cameraColor,
            pulseScale = pulse.pulseScale,
            cameraAlphaFinal = pulse.cameraAlphaFinal,
        )

        Box(
            modifier =
            Modifier
                .fillMaxSize()
                .padding(top = 18.dp, start = 10.dp, end = 10.dp, bottom = 4.dp)
                .clip(RoundedCornerShape(8.dp))
                .background(macScreenPreviewWallpaper()),
        ) {
            if (phase is MediaControlStreamCoordinator.Phase.Live) {
                MacScreenPreviewLiveRadar(infiniteTransition = infiniteTransition)
            } else {
                MacScreenPreviewTerminalOverlay(
                    phase = phase,
                    recoveringMercury = recoveringMercury,
                    pendingRequestID = pendingRequestID,
                )
            }
        }

        MacScreenPreviewBranding()
    }
}

private data class MacScreenPreviewPulseState(
    val pulseScale: Float,
    val cameraAlphaFinal: Float,
)

@Composable
private fun rememberMacScreenPreviewPulse(isPulsing: Boolean): MacScreenPreviewPulseState {
    val infiniteTransition = rememberInfiniteTransition(label = "camera_pulse")
    val cameraAlpha by infiniteTransition.animateFloat(
        initialValue = 0.4f,
        targetValue = 1.0f,
        animationSpec =
        infiniteRepeatable(
            animation = tween(1000, easing = LinearEasing),
            repeatMode = RepeatMode.Reverse,
        ),
        label = "camera_alpha",
    )
    val pulseScale by infiniteTransition.animateFloat(
        initialValue = 0.8f,
        targetValue = 1.6f,
        animationSpec =
        infiniteRepeatable(
            animation = tween(1000, easing = LinearEasing),
            repeatMode = RepeatMode.Reverse,
        ),
        label = "pulse_scale",
    )
    return MacScreenPreviewPulseState(
        pulseScale = pulseScale,
        cameraAlphaFinal = if (isPulsing) cameraAlpha else 1.0f,
    )
}

@Composable
private fun BoxScope.MacScreenPreviewCameraBezel(
    isPulsing: Boolean,
    phase: MediaControlStreamCoordinator.Phase,
    cameraColor: Color,
    pulseScale: Float,
    cameraAlphaFinal: Float,
) {
    Box(
        modifier =
        Modifier
            .align(Alignment.TopCenter)
            .padding(top = 6.dp)
            .size(12.dp),
        contentAlignment = Alignment.Center,
    ) {
        if (isPulsing || phase is MediaControlStreamCoordinator.Phase.Live) {
            Box(
                modifier =
                Modifier
                    .fillMaxSize()
                    .graphicsLayer {
                        scaleX = pulseScale
                        scaleY = pulseScale
                        alpha = (1.0f - pulseScale) * 0.7f
                    }
                    .background(cameraColor, shape = RoundedCornerShape(999.dp)),
            )
        }
        Box(
            modifier =
            Modifier
                .size(5.dp)
                .background(cameraColor.copy(alpha = cameraAlphaFinal), shape = RoundedCornerShape(999.dp)),
        )
    }
}

@Composable
private fun BoxScope.MacScreenPreviewLiveRadar(infiniteTransition: androidx.compose.animation.core.InfiniteTransition) {
    val waveProgress by infiniteTransition.animateFloat(
        initialValue = 0f,
        targetValue = 1f,
        animationSpec =
        infiniteRepeatable(
            animation = tween(3000, easing = LinearEasing),
            repeatMode = RepeatMode.Restart,
        ),
        label = "wave_progress",
    )

    MacScreenPreviewRadarCanvas(waveProgress = waveProgress)
    MacScreenPreviewMirroringBadge()
}

@Composable
private fun MacScreenPreviewRadarCanvas(waveProgress: Float) {
    Canvas(modifier = Modifier.fillMaxSize()) {
        val center = Offset(size.width / 2f, size.height / 2f)
        val maxRadius = size.minDimension * 0.8f
        for (i in 0..2) {
            val progress = (waveProgress + i / 3f) % 1f
            val radius = maxRadius * progress
            val alpha = (1f - progress) * 0.35f
            drawCircle(
                color = AuroraColors.successDark.copy(alpha = alpha),
                radius = radius,
                center = center,
                style = Stroke(width = 1.5.dp.toPx()),
            )
        }
        drawCircle(
            color = AuroraColors.successDark.copy(alpha = 0.2f),
            radius = 16.dp.toPx() * (1f + waveProgress * 0.3f),
            center = center,
        )
        drawCircle(
            color = AuroraColors.successDark,
            radius = 6.dp.toPx(),
            center = center,
        )
    }
}

@Composable
private fun BoxScope.MacScreenPreviewMirroringBadge() {
    Box(
        modifier =
        Modifier
            .align(Alignment.Center)
            .auroraGlass(cornerRadius = 14.dp, tintAlpha = 0.45f)
            .padding(horizontal = 14.dp, vertical = 8.dp),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Box(
                modifier =
                Modifier
                    .size(8.dp)
                    .background(AuroraColors.successDark, shape = RoundedCornerShape(999.dp)),
            )
            Text(
                text = "MIRRORING ACTIVE",
                style = AuroraType.monoTiny.copy(fontWeight = FontWeight.Bold, color = Color.White),
            )
        }
    }
}

@Composable
private fun BoxScope.MacScreenPreviewTerminalOverlay(phase: MediaControlStreamCoordinator.Phase, recoveringMercury: Boolean, pendingRequestID: String?) {
    Box(
        modifier =
        Modifier
            .align(Alignment.Center)
            .fillMaxWidth(0.92f)
            .fillMaxHeight(0.85f)
            .auroraGlass(cornerRadius = 12.dp, tintAlpha = 0.3f)
            .background(Color.Black.copy(alpha = 0.3f)),
    ) {
        Column(modifier = Modifier.fillMaxSize()) {
            MacScreenPreviewTerminalTitleBar()
            MacScreenPreviewTerminalBody(
                phase = phase,
                recoveringMercury = recoveringMercury,
                pendingRequestID = pendingRequestID,
            )
        }
    }
}

@Composable
private fun MacScreenPreviewTerminalTitleBar() {
    Row(
        modifier =
        Modifier
            .fillMaxWidth()
            .height(22.dp)
            .background(Color.White.copy(alpha = 0.05f))
            .padding(horizontal = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Row(horizontalArrangement = Arrangement.spacedBy(5.dp)) {
            Box(modifier = Modifier.size(6.dp).background(Color(0xFFFF5F56), shape = RoundedCornerShape(999.dp)))
            Box(modifier = Modifier.size(6.dp).background(Color(0xFFFFBD2E), shape = RoundedCornerShape(999.dp)))
            Box(modifier = Modifier.size(6.dp).background(Color(0xFF27C93F), shape = RoundedCornerShape(999.dp)))
        }
        Text(
            text = "openburnbar — zsh",
            style = AuroraType.monoTiny.copy(color = Color.White.copy(0.4f)),
            modifier = Modifier.fillMaxWidth(),
            textAlign = TextAlign.Center,
        )
    }
}

@Composable
private fun MacScreenPreviewTerminalBody(phase: MediaControlStreamCoordinator.Phase, recoveringMercury: Boolean, pendingRequestID: String?) {
    Column(
        modifier =
        Modifier
            .fillMaxSize()
            .padding(10.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Text(
            text = "Last login: Wed May 20 on ttys003",
            style = AuroraType.monoTiny.copy(color = Color.White.copy(0.35f)),
        )
        Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(
                text = "MacBook:~ admin$",
                style = AuroraType.monoTiny.copy(color = AuroraColors.whimsyDark),
            )
            Text(
                text = "./openburnbar --status",
                style = AuroraType.monoTiny.copy(color = Color.White),
            )
        }

        Text(
            text = pairedMacTerminalStatusLine(phase),
            style =
            AuroraType.monoTiny.copy(
                fontWeight = FontWeight.Bold,
                color = pairedMacTerminalStatusColor(phase),
            ),
        )

        if (recoveringMercury) {
            Text(
                text = ">> [MERCURY] Bootstrapping tunnel...",
                style = AuroraType.monoTiny.copy(color = AuroraColors.amber, fontWeight = FontWeight.Bold),
            )
        }

        if (pendingRequestID != null) {
            Text(
                text = ">> [PENDING] Waiting for screen authorization...",
                style = AuroraType.monoTiny.copy(color = AuroraColors.amber, fontWeight = FontWeight.Bold),
            )
        }
    }
}

@Composable
private fun BoxScope.MacScreenPreviewBranding() {
    Text(
        text = "BURNBAR",
        color = Color.White.copy(alpha = 0.12f),
        style =
        AuroraType.monoTiny.copy(
            fontSize = 8.sp,
            fontWeight = FontWeight.Bold,
            letterSpacing = 3.sp,
        ),
        modifier =
        Modifier
            .align(Alignment.BottomCenter)
            .padding(bottom = 2.dp),
    )
}

private fun pairedMacPreviewIsPulsing(phase: MediaControlStreamCoordinator.Phase, recoveringMercury: Boolean): Boolean =
    phase is MediaControlStreamCoordinator.Phase.Dialing ||
        phase is MediaControlStreamCoordinator.Phase.Reconnecting ||
        recoveringMercury

private fun pairedMacPreviewCameraColor(phase: MediaControlStreamCoordinator.Phase, recoveringMercury: Boolean): Color = when {
    phase is MediaControlStreamCoordinator.Phase.Live -> AuroraColors.successDark
    phase is MediaControlStreamCoordinator.Phase.Dialing ||
        phase is MediaControlStreamCoordinator.Phase.Reconnecting ||
        recoveringMercury -> AuroraColors.amber
    phase is MediaControlStreamCoordinator.Phase.Failed -> AuroraColors.errorDark
    else -> Color(0xFF4B5563)
}

private fun macScreenPreviewWallpaper(): Brush = Brush.linearGradient(
    colors =
    listOf(
        Color(0xFF0B0D19),
        Color(0xFF14132C),
        Color(0xFF28183B),
        Color(0xFF331D2D),
    ),
)

private fun pairedMacTerminalStatusLine(phase: MediaControlStreamCoordinator.Phase): String = when {
    phase is MediaControlStreamCoordinator.Phase.Idle -> ">> [IDLE] Waiting for connection request..."
    phase is MediaControlStreamCoordinator.Phase.Dialing -> ">> [DIALING] Initiating Iroh secure tunnel..."
    phase is MediaControlStreamCoordinator.Phase.Stopped -> ">> [STOPPED] Daemon inactive. Open Mac app to start."
    phase is MediaControlStreamCoordinator.Phase.Reconnecting -> ">> [RECONNECTING] Attempting peer recovery..."
    phase is MediaControlStreamCoordinator.Phase.Failed -> ">> [FAILED] Error: ${phase.reason}"
    else -> ">> [READY] Standby mode."
}

private fun pairedMacTerminalStatusColor(phase: MediaControlStreamCoordinator.Phase): Color = when {
    phase is MediaControlStreamCoordinator.Phase.Failed -> AuroraColors.errorDark
    phase is MediaControlStreamCoordinator.Phase.Dialing ||
        phase is MediaControlStreamCoordinator.Phase.Reconnecting -> AuroraColors.amber
    else -> Color.White.copy(0.85f)
}
