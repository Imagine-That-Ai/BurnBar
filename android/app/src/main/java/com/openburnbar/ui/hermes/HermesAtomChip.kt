package com.openburnbar.ui.hermes

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AccountCircle
import androidx.compose.material.icons.filled.AttachMoney
import androidx.compose.material.icons.filled.Build
import androidx.compose.material.icons.filled.Business
import androidx.compose.material.icons.filled.CalendarToday
import androidx.compose.material.icons.filled.ChatBubble
import androidx.compose.material.icons.filled.Computer
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.LocalFireDepartment
import androidx.compose.material.icons.filled.Memory
import androidx.compose.material.icons.filled.Numbers
import androidx.compose.material.icons.filled.OpenInNew
import androidx.compose.material.icons.filled.Psychology
import androidx.compose.material.icons.filled.Speed
import androidx.compose.material.icons.filled.Token
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.PlaceholderVerticalAlign
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.foundation.text.InlineTextContent
import androidx.compose.ui.text.Placeholder
import androidx.compose.ui.unit.em
import com.openburnbar.data.hermes.HermesAtom
import com.openburnbar.data.hermes.HermesAtomKind
import com.openburnbar.ui.theme.AuroraColors

// MARK: - Hermes Atom Chip (Compose)
//
// Atomic inline chip rendered for one `HermesAtom`. Backed by a typed atom,
// not a raw URL string — mirrors iOS `HermesAtomChip(atom:label:size:)`.
//
// Two surfaces:
//   • [HermesAtomChip] — standalone Composable suitable for grids / lists.
//   • [hermesAtomInlineTextContent] — builds the `InlineTextContent` entry a
//     `Text(buildAnnotatedString { … })` can use to flow the chip inline with
//     prose. The chip never breaks across lines.

/** Standalone atom chip. */
@Composable
fun HermesAtomChip(
    atom: HermesAtom,
    label: String,
    modifier: Modifier = Modifier,
    size: ChipSize = ChipSize.Standalone,
    onTap: ((HermesAtom) -> Unit)? = null
) {
    val accent = atomAccent(atom.kind)
    val cornerRadius = when (size) {
        ChipSize.Standalone -> 9.dp
        is ChipSize.Inline -> 7.dp
    }
    val hPad = when (size) {
        ChipSize.Standalone -> 10.dp
        is ChipSize.Inline -> 7.dp
    }
    val vPad = when (size) {
        ChipSize.Standalone -> 5.dp
        is ChipSize.Inline -> 1.5.dp
    }
    val fontSize = when (size) {
        ChipSize.Standalone -> 14.sp
        is ChipSize.Inline -> maxOf(11f, size.baseSize - 1f).sp
    }
    val iconSize = when (size) {
        ChipSize.Standalone -> 12.dp
        is ChipSize.Inline -> maxOf(9f, size.baseSize - 4f).dp
    }
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
        modifier = modifier
            .clip(RoundedCornerShape(cornerRadius))
            .then(if (onTap != null) Modifier.clickable { onTap(atom) } else Modifier)
            .background(accent.copy(alpha = 0.13f))
            .border(0.5.dp, accent.copy(alpha = 0.32f), RoundedCornerShape(cornerRadius))
            .padding(horizontal = hPad, vertical = vPad)
    ) {
        Icon(
            imageVector = iconForKind(atom.kind),
            contentDescription = null,
            tint = accent,
            modifier = Modifier.size(iconSize)
        )
        Text(
            text = label,
            color = accent,
            fontSize = fontSize,
            fontWeight = FontWeight.SemiBold,
            maxLines = 1
        )
    }
}

