// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.pro

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

internal val FoilCTASubtitleStyle =
    TextStyle(
        fontFamily = FontFamily.SansSerif,
        fontWeight = androidx.compose.ui.text.font.FontWeight.Medium,
        fontSize = 11.sp,
        lineHeight = 15.sp,
    )

@Composable
internal fun FoilCTAShimmerLayer(shimmerPhase: Float, shape: RoundedCornerShape) {
    Box(
        modifier =
        Modifier
            .fillMaxSize()
            .background(
                brush =
                Brush.linearGradient(
                    colors =
                    listOf(
                        Color.Transparent,
                        ProPalette.mercury.copy(alpha = 0.18f),
                        Color.White.copy(alpha = 0.16f),
                        ProPalette.mercury.copy(alpha = 0.18f),
                        Color.Transparent,
                    ),
                    start = Offset(shimmerPhase * 400f, 0f),
                    end = Offset(shimmerPhase * 400f + 320f, 320f),
                ),
                shape = shape,
            ),
    )
}

@Composable
internal fun FoilCTAButtonRow(title: String, subtitle: String?, icon: ImageVector, isLoading: Boolean) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier =
        Modifier
            .padding(horizontal = 18.dp, vertical = 12.dp)
            .fillMaxWidth(),
    ) {
        if (isLoading) {
            CircularProgressIndicator(
                color = ProPalette.mercury,
                strokeWidth = 2.dp,
                modifier = Modifier.size(14.dp),
            )
        } else {
            Icon(
                imageVector = icon,
                contentDescription = null,
                tint = ProPalette.aureate,
                modifier = Modifier.size(16.dp),
            )
        }
        Spacer(Modifier.width(12.dp))
        Column(verticalArrangement = Arrangement.Center) {
            Text(
                text = title,
                style = ProTypography.headlineSerif,
                color = ProPalette.mercury,
            )
            if (!subtitle.isNullOrEmpty()) {
                Text(
                    text = subtitle,
                    style = FoilCTASubtitleStyle,
                    color = ProPalette.mercury.copy(alpha = 0.68f),
                )
            }
        }
        Spacer(Modifier.weight(1f))
        if (!isLoading) {
            Icon(
                imageVector = Icons.AutoMirrored.Filled.ArrowForward,
                contentDescription = null,
                tint = ProPalette.aureate,
                modifier = Modifier.size(14.dp),
            )
        }
    }
}
