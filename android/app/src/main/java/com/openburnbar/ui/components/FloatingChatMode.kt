package com.openburnbar.ui.components

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.unit.dp
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraMotion
import com.openburnbar.ui.theme.AuroraRadius
import com.openburnbar.ui.theme.AuroraShadows
import com.openburnbar.ui.theme.AuroraSpacing

/** Mode that determines how `FloatingChatPill` displays itself. */
enum class FloatingChatMode { Idle, Streaming, Hidden }

/**
 * Floating chat pill — Aurora glass capsule that sits above the nav scaffold
 * and shows the last assistant snippet or a streaming indicator. Mirrors the
 * iOS `ChatMinimizedPill`. Tap → opens HermesView (caller-owned `onTap`); drag
 * → repositions the pill within its parent.
 *
 * The pill is intentionally a self-contained, stateful overlay — the parent
 * scaffold supplies the message stream and a tap callback; everything else
 * (position, press scale, render tier) lives here.
 */
@Composable
fun FloatingChatPill(snippet: String, mode: FloatingChatMode, onTap: () -> Unit, modifier: Modifier = Modifier, accent: Color = AuroraColors.hermesAureate) {
    // Only surface the pill when there's actual conversational signal — either
    // Hermes is mid-stream or we have a meaningful snippet to preview. An empty
    // pill on a fresh dashboard is visual noise.
    if (mode == FloatingChatMode.Hidden) return
    if (mode == FloatingChatMode.Idle && snippet.isBlank()) return

    var pressed by remember { mutableStateOf(false) }
    var offsetX by remember { mutableStateOf(0f) }
    var offsetY by remember { mutableStateOf(0f) }

    val scale by animateFloatAsState(
        targetValue = if (pressed) 0.97f else 1f,
        animationSpec = AuroraMotion.cardPressSpec(),
        label = "floating-chat-pill-scale",
    )

    Box(
        modifier =
        modifier
            .padding(AuroraSpacing.MD.dp)
            .graphicsLayer {
                translationX = offsetX
                translationY = offsetY
                scaleX = scale
                scaleY = scale
            }
            .heightIn(min = 44.dp)
            .widthIn(min = 180.dp, max = 280.dp)
            .auroraGlass(
                cornerRadius = AuroraRadius.FULL.dp,
                tintAlpha = 0.85f,
                shadow = AuroraShadows.cardHover,
            )
            .pointerInput(Unit) {
                detectDragGestures(
                    onDragEnd = { /* offset persists; no settle for now */ },
                    onDrag = { change, drag ->
                        change.consume()
                        offsetX += drag.x
                        offsetY += drag.y
                    },
                )
            }
            .pointerInput(onTap) {
                detectTapGestures(
                    onPress = {
                        pressed = true
                        val released = tryAwaitRelease()
                        pressed = false
                        if (released) onTap()
                    },
                )
            }
            .padding(horizontal = AuroraSpacing.LG.dp, vertical = AuroraSpacing.SM.dp),
        contentAlignment = Alignment.CenterStart,
    ) {
        FloatingChatPillContent(snippet = snippet, mode = mode, accent = accent)
    }
}
