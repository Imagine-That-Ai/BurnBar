@file:Suppress("MagicNumber")
// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures structure.

package com.openburnbar.ui.control

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.openburnbar.data.domains.DataDomain
import com.openburnbar.data.domains.EncryptionTier
import com.openburnbar.data.domains.PensieveControlTokens
import com.openburnbar.ui.components.AuroraGlassCard
import com.openburnbar.ui.theme.AuroraRadius
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraType

/**
 * Tier chip rendered directly from the encryption-tier design tokens (amber /
 * steel / teal). Not AuroraBadge — tier colors are token-canonical and must not
 * drift to the semantic palette.
 */
@Composable
internal fun TierChip(tier: EncryptionTier, modifier: Modifier = Modifier) {
    val color = PensieveControlTokens.tierColor(tier)
    Row(
        modifier =
        modifier
            .background(color.copy(alpha = 0.14f), RoundedCornerShape(AuroraRadius.full.dp))
            .border(0.75.dp, color.copy(alpha = 0.45f), RoundedCornerShape(AuroraRadius.full.dp))
            .padding(horizontal = AuroraSpacing.sm.dp, vertical = 2.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(modifier = Modifier.size(7.dp).background(color, CircleShape))
        Spacer(modifier = Modifier.width(AuroraSpacing.xs.dp))
        Text(PensieveControlTokens.tierLabel(tier), style = AuroraType.tiny, color = color)
    }
}

/**
 * The Transparency Inventory — every data domain from the registry, with its
 * encryption tier, plain-language summary, and live footprint. Tapping a row
 * opens its per-domain control pane. Locked (entitlement-gated) domains show a
 * subtle lock cue but stay visible so the user always sees the full picture.
 */
@Composable
internal fun TransparencyInventoryItem(
    row: DomainRow,
    tier: DataTier,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    selected: Boolean = false,
    onUnlock: ((com.openburnbar.ui.pro.GatedFeature) -> Unit)? = null,
) {
    val domain = row.domain
    val locked = isDomainLocked(domain, tier)
    val accent = PensieveControlTokens.tierColor(domain.encryptionTier)
    val gatedFeature = if (locked) gatedFeatureForDomain(domain.id) else null

    AuroraGlassCard(
        modifier = modifier,
        interactive = true,
        // A locked marquee feature taps straight into the evocative unlock sheet
        // (spec §5) instead of opening a detail pane behind a raw lock string.
        onClick = { if (gatedFeature != null && onUnlock != null) onUnlock(gatedFeature) else onClick() },
        cornerRadius = AuroraRadius.lg,
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            DomainGlyph(accent = accent, selected = selected)
            Spacer(modifier = Modifier.width(AuroraSpacing.md.dp))
            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        domain.title,
                        style = AuroraType.headline.copy(fontWeight = FontWeight.SemiBold),
                        color = PensieveControlTokens.mercuryBright,
                    )
                    if (locked) {
                        Spacer(modifier = Modifier.width(AuroraSpacing.sm.dp))
                        com.openburnbar.ui.pro.TierLockBadge(tier = requiredCloudTierForDomain(domain.id))
                    }
                }
                Text(
                    domain.summary,
                    style = AuroraType.caption,
                    color = PensieveControlTokens.textMute,
                    maxLines = 2,
                    overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis,
                )
                Row(
                    horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    TierChip(domain.encryptionTier)
                    FootprintLabel(row)
                }
            }
            Icon(
                Icons.AutoMirrored.Filled.KeyboardArrowRight,
                contentDescription = "Open ${domain.title}",
                tint = PensieveControlTokens.textDim,
            )
        }
    }
}

@Composable
private fun DomainGlyph(accent: Color, selected: Boolean) {
    Box(
        modifier =
        Modifier
            .size(40.dp)
            .background(
                accent.copy(alpha = if (selected) 0.30f else 0.16f),
                CircleShape,
            )
            .border(
                width = if (selected) 1.25.dp else 0.75.dp,
                color = accent.copy(alpha = if (selected) 0.85f else 0.4f),
                shape = CircleShape,
            ),
        contentAlignment = Alignment.Center,
    ) {
        // Mercury bead — the basin substance, in the domain's tier color.
        Box(modifier = Modifier.size(14.dp).background(accent, CircleShape))
    }
}

@Composable
private fun FootprintLabel(row: DomainRow) {
    val parts = mutableListOf<String>()
    if (row.count > 0L) parts += "${formatCount(row.count)} items"
    if (row.bytes > 0L) parts += formatBytes(row.bytes)
    val text = if (parts.isEmpty()) "Empty" else parts.joinToString(" · ")
    Text(text, style = AuroraType.tiny, color = PensieveControlTokens.textDim)
}

/** A domain is "locked" when its entitlement gate exceeds the member's tier. */
internal fun isDomainLocked(domain: DataDomain, tier: DataTier): Boolean =
    when (domain.entitlementGate) {
        null -> false
        "burnbar_pro" -> tier == DataTier.FREE
        "burnbar_pro_max" -> tier != DataTier.PRO && tier != DataTier.ULTRA
        "burnbar_pro_max_ultra", "burnbar_ultra" -> tier != DataTier.ULTRA
        else -> false
    }
