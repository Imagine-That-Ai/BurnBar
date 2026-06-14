// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.pro

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.ui.theme.LocalAuroraReduceMotion

// ── The unlock experience (spec §4.3 / §4.4) ──
//
// One shared anatomy, rendered two ways:
//   • LockedFeatureVeil — full-screen features behind a blurred teaser.
//   • FeatureUnlockSheet — a ModalBottomSheet for a row/card/nav-link tap.
// Plus TierLockBadge — the resting holographic tier chip on a gated entry point.
//
// Honesty: copy comes verbatim from the GatedFeature catalog (spec §3). Prices
// are live from Play (passed in as `livePrice`) — never hardcode dollars here.

/**
 * The shared unlock anatomy: hero crest → tier chip → feature name → one-liner →
 * "What you'll unlock" bullets → footer (Available on <Tier>, live price, one
 * soft "Unlock with <Tier>" CTA, quiet "Maybe later").
 */
@Composable
fun FeatureUnlockAnatomy(
    feature: GatedFeature,
    onUnlock: () -> Unit,
    modifier: Modifier = Modifier,
    livePrice: String? = null,
    onMaybeLater: (() -> Unit)? = null,
) {
    val tier = feature.requiredTier
    Column(
        modifier = modifier.widthIn(max = 460.dp).fillMaxWidth(),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(18.dp),
    ) {
        HolographicCrestHero(tier = tier)
        TierLockChip(tier = tier)
        Text(
            text = feature.publicName,
            style = ProTypography.titleSerif,
            color = ProPalette.mercury,
            textAlign = TextAlign.Center,
        )
        Text(
            text = feature.oneLineBenefit,
            style = ProTypography.headlineSerif.copy(fontWeight = FontWeight.Normal),
            color = ProPalette.mercury.copy(alpha = 0.74f),
            textAlign = TextAlign.Center,
        )
        UnlockBulletList(feature.benefitBullets, tier = tier)
        UnlockFooter(
            tier = tier,
            livePrice = livePrice,
            onUnlock = onUnlock,
            onMaybeLater = onMaybeLater,
        )
    }
}

@Composable
private fun UnlockBulletList(bullets: List<String>, tier: CloudTier) {
    val accent = tier.holo.colors.first()
    Column(
        modifier = Modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text(
            "WHAT YOU'LL UNLOCK",
            fontSize = 10.sp,
            fontWeight = FontWeight.Black,
            letterSpacing = 2.0.sp,
            color = accent.copy(alpha = 0.9f),
        )
        bullets.forEach { bullet ->
            Row(verticalAlignment = Alignment.Top, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Icon(
                    Icons.Filled.AutoAwesome,
                    contentDescription = null,
                    tint = accent,
                    modifier = Modifier.size(16.dp).padding(top = 2.dp),
                )
                Text(
                    bullet,
                    fontSize = 13.sp,
                    lineHeight = 18.sp,
                    color = ProPalette.mercury.copy(alpha = 0.82f),
                )
            }
        }
    }
}

@Composable
private fun UnlockFooter(tier: CloudTier, livePrice: String?, onUnlock: () -> Unit, onMaybeLater: (() -> Unit)?) {
    Column(
        modifier = Modifier.fillMaxWidth(),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(
                "Available on ${tier.displayName}",
                fontSize = 12.sp,
                color = ProPalette.mercury.copy(alpha = 0.6f),
            )
            livePrice?.takeIf { it.isNotBlank() }?.let {
                Text("·", fontSize = 12.sp, color = ProPalette.mercury.copy(alpha = 0.4f))
                Text(it, style = ProTypography.priceMono.copy(fontSize = 13.sp), color = ProPalette.aureate)
            }
        }
        FoilCTAButton(
            title = "Unlock with ${tier.displayName}",
            onClick = onUnlock,
            fillWidth = false,
            modifier = Modifier.widthIn(min = 240.dp, max = 340.dp),
        )
        onMaybeLater?.let { later ->
            Text(
                "Maybe later",
                fontSize = 13.sp,
                fontWeight = FontWeight.Medium,
                color = ProPalette.mercury.copy(alpha = 0.55f),
                modifier =
                Modifier
                    .clickable(onClick = later)
                    .padding(vertical = 8.dp, horizontal = 16.dp),
            )
        }
    }
}

/**
 * A presented [ModalBottomSheet] for gating a row / card / nav-link tap (spec
 * §4.4). Same anatomy as the veil. Render when `show` is true; [onDismiss] hides
 * it (also wired to "Maybe later").
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FeatureUnlockSheet(feature: GatedFeature, show: Boolean, onUnlock: () -> Unit, onDismiss: () -> Unit, livePrice: String? = null) {
    if (!show) return
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = ProPalette.obsidian,
        dragHandle = {
            Box(
                modifier =
                Modifier
                    .padding(top = 12.dp)
                    .size(width = 40.dp, height = 4.dp)
                    .background(ProPalette.mercury.copy(alpha = 0.25f), CircleShape),
            )
        },
    ) {
        FeatureUnlockAnatomy(
            feature = feature,
            livePrice = livePrice,
            onUnlock = {
                onUnlock()
                onDismiss()
            },
            onMaybeLater = onDismiss,
            modifier = Modifier.padding(horizontal = 24.dp).padding(top = 8.dp, bottom = 36.dp),
        )
    }
}

/**
 * The resting denotation on a gated entry point (spec §4.3): a compact
 * holographic tier chip — the tier's mini crest + name, with a faint iridescent
 * sheen. A premium shimmer-lock, never a grey padlock. Reduce-motion → static.
 */
@Composable
fun TierLockBadge(tier: CloudTier, modifier: Modifier = Modifier) {
    if (tier == CloudTier.NONE) return
    val accent = tier.holo.colors.first()
    val shape = RoundedCornerShape(50)
    Row(
        modifier =
        modifier
            .background(
                brush = Brush.linearGradient(tier.holo.colors.map { it.copy(alpha = 0.16f) }),
                shape = shape,
            )
            .border(0.7.dp, accent.copy(alpha = 0.45f), shape)
            .padding(horizontal = 9.dp, vertical = 4.dp)
            .semantics { contentDescription = "${tier.displayName} feature, locked" },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        Image(
            painter = painterResource(id = tier.crestDrawable),
            contentDescription = null,
            modifier = Modifier.size(13.dp),
        )
        Text(
            tier.displayName,
            fontSize = 10.sp,
            fontWeight = FontWeight.Bold,
            letterSpacing = 0.3.sp,
            color = ProPalette.mercury.copy(alpha = 0.92f),
        )
    }
}

/**
 * The compact tier chip used inside the unlock hero — an uppercased pill ("CLOUD
 * PRO") with the tier's iridescent sheen.
 */
@Composable
private fun TierLockChip(tier: CloudTier) {
    val reduceMotion = LocalAuroraReduceMotion.current
    val accent = tier.holo.colors.first()
    val shape = RoundedCornerShape(50)
    Box(
        modifier =
        Modifier
            .background(
                brush = Brush.linearGradient(tier.holo.colors.map { it.copy(alpha = if (reduceMotion) 0.18f else 0.22f) }),
                shape = shape,
            )
            .border(0.8.dp, accent.copy(alpha = 0.5f), shape)
            .padding(horizontal = 12.dp, vertical = 5.dp),
    ) {
        Text(
            tier.displayName.uppercase(),
            fontSize = 11.sp,
            fontWeight = FontWeight.Black,
            letterSpacing = 1.8.sp,
            color = ProPalette.mercury,
        )
    }
}
