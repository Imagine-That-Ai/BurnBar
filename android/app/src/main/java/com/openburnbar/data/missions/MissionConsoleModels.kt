package com.openburnbar.data.missions

import com.openburnbar.data.assistants.CLIAgentMissionSnapshot
import java.time.Instant

// MARK: - Mission Console Models (Hermes Square §6.4 / §6.9)
//
// Android-side parity for the iOS `MissionConsoleSnapshot`. These are the
// snapshot shapes the Hermes Square root reads to render the approval
// strip, active-mission tiles, and rollup health line.

data class MissionConsoleSnapshot(
    val activeMissions: List<ActiveMission> = emptyList(),
    val approvalQueue: List<ApprovalAsk> = emptyList(),
    val groups: List<MissionGroup> = emptyList(),
    val recentTicker: List<TickerEntry> = emptyList(),
    val knownProjects: List<String> = emptyList(),
    val recentProjects: List<String> = emptyList(),
    val openMissions: Int = 0,
    val queuedMissions: Int = 0,
    val blockedMissions: Int = 0,
    val daemonState: DaemonState = DaemonState.UNKNOWN,
) {
    companion object {
        val EMPTY = MissionConsoleSnapshot()
    }
}

enum class DaemonState { LIVE, MAC_OFFLINE, UNKNOWN }

data class ActiveMission(
    val id: String,
    val title: String,
    val runtimeID: String?,
    val runtimeDisplayLabel: String,
    val phase: Phase,
    val phaseDetail: String?,
    val currentToolName: String?,
    val lastEventSnippet: String?,
    val startedAt: Instant?,
    val burnSoFarUSD: Double = 0.0,
    val progressFraction: Double? = null,
    val approvalPending: Boolean = false,
) {
    enum class Phase(val displayLabel: String) {
        QUEUED("Queued"),
        STARTING("Starting"),
        RUNNING("Running"),
        TOOLING("Tooling"),
        STREAMING("Streaming"),
        AWAITING_APPROVAL("Awaiting approval"),
        COMPLETING("Completing"),
        COMPLETED("Completed"),
        FAILED("Failed"),
        BLOCKED("Blocked"),
        CANCELLED("Cancelled"),
        MAC_OFFLINE("Mac offline");

        val isLive: Boolean
            get() = this in setOf(QUEUED, STARTING, RUNNING, TOOLING, STREAMING, AWAITING_APPROVAL, COMPLETING)
    }
}

data class ApprovalAsk(
    val id: String,
    val missionID: String,
    val title: String,
    val message: String,
    val runtimeID: String?,
    val runtimeDisplayLabel: String,
    val requestedAtEpoch: Long,
)

data class TickerEntry(
    val id: String,
    val timestampEpoch: Long,
    val kind: Kind,
    val phase: String,
    val title: String?,
    val message: String,
    val toolName: String? = null,
    val pathDetail: String? = null,
    val missionID: String,
    val runtimeID: String?,
    val isError: Boolean = false,
) {
    enum class Kind { TOOL_CALL, TOOL_RESULT, LLM_RESPONSE, FINAL_ANSWER, CHANGED_FILE, ARTIFACT, ERROR, APPROVAL, STATUS }
}

data class MissionGroup(
    val id: String,
    val title: String,
    val prompt: String,
    val missionKind: String,
    val targetProject: String?,
    val childMissionIDs: List<String>,
    val runtimeTokens: List<String>,
    val parallelismLimit: Int,
    val mergeStrategy: String,
    val phase: String,
    val winnerMissionID: String?,
    val createdAtEpoch: Long,
    val updatedAtEpoch: Long,
) {
    enum class MergeAction {
        KEEP_ALL, SYNTHESIZE,
    }
}

internal fun CLIAgentMissionSnapshot.toActiveMission(): ActiveMission {
    val phase = when (displayStatus.lowercase()) {
        "completed" -> ActiveMission.Phase.COMPLETED
        "failed", "agent_launch_failed", "unauthorized" -> ActiveMission.Phase.FAILED
        "canceled", "cancelled" -> ActiveMission.Phase.CANCELLED
        "mac_offline" -> ActiveMission.Phase.MAC_OFFLINE
        "pending", "queued" -> ActiveMission.Phase.QUEUED
        "waiting_for_approval" -> ActiveMission.Phase.AWAITING_APPROVAL
        "running" -> if (activeToolName != null) ActiveMission.Phase.TOOLING else ActiveMission.Phase.RUNNING
        else -> if (events.lastOrNull()?.kind == "llm_response") ActiveMission.Phase.STREAMING else ActiveMission.Phase.RUNNING
    }
    val runtime = runtimeIDGuess(selectedRuntime ?: requestedRuntime)
    return ActiveMission(
        id = id,
        title = title,
        runtimeID = runtime,
        runtimeDisplayLabel = runtimeLabel,
        phase = phase,
        phaseDetail = errorMessage ?: displayLiveSummary,
        currentToolName = activeToolName,
        lastEventSnippet = events.lastOrNull()?.message,
        startedAt = createdAt,
        burnSoFarUSD = 0.0,
        progressFraction = when (phase) {
            ActiveMission.Phase.QUEUED -> 0.05
            ActiveMission.Phase.STARTING -> 0.15
            ActiveMission.Phase.RUNNING, ActiveMission.Phase.TOOLING, ActiveMission.Phase.STREAMING -> 0.5
            ActiveMission.Phase.AWAITING_APPROVAL -> 0.55
            ActiveMission.Phase.COMPLETING -> 0.9
            ActiveMission.Phase.COMPLETED -> 1.0
            else -> null
        },
        approvalPending = isWaitingForApproval,
    )
}

internal fun CLIAgentMissionSnapshot.toApprovalAskOrNull(): ApprovalAsk? {
    if (!isWaitingForApproval) return null
    return ApprovalAsk(
        id = "approval-$id",
        missionID = id,
        title = approvalTitle ?: "Approve $title?",
        message = approvalMessage ?: "The agent is waiting for your approval before continuing.",
        runtimeID = runtimeIDGuess(selectedRuntime ?: requestedRuntime),
        runtimeDisplayLabel = runtimeLabel,
        requestedAtEpoch = createdAt?.toEpochMilli() ?: System.currentTimeMillis(),
    )
}

internal fun runtimeIDGuess(rawRuntime: String?): String? {
    val raw = rawRuntime?.lowercase()?.takeIf { it.isNotBlank() && it != "auto" } ?: return null
    return when {
        raw.contains("claude") -> "claude"
        raw.contains("codex") -> "codex"
        raw.contains("hermes") -> "hermes"
        raw == "pi" || raw.contains("piagent") || raw.contains("pi-agent") -> "pi"
        raw.contains("openclaw") -> "openclaw"
        raw.contains("ollama") -> "ollama"
        else -> null
    }
}
