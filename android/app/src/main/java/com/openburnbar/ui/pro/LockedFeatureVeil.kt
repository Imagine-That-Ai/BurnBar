package com.openburnbar.ui.pro

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.blur
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.openburnbar.ui.theme.LocalAuroraReduceMotion

/**
 * Pro vocabulary — frosted mercury veil over a locked feature. Content
 * behind is rendered blurred-but-visible so the user *sees* what they're
 * missing. Centered CTA inside a MercuryFoilCard.
 *
 * Skip rendering this and just show `background` when the user is a member.
 */
@Composable
fun LockedFeatureVeil(
    headline: String,
    detail: String,
    onCta: () -> Unit,
    modifier: Modifier = Modifier,
    ctaLabel: String = "Open Cloud",
    background: @Composable () -> Unit
) {
    val reduceMotion = LocalAuroraReduceMotion.current

    Box(
        modifier = modifier.fillMaxSize(),
        contentAlignment = Alignment.Center
    ) {
        Box(
            modifier = Modifier
                .fillMaxSize()
                .blur(radius = 16.dp)
                .alpha(0.7f)
        ) {
            background()
        }

        // Obsidian veil
        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(
                    brush = Brush.verticalGradient(
                        colors = listOf(
                            ProPalette.obsidian.copy(alpha = 0.55f),
                            ProPalette.obsidian.copy(alpha = 0.82f)
                        )
                    )
                )
        )

        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(18.dp),
            modifier = Modifier.padding(horizontal = 28.dp)
        ) {
            MercuryCrest(size = MercuryCrestSize.Large, shimmer = !reduceMotion)
            Text(
                text = headline,
                style = ProTypography.titleSerif,
                color = ProPalette.mercury,
                textAlign = TextAlign.Center
            )
            Text(
                text = detail,
                style = ProTypography.headlineSerif.copy(fontWeight = androidx.compose.ui.text.font.FontWeight.Normal),
                color = ProPalette.mercury.copy(alpha = 0.72f),
                textAlign = TextAlign.Center
            )
            FoilCTAButton(
                title = ctaLabel,
                onClick = onCta,
                fillWidth = false,
                modifier = Modifier.widthIn(min = 220.dp, max = 320.dp)
            )
        }
    }
}
