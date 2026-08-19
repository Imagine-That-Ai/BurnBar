// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.fleet

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CloudOff
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.fleet.FleetAgent
import com.openburnbar.data.fleet.FleetPersistenceHealth
import com.openburnbar.data.fleet.FleetProbeHealth
import com.openburnbar.data.fleet.FleetProbeHealthState
import com.openburnbar.data.fleet.FleetSnapshot
import com.openburnbar.data.fleet.FleetUiState
import com.openburnbar.ui.components.AuroraGlassCard
import com.openburnbar.ui.components.ProviderLogo
import com.openburnbar.ui.inbox.inboxRelativeTime
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraType
import com.openburnbar.ui.theme.AuroraTypography

// ── Header ─────────────────────────────────────────────────────────────────

@Composable
internal fun FleetHeader(state: FleetUiState, nowEpoch: Long) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = "Fleet",
                style = AuroraType.displayLarge,
                color = MaterialTheme.colorScheme.onSurface,
            )
            Text(
                text = "What your Mac's agents are doing right now.",
                fontSize = AuroraTypography.caption.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        FleetRunningReadout(state = state, nowEpoch = nowEpoch)
    }
}

/**
 * The pinned running readout. A missing snapshot is never shown as
 * "0 running" — checking and offline get their own words, exactly as the Mac's
 * header does (VAL-DASH-028).
 */
