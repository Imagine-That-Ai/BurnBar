@file:OptIn(androidx.compose.foundation.layout.ExperimentalLayoutApi::class)
// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.insights

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Build
import androidx.compose.material.icons.filled.NorthEast
import androidx.compose.material.icons.filled.VerifiedUser
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.openburnbar.data.insights.InsightCitation
import com.openburnbar.data.insights.InsightFollowUpQuestion
import com.openburnbar.data.insights.InsightMissionCandidate
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraRadius
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraType

// ─── Mission Control ───────────────────────────────────────────────────────

data class MissionLaunchAction(
    val title: String,
    val subtitle: String,
    val tone: MissionTone,
    val prompt: String,
) {
    fun followUpQuestion(): InsightFollowUpQuestion = InsightFollowUpQuestion(
        question = prompt.trimIndent(),
        rationale = "Turns the current brief into a local-agent mission.",
    )
}

enum class MissionTone {
    CREATIVE,
    DILIGENCE,
    DEBT,
    ACCRETIVE,
    SECURITY,
    UI_IMPROVEMENT,
    MODERNIZATION,
    PROVIDER_ROUTING,
    COST_EFFICIENCY,
    PROJECT_FOCUS,
    CUSTOM,
}

enum class MissionRuntimeTarget(
    val firestoreValue: String,
    val label: String,
) {
    AUTO("auto", "Auto"),
    CODEX("codex", "Codex"),
    CLAUDE("claude", "Claude"),
    HERMES("hermes", "Hermes"),
    OPENCLAW("openclaw", "OpenClaw"),
    PI_AGENT("piAgent", "Pi"),
    OPENCODE("opencode", "OpenCode"),
    OLLAMA("ollama", "Ollama"),
}

enum class MissionDepth(val firestoreValue: String, val label: String) {
    LIGHT("light", "Light"),
    STANDARD("standard", "Standard"),
    DEEP("deep", "Deep"),
    MAX("max", "Max"),
}

enum class MissionApprovalMode(val firestoreValue: String, val label: String) {
    EXISTING("existing_policy", "Existing"),
    MANUAL("manual_all", "Manual"),
    RISKY("risky_only", "Risky"),
    READ_ONLY("read_only", "Read only"),
}

data class MissionLaunchOptions(
    val requestedRuntime: String,
    val targetProject: String?,
    val depth: String,
    val approvalMode: String,
    val commandsAllowed: Boolean,
    val fileEditsAllowed: Boolean,
)

fun MissionTone.firestoreValue(): String = when (this) {
    MissionTone.CREATIVE -> "creative"
    MissionTone.DILIGENCE -> "diligence"
    MissionTone.DEBT -> "debt"
    MissionTone.ACCRETIVE -> "accretive"
    MissionTone.SECURITY -> "security"
    MissionTone.UI_IMPROVEMENT -> "ui_improvement"
    MissionTone.MODERNIZATION -> "modernization"
    MissionTone.PROVIDER_ROUTING -> "provider_routing"
    MissionTone.COST_EFFICIENCY -> "cost_efficiency"
    MissionTone.PROJECT_FOCUS -> "project_focus"
    MissionTone.CUSTOM -> "custom"
}

