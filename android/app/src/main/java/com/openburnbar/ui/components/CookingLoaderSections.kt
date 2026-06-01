@file:Suppress("MagicNumber")
// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.components

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.openburnbar.R
import kotlin.math.abs
import kotlin.math.sin

@Composable
internal fun CookingLoaderSkillet(size: Dp, label: String?, reduceMotion: Boolean) {
    if (reduceMotion) {
        Image(
            painter = painterResource(id = R.drawable.ic_cooking_skillet),
            contentDescription = label ?: "Loading",
            modifier =
            Modifier
                .size(size)
                .graphicsLayer { alpha = 0.92f },
        )
        return
    }

    val infiniteTransition = rememberInfiniteTransition(label = "skillet-dance")
    val animationProgress by infiniteTransition.animateFloat(
        initialValue = 0f,
        targetValue = 1f,
        animationSpec =
        infiniteRepeatable(
            animation = tween(1600, easing = LinearEasing),
            repeatMode = RepeatMode.Restart,
        ),
        label = "dance-progress",
    )

    val phase = animationProgress
    val s = sin(phase * Math.PI * 2).toFloat()
    val bounceValue =
        if (s > 0) {
            Math.pow(s.toDouble(), 0.7).toFloat()
        } else {
            -Math.pow(abs(s).toDouble(), 1.4).toFloat() * 0.3f
        }
    val bounceOffset = -bounceValue * size.value * 0.12f
    val lagged = (phase + 0.15f) % 1.0f
    val swayRotation = sin(lagged * Math.PI * 2).toFloat() * 5.0f
    val squashScale = 1.0f + s * 0.04f

    Image(
        painter = painterResource(id = R.drawable.ic_cooking_skillet),
        contentDescription = label ?: "Loading",
        modifier =
        Modifier
            .size(size)
            .graphicsLayer {
                translationY = bounceOffset.dp.toPx()
                rotationZ = swayRotation
                scaleX = squashScale
                scaleY = squashScale
            },
    )
}
