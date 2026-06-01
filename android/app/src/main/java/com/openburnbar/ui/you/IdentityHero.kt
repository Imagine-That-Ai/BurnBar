@file:Suppress("MagicNumber")
// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.you

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import com.openburnbar.data.stores.CloudSyncHealth
import com.openburnbar.ui.components.AuroraGlassCard

@Composable
fun IdentityHero(
    displayName: String,
    email: String?,
    photoUrl: String?,
    syncHealth: CloudSyncHealth,
    connectionsCount: Int,
    modifier: Modifier = Modifier,
) {
    val infiniteTransition = rememberInfiniteTransition(label = "halo")
    val haloRotation by infiniteTransition.animateFloat(
        initialValue = 0f,
        targetValue = 360f,
        animationSpec =
        infiniteRepeatable(
            animation = tween(18000, easing = LinearEasing),
            repeatMode = RepeatMode.Restart,
        ),
        label = "rotation",
    )

    AuroraGlassCard(modifier = modifier) {
        IdentityHeroCardContent(
            displayName = displayName,
            email = email,
            photoUrl = photoUrl,
            syncHealth = syncHealth,
            connectionsCount = connectionsCount,
            haloRotation = haloRotation,
        )
    }
}
