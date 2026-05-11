package com.openburnbar.ui.burn

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.blur
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.models.AgentProvider
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraSpacing

@Composable
fun ProviderAuroraAvatar(
    providerKey: String,
    size: Int = 48,
    showHalo: Boolean = true,
    modifier: Modifier = Modifier
) {
    val provider = AgentProvider.fromKey(providerKey)
    val color = provider?.let { Color(it.brandColor) } ?: AuroraColors.whimsy
    val accent = provider?.let { Color(it.accentColor) } ?: AuroraColors.ember

    Box(contentAlignment = Alignment.Center, modifier = modifier) {
        if (showHalo) {
            Box(
                modifier = Modifier
                    .size((size + 8).dp)
                    .clip(CircleShape)
                    .background(color.copy(alpha = 0.16f))
                    .blur(radius = 4.dp)
            )
        }
        Box(
            modifier = Modifier
                .size(size.dp)
                .clip(CircleShape)
                .background(
                    Brush.linearGradient(listOf(color, accent.copy(alpha = 0.7f)))
                )
                .border(
                    width = 1.dp,
                    color = color.copy(alpha = 0.35f),
                    shape = CircleShape
                ),
            contentAlignment = Alignment.Center
        ) {
            Text(
                text = provider?.displayName?.take(2)?.uppercase() ?: "?",
                color = Color.White,
                fontSize = (size / 3).sp,
                fontWeight = FontWeight.Bold
            )
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
