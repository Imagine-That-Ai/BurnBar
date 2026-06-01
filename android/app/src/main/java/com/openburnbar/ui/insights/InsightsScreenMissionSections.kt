@file:Suppress("MagicNumber")
// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.insights

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.clickable
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.GraphicEq
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material.icons.filled.WarningAmber
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.openburnbar.data.assistants.CLIAgentMissionEvent
import com.openburnbar.data.assistants.CLIAgentMissionSnapshot
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraRadius
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraType

@Composable
fun MissionStatusBanner(status: InsightsViewModel.MissionStatus, onDismiss: () -> Unit, onOpen: () -> Unit) {
    when (status) {
        InsightsViewModel.MissionStatus.Idle -> Unit
        is InsightsViewModel.MissionStatus.Dispatched ->
            MissionDispatchedBanner(status = status, onDismiss = onDismiss, onOpen = onOpen)
        is InsightsViewModel.MissionStatus.Tracking ->
            MissionTrackingBanner(status = status, onDismiss = onDismiss, onOpen = onOpen)
        is InsightsViewModel.MissionStatus.Failed ->
            MissionFailedBanner(status = status, onDismiss = onDismiss, onOpen = onOpen)
    }
}

@Composable
private fun MissionDispatchedBanner(
    status: InsightsViewModel.MissionStatus.Dispatched,
    onDismiss: () -> Unit,
    onOpen: () -> Unit,
) {
    MissionBanner(
        model =
        MissionBannerModel(
            icon = Icons.AutoMirrored.Filled.Send,
            tone = InsightsColors.kpiPositive,
            title = "Mission dispatched to ${status.runtime}",
            detail = "${status.title}. Waiting for the Mac agent listener to claim it.",
        ),
        actions = MissionBannerActions(onDismiss = onDismiss, onOpen = onOpen),
    )
}

@Composable
private fun MissionTrackingBanner(
    status: InsightsViewModel.MissionStatus.Tracking,
    onDismiss: () -> Unit,
    onOpen: () -> Unit,
) {
    val isDark = isSystemInDarkTheme()
    val presentation = missionTrackingPresentation(status.mission, isDark)
    MissionBanner(
        model =
        MissionBannerModel(
            icon = presentation.icon,
            tone = presentation.tone,
            title = presentation.title,
            detail = presentation.detail,
            feedLines = status.mission.events.takeLast(4).map { event -> "${event.phase}: ${event.message}" },
        ),
        actions = MissionBannerActions(onDismiss = onDismiss, onOpen = onOpen),
    )
}

@Composable
private fun MissionFailedBanner(
    status: InsightsViewModel.MissionStatus.Failed,
    onDismiss: () -> Unit,
    onOpen: () -> Unit,
) {
    val isDark = isSystemInDarkTheme()
    MissionBanner(
        model =
        MissionBannerModel(
            icon = Icons.Filled.WarningAmber,
            tone = if (isDark) AuroraColors.warningDark else AuroraColors.warning,
            title = "Mission was not dispatched",
            detail = "${status.title}: ${status.message}",
        ),
        actions = MissionBannerActions(onDismiss = onDismiss, onOpen = onOpen),
    )
}

private data class MissionTrackingPresentation(
    val icon: ImageVector,
    val tone: Color,
    val title: String,
    val detail: String,
)

