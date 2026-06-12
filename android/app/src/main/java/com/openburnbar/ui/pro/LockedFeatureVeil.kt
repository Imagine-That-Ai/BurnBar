@file:Suppress("MagicNumber")
// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.pro

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.blur
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.openburnbar.ui.theme.LocalAuroraReduceMotion

/**
 * Pro vocabulary — frosted mercury veil over a locked feature. Content behind is
 * rendered blurred-but-visible so the user *sees* what they're missing.
 *
 * Two ways to drive it:
 *  • [LockedFeatureVeil] taking a [GatedFeature] — the tier+feature-aware
 *    unlock experience (spec §4.4): the required tier's holographic crest, the
 *    feature name, its one-liner, the "what you'll unlock" bullets, a single
 *    "Unlock with <Tier>" FoilCTAButton, and a quiet "Maybe later".
 *  • The legacy headline/detail overload — kept so existing call sites compile;
 *    new gates should pass a [GatedFeature].
 *
 * Skip rendering this and just show `background` when the user's tier satisfies
 * the feature's requirement.
 */
@Composable
fun LockedFeatureVeil(
    feature: GatedFeature,
    onUnlock: () -> Unit,
    modifier: Modifier = Modifier,
    livePrice: String? = null,
    onMaybeLater: (() -> Unit)? = null,
    background: @Composable () -> Unit,
) {
    Box(
        modifier = modifier.fillMaxSize(),
        contentAlignment = Alignment.Center,
    ) {
        BlurredTeaser(background = background)
        Box(
            modifier =
            Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState()),
            contentAlignment = Alignment.Center,
        ) {
            FeatureUnlockAnatomy(
                feature = feature,
                livePrice = livePrice,
                onUnlock = onUnlock,
                onMaybeLater = onMaybeLater,
                modifier = Modifier.padding(horizontal = 28.dp, vertical = 36.dp),
            )
        }
    }
}

/**
 * Legacy string-driven veil. Retained for entry points that have not yet been
 * migrated to a [GatedFeature]. Renders the MercuryCrest (no tier crest) and a
 * generic CTA. Prefer the [GatedFeature] overload for new work.
 */
@Composable
fun LockedFeatureVeil(
    headline: String,
    detail: String,
    onCta: () -> Unit,
    modifier: Modifier = Modifier,
    ctaLabel: String = "Open Cloud",
    background: @Composable () -> Unit,
) {
    val reduceMotion = LocalAuroraReduceMotion.current
    Box(
        modifier = modifier.fillMaxSize(),
        contentAlignment = Alignment.Center,
    ) {
        BlurredTeaser(background = background)
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(18.dp),
            modifier = Modifier.padding(horizontal = 28.dp),
        ) {
            MercuryCrest(size = MercuryCrestSize.Large, shimmer = !reduceMotion)
            Text(
                text = headline,
                style = ProTypography.titleSerif,
                color = ProPalette.mercury,
                textAlign = TextAlign.Center,
            )
            Text(
                text = detail,
                style = ProTypography.headlineSerif.copy(fontWeight = FontWeight.Normal),
                color = ProPalette.mercury.copy(alpha = 0.72f),
                textAlign = TextAlign.Center,
            )
            FoilCTAButton(
                title = ctaLabel,
                onClick = onCta,
                fillWidth = false,
                modifier = Modifier.widthIn(min = 220.dp, max = 320.dp),
            )
        }
    }
}

/** The blurred teaser of the real feature + the obsidian veil over it. */
@Composable
private fun BlurredTeaser(background: @Composable () -> Unit) {
    Box(
        modifier =
        Modifier
            .fillMaxSize()
            .blur(radius = 16.dp)
            .alpha(0.7f),
    ) {
        background()
    }
    Box(
        modifier =
        Modifier
            .fillMaxSize()
            .background(
                brush =
                Brush.verticalGradient(
                    colors =
                    listOf(
                        ProPalette.obsidian.copy(alpha = 0.55f),
                        ProPalette.obsidian.copy(alpha = 0.82f),
                    ),
                ),
            ),
    )
}