internal val missionLaunchActions = listOf(
    MissionLaunchAction(
        title = "Creative Mission",
        subtitle = "Accretive features, UI improvements, modernizations.",
        tone = MissionTone.CREATIVE,
        prompt = """
            Create a creative/accretive mission from this Insights brief for my local agent fleet: Hermes, Pi, OpenClaw/OpenClaude, Claude, and Codex. Recommend the best agent, target project, user value, implementation surface, acceptance criteria, evidence to inspect, likely risks, and how mobile should show the result. Also recommend adjacent missions for UI improvements, modernizations, and small features that compound product value.
        """,
    ),
    MissionLaunchAction(
        title = "Diligence Mission",
        subtitle = "Security, reliability, launch-readiness evidence.",
        tone = MissionTone.DILIGENCE,
        prompt = """
            Create a diligence mission from this Insights brief for my local agent fleet: Hermes, Pi, OpenClaw/OpenClaude, Claude, and Codex. Recommend the best agent, target project, launch-readiness/security/reliability questions, exact evidence to collect, severity model, acceptance criteria, and the mobile result summary I should expect. Also recommend adjacent security, QA, and production-readiness missions when the data supports them.
        """,
    ),
    MissionLaunchAction(
        title = "Debt Mission",
        subtitle = "Compounding drag, rewrite risk, focused remediation.",
        tone = MissionTone.DEBT,
        prompt = """
            Create a technical debt mission from this Insights brief for my local agent fleet: Hermes, Pi, OpenClaw/OpenClaude, Claude, and Codex. Recommend the best agent, project/module focus, debt hypothesis, delivery drag, validation commands, acceptance criteria, remediation sequence, and how mobile should summarize progress. Also recommend adjacent modernization, dependency, architecture, and UI cleanup missions when the evidence supports them.
        """,
    ),
    MissionLaunchAction(
        title = "Accretive Mission",
        subtitle = "Small compounding product or workflow wins.",
        tone = MissionTone.ACCRETIVE,
        prompt = """
            Create an accretive product mission from this Insights brief. Identify the smallest compounding feature or workflow improvement, the target project, the best local agent/runtime, acceptance criteria, evidence to inspect, and how mobile should stream progress and final artifacts.
        """,
    ),
    MissionLaunchAction(
        title = "Security Mission",
        subtitle = "Trust boundaries, abuse paths, hardening work.",
        tone = MissionTone.SECURITY,
        prompt = """
            Create a security mission from this Insights brief. Identify trust boundaries, risky data paths, likely abuse cases, validation commands, approval requirements, and the exact evidence the local Mac agent should collect before proposing changes.
        """,
    ),
    MissionLaunchAction(
        title = "UI Mission",
        subtitle = "Operator surfaces, visual polish, accessibility.",
        tone = MissionTone.UI_IMPROVEMENT,
        prompt = """
            Create a UI improvement mission from this Insights brief. Identify the most operator-visible screen or flow, the UX defect to fix, target files, visual acceptance criteria, accessibility checks, and the mobile timeline events I should expect while the Mac agent works.
        """,
    ),
    MissionLaunchAction(
        title = "Modernization Mission",
        subtitle = "Migrations, stale APIs, compatibility cleanup.",
        tone = MissionTone.MODERNIZATION,
        prompt = """
            Create a modernization mission from this Insights brief. Identify outdated architecture, dependencies, APIs, or code organization, the safest migration path, compatibility constraints, tests to run, and rollback risks.
        """,
    ),
    MissionLaunchAction(
        title = "Routing Mission",
        subtitle = "Model selection, fallback, quota-aware routing.",
        tone = MissionTone.PROVIDER_ROUTING,
        prompt = """
            Create a provider-routing mission from this Insights brief. Inspect routing policy, fallback behavior, quota state, model selection, and account-level failover, then recommend the highest-leverage routing fix with validation steps.
        """,
    ),
    MissionLaunchAction(
        title = "Cost Mission",
        subtitle = "Spend reduction without quality loss.",
        tone = MissionTone.COST_EFFICIENCY,
        prompt = """
            Create a cost-efficiency mission from this Insights brief. Find the highest-confidence spend reduction, target providers or models, expected savings, quality risks, validation queries, and implementation steps.
        """,
    ),
    MissionLaunchAction(
        title = "Focus Mission",
        subtitle = "Repo focus, priority, next best outcome.",
        tone = MissionTone.PROJECT_FOCUS,
        prompt = """
            Create a project-focus mission from this Insights brief. Identify the repo or surface consuming the most attention, the most valuable next outcome, distractions to avoid, evidence to collect, and a focused execution plan.
        """,
    ),
    MissionLaunchAction(
        title = "Custom Mission",
        subtitle = "Dispatch the current brief as a flexible prompt.",
        tone = MissionTone.CUSTOM,
        prompt = """
            Create a custom local-agent mission from this Insights brief. Preserve the brief context, choose the best runtime, name the target project, list acceptance criteria, and stream all reasoning, tool calls, tool results, changed files, and final answer back to mobile.
        """,
    ),
)

