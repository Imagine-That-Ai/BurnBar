@file:Suppress("MagicNumber")
// Compose layout/animation literals; token-per-line extraction obscures structure.

package com.openburnbar.ui.control

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.openburnbar.data.domains.DataDomain
import com.openburnbar.data.domains.PensieveControlTokens
import com.openburnbar.ui.theme.AuroraRadius
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraType
import com.openburnbar.ui.theme.LocalAuroraReduceMotion

/**
 * The yours<->server flip: a single card with two facets the user toggles —
 * "What's yours" (device-only, never leaves your device) on the front, "What
 * the server sees" on the back. The flip is the literal embodiment of the
 * encryption promise. Frost-flip duration comes from the design tokens.
 */
@Composable
internal fun YoursServerFlipCard(domain: DataDomain, modifier: Modifier = Modifier) {
    var face by remember(domain.id) { mutableStateOf(BasinFace.YOURS) }
    val reduceMotion = LocalAuroraReduceMotion.current
    val rotation by animateFloatAsState(
        targetValue = if (face == BasinFace.YOURS) 0f else 180f,
        animationSpec = tween(durationMillis = if (reduceMotion) 0 else FROST_FLIP_MS),
        label = "yours-server-rotation",
    )
    val showingYours = rotation <= 90f

    Box(
        modifier =
        modifier
            .fillMaxWidth()
            .graphicsLayer {
                rotationY = rotation
                cameraDistance = 12f * density
            }
            .clip(RoundedCornerShape(AuroraRadius.lg.dp))
            .background(PensieveControlTokens.glassBgElevated)
            .border(
                width = 0.75.dp,
                color = PensieveControlTokens.glassLineBright,
                shape = RoundedCornerShape(AuroraRadius.lg.dp),
            )
            .clickable {
                face = if (face == BasinFace.YOURS) BasinFace.SERVER else BasinFace.YOURS
            }
            .padding(AuroraSpacing.lg.dp),
    ) {
        // Back face content is counter-rotated so text isn't mirrored.
        Box(modifier = Modifier.graphicsLayer { rotationY = if (showingYours) 0f else 180f }) {
            if (showingYours) {
                FlipFace(
                    accent = PensieveControlTokens.tierEndToEnd,
                    title = "What's yours",
                    subtitle = "Stays on your device — BurnBar never sees this.",
                    facets = domain.deviceOnly.ifEmpty { listOf("Nothing device-only for this domain.") },
                    hintColorless = domain.deviceOnly.isEmpty(),
                )
            } else {
                FlipFace(
                    accent = PensieveControlTokens.tierColor(domain.encryptionTier),
                    title = "What the server sees",
                    subtitle = PensieveControlTokens.tierPromise(domain.encryptionTier),
                    facets = domain.serverSees.ifEmpty { listOf("No server-readable facets.") },
                    hintColorless = domain.serverSees.isEmpty(),
                )
            }
        }
    }
}

@Composable
private fun FlipFace(
    accent: Color,
    title: String,
    subtitle: String,
    facets: List<String>,
    hintColorless: Boolean,
) {
    Column(verticalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp), modifier = Modifier.fillMaxWidth()) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(
                modifier =
                Modifier
                    .size(8.dp)
                    .clip(androidx.compose.foundation.shape.CircleShape)
                    .background(accent),
            )
            Spacer(modifier = Modifier.width(AuroraSpacing.sm.dp))
            Text(title, style = AuroraType.headline.copy(fontWeight = FontWeight.SemiBold), color = PensieveControlTokens.mercuryBright)
            Spacer(modifier = Modifier.width(AuroraSpacing.sm.dp))
            Text("Tap to flip", style = AuroraType.tiny, color = PensieveControlTokens.textDim)
        }
        Text(subtitle, style = AuroraType.caption, color = PensieveControlTokens.textMute)
        Spacer(modifier = Modifier.height(AuroraSpacing.xs.dp))
        facets.forEach { facet ->
            Row(verticalAlignment = Alignment.Top) {
                Text("•", style = AuroraType.body, color = accent.copy(alpha = if (hintColorless) 0.4f else 1f))
                Spacer(modifier = Modifier.width(AuroraSpacing.sm.dp))
                Text(
                    facet,
                    style = AuroraType.body,
                    color = if (hintColorless) PensieveControlTokens.textDim else PensieveControlTokens.textBase,
                )
            }
        }
    }
}

private const val FROST_FLIP_MS = 520
