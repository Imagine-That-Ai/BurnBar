// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.inbox

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.widget.Toast
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Archive
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material.icons.filled.ThumbDown
import androidx.compose.material.icons.filled.ThumbUp
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.core.net.toUri
import com.openburnbar.data.inbox.AIInboxAction
import com.openburnbar.data.inbox.AIInboxActionKind
import com.openburnbar.data.inbox.AIInboxEvidence
import com.openburnbar.data.inbox.AIInboxRow
import com.openburnbar.data.inbox.AIInboxSnoozeInterval
import com.openburnbar.ui.components.AuroraBadge
import com.openburnbar.ui.components.AuroraBadgeTone
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraRadius
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraType

// MARK: - Inbox item detail
//
// The reading surface for one item. Mirrors the Mac `InboxItemDetailView`
// section order — header, brief, numbers, evidence, memory proposals, next
// steps, provenance footer — because the order encodes the argument: claim,
// then reasons, then only afterwards what to do about it.

@Composable
internal fun InboxDetail(row: AIInboxRow, nowEpoch: Long, callbacks: InboxDetailCallbacks, modifier: Modifier = Modifier) {
    val item = row.item
    val context = LocalContext.current
    Column(
        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.LG.dp),
        modifier =
        modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(AuroraSpacing.LG.dp),
    ) {
        InboxDetailHeader(row = row, nowEpoch = nowEpoch)

        if (item.summaryMarkdown.isNotBlank()) {
            InboxDetailBody(
                markdown = item.summaryMarkdown,
                onOpenLink = { url -> openInboxTarget(context, url, callbacks.onOpenRoute) },
            )
        }

        if (item.payload.metrics.isNotEmpty()) {
            InboxDetailSectionLabel("By the numbers")
            InboxDetailMetrics(item.payload.metrics)
        }

        if (item.payload.evidence.isNotEmpty()) {
            InboxDetailSectionLabel("Evidence")
            Column(verticalArrangement = Arrangement.spacedBy(AuroraSpacing.XS.dp)) {
                for (evidence in item.payload.evidence) {
                    InboxEvidenceRow(evidence) { openInboxEvidence(context, it, callbacks.onOpenRoute) }
                }
            }
        }

        if (item.payload.memoryCandidates.isNotEmpty()) {
            InboxDetailMemorySection(row = row)
        }

        if (item.payload.actions.isNotEmpty()) {
            InboxDetailSectionLabel("Next")
            InboxDetailActions(item.payload.actions) { performInboxAction(context, it, callbacks.onOpenRoute) }
        }

        InboxDetailFooter(row = row, callbacks = callbacks)
    }
}