@OptIn(ExperimentalLayoutApi::class)
@Composable
internal fun MissionRuntimeSelector(selectedRuntime: MissionRuntimeTarget, onRuntimeSelected: (MissionRuntimeTarget) -> Unit) {
    LazyRow(
        horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.XS.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        items(MissionRuntimeTarget.values().asList()) { runtime ->
            val selected = runtime == selectedRuntime
            TextButton(
                onClick = { onRuntimeSelected(runtime) },
                modifier =
                Modifier
                    .clip(RoundedCornerShape(999.dp))
                    .background(
                        if (selected) {
                            MaterialTheme.colorScheme.onSurface
                        } else {
                            MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.72f)
                        },
                    )
                    .testTag("insights.mission.runtime.${runtime.firestoreValue}")
                    .semantics { contentDescription = "Run mission on ${runtime.label}" },
            ) {
                Text(
                    text = runtime.label,
                    style = AuroraType.caption.copy(fontWeight = FontWeight.SemiBold),
                    color = if (selected) MaterialTheme.colorScheme.surface else MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

@Composable
internal fun MissionLaunchpad(onSelect: (MissionLaunchAction, MissionLaunchOptions) -> Unit) {
    var selectedRuntime by remember { mutableStateOf(MissionRuntimeTarget.AUTO) }
    var targetProject by remember { mutableStateOf("") }
    var selectedDepth by remember { mutableStateOf(MissionDepth.STANDARD) }
    var selectedApprovalMode by remember { mutableStateOf(MissionApprovalMode.EXISTING) }
    var commandsAllowed by remember { mutableStateOf(false) }
    var fileEditsAllowed by remember { mutableStateOf(false) }
    val launchOptions = MissionLaunchOptions(
        requestedRuntime = selectedRuntime.firestoreValue,
        targetProject = targetProject.trim().ifBlank { null },
        depth = selectedDepth.firestoreValue,
        approvalMode = selectedApprovalMode.firestoreValue,
        commandsAllowed = commandsAllowed,
        fileEditsAllowed = fileEditsAllowed,
    )
    Column(
        modifier = Modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.MD.dp),
    ) {
        SectionHeader(title = "MISSION CONTROL")
        Text(
            text = "Create a dispatch-ready mission for your local Hermes, Pi, OpenClaw, Claude, and Codex agents.",
            style = AuroraType.body,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        MissionRuntimeSelector(
            selectedRuntime = selectedRuntime,
            onRuntimeSelected = { selectedRuntime = it },
        )
        MissionOptionsPanel(
            state =
            MissionOptionsState(
                targetProject = targetProject,
                selectedDepth = selectedDepth,
                selectedApprovalMode = selectedApprovalMode,
                commandsAllowed = commandsAllowed,
                fileEditsAllowed = fileEditsAllowed,
            ),
            callbacks =
            MissionOptionsCallbacks(
                onTargetProjectChange = { targetProject = it },
                onDepthChange = { selectedDepth = it },
                onApprovalModeChange = { selectedApprovalMode = it },
                onCommandsAllowedChange = { commandsAllowed = it },
                onFileEditsAllowedChange = { fileEditsAllowed = it },
            ),
        )
        FlowRow(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.SM.dp),
            verticalArrangement = Arrangement.spacedBy(AuroraSpacing.SM.dp),
        ) {
            missionLaunchActions.forEach { action ->
                MissionLaunchButton(action = action, options = launchOptions, onSelect = onSelect)
            }
        }
    }
}

internal data class MissionOptionsState(
    val targetProject: String,
    val selectedDepth: MissionDepth,
    val selectedApprovalMode: MissionApprovalMode,
    val commandsAllowed: Boolean,
    val fileEditsAllowed: Boolean,
)

internal data class MissionOptionsCallbacks(
    val onTargetProjectChange: (String) -> Unit,
    val onDepthChange: (MissionDepth) -> Unit,
    val onApprovalModeChange: (MissionApprovalMode) -> Unit,
    val onCommandsAllowedChange: (Boolean) -> Unit,
    val onFileEditsAllowedChange: (Boolean) -> Unit,
)

@OptIn(ExperimentalLayoutApi::class)
@Composable
internal fun MissionOptionsPanel(state: MissionOptionsState, callbacks: MissionOptionsCallbacks) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .border(BorderStroke(0.75.dp, MaterialTheme.colorScheme.outlineVariant), RoundedCornerShape(AuroraRadius.SM.dp))
            .padding(AuroraSpacing.SM.dp),
        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.SM.dp),
    ) {
        OutlinedTextField(
            value = state.targetProject,
            onValueChange = callbacks.onTargetProjectChange,
            label = { Text("Target project path on Mac") },
            singleLine = true,
            textStyle = AuroraType.caption,
            modifier = Modifier
                .fillMaxWidth()
                .testTag("insights.mission.targetProject"),
        )
        MissionOptionChips(
            title = "Depth",
            entries = MissionDepth.entries,
            selected = state.selectedDepth,
            label = { it.label },
            onSelect = callbacks.onDepthChange,
        )
        MissionOptionChips(
            title = "Approval",
            entries = MissionApprovalMode.entries,
            selected = state.selectedApprovalMode,
            label = { it.label },
            onSelect = callbacks.onApprovalModeChange,
        )
        FlowRow(
            horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.SM.dp),
            verticalArrangement = Arrangement.spacedBy(AuroraSpacing.XS.dp),
        ) {
            MissionBooleanChip(
                label = "Commands",
                selected = state.commandsAllowed,
                onClick = { callbacks.onCommandsAllowedChange(!state.commandsAllowed) },
                tag = "insights.mission.commandsAllowed",
            )
            MissionBooleanChip(
                label = "File edits",
                selected = state.fileEditsAllowed,
                onClick = { callbacks.onFileEditsAllowedChange(!state.fileEditsAllowed) },
                tag = "insights.mission.fileEditsAllowed",
            )
        }
    }
}

