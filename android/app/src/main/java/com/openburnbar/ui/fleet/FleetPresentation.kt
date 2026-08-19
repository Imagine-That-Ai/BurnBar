package com.openburnbar.ui.fleet

import androidx.compose.ui.graphics.Color
import com.openburnbar.data.fleet.FleetAgent
import com.openburnbar.data.fleet.FleetAgentStatus
import com.openburnbar.data.fleet.FleetConfidence
import com.openburnbar.data.fleet.FleetMachineStatus
import com.openburnbar.data.fleet.FleetSnapshot
import com.openburnbar.data.models.AgentProvider
import com.openburnbar.ui.theme.AuroraColors
import java.util.Locale

// MARK: - Fleet presentation vocabulary
//
// One place decides how status, confidence, and machine metrics read —
// mirroring the Mac's `FleetStatusPresentation` / `FleetConfidencePresentation`
// (FleetViewModel.swift) so the two dashboards say the same thing about the
// same snapshot. Honesty rules carried over verbatim:
// - liveness is never invented; every label derives from the snapshot;
// - color is never the only channel — every dot pairs with a word;
// - provenance shows the signal KIND only, never the path or detail
//   (which could bear secret material);
// - absent metrics render as absent ("—"), never as 0 or a current-looking
//   value.
//
// Wording note: the Mac's Home-rail fleet panel bans the word "idle"
// ("absence of a write is not evidence of idleness" —
// LiveAgentFleetPanel.swift), but this surface is the port of the snapshot
// DASHBOARD, whose vocabulary labels the wire status `idle` as "Idle" — and
// the iOS fleet dashboard renders the same word. Cross-platform consistency
// with the ported surface wins over the other panel's rule.

internal object FleetPresentation {
    fun statusLabel(status: FleetAgentStatus): String = when (status) {
        FleetAgentStatus.RUNNING -> "Running"
        FleetAgentStatus.IDLE -> "Idle"
        FleetAgentStatus.STALE -> "Stale"
        FleetAgentStatus.UNKNOWN -> "Unknown"
    }

    fun statusColor(status: FleetAgentStatus): Color = when (status) {
        FleetAgentStatus.RUNNING -> AuroraColors.success
        FleetAgentStatus.IDLE -> AuroraColors.hermesMercury
        FleetAgentStatus.STALE -> AuroraColors.warning
        FleetAgentStatus.UNKNOWN -> AuroraColors.darkTextSecondary
    }

    fun confidenceLabel(confidence: FleetConfidence): String = when (confidence) {
        FleetConfidence.EXACT_PROCESS -> "Exact process"
        FleetConfidence.ACTIVE_SESSION_FILE -> "Session file"
        FleetConfidence.LOG_HEARTBEAT -> "Log heartbeat"
        FleetConfidence.ESTIMATED -> "Estimated"
        FleetConfidence.UNSUPPORTED -> "No live signal"
    }

    fun confidenceShortLabel(confidence: FleetConfidence): String = when (confidence) {
        FleetConfidence.EXACT_PROCESS -> "Exact"
        FleetConfidence.ACTIVE_SESSION_FILE -> "Session"
        FleetConfidence.LOG_HEARTBEAT -> "Heartbeat"
        FleetConfidence.ESTIMATED -> "Estimated"
        FleetConfidence.UNSUPPORTED -> "Unsupported"
    }

    fun confidenceColor(confidence: FleetConfidence): Color = when (confidence) {
        FleetConfidence.EXACT_PROCESS -> AuroraColors.success
        FleetConfidence.ACTIVE_SESSION_FILE -> AuroraColors.whimsy
        FleetConfidence.LOG_HEARTBEAT -> AuroraColors.warning
        FleetConfidence.ESTIMATED -> AuroraColors.blaze
        FleetConfidence.UNSUPPORTED -> AuroraColors.hermesMercury
    }