private fun missionTrackingPresentation(mission: CLIAgentMissionSnapshot, isDark: Boolean): MissionTrackingPresentation {
    val statusText = mission.displayStatus.lowercase()
    val isFailed = statusText == "failed" || statusText == "agent_launch_failed" || statusText == "unauthorized"
    val isComplete = statusText == "completed"
    val icon =
        when {
            isFailed -> Icons.Filled.WarningAmber
            isComplete -> Icons.Filled.CheckCircle
            else -> Icons.Filled.GraphicEq
        }
    val tone =
        when {
            isFailed -> if (isDark) AuroraColors.warningDark else AuroraColors.warning
            isComplete -> InsightsColors.kpiPositive
            else -> AuroraColors.whimsy(isDark)
        }
    val title =
        when (statusText) {
            "pending", "queued" -> "Mission queued for ${mission.runtimeLabel}"
            "accepted" -> "Mission accepted by ${mission.runtimeLabel}"
            "starting" -> "Mission starting on ${mission.runtimeLabel}"
            "mac_offline" -> "Mac offline for ${mission.runtimeLabel}"
            "running" -> "Mission running on ${mission.runtimeLabel}"
            "waiting_for_approval" -> "Mission waiting for approval on ${mission.runtimeLabel}"
            "completed" -> "Mission completed on ${mission.runtimeLabel}"
            "failed" -> "Mission failed on ${mission.runtimeLabel}"
            "canceled", "cancelled" -> "Mission canceled on ${mission.runtimeLabel}"
            "unauthorized" -> "Mac not trusted for ${mission.runtimeLabel}"
            "agent_launch_failed" -> "Agent launch failed on ${mission.runtimeLabel}"
            else -> "Mission ${mission.displayStatus} on ${mission.runtimeLabel}"
        }
    val detail =
        when {
            isFailed ->
                mission.errorMessage?.takeIf { it.isNotBlank() }
                    ?: mission.displayLiveSummary?.takeIf { it.isNotBlank() } ?: mission.title
            isComplete ->
                mission.resultPreview?.takeIf { it.isNotBlank() }
                    ?: mission.displayLiveSummary?.takeIf { it.isNotBlank() } ?: mission.title
            else -> mission.displayLiveSummary?.takeIf { it.isNotBlank() } ?: mission.title
        }
    return MissionTrackingPresentation(icon = icon, tone = tone, title = title, detail = detail)
}

private data class MissionBannerModel(
    val icon: ImageVector,
    val tone: Color,
    val title: String,
    val detail: String,
    val feedLines: List<String> = emptyList(),
)

private data class MissionBannerActions(
    val onDismiss: () -> Unit,
    val onOpen: () -> Unit,
)

@Composable
private fun MissionBanner(model: MissionBannerModel, actions: MissionBannerActions) {
    Surface(
        modifier =
        Modifier
            .fillMaxWidth()
            .clickable(onClick = actions.onOpen),
        shape = RoundedCornerShape(AuroraRadius.md.dp),
        color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.72f),
        tonalElevation = 1.dp,
        border = BorderStroke(0.5.dp, MaterialTheme.colorScheme.outlineVariant),
    ) {
        Row(
            modifier =
            Modifier.padding(
                horizontal = AuroraSpacing.md.dp,
                vertical = AuroraSpacing.sm.dp,
            ),
            horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp),
            verticalAlignment = Alignment.Top,
        ) {
            MissionBannerIcon(icon = model.icon, tone = model.tone)
            MissionBannerBody(model = model)
            MissionBannerActionButtons(tone = model.tone, actions = actions)
        }
    }
}

@Composable
private fun MissionBannerIcon(icon: ImageVector, tone: Color) {
    Icon(
        imageVector = icon,
        contentDescription = null,
        tint = tone,
        modifier =
        Modifier
            .padding(top = 2.dp)
            .size(18.dp),
    )
}

@Composable
private fun MissionBannerBody(model: MissionBannerModel) {
    Column(
        modifier = Modifier.weight(1f),
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        Text(
            text = model.title,
            style = AuroraType.caption.copy(fontWeight = FontWeight.SemiBold),
            color = MaterialTheme.colorScheme.onSurface,
        )
        Text(
            text = model.detail,
            style = AuroraType.tiny,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            maxLines = 3,
        )
        MissionBannerFeedLines(feedLines = model.feedLines)
    }
}

@Composable
private fun MissionBannerFeedLines(feedLines: List<String>) {
    if (feedLines.isEmpty()) return
    Spacer(modifier = Modifier.height(4.dp))
    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
        feedLines.forEach { line ->
            Text(
                text = line,
                style = AuroraType.monoTiny,
                color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f),
                maxLines = 2,
            )
        }
    }
}

