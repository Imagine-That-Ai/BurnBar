// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.inbox

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import com.openburnbar.data.inbox.AIInboxAction
import com.openburnbar.data.inbox.AIInboxEvidence
import com.openburnbar.data.inbox.AIInboxItem
import com.openburnbar.data.inbox.AIInboxMemoryCandidate
import com.openburnbar.data.inbox.AIInboxVerdict
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraRadius
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraType
import kotlin.math.roundToInt

// MARK: - Inbox detail sections
//
// The reading surface is laid out in the shape of the claim itself: what
// happened, why we believe it, what you can do, and only then provenance.
// Evidence sits above actions on purpose — the user should be able to disbelieve
// an item before acting on it.

@Composable
internal fun InboxDetailSectionLabel(text: String) {
    Text(
        text = text.uppercase(),
        style = AuroraType.tiny,
        fontWeight = FontWeight.Bold,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
    )
}

// ── Body ─────────────────────────────────────────────────────────────────────

/**
 * Renders the markdown body. Any run that fails to parse as a delimiter is kept
 * as literal text, so a formatting quirk in a model-written brief never blanks
 * the item.
 */
@Composable
internal fun InboxDetailBody(markdown: String, onOpenLink: (String) -> Unit) {
    val spans = remember(markdown) { InboxMarkdown.parse(markdown) }
    val linkColor = AuroraColors.whimsy
    val codeBackground = MaterialTheme.colorScheme.surfaceVariant
    val annotated =
        remember(spans, linkColor, codeBackground) {
            inboxMarkdownAnnotated(spans, linkColor, codeBackground)
        }
    Text(
        text = annotated,
        style = AuroraType.body,
        color = MaterialTheme.colorScheme.onSurface,
    )
    val links = remember(spans) { spans.mapNotNull { it.linkURL }.distinct() }
    if (links.isNotEmpty()) {
        // Compose's `Text` cannot dispatch a per-span tap without a click
        // handler this layout does not carry, so links are surfaced as explicit
        // affordances rather than as unreachable inline styling.
        Spacer(modifier = Modifier.size(AuroraSpacing.SM.dp))
        FlowRowLinks(links = links, onOpenLink = onOpenLink)
    }
}

internal fun inboxMarkdownAnnotated(spans: List<InboxMarkdownSpan>, linkColor: Color, codeBackground: Color): AnnotatedString = buildAnnotatedString {
    for (span in spans) {
        val style =
            SpanStyle(
                fontWeight = if (span.bold) FontWeight.SemiBold else null,
                fontStyle = if (span.italic) FontStyle.Italic else null,
                fontFamily = if (span.code) FontFamily.Monospace else null,
                background = if (span.code) codeBackground else Color.Unspecified,
                color = if (span.linkURL != null) linkColor else Color.Unspecified,
                textDecoration = if (span.linkURL != null) TextDecoration.Underline else null,
            )
        withStyle(style) { append(span.text) }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun FlowRowLinks(links: List<String>, onOpenLink: (String) -> Unit) {
    FlowRow(
        horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.SM.dp),
        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.XS.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        for (link in links) {
            InboxChip(
                label = link.removePrefix("https://").removePrefix("http://").take(48),
                icon = Icons.Filled.ChevronRight,
                onClick = { onOpenLink(link) },
            )
        }
    }
}

// ── Metrics ──────────────────────────────────────────────────────────────────

@OptIn(ExperimentalLayoutApi::class)
@Composable
internal fun InboxDetailMetrics(metrics: Map<String, String>) {
    FlowRow(
        horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.SM.dp),
        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.XS.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        for ((label, value) in inboxDisplayMetrics(metrics)) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier =
                Modifier
                    .background(
                        MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.55f),
                        RoundedCornerShape(AuroraRadius.SM.dp),
                    )
                    .padding(horizontal = AuroraSpacing.SM.dp, vertical = AuroraSpacing.XS.dp),
            ) {
                Text(label, style = AuroraType.tiny, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Spacer(modifier = Modifier.width(AuroraSpacing.XS.dp))
                Text(value, style = AuroraType.monoSmall, color = MaterialTheme.colorScheme.onSurface)
            }
        }
    }
}

/**
 * Humanizes raw detector keys for display (`waste_rate` → "Waste rate",
 * `0.85` → "85%"). Kept pure and sorted so the chip order is stable between
 * renders and the formatting is unit-testable.
 */
internal fun inboxDisplayMetrics(metrics: Map<String, String>): List<Pair<String, String>> = metrics
    .toSortedMap()
    .map { (key, value) ->
        val words = key.replace('_', ' ')
        val label = words.replaceFirstChar { it.uppercaseChar() }
        val number = value.toDoubleOrNull()
        val display =
            when {
                number == null -> value
                key.endsWith("_rate") -> "${(number * 100).roundToInt()}%"
                key.endsWith("_usd") -> "$" + String.format(java.util.Locale.US, "%.3f", number)
                key.endsWith("_minutes") -> "${number.roundToInt()}m"
                else -> value
            }
        label to display
    }

// ── Evidence ─────────────────────────────────────────────────────────────────

