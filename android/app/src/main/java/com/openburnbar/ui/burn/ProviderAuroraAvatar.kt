package com.openburnbar.ui.burn

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.blur
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.openburnbar.data.models.AgentProvider
import com.openburnbar.ui.components.ProviderLogo
import com.openburnbar.ui.theme.AuroraColors

/**
 * Provider avatar with a soft blurred brand-tinted halo behind the actual
 * provider logo. Drop-in replacement for the older text-initials variant —
 * the rendered logo is the bundled PNG (or initials fallback when no asset
 * is available; see `ProviderLogo`).
 */
@Composable
fun ProviderAuroraAvatar(
    providerKey: String,
    size: Int = 48,
    showHalo: Boolean = true,
    modifier: Modifier = Modifier
) {
    val provider = AgentProvider.fromKey(providerKey)
    Box(contentAlignment = Alignment.Center, modifier = modifier) {
        if (showHalo) {
            Box(
                modifier = Modifier
                    .size((size + 12).dp)
                    .clip(CircleShape)
                    .background(Color.White.copy(alpha = 0.86f))
                    .blur(radius = 6.dp)
            )
        }

        if (provider != null) {
            ProviderLogo(
                provider = provider,
                size = size.dp,
                circular = true
            )
        } else {
            // Unknown provider — fallback to whimsy gradient circle with "?"
            Box(
                modifier = Modifier
                    .size(size.dp)
                    .clip(CircleShape)
                    .background(Color.White),
                contentAlignment = Alignment.Center
            ) {
                Text(text = "?", color = AuroraColors.whimsy, fontWeight = FontWeight.Bold)
            }
        }
    }
}

@Composable
fun ProviderAuroraAvatar(
    provider: AgentProvider,
    size: Int = 48,
    showHalo: Boolean = true,
    modifier: Modifier = Modifier
) {
    ProviderAuroraAvatar(
        providerKey = provider.key,
        size = size,
        showHalo = showHalo,
        modifier = modifier
    )
}