@Composable
internal fun <T> MissionOptionChips(title: String, entries: List<T>, selected: T, label: (T) -> String, onSelect: (T) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(
            text = title,
            style = AuroraType.monoTiny.copy(fontWeight = FontWeight.SemiBold),
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        LazyRow(horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.XS.dp)) {
            items(entries) { entry ->
                MissionBooleanChip(
                    label = label(entry),
                    selected = entry == selected,
                    onClick = { onSelect(entry) },
                    tag = null,
                )
            }
        }
    }
}

@Composable
internal fun MissionBooleanChip(label: String, selected: Boolean, onClick: () -> Unit, tag: String?) {
    TextButton(
        onClick = onClick,
        modifier = Modifier
            .clip(RoundedCornerShape(999.dp))
            .background(
                if (selected) {
                    MaterialTheme.colorScheme.onSurface
                } else {
                    MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.72f)
                },
            )
            .then(if (tag != null) Modifier.testTag(tag) else Modifier),
    ) {
        Text(
            text = label,
            style = AuroraType.caption.copy(fontWeight = FontWeight.SemiBold),
            color = if (selected) MaterialTheme.colorScheme.surface else MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

private data class MissionToneVisual(val color: Color, val icon: androidx.compose.ui.graphics.vector.ImageVector)

@Composable
private fun missionToneVisual(tone: MissionTone): MissionToneVisual {
    val isDark = isSystemInDarkTheme()
    val color =
        when (tone) {
            MissionTone.CREATIVE -> AuroraColors.whimsy(isDark)
            MissionTone.DILIGENCE -> if (isDark) AuroraColors.warningDark else AuroraColors.warning
            MissionTone.DEBT -> AuroraColors.ember(isDark)
            MissionTone.ACCRETIVE -> InsightsColors.kpiPositive
            MissionTone.SECURITY -> InsightsColors.kpiNegative
            MissionTone.UI_IMPROVEMENT -> MaterialTheme.colorScheme.primary
            MissionTone.MODERNIZATION -> MaterialTheme.colorScheme.onSurfaceVariant
            MissionTone.PROVIDER_ROUTING -> if (isDark) AuroraColors.goldDark else AuroraColors.gold
            MissionTone.COST_EFFICIENCY -> InsightsColors.kpiNeutral
            MissionTone.PROJECT_FOCUS -> MaterialTheme.colorScheme.onSurfaceVariant
            MissionTone.CUSTOM -> MaterialTheme.colorScheme.onSurface
        }
    val icon =
        when (tone) {
            MissionTone.CREATIVE -> Icons.Filled.AutoAwesome
            MissionTone.DILIGENCE -> Icons.Filled.VerifiedUser
            MissionTone.DEBT -> Icons.Filled.Build
            else -> Icons.Filled.NorthEast
        }
    return MissionToneVisual(color = color, icon = icon)
}

@Composable
private fun RowScope.MissionLaunchButtonLabels(action: MissionLaunchAction, options: MissionLaunchOptions) {
    Column(
        modifier = Modifier.weight(1f),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Text(
            text = action.title,
            style = AuroraType.body.copy(fontWeight = FontWeight.SemiBold),
            color = MaterialTheme.colorScheme.onSurface,
        )
        Text(
            text = "${action.subtitle} Run on ${missionRuntimeLabel(options.requestedRuntime)}.",
            style = AuroraType.caption,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            maxLines = 3,
        )
    }
}

@Composable
internal fun MissionLaunchButton(action: MissionLaunchAction, options: MissionLaunchOptions, onSelect: (MissionLaunchAction, MissionLaunchOptions) -> Unit) {
    val visual = missionToneVisual(action.tone)
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(AuroraRadius.SM.dp))
            .border(BorderStroke(0.75.dp, visual.color.copy(alpha = 0.32f)), RoundedCornerShape(AuroraRadius.SM.dp))
            .clickable { onSelect(action, options) }
            .padding(AuroraSpacing.MD.dp)
            .testTag("insights.mission.${action.tone.firestoreValue()}")
            .semantics { contentDescription = action.title },
        horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.SM.dp),
        verticalAlignment = Alignment.Top,
    ) {
        Icon(
            imageVector = visual.icon,
            contentDescription = null,
            tint = visual.color,
            modifier = Modifier.padding(top = 1.dp).size(22.dp),
        )
        MissionLaunchButtonLabels(action = action, options = options)
        Icon(
            imageVector = Icons.Filled.NorthEast,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(top = 2.dp).size(16.dp),
        )
    }
}

