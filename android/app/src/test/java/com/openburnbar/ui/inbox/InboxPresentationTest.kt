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
import com.openburnbar.data.inbox.AIInboxActionKind
import com.openburnbar.data.inbox.AIInboxEvidenceKind
import com.openburnbar.data.inbox.AIInboxItemKind
import com.openburnbar.data.inbox.AIInboxPriority
import com.openburnbar.data.inbox.AIInboxVerdict
import com.openburnbar.ui.components.AuroraBadgeTone
import com.openburnbar.ui.theme.AuroraColors
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Exhaustive branch coverage for the [InboxPresentation] vocabulary: every
 * item kind, priority, evidence kind, action kind, and verdict (including the
 * null verdict) maps to the icon, tint, tone, and label the Mac counterpart
 * uses, so a renamed enum case or a swapped branch fails here instead of in a
 * screenshot diff.
 */
class InboxPresentationTest {
    @Test
    fun iconCoversEveryItemKind() {
        assertEquals(Icons.Filled.LocalFireDepartment, InboxPresentation.icon(AIInboxItemKind.CI_WASTE))
        assertEquals(Icons.Filled.WorkHistory, InboxPresentation.icon(AIInboxItemKind.PROMISED_NOT_LANDED))
        assertEquals(Icons.Filled.Inventory2, InboxPresentation.icon(AIInboxItemKind.UNCOMMITTED_WORK))
        assertEquals(Icons.Filled.TrendingUp, InboxPresentation.icon(AIInboxItemKind.COST_ANOMALY))
        assertEquals(Icons.Filled.CallMerge, InboxPresentation.icon(AIInboxItemKind.STUCK_PR))
        assertEquals(Icons.Filled.MonitorHeart, InboxPresentation.icon(AIInboxItemKind.INDEX_HEALTH))
        assertEquals(Icons.Filled.Article, InboxPresentation.icon(AIInboxItemKind.BRIEF))
        assertEquals(Icons.Filled.Speed, InboxPresentation.icon(AIInboxItemKind.BUDGET))
        assertEquals(Icons.Filled.Info, InboxPresentation.icon(AIInboxItemKind.SYSTEM))
    }

    @Test
    fun tintCoversEveryItemKind() {
        assertEquals(AuroraColors.amber, InboxPresentation.tint(AIInboxItemKind.CI_WASTE))
        assertEquals(AuroraColors.amber, InboxPresentation.tint(AIInboxItemKind.COST_ANOMALY))
        assertEquals(AuroraColors.amber, InboxPresentation.tint(AIInboxItemKind.BUDGET))
        assertEquals(AuroraColors.ember, InboxPresentation.tint(AIInboxItemKind.PROMISED_NOT_LANDED))
        assertEquals(AuroraColors.ember, InboxPresentation.tint(AIInboxItemKind.STUCK_PR))
        assertEquals(AuroraColors.whimsy, InboxPresentation.tint(AIInboxItemKind.UNCOMMITTED_WORK))
        assertEquals(AuroraColors.hermesMercury, InboxPresentation.tint(AIInboxItemKind.INDEX_HEALTH))
        assertEquals(AuroraColors.hermesMercury, InboxPresentation.tint(AIInboxItemKind.SYSTEM))
        assertEquals(AuroraColors.blaze, InboxPresentation.tint(AIInboxItemKind.BRIEF))
    }

    @Test
    fun kindLabelCoversEveryItemKind() {
        assertEquals("CI waste", InboxPresentation.kindLabel(AIInboxItemKind.CI_WASTE))
        assertEquals("Possibly unfinished", InboxPresentation.kindLabel(AIInboxItemKind.PROMISED_NOT_LANDED))
        assertEquals("Uncommitted work", InboxPresentation.kindLabel(AIInboxItemKind.UNCOMMITTED_WORK))
        assertEquals("Spend anomaly", InboxPresentation.kindLabel(AIInboxItemKind.COST_ANOMALY))
        assertEquals("Stalled PR", InboxPresentation.kindLabel(AIInboxItemKind.STUCK_PR))
        assertEquals("Index", InboxPresentation.kindLabel(AIInboxItemKind.INDEX_HEALTH))
        assertEquals("Brief", InboxPresentation.kindLabel(AIInboxItemKind.BRIEF))
        assertEquals("Budget", InboxPresentation.kindLabel(AIInboxItemKind.BUDGET))
        assertEquals("Notice", InboxPresentation.kindLabel(AIInboxItemKind.SYSTEM))
    }

