package com.openburnbar.ui.components

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraMotion
import com.openburnbar.ui.theme.AuroraRadius
import com.openburnbar.ui.theme.AuroraShadows
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraType

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
fun FloatingChatPill(
    snippet: String,
    mode: FloatingChatMode,
    onTap: () -> Unit,
    modifier: Modifier = Modifier,
    accent: Color = AuroraColors.hermesAureate
) {
    if (mode == FloatingChatMode.Hidden) return

    var pressed by remember { mutableStateOf(false) }
    var offsetX by remember { mutableStateOf(0f) }
    var offsetY by remember { mutableStateOf(0f) }

    val scale by animateFloatAsState(
        targetValue = if (pressed) 0.97f else 1f,
        animationSpec = AuroraMotion.cardPressSpec(),
        label = "floating-chat-pill-scale"
    )

    Box(
        modifier = modifier
            .padding(AuroraSpacing.md.dp)
            .graphicsLayer {
                translationX = offsetX
                translationY = offsetY
                scaleX = scale
                scaleY = scale
            }
            .heightIn(min = 56.dp)
            .widthIn(min = 200.dp, max = 320.dp)
            .auroraGlass(
                cornerRadius = AuroraRadius.full.dp,
                shadow = AuroraShadows.cardHover
            )
            .pointerInput(Unit) {
                detectDragGestures(
                    onDragEnd = { /* offset persists; no settle for now */ },
                    onDrag = { change, drag ->
                        change.consume()
                        offsetX += drag.x
                        offsetY += drag.y
                    }
                )
            }
            .pointerInput(onTap) {
                detectTapGestures(
                    onPress = {
                        pressed = true
                        val released = tryAwaitRelease()
                        pressed = false
                        if (released) onTap()
                    }
                )
            }
            .padding(horizontal = AuroraSpacing.lg.dp, vertical = AuroraSpacing.sm.dp),
        contentAlignment = Alignment.CenterStart
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp)
        ) {
            Box(
                Modifier
                    .size(28.dp)
                    .clip(RoundedCornerShape(14.dp))
                    .background(accent.copy(alpha = 0.18f)),
                contentAlignment = Alignment.Center
            ) {
                if (mode == FloatingChatMode.Streaming) {
                    CircularProgressIndicator(
                        color = accent,
                        strokeWidth = 2.dp,
                        modifier = Modifier.size(14.dp)
                    )
                } else {
                    Icon(
                        imageVector = Icons.Filled.AutoAwesome,
                        contentDescription = null,
                        tint = accent,
                        modifier = Modifier.size(16.dp)
                    )
                }
            }

            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = if (mode == FloatingChatMode.Streaming) "Hermes is thinking…" else "Hermes",
                    style = AuroraType.tiny,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
                if (snippet.isNotBlank()) {
                    Text(
                        text = snippet,
                        style = AuroraType.caption,
                        color = MaterialTheme.colorScheme.onSurface,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )
                }
            }
        }
    }
}