@Composable
internal fun InboxEvidenceRow(evidence: AIInboxEvidence, onOpen: (AIInboxEvidence) -> Unit) {
    val hasTarget = evidence.url != null
    Row(
        verticalAlignment = Alignment.Top,
        modifier =
        Modifier
            .fillMaxWidth()
            .background(
                MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.42f),
                RoundedCornerShape(AuroraRadius.SM.dp),
            )
            .let { if (hasTarget) it.clickable { onOpen(evidence) } else it }
            .padding(AuroraSpacing.SM.dp),
    ) {
        Icon(
            imageVector = InboxPresentation.evidenceIcon(evidence.kind),
            contentDescription = null,
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.size(14.dp),
        )
        Spacer(modifier = Modifier.width(AuroraSpacing.SM.dp))
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(
                evidence.label,
                style = AuroraType.caption,
                color = MaterialTheme.colorScheme.onSurface,
                maxLines = 2,
            )
            evidence.detail?.let {
                Text(it, style = AuroraType.tiny, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 2)
            }
        }
        if (hasTarget) {
            Icon(
                imageVector = Icons.Filled.ChevronRight,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.size(14.dp),
            )
        }
    }
}

// ── Actions ──────────────────────────────────────────────────────────────────

@OptIn(ExperimentalLayoutApi::class)
@Composable
internal fun InboxDetailActions(actions: List<AIInboxAction>, onPerform: (AIInboxAction) -> Unit) {
    FlowRow(
        horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.SM.dp),
        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.XS.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        for (action in actions) {
            InboxChip(
                label = action.title,
                icon = InboxPresentation.actionIcon(action.kind),
                isPrimary = action.isPrimary,
                onClick = { onPerform(action) },
            )
        }
    }
}

@Composable
internal fun InboxChip(
    label: String,
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    onClick: () -> Unit,
    isPrimary: Boolean = false,
    modifier: Modifier = Modifier,
) {
    val shape = RoundedCornerShape(AuroraRadius.FULL.dp)
    val foreground = if (isPrimary) AuroraColors.ember else MaterialTheme.colorScheme.onSurface
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier =
        modifier
            .background(
                if (isPrimary) AuroraColors.ember.copy(alpha = 0.16f) else MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.6f),
                shape,
            )
            .border(0.75.dp, foreground.copy(alpha = if (isPrimary) 0.45f else 0.20f), shape)
            .clickable(onClick = onClick)
            .padding(horizontal = AuroraSpacing.MD.dp, vertical = AuroraSpacing.SM.dp),
    ) {
        Icon(imageVector = icon, contentDescription = null, tint = foreground, modifier = Modifier.size(13.dp))
        Spacer(modifier = Modifier.width(AuroraSpacing.XS.dp))
        Text(
            label,
            style = AuroraType.caption,
            fontWeight = if (isPrimary) FontWeight.SemiBold else FontWeight.Normal,
            color = foreground,
            maxLines = 1,
        )
    }
}

// ── Memory candidates ────────────────────────────────────────────────────────

/**
 * Proposed memories, read-only here.
 *
 * Approval on the Mac routes through the memory quarantine flow, which applies
 * PII screening, provenance, and audit treatment that Android has no equivalent
 * of. Rather than half-implement that authority, the phone shows the proposal
 * and says plainly where it can be acted on.
 */
@Composable
internal fun InboxMemoryCandidateCard(candidate: AIInboxMemoryCandidate) {
    Column(
        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.SM.dp),
        modifier =
        Modifier
            .fillMaxWidth()
            .background(
                MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.42f),
                RoundedCornerShape(AuroraRadius.MD.dp),
            )
            .padding(AuroraSpacing.MD.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(
                modifier =
                Modifier
                    .background(AuroraColors.amber.copy(alpha = 0.14f), RoundedCornerShape(AuroraRadius.FULL.dp))
                    .padding(horizontal = AuroraSpacing.SM.dp, vertical = 2.dp),
            ) {
                Text(candidate.kind.uppercase(), style = AuroraType.tiny, color = AuroraColors.amber)
            }
            Spacer(modifier = Modifier.weight(1f))
            Text(
                "${(candidate.confidence * 100).roundToInt()}%",
                style = AuroraType.monoTiny,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        Text(candidate.text, style = AuroraType.caption, color = MaterialTheme.colorScheme.onSurface)
    }
}

// ── Provenance ───────────────────────────────────────────────────────────────

/**
 * Plain-language provenance. This is a deliberate honesty feature: the user can
 * always see whether an item came from arithmetic or from a model, and whether
 * it survived an independent check. No jargon — "measured directly" beats
 * "deterministic detector".
 */
internal fun inboxProvenanceText(item: AIInboxItem): String {
    val source =
        if (item.modelProvenance == "local-rules") {
            "Measured directly on your Mac — no model was involved."
        } else {
            "Written by ${inboxFriendlyModelNames(item.modelProvenance)}."
        }
    val verification = item.payload.verification ?: return source
    return when (verification.verdict) {
        AIInboxVerdict.DETERMINISTIC -> listOfNotNull(source, verification.reason).joinToString(" ")
        AIInboxVerdict.CONFIRMED -> "$source A second model checked this and agreed."
        AIInboxVerdict.UNCLEAR -> "$source A second model could not confirm it, so it is ranked lower."
        AIInboxVerdict.UNVERIFIED -> "$source It was not independently checked."
        AIInboxVerdict.REFUTED -> source
    }
}

/** `deepseek:deepseek-v4-flash+openai:gpt-5.6-luna` → "deepseek-v4-flash and gpt-5.6-luna". */
internal fun inboxFriendlyModelNames(provenance: String): String = provenance
    .split("+")
    .map { component -> component.substringAfter(':', component) }
    .joinToString(" and ")