// ─── Mission Board ────────────────────────────────────────────────────────

@Composable
internal fun MissionBoardSection(
    missions: List<InsightMissionCandidate>,
    expandedMissionID: String?,
    onToggle: (String) -> Unit,
    onLaunch: (InsightMissionCandidate) -> Unit,
    onCitationTap: (InsightCitation) -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(SECTION_TAG_MISSIONS),
        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.MD.dp),
    ) {
        SectionHeader(title = SECTION_MISSIONS_TITLE)
        missions.forEach { mission ->
            MissionCard(
                mission = mission,
                expanded = expandedMissionID == mission.id,
                onToggle = { onToggle(mission.id) },
                onLaunch = { onLaunch(mission) },
                onCitationTap = onCitationTap,
            )
        }
    }
}

@Composable
private fun MissionCardHeader(mission: InsightMissionCandidate, lensColor: Color, expanded: Boolean, onLaunch: () -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.SM.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = missionLensLabel(mission.lens).uppercase(),
            style = AuroraType.monoTiny.copy(fontWeight = FontWeight.SemiBold),
            color = lensColor,
        )
        Text(
            text = missionPriorityLabel(mission.priority).uppercase(),
            style = AuroraType.monoTiny.copy(fontWeight = FontWeight.SemiBold),
            color = missionPriorityColor(mission.priority),
        )
        Spacer(modifier = Modifier.weight(1f))
        Text(
            text = mission.effort.name.lowercase().uppercase(),
            style = AuroraType.monoTiny,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Text(
            text = if (expanded) "Close" else "Open",
            style = AuroraType.monoTiny,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        TextButton(
            onClick = onLaunch,
            modifier = Modifier.testTag("insights.mission.candidate.${mission.launchAction().tone.firestoreValue()}"),
        ) {
            Text(
                text = "Launch Mission",
                style = AuroraType.monoTiny.copy(fontWeight = FontWeight.SemiBold),
                color = lensColor,
            )
        }
    }
}

@Composable
private fun MissionCardExpandedBody(mission: InsightMissionCandidate, onCitationTap: (InsightCitation) -> Unit) {
    if (mission.expectedImpact.isNotBlank()) {
        ActionStripe(text = mission.expectedImpact)
    }
    mission.acceptanceCriteria.take(5).forEachIndexed { index, criterion ->
        Row(horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.SM.dp)) {
            Text(
                text = "${index + 1}.",
                style = AuroraType.monoTiny,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Text(
                text = criterion,
                style = AuroraType.body,
                color = MaterialTheme.colorScheme.onSurface,
            )
        }
    }
    if (mission.evidence.isNotEmpty()) {
        CitationChipRow(citations = mission.evidence, onTap = onCitationTap)
    }
}