@Composable
private fun FleetRunningReadout(state: FleetUiState, nowEpoch: Long) {
    val (text, color) = when (state) {
        is FleetUiState.Loading -> "checking…" to MaterialTheme.colorScheme.onSurfaceVariant
        is FleetUiState.MacOffline -> "offline" to MaterialTheme.colorScheme.onSurfaceVariant
        is FleetUiState.Empty -> "0 running" to MaterialTheme.colorScheme.onSurfaceVariant
        is FleetUiState.Ready -> "${state.snapshot.runningCount} running" to AuroraColors.success
    }
    Column(horizontalAlignment = Alignment.End) {
        Text(
            text = text,
            fontSize = AuroraTypography.body.sp,
            fontWeight = FontWeight.Bold,
            color = color,
            modifier = Modifier.semantics { contentDescription = "Fleet status: $text" },
        )
        val updatedAt = when (state) {
            is FleetUiState.Ready -> state.updatedAtEpoch
            is FleetUiState.Empty -> state.updatedAtEpoch
            else -> null
        }
        updatedAt?.let {
            Text(
                text = "Updated ${inboxRelativeTime(it, nowEpoch)}",
                fontSize = AuroraTypography.tiny.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

// ── Whole-screen states ────────────────────────────────────────────────────

@Composable
internal fun FleetLoadingState() {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.MD.dp),
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 48.dp)
            .semantics { contentDescription = "Loading fleet snapshot" },
    ) {
        CircularProgressIndicator(modifier = Modifier.size(28.dp))
        Text(
            text = "Loading fleet snapshot…",
            fontSize = AuroraTypography.body.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
internal fun FleetVaultNotReadyCard() {
    AuroraGlassCard(modifier = Modifier.fillMaxWidth()) {
        Text(
            text = "Approve this device to read fleet data",
            fontSize = AuroraTypography.body.sp,
            fontWeight = FontWeight.SemiBold,
            color = MaterialTheme.colorScheme.onSurface,
        )
        Spacer(modifier = Modifier.height(4.dp))
        Text(
            text =
            "Fleet snapshots are sealed with your Cloud Vault key. Approve this device from your " +
                "Mac or iPhone (Settings → Connected Devices) and the dashboard opens automatically.",
            fontSize = AuroraTypography.caption.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
internal fun FleetErrorBanner(message: String) {
    Text(
        text = message,
        fontSize = AuroraTypography.caption.sp,
        color = AuroraColors.warning,
        modifier = Modifier
            .fillMaxWidth()
            .padding(bottom = AuroraSpacing.SM.dp)
            .semantics { contentDescription = "Fleet error: $message" },
    )
}

@Composable
internal fun FleetMacOfflineCard(lastUpdatedAtEpoch: Long?, nowEpoch: Long) {
    AuroraGlassCard(modifier = Modifier.fillMaxWidth()) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.SM.dp)) {
            Icon(
                imageVector = Icons.Filled.CloudOff,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.size(18.dp),
            )
            Text(
                text = "Your Mac hasn't synced recently",
                fontSize = AuroraTypography.body.sp,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurface,
            )
        }
        Spacer(modifier = Modifier.height(4.dp))
        Text(
            text = lastUpdatedAtEpoch?.let {
                "Last snapshot arrived ${inboxRelativeTime(it, nowEpoch)}. No agent or machine data is " +
                    "shown because none is current."
            } ?: "No fleet snapshot has ever arrived from your Mac. Open BurnBar on the Mac with the " +
                "fleet cloud mirror enabled and this dashboard fills in on its next publish.",
            fontSize = AuroraTypography.caption.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
internal fun FleetEmptyCard(updatedAtEpoch: Long, nowEpoch: Long) {
    AuroraGlassCard(modifier = Modifier.fillMaxWidth()) {
        Text(
            text = "No agent rows in this snapshot",
            fontSize = AuroraTypography.body.sp,
            fontWeight = FontWeight.SemiBold,
            color = MaterialTheme.colorScheme.onSurface,
        )
        Spacer(modifier = Modifier.height(4.dp))
        FleetProvenanceText(updatedAtEpoch = updatedAtEpoch, nowEpoch = nowEpoch)
    }
}

// ── Dashboard items ────────────────────────────────────────────────────────

internal fun LazyListScope.fleetDashboardItems(snapshot: FleetSnapshot, updatedAtEpoch: Long, nowEpoch: Long) {
    val machineRows = FleetPresentation.machineStripRows(snapshot.machine)
    if (machineRows.isNotEmpty()) {
        item(key = "machine") { FleetMachineStrip(rows = machineRows) }
    }
    item(key = "agents-label") { FleetSectionLabel("AGENTS") }
    items(snapshot.agents.size, key = { "agent-${snapshot.agents[it].id}" }) { index ->
        FleetAgentCard(agent = snapshot.agents[index], nowEpoch = nowEpoch)
    }
    val repoRows = FleetPresentation.repoRows(snapshot)
    if (repoRows.isNotEmpty()) {
        item(key = "repos-label") { FleetSectionLabel("REPOS") }
        items(repoRows.size, key = { "repo-${repoRows[it].projectName}" }) { index ->
            FleetRepoRow(row = repoRows[index], snapshot = snapshot)
        }
    }
    item(key = "probe-health") {
        FleetProbeHealthSection(
            health = snapshot.probeHealth,
            persistenceHealth = snapshot.persistenceHealth,
            snapshot = snapshot,
        )
    }
    item(key = "provenance") {
        Column {
            FleetProvenanceText(updatedAtEpoch = updatedAtEpoch, nowEpoch = nowEpoch)
            Spacer(modifier = Modifier.height(AuroraSpacing.LG.dp))
        }
    }
}

@Composable
internal fun FleetSectionLabel(text: String) {
    Text(
        text = text,
        fontWeight = FontWeight.Bold,
        fontSize = AuroraTypography.tiny.sp,
        letterSpacing = 1.2.sp,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
    )
}

/** The provenance line: where this truth came from and how old it is. */
@Composable
internal fun FleetProvenanceText(updatedAtEpoch: Long, nowEpoch: Long) {
    val label = "Synced from your Mac ${inboxRelativeTime(updatedAtEpoch, nowEpoch)}"
    Text(
        text = label,
        fontSize = AuroraTypography.tiny.sp,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.semantics { contentDescription = label },
    )
}

// ── Machine strip ──────────────────────────────────────────────────────────

@Composable
internal fun FleetMachineStrip(rows: List<Pair<String, String>>) {
    AuroraGlassCard(modifier = Modifier.fillMaxWidth()) {
        Row(
            horizontalArrangement = Arrangement.SpaceBetween,
            modifier = Modifier.fillMaxWidth(),
        ) {
            rows.forEach { (label, value) ->
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    modifier = Modifier.semantics { contentDescription = "$label: $value" },
                ) {
                    Text(
                        text = label,
                        fontSize = AuroraTypography.tiny.sp,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Text(
                        text = value,
                        fontSize = AuroraTypography.caption.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = MaterialTheme.colorScheme.onSurface,
                    )
                }
            }
        }
    }
}

// ── Agent card ─────────────────────────────────────────────────────────────

@Composable
internal fun FleetAgentCard(agent: FleetAgent, nowEpoch: Long) {
    AuroraGlassCard(
        modifier = Modifier
            .fillMaxWidth()
            .semantics { contentDescription = fleetAgentAccessibilityLabel(agent, nowEpoch) },
    ) {
        FleetAgentCardHeader(agent = agent)
        agent.currentTask?.let { task ->
            Spacer(modifier = Modifier.height(4.dp))
            Text(
                text = task,
                fontSize = AuroraTypography.caption.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
        }
        Spacer(modifier = Modifier.height(6.dp))
        FleetAgentCardDetailRow(label = "Repo", value = agent.projectName)
        FleetAgentCardDetailRow(label = "Model", value = agent.model)
        FleetAgentCardDetailRow(
            label = "Last activity",
            value = agent.lastActivityAtEpoch?.let { inboxRelativeTime(it, nowEpoch) },
        )
        Spacer(modifier = Modifier.height(6.dp))
        FleetAgentCardFooter(agent = agent)
    }
}

@Composable
private fun FleetAgentCardHeader(agent: FleetAgent) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.SM.dp)) {
        Box(
            modifier = Modifier
                .size(9.dp)
                .clip(CircleShape)
                .background(FleetPresentation.statusColor(agent.status)),
        )
        FleetPresentation.provider(agent.id)?.let { provider ->
            ProviderLogo(provider = provider, size = 18.dp)
        }
        Text(
            text = agent.displayName,
            fontSize = AuroraTypography.body.sp,
            fontWeight = FontWeight.SemiBold,
            color = MaterialTheme.colorScheme.onSurface,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
        Text(
            text = FleetPresentation.statusLabel(agent.status),
            fontSize = AuroraTypography.tiny.sp,
            color = MaterialTheme.colorScheme.onSurface,
        )
    }
}

@Composable
private fun FleetAgentCardDetailRow(label: String, value: String?) {
    Row {
        Text(
            text = label,
            fontSize = AuroraTypography.tiny.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.width(84.dp),
        )
        Text(
            text = value ?: "—",
            fontSize = AuroraTypography.tiny.sp,
            color = if (value == null) MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.onSurface,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

@Composable
private fun FleetAgentCardFooter(agent: FleetAgent) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.SM.dp)) {
        FleetConfidenceBadge(agent = agent)
        Text(
            text = FleetPresentation.provenanceLabel(agent),
            fontSize = AuroraTypography.tiny.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
        agent.note?.let { note ->
            Text(
                text = note,
                fontSize = AuroraTypography.tiny.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

@Composable
private fun FleetConfidenceBadge(agent: FleetAgent) {
    val color = FleetPresentation.confidenceColor(agent.confidence)
    Text(
        text = FleetPresentation.confidenceShortLabel(agent.confidence),
        fontSize = AuroraTypography.tiny.sp,
        color = MaterialTheme.colorScheme.onSurface,
        modifier = Modifier
            .clip(CircleShape)
            .background(color.copy(alpha = 0.14f))
            .padding(horizontal = 8.dp, vertical = 2.dp),
    )
}

internal fun fleetAgentAccessibilityLabel(agent: FleetAgent, nowEpoch: Long): String {
    val parts = mutableListOf(
        "${agent.displayName}, ${FleetPresentation.statusLabel(agent.status)}, ${FleetPresentation.provenanceLabel(agent)}",
    )
    agent.currentTask?.let { parts.add("task: $it") }
    agent.projectName?.let { parts.add("repo: $it") }
    agent.model?.let { parts.add("model: $it") }
    agent.lastActivityAtEpoch?.let { parts.add("last activity: ${inboxRelativeTime(it, nowEpoch)}") }
    return parts.joinToString(", ")
}

// ── Repos ──────────────────────────────────────────────────────────────────

@Composable
internal fun FleetRepoRow(row: FleetRepoRowModel, snapshot: FleetSnapshot) {
    val members = row.agentIDs.joinToString(", ") { FleetPresentation.agentDisplayName(snapshot, it) }
    AuroraGlassCard(
        modifier = Modifier
            .fillMaxWidth()
            .semantics { contentDescription = "${row.projectName}: ${row.agentIDs.size} agents — $members" },
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                text = row.projectName,
                fontSize = AuroraTypography.caption.sp,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurface,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f),
            )
            Text(
                text = "${row.agentIDs.size}",
                fontSize = AuroraTypography.caption.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        Text(
            text = members,
            fontSize = AuroraTypography.tiny.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

// ── Probe health (collapsed caveats) ───────────────────────────────────────

@Composable
internal fun FleetProbeHealthSection(health: List<FleetProbeHealth>, persistenceHealth: FleetPersistenceHealth, snapshot: FleetSnapshot) {
    var expanded by rememberSaveable { mutableStateOf(false) }
    Column {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .fillMaxWidth()
                .clickable { expanded = !expanded }
                .semantics { contentDescription = if (expanded) "Collapse probe health" else "Expand probe health" },
        ) {
            FleetSectionLabel("PROBE HEALTH")
            Spacer(modifier = Modifier.weight(1f))
            Icon(
                imageVector = Icons.Filled.KeyboardArrowDown,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier
                    .size(18.dp)
                    .rotate(if (expanded) 180f else 0f),
            )
        }
        if (expanded) {
            Spacer(modifier = Modifier.height(4.dp))
            health.forEach { entry -> FleetProbeHealthRow(entry = entry, snapshot = snapshot) }
            FleetPersistenceHealthRow(persistenceHealth)
        }
    }
}

@Composable
private fun FleetProbeHealthRow(entry: FleetProbeHealth, snapshot: FleetSnapshot) {
    val stateText = when (val state = entry.state) {
        is FleetProbeHealthState.Ok -> "ok"
        is FleetProbeHealthState.Degraded -> "degraded: ${state.reason}"
        is FleetProbeHealthState.Failed -> "failed: ${state.reason}"
    }
    val color = when (entry.state) {
        is FleetProbeHealthState.Ok -> AuroraColors.success
        is FleetProbeHealthState.Degraded -> AuroraColors.warning
        is FleetProbeHealthState.Failed -> AuroraColors.error
    }
    val name = FleetPresentation.agentDisplayName(snapshot, entry.agent)
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.SM.dp),
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 2.dp)
            .semantics { contentDescription = "$name: $stateText" },
    ) {
        Box(
            modifier = Modifier
                .size(7.dp)
                .clip(CircleShape)
                .background(color),
        )
        Text(
            text = name,
            fontSize = AuroraTypography.tiny.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(modifier = Modifier.weight(1f))
        Text(
            text = stateText,
            fontSize = AuroraTypography.tiny.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

@Composable
private fun FleetPersistenceHealthRow(persistenceHealth: FleetPersistenceHealth) {
    val (text, color) = when (persistenceHealth) {
        is FleetPersistenceHealth.Ok -> "Daemon persistence: ok" to MaterialTheme.colorScheme.onSurfaceVariant
        is FleetPersistenceHealth.Degraded ->
            "Daemon persistence degraded: ${persistenceHealth.reason}" to AuroraColors.warning
    }
    Text(
        text = text,
        fontSize = AuroraTypography.tiny.sp,
        color = color,
        modifier = Modifier
            .padding(top = 4.dp)
            .semantics { contentDescription = text },
    )
}