    /**
     * Visible per-card provenance: the confidence label plus the first signal
     * KIND when one exists. Unsupported rows state that no live signal is
     * available. Mirrors `FleetConfidencePresentation.provenanceLabel`.
     */
    fun provenanceLabel(agent: FleetAgent): String {
        if (agent.confidence == FleetConfidence.UNSUPPORTED) return "No live signal"
        val label = confidenceLabel(agent.confidence)
        val signalKind = agent.signals.firstOrNull()?.kind?.takeIf { it.isNotEmpty() } ?: return label
        return "$label · $signalKind"
    }

    /**
     * The app-side provider for a fleet wire id, when the roster id maps to
     * one (same identity the usage surfaces render). Unknown ids return null —
     * the card then leans on the payload's displayName alone.
     */
    fun provider(agentID: String): AgentProvider? = when (agentID) {
        "factory-droid" -> AgentProvider.FACTORY
        "grok-bot", "grok-cli" -> AgentProvider.XAI
        "pi" -> AgentProvider.PI_AGENT
        else -> AgentProvider.fromKey(agentID)
    }

    /** "42%" — one decimal only when it says something. */
    fun formatCPU(cpuPercent: Double): String = if (cpuPercent >= 100.0 || cpuPercent == cpuPercent.toLong().toDouble()) {
        "${cpuPercent.toLong()}%"
    } else {
        String.format(Locale.US, "%.1f%%", cpuPercent)
    }

    /** "12.4 / 32.0 GB" */
    fun formatMemory(usedBytes: Long, totalBytes: Long): String = "${formatGigabytes(usedBytes)} / ${formatGigabytes(totalBytes)} GB"

    /** "418.2 GB free" */
    fun formatDiskFree(bytes: Long): String = "${formatGigabytes(bytes)} GB free"

    private fun formatGigabytes(bytes: Long): String = String.format(Locale.US, "%.1f", bytes / 1_073_741_824.0)

    /**
     * The header strip rows: label + value for each metric the snapshot
     * actually carries. Absent metrics are omitted from the strip (the Mac
     * keeps its full panel with "—" rows; the phone strip only has room for
     * what is real).
     */
    fun machineStripRows(machine: FleetMachineStatus): List<Pair<String, String>> {
        val rows = mutableListOf<Pair<String, String>>()
        machine.cpuPercent?.let { rows.add("CPU" to formatCPU(it)) }
        machine.memoryUsedBytes?.let { rows.add("Memory" to formatMemory(it, machine.memoryTotalBytes)) }
        machine.diskFreeBytes?.let { rows.add("Disk" to formatDiskFree(it)) }
        return rows
    }

    /** The display name for a wire agent id, resolved from the snapshot's own rows first. */
    fun agentDisplayName(snapshot: FleetSnapshot, agentID: String): String = snapshot.agents.firstOrNull { it.id == agentID }?.displayName
        ?: provider(agentID)?.displayName
        ?: agentID

    /** The name of the explicit ungrouped bucket — agents there are never dropped. */
    const val NO_REPO_BUCKET = "No repo"

    /**
     * Repo group rows: snapshot repos in payload order, plus the explicit
     * "No repo" bucket for agents with no projectName. Mirrors
     * `FleetViewModel.repoGroupRows` (minus collapse state — the phone list
     * always shows the one-line member summary).
     */
    fun repoRows(snapshot: FleetSnapshot): List<FleetRepoRowModel> {
        val rows = snapshot.repos
            .map { FleetRepoRowModel(projectName = it.projectName, agentIDs = it.agents) }
            .toMutableList()
        val ungrouped = snapshot.agents.filter { it.projectName.isNullOrEmpty() }.map { it.id }
        if (ungrouped.isNotEmpty()) {
            rows.add(FleetRepoRowModel(projectName = NO_REPO_BUCKET, agentIDs = ungrouped))
        }
        return rows
    }
}

/** One per-repo group row. */
internal data class FleetRepoRowModel(
    val projectName: String,
    val agentIDs: List<String>,
)