@Composable
internal fun MissionCard(
    mission: InsightMissionCandidate,
    expanded: Boolean,
    onToggle: () -> Unit,
    onLaunch: () -> Unit,
    onCitationTap: (InsightCitation) -> Unit,
) {
    val lensColor = missionLensColor(mission.lens)
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(AuroraRadius.SM.dp))
            .border(
                BorderStroke(if (expanded) 1.dp else 0.5.dp, lensColor.copy(alpha = if (expanded) 0.55f else 0.28f)),
                RoundedCornerShape(AuroraRadius.SM.dp),
            )
            .clickable(onClick = onToggle)
            .padding(AuroraSpacing.MD.dp)
            .semantics {
                contentDescription = "Mission ${missionLensLabel(mission.lens)}, ${missionPriorityLabel(mission.priority)} priority, ${mission.title}"
            },
        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.SM.dp),
    ) {
        MissionCardHeader(
            mission = mission,
            lensColor = lensColor,
            expanded = expanded,
            onLaunch = onLaunch,
        )
        Text(
            text = mission.title,
            style = AuroraType.headline,
            color = MaterialTheme.colorScheme.onSurface,
        )
        if (mission.summary.isNotBlank()) {
            Text(
                text = mission.summary,
                style = AuroraType.body,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        if (expanded) {
            MissionCardExpandedBody(mission = mission, onCitationTap = onCitationTap)
        }
    }
}

internal fun missionRuntimeLabel(rawValue: String): String = MissionRuntimeTarget.entries.firstOrNull { it.firestoreValue == rawValue }?.label ?: rawValue

internal fun InsightMissionCandidate.launchAction(): MissionLaunchAction {
    val kind = dispatchMetadata["missionKind"] ?: when (lens) {
        InsightMissionCandidate.Lens.ACCRETION -> "accretive"
        InsightMissionCandidate.Lens.DILIGENCE -> "diligence"
        InsightMissionCandidate.Lens.TECH_DEBT -> "debt"
        InsightMissionCandidate.Lens.ROUTING -> "provider_routing"
        InsightMissionCandidate.Lens.QUOTA -> "cost_efficiency"
        InsightMissionCandidate.Lens.FOCUS -> "project_focus"
    }
    val criteria = acceptanceCriteria.take(4).joinToString(separator = "\n") { "- $it" }
    val evidenceLabels = evidence.take(6).joinToString(separator = ", ") { it.label }
    return MissionLaunchAction(
        title = title,
        subtitle = summary.ifBlank { "Recommended mission from this brief." },
        tone = MissionTone.entries.firstOrNull { it.firestoreValue() == kind } ?: MissionTone.CUSTOM,
        prompt = """
            Launch this recommended $kind mission from the current Intelligence Brief.

            Title: $title
            Summary: $summary
            Expected impact: $expectedImpact
            Target project: ${projectDisplayName ?: projectID ?: "Use the brief evidence to choose the safest target project."}
            Acceptance criteria:
            ${criteria.ifBlank { "- Define acceptance criteria from the brief evidence." }}
            Evidence: ${evidenceLabels.ifBlank { "Use the current brief citations and findings." }}
        """,
    )
}

internal fun missionLensLabel(lens: InsightMissionCandidate.Lens): String = when (lens) {
    InsightMissionCandidate.Lens.ACCRETION -> "Accretion"
    InsightMissionCandidate.Lens.DILIGENCE -> "Diligence"
    InsightMissionCandidate.Lens.TECH_DEBT -> "Debt"
    InsightMissionCandidate.Lens.ROUTING -> "Routing"
    InsightMissionCandidate.Lens.QUOTA -> "Quota"
    InsightMissionCandidate.Lens.FOCUS -> "Focus"
}

internal fun missionPriorityLabel(priority: InsightMissionCandidate.Priority): String = when (priority) {
    InsightMissionCandidate.Priority.LOW -> "Low"
    InsightMissionCandidate.Priority.MEDIUM -> "Medium"
    InsightMissionCandidate.Priority.HIGH -> "High"
    InsightMissionCandidate.Priority.CRITICAL -> "Critical"
}

@Composable
internal fun missionLensColor(lens: InsightMissionCandidate.Lens): Color = when (lens) {
    InsightMissionCandidate.Lens.ACCRETION -> InsightsColors.kpiPositive
    InsightMissionCandidate.Lens.DILIGENCE -> if (isSystemInDarkTheme()) AuroraColors.goldDark else AuroraColors.gold
    InsightMissionCandidate.Lens.TECH_DEBT -> AuroraColors.ember(isSystemInDarkTheme())
    InsightMissionCandidate.Lens.ROUTING -> MaterialTheme.colorScheme.primary
    InsightMissionCandidate.Lens.QUOTA -> InsightsColors.kpiNeutral
    InsightMissionCandidate.Lens.FOCUS -> MaterialTheme.colorScheme.onSurfaceVariant
}

@Composable
internal fun missionPriorityColor(priority: InsightMissionCandidate.Priority): Color = when (priority) {
    InsightMissionCandidate.Priority.LOW -> MaterialTheme.colorScheme.onSurfaceVariant
    InsightMissionCandidate.Priority.MEDIUM -> InsightsColors.kpiNeutral
    InsightMissionCandidate.Priority.HIGH -> AuroraColors.ember(isSystemInDarkTheme())
    InsightMissionCandidate.Priority.CRITICAL -> InsightsColors.kpiNegative
}
