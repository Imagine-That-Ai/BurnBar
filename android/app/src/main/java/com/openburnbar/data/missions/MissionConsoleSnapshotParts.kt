
package com.openburnbar.data.missions

import com.openburnbar.data.assistants.CLIAgentMissionSnapshot
import java.time.Instant

private const val MISSION_TICKER_EVENTS = 6
private const val MISSION_TICKER_LIMIT = 16
private const val MISSION_KNOWN_PROJECT_LIMIT = 24

internal data class MissionConsoleSnapshotParts(
    val activeTiles: List<ActiveMission>,
    val approvalAsks: List<ApprovalAsk>,
    val ticker: List<TickerEntry>,
    val knownProjects: List<String>,
    val daemonState: DaemonState,
)

internal fun buildMissionConsoleSnapshotParts(
    orderedMissions: List<CLIAgentMissionSnapshot>,
    runtimeIDGuess: (String?) -> String?,
): MissionConsoleSnapshotParts {
    val macOnline =
        orderedMissions.any { snap ->
            (snap.selectedRuntime ?: "").isNotBlank() || snap.status !in setOf("pending", "queued")
        }
    val activeTiles =
        orderedMissions
            .filter { !it.isTerminal && !(it.displayStatus == "mac_offline" && macOnline) }
            .map { it.toActiveMission() }
    val approvalAsks = orderedMissions.mapNotNull { it.toApprovalAskOrNull() }
    val ticker = missionConsoleTickerEntries(orderedMissions, runtimeIDGuess)
    val knownProjects = orderedMissions.mapNotNull { it.targetProject?.takeIf { project -> project.isNotBlank() } }.distinct().take(MISSION_KNOWN_PROJECT_LIMIT)
    val daemonState =
        when {
            orderedMissions.any { it.displayStatus == "mac_offline" } && !macOnline -> DaemonState.MAC_OFFLINE
            macOnline -> DaemonState.LIVE
            else -> DaemonState.UNKNOWN
        }
    return MissionConsoleSnapshotParts(
        activeTiles = activeTiles,
        approvalAsks = approvalAsks,
        ticker = ticker,
        knownProjects = knownProjects,
        daemonState = daemonState,
    )
}

private fun missionConsoleTickerEntries(orderedMissions: List<CLIAgentMissionSnapshot>, runtimeIDGuess: (String?) -> String?): List<TickerEntry> =
    orderedMissions
        .flatMap { mission ->
            mission.events.takeLast(MISSION_TICKER_EVENTS).map { ev ->
                TickerEntry(
                    id = "${mission.id}-${ev.sequence}",
                    timestampEpoch = runCatching { Instant.parse(ev.timestamp).toEpochMilli() }.getOrDefault(System.currentTimeMillis()),
                    kind =
                    when (ev.kind) {
                        "tool_call" -> TickerEntry.Kind.TOOL_CALL
                        "tool_result" -> TickerEntry.Kind.TOOL_RESULT
                        "llm_response" -> TickerEntry.Kind.LLM_RESPONSE
                        "final_answer" -> TickerEntry.Kind.FINAL_ANSWER
                        "changed_file" -> TickerEntry.Kind.CHANGED_FILE
                        "artifact" -> TickerEntry.Kind.ARTIFACT
                        "error" -> TickerEntry.Kind.ERROR
                        "approval_request" -> TickerEntry.Kind.APPROVAL
                        else -> TickerEntry.Kind.STATUS
                    },
                    phase = ev.phase,
                    title = ev.title,
                    message = ev.fullMessage ?: ev.message,
                    toolName = ev.toolName,
                    pathDetail = ev.changedFilePath ?: ev.artifactPath,
                    missionID = mission.id,
                    runtimeID = runtimeIDGuess(mission.selectedRuntime ?: mission.requestedRuntime),
                    isError = ev.isError,
                )
            }
        }
        .sortedByDescending { it.timestampEpoch }
        .take(MISSION_TICKER_LIMIT)
