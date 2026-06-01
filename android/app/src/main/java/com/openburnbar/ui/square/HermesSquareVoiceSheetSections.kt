@file:Suppress("MagicNumber")
// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.square

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.ui.theme.LocalAuroraReduceMotion
import kotlin.math.PI
import kotlin.math.sin

@Composable
internal fun VoiceSheetContent(
    state: VoiceSheetCaptureState,
    callbacks: VoiceHoldToTalkCallbacks,
) {
    Column(modifier = Modifier.fillMaxWidth().padding(horizontal = 24.dp, vertical = 18.dp)) {
        Text(
            "Voice command",
            fontSize = 18.sp,
            fontWeight = FontWeight.Bold,
            color = MaterialTheme.colorScheme.onSurface,
        )
        Spacer(modifier = Modifier.height(8.dp))
        VoiceTranscriptPanel(listening = state.listening, transcript = state.transcript)
        Spacer(modifier = Modifier.height(18.dp))
        VoiceHoldToTalkControl(state = state, callbacks = callbacks)
        state.errorMessage?.let { msg ->
            Spacer(modifier = Modifier.height(12.dp))
            Text(msg, color = MaterialTheme.colorScheme.error, fontSize = 12.sp)
        }
    }
}

@Composable
internal fun VoiceTranscriptPanel(listening: Boolean, transcript: String) {
    Surface(
        shape = RoundedCornerShape(10.dp),
        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.6f),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(modifier = Modifier.padding(14.dp)) {
            Text(
                if (listening) "Listening…" else "Hold to talk",
                fontSize = 11.sp,
                fontWeight = FontWeight.Bold,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Spacer(modifier = Modifier.height(4.dp))
            Text(
                if (transcript.isBlank()) {
                    "Try \"open Claude\", \"dispatch the brief to Codex\", or \"what's important?\""
                } else {
                    transcript
                },
                fontSize = 14.sp,
                color =
                if (transcript.isBlank()) {
                    MaterialTheme.colorScheme.onSurfaceVariant
                } else {
                    MaterialTheme.colorScheme.onSurface
                },
            )
        }
    }
}

@Composable
internal fun VoiceHoldToTalkControl(
    state: VoiceSheetCaptureState,
    callbacks: VoiceHoldToTalkCallbacks,
) {
    val pulseScale = voiceMicPulseScale(listening = state.listening)
    Box(contentAlignment = Alignment.Center, modifier = Modifier.fillMaxWidth().height(140.dp)) {
        VoiceMicButton(state = state, pulseScale = pulseScale, callbacks = callbacks)
    }
}

@Composable
private fun VoiceMicButton(
    state: VoiceSheetCaptureState,
    pulseScale: Float,
    callbacks: VoiceHoldToTalkCallbacks,
) {
    Box(
        contentAlignment = Alignment.Center,
        modifier =
        Modifier
            .size(if (state.listening) 108.dp else 96.dp)
            .scale(pulseScale)
            .clip(RoundedCornerShape(50))
            .background(
                Brush.linearGradient(
                    listOf(Color(0xFFF45B69), Color(0xFFFFA800)),
                ),
            )
            .voiceMicGesture(state = state, callbacks = callbacks),
    ) {
        Icon(Icons.Filled.Mic, contentDescription = "Hold to talk", tint = Color.White, modifier = Modifier.size(36.dp))
    }
}

@Composable
private fun voiceMicPulseScale(listening: Boolean): Float {
    val reduceMotion = LocalAuroraReduceMotion.current
    if (!listening || reduceMotion) return 1f
    val infiniteTransition = rememberInfiniteTransition(label = "voice-breath")
    val pulsePhase by infiniteTransition.animateFloat(
        initialValue = 0f,
        targetValue = (2 * PI).toFloat(),
        animationSpec = infiniteRepeatable(animation = tween(durationMillis = 1200, easing = LinearEasing), repeatMode = RepeatMode.Restart),
        label = "voice-breath-phase",
    )
    return 1.005f + 0.055f * sin(pulsePhase)
}

private fun Modifier.voiceMicGesture(
    state: VoiceSheetCaptureState,
    callbacks: VoiceHoldToTalkCallbacks,
): Modifier =
    pointerInput(state.permissionGranted, state.listening, state.transcript) {
        awaitPointerEventScope {
            while (true) {
                val event = awaitPointerEvent()
                val pressed = event.changes.any { it.pressed }
                if (pressed && !state.listening && state.permissionGranted) {
                    beginCapture(
                        recognizer = state.recognizer,
                        onPartial = callbacks.onTranscriptChange,
                        onFailure = { msg ->
                            callbacks.onCaptureError(msg)
                            callbacks.onListeningChange(false)
                        },
                    )
                    callbacks.onListeningChange(true)
                    callbacks.onCaptureStart()
                } else if (!pressed && state.listening) {
                    callbacks.onListeningChange(false)
                    state.recognizer.stopListening()
                    callbacks.onReleaseWithTranscript(state.transcript)
                }
            }
        }
    }

internal fun resolveVoiceIntentOnRelease(
    transcript: String,
    nameMap: Map<String, String>,
    currentThreadAgentURI: String?,
): AndroidVoiceIntent? {
    if (transcript.isBlank()) return null
    return AndroidVoiceIntentResolver.resolve(
        transcript = transcript,
        installedAgentNames = nameMap,
        currentThreadAgentURI = currentThreadAgentURI,
    )
}