@Composable
private fun MissionBannerActionButtons(tone: Color, actions: MissionBannerActions) {
    TextButton(
        onClick = actions.onOpen,
        contentPadding = PaddingValues(horizontal = 6.dp, vertical = 0.dp),
    ) {
        Text(
            text = "Open",
            style = AuroraType.tiny,
            color = tone,
        )
    }
    TextButton(
        onClick = actions.onDismiss,
        contentPadding = PaddingValues(horizontal = 6.dp, vertical = 0.dp),
    ) {
        Text(
            text = "Dismiss",
            style = AuroraType.tiny,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MissionDetailSheet(
    status: InsightsViewModel.MissionStatus,
    onApprovalResponse: (String, Boolean) -> Unit,
    onDismiss: () -> Unit,
    onFloat: ((CLIAgentMissionSnapshot) -> Unit)? = null,
    onPictureInPicture: ((CLIAgentMissionSnapshot) -> Unit)? = null,
) {
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = false),
    ) {
        when (status) {
            is InsightsViewModel.MissionStatus.Tracking ->
                MissionLiveDetailContent(
                    mission = status.mission,
                    onApprovalResponse = onApprovalResponse,
                    onFloat = onFloat,
                    onPictureInPicture = onPictureInPicture,
                )
            is InsightsViewModel.MissionStatus.Dispatched ->
                MissionQueuedDetailContent(
                    title = status.title,
                    runtime = status.runtime,
                    detail = "Waiting for the signed-in Mac agent listener to claim this mission.",
                )
            is InsightsViewModel.MissionStatus.Failed ->
                MissionQueuedDetailContent(
                    title = status.title,
                    runtime = "Mac agent fleet",
                    detail = status.message,
                )
            InsightsViewModel.MissionStatus.Idle -> Spacer(modifier = Modifier.height(1.dp))
        }
    }
}

@Composable
private fun MissionLiveDetailContent(
    mission: CLIAgentMissionSnapshot,
    onApprovalResponse: (String, Boolean) -> Unit,
    onFloat: ((CLIAgentMissionSnapshot) -> Unit)? = null,
    onPictureInPicture: ((CLIAgentMissionSnapshot) -> Unit)? = null,
) {
    var activeFilters by remember { mutableStateOf(MissionEventFilter.entries.toSet()) }
    val visibleEvents = mission.events.filter { activeFilters.contains(MissionEventFilter.from(it)) }
    val showSkillRunCompanionControls = shouldShowSkillRunCompanionControls(mission)

    LazyColumn(
        modifier =
        Modifier
            .fillMaxWidth()
            .padding(horizontal = AuroraSpacing.lg.dp),
        contentPadding = PaddingValues(bottom = AuroraSpacing.xl.dp),
        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.lg.dp),
    ) {
        item { MissionLiveDetailHeader(mission) }
        item { MissionLiveDetailChipRow(mission, showSkillRunCompanionControls) }
        missionLiveCompanionControlsItem(
            showSkillRunCompanionControls = showSkillRunCompanionControls,
            mission = mission,
            onFloat = onFloat,
            onPictureInPicture = onPictureInPicture,
        )
        missionLiveApprovalItem(mission, onApprovalResponse)
        item {
            MissionLiveTimelineSection(
                events = mission.events,
                activeFilters = activeFilters,
                onToggleFilter = { filter ->
                    activeFilters =
                        if (filter in activeFilters && activeFilters.size > 1) {
                            activeFilters - filter
                        } else {
                            activeFilters + filter
                        }
                },
            )
        }
        items(visibleEvents) { event ->
            MissionTimelineRow(event)
        }
        missionLiveResultItem(mission.resultPreview)
        missionLiveFailureItem(mission.errorMessage)
    }
}