/** Legacy URL-driven entry point — kept for callers that already use raw URL strings. */
@Composable
fun HermesAtomChip(
    label: String,
    url: String,
    onClick: (String, String) -> Unit,
    modifier: Modifier = Modifier
) {
    val atom = com.openburnbar.data.hermes.HermesAtomURL.decode(url)
    if (atom != null) {
        HermesAtomChip(
            atom = atom,
            label = label,
            modifier = modifier,
            size = ChipSize.Inline(baseSize = 15f),
            onTap = { onClick(label, url) }
        )
    } else {
        // Unknown / undecodable URL — fall back to the previous look so
        // existing consumers don't lose visual fidelity.
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(4.dp),
            modifier = modifier
                .clip(RoundedCornerShape(7.dp))
                .clickable { onClick(label, url) }
                .background(AuroraColors.hermesMercury.copy(alpha = 0.13f))
                .border(0.5.dp, AuroraColors.hermesMercury.copy(alpha = 0.32f), RoundedCornerShape(7.dp))
                .padding(horizontal = 7.dp, vertical = 1.5.dp)
        ) {
            Icon(
                imageVector = Icons.Filled.OpenInNew,
                contentDescription = null,
                tint = AuroraColors.hermesMercury,
                modifier = Modifier.size(12.dp)
            )
            Spacer(modifier = Modifier.width(4.dp))
            Text(
                text = label,
                color = AuroraColors.hermesMercury,
                fontSize = 12.sp,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1
            )
        }
    }
}

/** Chip render-size variant — mirrors iOS `HermesAtomChip.ChipSize`. */
sealed class ChipSize {
    object Standalone : ChipSize()
    data class Inline(val baseSize: Float) : ChipSize()
}

/**
 * Build the `InlineTextContent` entry an annotated `Text` uses to flow
 * an atom chip inline with prose. The caller appends an `inlineContent`
 * span with `id = key`, calls this to register the renderer, and sets
 * the `width`/`height` to the placeholder values used here.
 *
 * Mirrors the iOS pretext rich-inline pipeline where atoms are placed
 * as atomic chips alongside body text — width is a coarse estimate
 * derived from the label length and the inline base size.
 */
fun hermesAtomInlineTextContent(
    atom: HermesAtom,
    label: String,
    baseSize: Float,
    onTap: ((HermesAtom) -> Unit)?
): InlineTextContent {
    // Estimate width: 7pt horizontal padding × 2 + 12pt icon + 4pt gap +
    // ~0.6em per label character. Mirrors the extraWidth math iOS sends
    // to pretext (`14 + 12 + 4` + label width).
    val charWidthEm = 0.62f
    val labelWidthEm = label.length * charWidthEm
    val chromeEm = (7 * 2 + 12 + 4) / baseSize
    val totalWidth = (labelWidthEm + chromeEm).coerceAtLeast(2.0f)
    return InlineTextContent(
        placeholder = Placeholder(
            width = totalWidth.em,
            height = 1.45.em,
            placeholderVerticalAlign = PlaceholderVerticalAlign.Center
        ),
        children = {
            HermesAtomChip(
                atom = atom,
                label = label,
                size = ChipSize.Inline(baseSize = baseSize),
                onTap = onTap
            )
        }
    )
}

internal fun atomAccent(kind: HermesAtomKind): Color = when (kind) {
    HermesAtomKind.COST -> AuroraColors.amber
    HermesAtomKind.SESSION -> AuroraColors.hermesAureate
    HermesAtomKind.PROVIDER -> AuroraColors.ember
    HermesAtomKind.MODEL -> AuroraColors.whimsy
    HermesAtomKind.WINDOW -> AuroraColors.hermesAureate
    HermesAtomKind.TOOL -> AuroraColors.blaze
    HermesAtomKind.PROJECT -> AuroraColors.amber
    HermesAtomKind.TOKENS -> AuroraColors.success
    HermesAtomKind.QUOTA -> AuroraColors.warning
    HermesAtomKind.RUNTIME -> AuroraColors.hermesAureate
}

internal fun iconForKind(kind: HermesAtomKind): ImageVector = when (kind) {
    HermesAtomKind.COST -> Icons.Filled.AttachMoney
    HermesAtomKind.SESSION -> Icons.Filled.ChatBubble
    HermesAtomKind.PROVIDER -> Icons.Filled.Business
    HermesAtomKind.MODEL -> Icons.Filled.Psychology
    HermesAtomKind.WINDOW -> Icons.Filled.CalendarToday
    HermesAtomKind.TOOL -> Icons.Filled.Build
    HermesAtomKind.PROJECT -> Icons.Filled.Folder
    HermesAtomKind.TOKENS -> Icons.Filled.Numbers
    HermesAtomKind.QUOTA -> Icons.Filled.Speed
    HermesAtomKind.RUNTIME -> Icons.Filled.Memory
}
