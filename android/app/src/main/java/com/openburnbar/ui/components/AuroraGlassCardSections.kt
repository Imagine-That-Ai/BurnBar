// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.components

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.openburnbar.ui.theme.AuroraMotion
import com.openburnbar.ui.theme.AuroraShadowSpec

@Composable
internal fun AuroraGlassCardSurface(
    state: AuroraGlassCardSurfaceState,
    content: @Composable ColumnScope.() -> Unit,
) {
    Card(
        shape = RoundedCornerShape(state.cornerRadius.dp),
        colors =
        CardDefaults.cardColors(
            containerColor = Color.White.copy(alpha = 0.07f),
            contentColor = MaterialTheme.colorScheme.onSurface,
        ),
        modifier =
        state.modifier
            .graphicsLayer(scaleX = state.scale, scaleY = state.scale)
            .shadow(
                elevation = state.shadow.elevation,
                shape = RoundedCornerShape(state.cornerRadius.dp),
                clip = false,
                ambientColor = Color.Black.copy(alpha = state.shadow.spotAlpha),
                spotColor = Color.Black.copy(alpha = state.shadow.spotAlpha),
            )
            .then(state.clickModifier)
            .border(
                width = 0.75.dp,
                brush =
                Brush.verticalGradient(
                    colors =
                    listOf(
                        Color.White.copy(alpha = 0.16f),
                        Color.White.copy(alpha = 0.04f),
                    ),
                ),
                shape = RoundedCornerShape(state.cornerRadius.dp),
            ),
    ) {
        Column(
            modifier = Modifier.padding(state.contentPadding),
            content = content,
        )
    }
}

@Composable
internal fun rememberAuroraGlassCardInteraction(
    interactive: Boolean,
    onClick: (() -> Unit)?,
): Pair<Float, Modifier> {
    var pressed by remember { mutableStateOf(false) }
    val targetScale = if (pressed && interactive) 0.98f else 1f
    val scale by animateFloatAsState(
        targetValue = targetScale,
        animationSpec = AuroraMotion.cardPressSpec(),
        label = "aurora-glass-card-scale",
    )
    val clickModifier =
        if (onClick != null) {
            Modifier.pointerInput(onClick) {
                detectTapGestures(
                    onPress = {
                        pressed = true
                        val released = tryAwaitRelease()
                        pressed = false
                        if (released) onClick()
                    },
                    onTap = { /* handled in onPress */ },
                )
            }
        } else {
            Modifier
        }
    return scale to clickModifier
}

internal data class AuroraGlassCardSurfaceState(
    val modifier: Modifier,
    val cornerRadius: Int,
    val contentPadding: Dp,
    val scale: Float,
    val clickModifier: Modifier,
    val shadow: AuroraShadowSpec,
)