@Composable
private fun MissionLiveDetailHeader(mission: CLIAgentMissionSnapshot) {
    Column(verticalArrangement = Arrangement.spacedBy(AuroraSpacing.xs.dp)) {
        Text(
            text = "Mission Live",
            style = AuroraType.headline,
            color = MaterialTheme.colorScheme.onSurface,
        )
        Text(
            text = mission.title,
            style = AuroraType.body.copy(fontWeight = FontWeight.SemiBold),
            color = MaterialTheme.colorScheme.onSurface,
        )
        Text(
            text = mission.displayLiveSummary?.takeIf { it.isNotBlank() } ?: mission.displayStatus,
            style = AuroraType.caption,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun MissionLiveDetailChipRow(mission: CLIAgentMissionSnapshot, showSkillRunCompanionControls: Boolean) {
    LazyRow(horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp)) {
        item { MissionDetailChip(mission.displayStatus.uppercase(), Icons.Filled.GraphicEq) }
        item { MissionDetailChip(mission.runtimeLabel, Icons.Filled.CheckCircle) }
        item { MissionDetailChip(mission.currentStepLabel, Icons.Filled.GraphicEq) }
        mission.skillRunID?.let { skill ->
            item { MissionDetailChip(skill.displayLabel, Icons.Filled.AutoAwesome) }
        }
        if (showSkillRunCompanionControls) {
            item { MissionDetailChip(mission.deliveryMode.displayLabel, Icons.Filled.GraphicEq) }
        }
        mission.activeToolName?.let { tool ->
            item { MissionDetailChip(tool, Icons.Filled.Tune) }
        }
        mission.latestArtifactLabel?.let { artifact ->
            item { MissionDetailChip(artifact, Icons.Filled.AutoAwesome) }
        }
        mission.sessionID?.takeIf { it.isNotBlank() }?.let { session ->
            item { MissionDetailChip(session, Icons.Filled.AutoAwesome) }
        }
    }
}

private fun LazyListScope.missionLiveCompanionControlsItem(
    showSkillRunCompanionControls: Boolean,
    mission: CLIAgentMissionSnapshot,
    onFloat: ((CLIAgentMissionSnapshot) -> Unit)?,
    onPictureInPicture: ((CLIAgentMissionSnapshot) -> Unit)?,
) {
    if (showSkillRunCompanionControls && (onFloat != null || onPictureInPicture != null)) {
        item {
            Row(horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp)) {
                onFloat?.let { callback ->
                    TextButton(onClick = { callback(mission) }) {
                        Text(
                            text = "Float",
                            style = AuroraType.caption.copy(fontWeight = FontWeight.SemiBold),
                            color = MaterialTheme.colorScheme.onSurface,
                        )
                    }
                }
                onPictureInPicture?.let { callback ->
                    TextButton(onClick = { callback(mission) }) {
                        Text(
                            text = "PiP",
                            style = AuroraType.caption.copy(fontWeight = FontWeight.SemiBold),
                            color = AuroraColors.amber,
                        )
                    }
                }
            }
        }
    }
}

private fun LazyListScope.missionLiveApprovalItem(
    mission: CLIAgentMissionSnapshot,
    onApprovalResponse: (String, Boolean) -> Unit,
) {
    if (mission.isWaitingForApproval) {
        item {
            MissionDetailSection(title = mission.approvalTitle?.takeIf { it.isNotBlank() } ?: "Approval required") {
                Column(verticalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp)) {
                    Text(
                        text =
                        mission.approvalMessage?.takeIf { it.isNotBlank() }
                            ?: "The Mac is waiting for approval before continuing this mission.",
                        style = AuroraType.caption,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Row(horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp)) {
                        TextButton(onClick = { onApprovalResponse(mission.id, true) }) {
                            Text(
                                text = "Approve",
                                style = AuroraType.caption.copy(fontWeight = FontWeight.SemiBold),
                                color = InsightsColors.kpiPositive,
                            )
                        }
                        TextButton(onClick = { onApprovalResponse(mission.id, false) }) {
                            Text(
                                text = "Reject",
                                style = AuroraType.caption.copy(fontWeight = FontWeight.SemiBold),
                                color = MaterialTheme.colorScheme.error,
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun MissionLiveTimelineSection(
    events: List<CLIAgentMissionEvent>,
    activeFilters: Set<MissionEventFilter>,
    onToggleFilter: (MissionEventFilter) -> Unit,
) {
    MissionDetailSection(title = "Live timeline") {
        if (events.isEmpty()) {
            Text(
                text = "Waiting for the Mac agent to report progress.",
                style = AuroraType.caption,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        } else {
            MissionEventFilterBar(activeFilters = activeFilters, onToggle = onToggleFilter)
        }
    }
}

private fun LazyListScope.missionLiveResultItem(resultPreview: String?) {
    resultPreview?.takeIf { it.isNotBlank() }?.let { result ->
        item {
            MissionDetailSection(title = "Result") {
                Text(
                    text = result,
                    style = AuroraType.caption,
                    color = MaterialTheme.colorScheme.onSurface,
                )
            }
        }
    }
}

private fun LazyListScope.missionLiveFailureItem(errorMessage: String?) {
    errorMessage?.takeIf { it.isNotBlank() }?.let { error ->
        item {
            MissionDetailSection(title = "Failure") {
                Text(
                    text = error,
                    style = AuroraType.caption,
                    color = MaterialTheme.colorScheme.error,
                )
            }
        }
    }
}

fun shouldShowSkillRunCompanionControls(mission: CLIAgentMissionSnapshot): Boolean = mission.skillRunID != null

private enum class MissionEventFilter(val label: String) {
    LLM("LLM"),
    TOOLS("Tools"),
    ERRORS("Errors"),
    APPROVALS("Approvals"),
    ARTIFACTS("Artifacts"),
    STATUS("Status"),
    ;

    companion object {
        fun from(event: CLIAgentMissionEvent): MissionEventFilter = when {
            event.isError || event.kind == "error" || event.phase == "failed" -> ERRORS
            event.kind in setOf("tool_call", "tool_result") || event.phase == "tool_use" -> TOOLS
            event.kind == "approval_request" || "approval" in event.phase -> APPROVALS
            event.kind in setOf("artifact", "changed_file") || event.artifactPath != null || event.changedFilePath != null -> ARTIFACTS
            event.kind in setOf("llm_response", "assistant_message", "final_answer") || event.phase == "assistant_response" -> LLM
            else -> STATUS
        }
    }
}

@Composable
private fun MissionEventFilterBar(activeFilters: Set<MissionEventFilter>, onToggle: (MissionEventFilter) -> Unit) {
    LazyRow(horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.xs.dp)) {
        items(MissionEventFilter.entries) { filter ->
            FilterChip(
                selected = filter in activeFilters,
                onClick = { onToggle(filter) },
                label = {
                    Text(
                        text = filter.label,
                        style = AuroraType.monoTiny.copy(fontWeight = FontWeight.SemiBold),
                    )
                },
            )
        }
    }
}

@Composable
private fun MissionQueuedDetailContent(title: String, runtime: String, detail: String) {
    Column(
        modifier =
        Modifier
            .fillMaxWidth()
            .padding(AuroraSpacing.lg.dp),
        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.md.dp),
    ) {
        Text(
            text = "Mission Live",
            style = AuroraType.headline,
            color = MaterialTheme.colorScheme.onSurface,
        )
        Text(
            text = title,
            style = AuroraType.body.copy(fontWeight = FontWeight.SemiBold),
            color = MaterialTheme.colorScheme.onSurface,
        )
        MissionDetailChip(runtime, Icons.Filled.GraphicEq)
        Text(
            text = detail,
            style = AuroraType.caption,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(modifier = Modifier.height(AuroraSpacing.xl.dp))
    }
}

@Composable
private fun MissionDetailChip(label: String, icon: ImageVector) {
    Surface(
        shape = RoundedCornerShape(AuroraRadius.sm.dp),
        color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.6f),
        border = BorderStroke(0.5.dp, MaterialTheme.colorScheme.outlineVariant),
    ) {
        Row(
            modifier = Modifier.padding(horizontal = AuroraSpacing.sm.dp, vertical = 6.dp),
            horizontalArrangement = Arrangement.spacedBy(6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.size(14.dp),
            )
            Text(
                text = label,
                style = AuroraType.monoTiny,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
            )
        }
    }
}

@Composable
private fun MissionDetailSection(title: String, content: @Composable () -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp)) {
        Text(
            text = title,
            style = AuroraType.caption.copy(fontWeight = FontWeight.SemiBold),
            color = MaterialTheme.colorScheme.onSurface,
        )
        content()
    }
}

@Composable
private fun MissionTimelineRow(event: CLIAgentMissionEvent) {
    val isDark = isSystemInDarkTheme()
    val tone =
        when (event.phase) {
            "completed" -> InsightsColors.kpiPositive
            "failed", "agent_launch_failed" -> if (isDark) AuroraColors.warningDark else AuroraColors.warning
            "tool_use" -> AuroraColors.ember
            else -> AuroraColors.whimsy(isDark)
        }
    val icon =
        when (event.phase) {
            "completed" -> Icons.Filled.CheckCircle
            "failed", "agent_launch_failed" -> Icons.Filled.WarningAmber
            "tool_use" -> Icons.Filled.Tune
            else -> Icons.Filled.GraphicEq
        }
    Row(
        horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp),
        verticalAlignment = Alignment.Top,
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            tint = tone,
            modifier = Modifier.size(18.dp),
        )
        MissionTimelineEventContent(event = event)
    }
}

@Composable
private fun MissionTimelineEventContent(event: CLIAgentMissionEvent) {
    Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
        MissionTimelineEventHeader(event)
        MissionTimelineEventMessage(event)
        if (event.messageTruncated) {
            Text(
                text = "Showing redacted mobile payload capped at ${event.messageLength ?: event.displayMessage.length} chars.",
                style = AuroraType.monoTiny,
                color = MaterialTheme.colorScheme.error,
            )
        }
        MissionTimelineEventMetadataChips(event)
        Text(
            text = event.timestamp,
            style = AuroraType.monoTiny,
            color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.62f),
        )
    }
}

@Composable
private fun MissionTimelineEventHeader(event: CLIAgentMissionEvent) {
    Row(horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.xs.dp)) {
        Text(
            text = (event.title ?: event.phase.replace("_", " ")).uppercase(),
            style = AuroraType.monoTiny.copy(fontWeight = FontWeight.SemiBold),
            color = MaterialTheme.colorScheme.onSurface,
        )
        event.runtime?.takeIf { it.isNotBlank() }?.let { runtime ->
            Text(
                text = runtime,
                style = AuroraType.monoTiny,
                color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f),
            )
        }
    }
}

