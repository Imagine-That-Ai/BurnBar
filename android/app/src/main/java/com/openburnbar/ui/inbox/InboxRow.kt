// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.inbox

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
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
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.openburnbar.data.inbox.AIInboxRow
import com.openburnbar.data.policy.MobileAccessibilityLabelPolicy
import com.openburnbar.ui.components.AuroraBadge
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraRadius
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraType

// MARK: - Inbox list row
//
// One item as it reads in the list: kind glyph, title, and the one line of
// context that decides whether the item is worth opening. The unread dot and
// priority badge carry urgency; everything else is deliberately quiet, because a
// list where every row shouts is a list nobody scans.

@Composable
internal fun InboxRow(row: AIInboxRow, isSelected: Boolean, nowEpoch: Long, onClick: () -> Unit, modifier: Modifier = Modifier) {
    val item = row.item
    val unread = row.isUnread()
    val accent = InboxPresentation.tint(item.kind)

    Row(
        verticalAlignment = Alignment.Top,
        modifier =
        modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(AuroraRadius.MD.dp))
            .background(
                if (isSelected) {
                    MaterialTheme.colorScheme.primary.copy(alpha = 0.12f)
                } else {
                    Color.Transparent
                },
            )
            .border(
                width = if (isSelected) 0.75.dp else 0.dp,
                color = if (isSelected) accent.copy(alpha = 0.35f) else Color.Transparent,
                shape = RoundedCornerShape(AuroraRadius.MD.dp),
            )
            .clickable(onClick = onClick)
            .padding(horizontal = AuroraSpacing.MD.dp, vertical = AuroraSpacing.SM.dp)
            .semantics { contentDescription = inboxRowAccessibilityLabel(row) },
    ) {
        InboxRowLeading(row = row, accent = accent, unread = unread)
        Spacer(modifier = Modifier.width(AuroraSpacing.SM.dp))
        Column(verticalArrangement = Arrangement.spacedBy(3.dp), modifier = Modifier.weight(1f)) {
            Text(
                text = item.title,
                style = AuroraType.body,
                fontWeight = if (unread) FontWeight.SemiBold else FontWeight.Normal,
                color = MaterialTheme.colorScheme.onSurface,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
            InboxRowSubtitle(row = row, nowEpoch = nowEpoch)
        }
        Spacer(modifier = Modifier.width(AuroraSpacing.SM.dp))
        AuroraBadge(
            text = InboxPresentation.priorityLabel(item.priority),
            tone = InboxPresentation.priorityTone(item.priority),
        )
    }
}

@Composable
private fun InboxRowLeading(row: AIInboxRow, accent: Color, unread: Boolean) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Icon(
            imageVector = InboxPresentation.icon(row.item.kind),
            contentDescription = null,
            tint = accent,
            modifier = Modifier.size(16.dp),
        )
        Spacer(modifier = Modifier.size(4.dp))
        // The unread dot occupies its slot whether or not it is drawn, so a row
        // does not shift horizontally the instant it is read.
        Box(
            modifier =
            Modifier
                .size(6.dp)
                .clip(CircleShape)
                .background(if (unread) accent else Color.Transparent),
        )
    }
}

@Composable
private fun InboxRowSubtitle(row: AIInboxRow, nowEpoch: Long) {
    Text(
        text = inboxRowSubtitle(row, nowEpoch),
        style = AuroraType.tiny,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        maxLines = 1,
        overflow = TextOverflow.Ellipsis,
    )
}

/**
 * The one line under a title. Ordered by what settles the "should I open this"
 * question fastest: what kind of claim it is, where it happened, how long it has
 * been happening, and whether it is already closed.
 */
internal fun inboxRowSubtitle(row: AIInboxRow, nowEpoch: Long): String {
    val item = row.item
    val parts = mutableListOf(InboxPresentation.kindLabel(item.kind))
    item.projectName?.let(parts::add)
    parts.add(inboxRelativeTime(item.lastSeenAtEpoch, nowEpoch))
    if (item.occurrenceCount > 1) parts.add("seen ${item.occurrenceCount}×")
    if (!item.state.isOpen) parts.add("resolved")
    if (row.isSnoozed(nowEpoch)) parts.add("snoozed")
    return parts.joinToString(" · ")
}

/** Spoken form of a row, so the list is navigable without reading the chrome. */
internal fun inboxRowAccessibilityLabel(row: AIInboxRow): String =
    MobileAccessibilityLabelPolicy.inboxRow(
        unread = row.isUnread(),
        kindLabel = InboxPresentation.kindLabel(row.item.kind),
        priorityLabel = InboxPresentation.priorityLabel(row.item.priority).takeIf { row.item.priority.rank <= 2 },
        title = row.item.title,
    )

/**
 * Coarse relative time. Deliberately vague past a week: "3 weeks ago" is a more
 * honest summary of a stale item than a false-precision date.
 */
internal fun inboxRelativeTime(epoch: Long, nowEpoch: Long): String {
    val delta = nowEpoch - epoch
    if (delta < 0) return "just now"
    val minutes = delta / 60_000
    if (minutes < 1) return "just now"
    if (minutes < 60) return "${minutes}m ago"
    val hours = minutes / 60
    if (hours < 24) return "${hours}h ago"
    val days = hours / 24
    if (days < 7) return "${days}d ago"
    val weeks = days / 7
    if (weeks < 5) return if (weeks == 1L) "1 week ago" else "$weeks weeks ago"
    val months = days / 30
    return if (months <= 1L) "1 month ago" else "$months months ago"
}

/** Section heading above a run of rows. */
@Composable
internal fun InboxSectionHeader(title: String, count: Int, modifier: Modifier = Modifier) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = modifier.fillMaxWidth().padding(horizontal = AuroraSpacing.MD.dp, vertical = AuroraSpacing.XS.dp),
    ) {
        Text(
            text = title.uppercase(),
            style = AuroraType.tiny,
            fontWeight = FontWeight.Bold,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(modifier = Modifier.weight(1f))
        Text(
            text = "$count",
            style = AuroraType.monoTiny,
            color = AuroraColors.hermesMercury,
        )
    }
}