    @Test
    fun priorityLabelUsesPlainLanguageForEveryBand() {
        assertEquals("Urgent", InboxPresentation.priorityLabel(AIInboxPriority.P1))
        assertEquals("Today", InboxPresentation.priorityLabel(AIInboxPriority.P2))
        assertEquals("Worth knowing", InboxPresentation.priorityLabel(AIInboxPriority.P3))
        assertEquals("Background", InboxPresentation.priorityLabel(AIInboxPriority.P4))
    }

    @Test
    fun priorityToneCoversEveryBand() {
        assertEquals(AuroraBadgeTone.Error, InboxPresentation.priorityTone(AIInboxPriority.P1))
        assertEquals(AuroraBadgeTone.Warning, InboxPresentation.priorityTone(AIInboxPriority.P2))
        assertEquals(AuroraBadgeTone.Info, InboxPresentation.priorityTone(AIInboxPriority.P3))
        assertEquals(AuroraBadgeTone.Neutral, InboxPresentation.priorityTone(AIInboxPriority.P4))
    }

    @Test
    fun priorityColorCoversEveryBand() {
        assertEquals(AuroraColors.error, InboxPresentation.priorityColor(AIInboxPriority.P1))
        assertEquals(AuroraColors.amber, InboxPresentation.priorityColor(AIInboxPriority.P2))
        assertEquals(AuroraColors.whimsy, InboxPresentation.priorityColor(AIInboxPriority.P3))
        assertEquals(AuroraColors.hermesMercury, InboxPresentation.priorityColor(AIInboxPriority.P4))
    }

    @Test
    fun evidenceIconCoversEveryEvidenceKind() {
        assertEquals(Icons.Filled.ChatBubbleOutline, InboxPresentation.evidenceIcon(AIInboxEvidenceKind.CONVERSATION))
        assertEquals(Icons.Filled.CallMerge, InboxPresentation.evidenceIcon(AIInboxEvidenceKind.PULL_REQUEST))
        assertEquals(Icons.Filled.ErrorOutline, InboxPresentation.evidenceIcon(AIInboxEvidenceKind.ISSUE))
        assertEquals(Icons.Filled.Tune, InboxPresentation.evidenceIcon(AIInboxEvidenceKind.WORKFLOW_RUN))
        assertEquals(Icons.Filled.Commit, InboxPresentation.evidenceIcon(AIInboxEvidenceKind.COMMIT))
        assertEquals(Icons.Filled.Folder, InboxPresentation.evidenceIcon(AIInboxEvidenceKind.FILE))
        assertEquals(Icons.Filled.AttachMoney, InboxPresentation.evidenceIcon(AIInboxEvidenceKind.USAGE))
        assertEquals(Icons.Filled.BarChart, InboxPresentation.evidenceIcon(AIInboxEvidenceKind.METRIC))
    }

    @Test
    fun actionIconCoversEveryActionKind() {
        assertEquals(Icons.Filled.ArrowOutward, InboxPresentation.actionIcon(AIInboxActionKind.OPEN_URL))
        assertEquals(Icons.Filled.Refresh, InboxPresentation.actionIcon(AIInboxActionKind.RESUME_CONVERSATION))
        assertEquals(Icons.Filled.ChatBubbleOutline, InboxPresentation.actionIcon(AIInboxActionKind.OPEN_SESSION_LOG))
        assertEquals(Icons.Filled.Folder, InboxPresentation.actionIcon(AIInboxActionKind.OPEN_PROJECT))
        assertEquals(Icons.Filled.Settings, InboxPresentation.actionIcon(AIInboxActionKind.OPEN_SETTINGS))
        assertEquals(Icons.Filled.Terminal, InboxPresentation.actionIcon(AIInboxActionKind.RUN_COMMAND))
    }

    @Test
    fun verdictIconCoversEveryVerdictIncludingNull() {
        assertEquals(Icons.Filled.BarChart, InboxPresentation.verdictIcon(AIInboxVerdict.DETERMINISTIC))
        assertEquals(Icons.Filled.MonitorHeart, InboxPresentation.verdictIcon(AIInboxVerdict.CONFIRMED))
        assertEquals(Icons.Filled.ErrorOutline, InboxPresentation.verdictIcon(AIInboxVerdict.UNCLEAR))
        assertEquals(Icons.Filled.ErrorOutline, InboxPresentation.verdictIcon(AIInboxVerdict.UNVERIFIED))
        assertEquals(Icons.Filled.Info, InboxPresentation.verdictIcon(AIInboxVerdict.REFUTED))
        assertEquals(Icons.Filled.Info, InboxPresentation.verdictIcon(null))
    }
}
