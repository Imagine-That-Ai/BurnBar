// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ProvideTextStyle
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.unit.dp
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraGradients
import com.openburnbar.ui.theme.AuroraShadows
import com.openburnbar.ui.theme.AuroraSpacing

@Composable
internal fun AuroraGradientButtonSurface(
    modifier: Modifier,
    scale: Float,
    enabled: Boolean,
    loading: Boolean,
    clickModifier: Modifier,
    content: @Composable RowScope.() -> Unit,
) {
    val gradient =
        if (enabled) {
            Brush.linearGradient(colors = listOf(AuroraColors.ember, AuroraColors.amber))
        } else {
            Brush.linearGradient(
                colors =
                listOf(
                    AuroraColors.ember.copy(alpha = 0.35f),
                    AuroraColors.amber.copy(alpha = 0.35f),
                ),
            )
        }

    Box(
        modifier =
        modifier
            .graphicsLayer {
                scaleX = scale
                scaleY = scale
            }
            .shadow(
                elevation = AuroraShadows.medium.elevation,
                shape = AuroraButtonDefaults.shape,
                spotColor = Color.Black.copy(alpha = AuroraShadows.medium.spotAlpha),
                ambientColor = Color.Black.copy(alpha = AuroraShadows.medium.spotAlpha),
            )
            .clip(AuroraButtonDefaults.shape)
            .background(gradient, AuroraButtonDefaults.shape)
            .background(
                Brush.linearGradient(colors = AuroraGradients.glassSheen),
                AuroraButtonDefaults.shape,
            )
            .then(clickModifier)
            .padding(AuroraButtonDefaults.contentPadding),
        contentAlignment = Alignment.Center,
    ) {
        if (loading) {
            CircularProgressIndicator(
                color = Color.White,
                strokeWidth = 2.dp,
                modifier = Modifier.size(18.dp),
            )
        } else {
            ProvideTextStyle(
                MaterialTheme.typography.labelLarge.copy(
                    fontWeight = androidx.compose.ui.text.font.FontWeight.SemiBold,
                    color = Color.White,
                ),
            ) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.SM.dp),
                    content = content,
                )
            }
        }
    }
}
