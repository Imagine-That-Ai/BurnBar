package com.openburnbar.ui.inbox

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowOutward
import androidx.compose.material.icons.filled.Article
import androidx.compose.material.icons.filled.AttachMoney
import androidx.compose.material.icons.filled.BarChart
import androidx.compose.material.icons.filled.CallMerge
import androidx.compose.material.icons.filled.ChatBubbleOutline
import androidx.compose.material.icons.filled.Commit
import androidx.compose.material.icons.filled.ErrorOutline
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Inventory2
import androidx.compose.material.icons.filled.LocalFireDepartment
import androidx.compose.material.icons.filled.MonitorHeart
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Speed
import androidx.compose.material.icons.filled.Terminal
import androidx.compose.material.icons.filled.TrendingUp
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material.icons.filled.WorkHistory
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import com.openburnbar.data.inbox.AIInboxActionKind
import com.openburnbar.data.inbox.AIInboxEvidenceKind
import com.openburnbar.data.inbox.AIInboxItemKind
import com.openburnbar.data.inbox.AIInboxPriority
import com.openburnbar.data.inbox.AIInboxVerdict
import com.openburnbar.ui.components.AuroraBadgeTone
import com.openburnbar.ui.theme.AuroraColors

// MARK: - Inbox presentation vocabulary
//
// One place decides how each item kind, priority, evidence kind, and action
// reads. Centralized the way the Mac's `InboxPresentation` is, so a new detector
// gets a coherent icon, tint, and label by adding one branch here — and so the
// two platforms stay recognisably the same product.

internal object InboxPresentation {
    fun icon(kind: AIInboxItemKind): ImageVector = when (kind) {
        AIInboxItemKind.CI_WASTE -> Icons.Filled.LocalFireDepartment
        AIInboxItemKind.PROMISED_NOT_LANDED -> Icons.Filled.WorkHistory
        AIInboxItemKind.UNCOMMITTED_WORK -> Icons.Filled.Inventory2
        AIInboxItemKind.COST_ANOMALY -> Icons.Filled.TrendingUp
        AIInboxItemKind.STUCK_PR -> Icons.Filled.CallMerge
        AIInboxItemKind.INDEX_HEALTH -> Icons.Filled.MonitorHeart
        AIInboxItemKind.BRIEF -> Icons.Filled.Article
        AIInboxItemKind.BUDGET -> Icons.Filled.Speed
        AIInboxItemKind.SYSTEM -> Icons.Filled.Info
    }

    fun tint(kind: AIInboxItemKind): Color = when (kind) {
        AIInboxItemKind.CI_WASTE, AIInboxItemKind.COST_ANOMALY, AIInboxItemKind.BUDGET -> AuroraColors.amber
        AIInboxItemKind.PROMISED_NOT_LANDED, AIInboxItemKind.STUCK_PR -> AuroraColors.ember
        AIInboxItemKind.UNCOMMITTED_WORK -> AuroraColors.whimsy
        AIInboxItemKind.INDEX_HEALTH, AIInboxItemKind.SYSTEM -> AuroraColors.hermesMercury
        AIInboxItemKind.BRIEF -> AuroraColors.blaze
    }

    fun kindLabel(kind: AIInboxItemKind): String = when (kind) {
        AIInboxItemKind.CI_WASTE -> "CI waste"
        AIInboxItemKind.PROMISED_NOT_LANDED -> "Possibly unfinished"
        AIInboxItemKind.UNCOMMITTED_WORK -> "Uncommitted work"
        AIInboxItemKind.COST_ANOMALY -> "Spend anomaly"
        AIInboxItemKind.STUCK_PR -> "Stalled PR"
        AIInboxItemKind.INDEX_HEALTH -> "Index"
        AIInboxItemKind.BRIEF -> "Brief"
        AIInboxItemKind.BUDGET -> "Budget"
        AIInboxItemKind.SYSTEM -> "Notice"
    }

    /** Plain language, not band numbers: "Urgent" says more than "P1". */
    fun priorityLabel(priority: AIInboxPriority): String = when (priority) {
        AIInboxPriority.P1 -> "Urgent"
        AIInboxPriority.P2 -> "Today"
        AIInboxPriority.P3 -> "Worth knowing"
        AIInboxPriority.P4 -> "Background"
    }

    fun priorityTone(priority: AIInboxPriority): AuroraBadgeTone = when (priority) {
        AIInboxPriority.P1 -> AuroraBadgeTone.Error
        AIInboxPriority.P2 -> AuroraBadgeTone.Warning
        AIInboxPriority.P3 -> AuroraBadgeTone.Info
        AIInboxPriority.P4 -> AuroraBadgeTone.Neutral
    }

    fun priorityColor(priority: AIInboxPriority): Color = when (priority) {
        AIInboxPriority.P1 -> AuroraColors.error
        AIInboxPriority.P2 -> AuroraColors.amber
        AIInboxPriority.P3 -> AuroraColors.whimsy
        AIInboxPriority.P4 -> AuroraColors.hermesMercury
    }

    fun evidenceIcon(kind: AIInboxEvidenceKind): ImageVector = when (kind) {
        AIInboxEvidenceKind.CONVERSATION -> Icons.Filled.ChatBubbleOutline
        AIInboxEvidenceKind.PULL_REQUEST -> Icons.Filled.CallMerge
        AIInboxEvidenceKind.ISSUE -> Icons.Filled.ErrorOutline
        AIInboxEvidenceKind.WORKFLOW_RUN -> Icons.Filled.Tune
        AIInboxEvidenceKind.COMMIT -> Icons.Filled.Commit
        AIInboxEvidenceKind.FILE -> Icons.Filled.Folder
        AIInboxEvidenceKind.USAGE -> Icons.Filled.AttachMoney
        AIInboxEvidenceKind.METRIC -> Icons.Filled.BarChart
    }

    fun actionIcon(kind: AIInboxActionKind): ImageVector = when (kind) {
        AIInboxActionKind.OPEN_URL -> Icons.Filled.ArrowOutward
        AIInboxActionKind.RESUME_CONVERSATION -> Icons.Filled.Refresh
        AIInboxActionKind.OPEN_SESSION_LOG -> Icons.Filled.ChatBubbleOutline
        AIInboxActionKind.OPEN_PROJECT -> Icons.Filled.Folder
        AIInboxActionKind.OPEN_SETTINGS -> Icons.Filled.Settings
        AIInboxActionKind.RUN_COMMAND -> Icons.Filled.Terminal
    }

    fun verdictIcon(verdict: AIInboxVerdict?): ImageVector = when (verdict) {
        AIInboxVerdict.DETERMINISTIC -> Icons.Filled.BarChart
        AIInboxVerdict.CONFIRMED -> Icons.Filled.MonitorHeart
        AIInboxVerdict.UNCLEAR, AIInboxVerdict.UNVERIFIED -> Icons.Filled.ErrorOutline
        AIInboxVerdict.REFUTED, null -> Icons.Filled.Info
    }
}