@Composable
private fun MissionTimelineEventMessage(event: CLIAgentMissionEvent) {
    Surface(
        shape = RoundedCornerShape(AuroraRadius.sm.dp),
        color =
        if (event.prefersMonospace) {
            MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.52f)
        } else {
            Color.Transparent
        },
    ) {
        Text(
            text = event.displayMessage,
            style = if (event.prefersMonospace) AuroraType.monoTiny else AuroraType.caption,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(if (event.prefersMonospace) 10.dp else 0.dp),
        )
    }
}

@Composable
private fun MissionTimelineEventMetadataChips(event: CLIAgentMissionEvent) {
    if (event.toolName.isNullOrBlank() && event.artifactPath.isNullOrBlank() && event.changedFilePath.isNullOrBlank()) {
        return
    }
    LazyRow(horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.xs.dp)) {
        event.toolName?.takeIf { it.isNotBlank() }?.let { tool ->
            item { MissionDetailChip(tool, Icons.Filled.Tune) }
        }
        event.artifactPath?.takeIf { it.isNotBlank() }?.let { artifact ->
            item { MissionDetailChip(artifact, Icons.Filled.AutoAwesome) }
        }
        event.changedFilePath?.takeIf { it.isNotBlank() }?.let { changedFile ->
            item { MissionDetailChip(changedFile, Icons.Filled.AutoAwesome) }
        }
    }
}

private val CLIAgentMissionEvent.displayMessage: String
    get() = fullMessage?.takeIf { it.isNotBlank() } ?: message

private val CLIAgentMissionEvent.prefersMonospace: Boolean
    get() =
        kind in setOf("tool_call", "tool_result", "llm_response", "assistant_message", "final_answer") ||
            displayMessage.contains("\n")