@Composable
private fun InboxDetailHeader(row: AIInboxRow, nowEpoch: Long) {
    val item = row.item
    Column(verticalArrangement = Arrangement.spacedBy(AuroraSpacing.SM.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(
                imageVector = InboxPresentation.icon(item.kind),
                contentDescription = null,
                tint = InboxPresentation.tint(item.kind),
                modifier = Modifier.size(15.dp),
            )
            Spacer(modifier = Modifier.width(AuroraSpacing.SM.dp))
            Text(
                InboxPresentation.kindLabel(item.kind).uppercase(),
                style = AuroraType.tiny,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Spacer(modifier = Modifier.width(AuroraSpacing.SM.dp))
            AuroraBadge(
                text = InboxPresentation.priorityLabel(item.priority),
                tone = InboxPresentation.priorityTone(item.priority),
            )
            if (!item.state.isOpen) {
                Spacer(modifier = Modifier.width(AuroraSpacing.XS.dp))
                AuroraBadge(text = "Resolved", tone = AuroraBadgeTone.Success)
            }
        }

        Text(item.title, style = AuroraType.title, color = MaterialTheme.colorScheme.onSurface)

        Text(
            text = inboxDetailSubtitle(row, nowEpoch),
            style = AuroraType.caption,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )

        item.resolutionNote?.takeIf { !item.state.isOpen }?.let { note ->
            Text(
                note,
                style = AuroraType.caption,
                color = MaterialTheme.colorScheme.onSurface,
                modifier =
                Modifier
                    .fillMaxWidth()
                    .background(AuroraColors.success.copy(alpha = 0.10f), RoundedCornerShape(AuroraRadius.SM.dp))
                    .padding(AuroraSpacing.SM.dp),
            )
        }
    }
}

@Composable
private fun InboxDetailMemorySection(row: AIInboxRow) {
    InboxDetailSectionLabel("Worth remembering")
    Text(
        "These are proposals. Approving a memory happens on your Mac, where the same review and screening every " +
            "other memory gets is applied — nothing here is saved or used in a prompt from this phone.",
        style = AuroraType.tiny,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
    )
    Spacer(modifier = Modifier.size(AuroraSpacing.XS.dp))
    Column(verticalArrangement = Arrangement.spacedBy(AuroraSpacing.SM.dp)) {
        for (candidate in row.item.payload.memoryCandidates) {
            InboxMemoryCandidateCard(candidate)
        }
    }
}

@Composable
private fun InboxDetailFooter(row: AIInboxRow, callbacks: InboxDetailCallbacks) {
    Column(verticalArrangement = Arrangement.spacedBy(AuroraSpacing.MD.dp)) {
        HorizontalDivider(color = MaterialTheme.colorScheme.outline.copy(alpha = 0.20f))
        Row(verticalAlignment = Alignment.Top) {
            Icon(
                imageVector = InboxPresentation.verdictIcon(row.item.payload.verification?.verdict),
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.size(13.dp),
            )
            Spacer(modifier = Modifier.width(AuroraSpacing.SM.dp))
            Text(
                inboxProvenanceText(row.item),
                style = AuroraType.tiny,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        InboxDetailDispositionRow(row = row, callbacks = callbacks)
    }
}

@Composable
private fun InboxDetailDispositionRow(row: AIInboxRow, callbacks: InboxDetailCallbacks) {
    var snoozeExpanded by remember { mutableStateOf(false) }
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
        InboxFeedbackButton(
            label = "Useful",
            icon = Icons.Filled.ThumbUp,
            isActive = row.feedback == "useful",
            activeColor = AuroraColors.success,
            onClick = { callbacks.onFeedback(if (row.feedback == "useful") null else "useful") },
        )
        Spacer(modifier = Modifier.width(AuroraSpacing.MD.dp))
        InboxFeedbackButton(
            label = "Not useful",
            icon = Icons.Filled.ThumbDown,
            isActive = row.feedback == "not_useful",
            activeColor = AuroraColors.warning,
            onClick = { callbacks.onFeedback(if (row.feedback == "not_useful") null else "not_useful") },
        )
        Spacer(modifier = Modifier.weight(1f))

        Box {
            InboxFeedbackButton(
                label = "Snooze",
                icon = Icons.Filled.Schedule,
                isActive = false,
                activeColor = AuroraColors.whimsy,
                onClick = { snoozeExpanded = true },
            )
            DropdownMenu(expanded = snoozeExpanded, onDismissRequest = { snoozeExpanded = false }) {
                for (interval in AIInboxSnoozeInterval.entries) {
                    DropdownMenuItem(
                        text = { Text(interval.label, style = AuroraType.caption) },
                        onClick = {
                            snoozeExpanded = false
                            callbacks.onSnooze(interval)
                        },
                    )
                }
            }
        }
        Spacer(modifier = Modifier.width(AuroraSpacing.MD.dp))
        InboxFeedbackButton(
            label = if (row.isArchived) "Unarchive" else "Archive",
            icon = Icons.Filled.Archive,
            isActive = row.isArchived,
            activeColor = AuroraColors.hermesMercury,
            onClick = callbacks.onArchive,
        )
    }
}

@Composable
private fun InboxFeedbackButton(
    label: String,
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    isActive: Boolean,
    activeColor: androidx.compose.ui.graphics.Color,
    onClick: () -> Unit,
) {
    val color = if (isActive) activeColor else MaterialTheme.colorScheme.onSurfaceVariant
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier =
        Modifier
            .clickable(onClick = onClick)
            .padding(vertical = AuroraSpacing.XS.dp)
            .semantics { contentDescription = label },
    ) {
        Icon(imageVector = icon, contentDescription = null, tint = color, modifier = Modifier.size(14.dp))
        Spacer(modifier = Modifier.width(AuroraSpacing.XS.dp))
        Text(
            label,
            style = AuroraType.tiny,
            fontWeight = if (isActive) FontWeight.SemiBold else FontWeight.Normal,
            color = color,
        )
    }
}

internal fun inboxDetailSubtitle(row: AIInboxRow, nowEpoch: Long): String {
    val item = row.item
    val parts = mutableListOf<String>()
    item.projectName?.let(parts::add)
    parts.add("first seen ${inboxRelativeTime(item.firstSeenAtEpoch, nowEpoch)}")
    if (item.occurrenceCount > 1) parts.add("seen ${item.occurrenceCount} times")
    return parts.joinToString(" · ")
}

// ── Target handling ──────────────────────────────────────────────────────────

/**
 * Opens one evidence citation. In-app `burnbar://` targets route through the nav
 * controller; `https://` targets hand off to the browser. Anything else — a
 * `file://` path from the Mac, a scheme this build does not know — is ignored
 * rather than fired blindly at an implicit intent.
 */
internal fun openInboxEvidence(context: Context, evidence: AIInboxEvidence, onOpenRoute: (String) -> Unit) {
    val url = evidence.url ?: return
    openInboxTarget(context, url, onOpenRoute)
}

internal fun performInboxAction(context: Context, action: AIInboxAction, onOpenRoute: (String) -> Unit) {
    when (action.kind) {
        AIInboxActionKind.OPEN_URL -> openInboxTarget(context, action.value, onOpenRoute)
        AIInboxActionKind.RESUME_CONVERSATION, AIInboxActionKind.OPEN_SESSION_LOG ->
            // The Mac addresses conversations by id; on Android the equivalent
            // surface is the Streams cockpit, which owns session reading.
            onOpenRoute("streams")
        AIInboxActionKind.OPEN_SETTINGS -> onOpenRoute("you")
        // A project path and a shell command are both Mac-side artifacts. Copying
        // is the honest affordance: this phone cannot open the folder or run the
        // command, and pretending otherwise would be worse than saying so.
        AIInboxActionKind.OPEN_PROJECT, AIInboxActionKind.RUN_COMMAND ->
            copyInboxValue(context, action.value)
    }
}

internal fun openInboxTarget(context: Context, raw: String, onOpenRoute: (String) -> Unit) {
    val value = raw.trim()
    when {
        value.startsWith("burnbar://") -> onOpenRoute(value.removePrefix("burnbar://"))
        // The Mac emits `openburnbar://sessions/<id>` for session deep links; the
        // Android equivalent is the Streams cockpit.
        value.startsWith("openburnbar://sessions/") -> onOpenRoute("streams")
        value.startsWith("https://") || value.startsWith("http://") ->
            runCatching {
                context.startActivity(
                    Intent(Intent.ACTION_VIEW, value.toUri()).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                )
            }
        else -> Unit
    }
}

private fun copyInboxValue(context: Context, value: String) {
    val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager ?: return
    clipboard.setPrimaryClip(ClipData.newPlainText("OpenBurnBar", value))
    Toast.makeText(context, "Copied — run it on your Mac", Toast.LENGTH_SHORT).show()
}
