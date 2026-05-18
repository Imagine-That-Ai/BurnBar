package com.openburnbar.ui.square

import androidx.compose.foundation.background
import androidx.compose.foundation.border
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
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Icon
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.assistants.CLIAgentMissionSnapshot
import com.openburnbar.data.missions.MissionGroup
import com.openburnbar.data.missions.MissionGroupSnapshot
import com.openburnbar.ui.theme.AuroraColors

// MARK: - Mission Fan-Out Group Card (Android parity, Hermes Square §6.4)
//
// List-detail card surfaced beneath the Approval Inbox when a fan-out
// group is active. Renders the parent title + a tally + a row per child
// mission with phase pill, and a "merge" / "keep all" action stripe.

@Composable
internal fun MissionFanOutGroupCard(
    snapshot: MissionGroupSnapshot,
    onPickWinner: (childMissionID: String) -> Unit,
    onMergeAction: (MissionGroup.MergeAction) -> Unit,
    modifier: Modifier = Modifier
) {
    val group = snapshot.group ?: return
    val tally = snapshot.childPhaseTally
    Surface(
        shape = RoundedCornerShape(12.dp),
        color = MaterialTheme.colorScheme.tertiary.copy(alpha = 0.08f),
        modifier = modifier
            .fillMaxWidth()
            .border(
                width = 0.5.dp,
                color = MaterialTheme.colorScheme.tertiary.copy(alpha = 0.45f),
                shape = RoundedCornerShape(12.dp)
            )
    ) {
        Column(
            verticalArrangement = Arrangement.spacedBy(10.dp),
            modifier = Modifier.padding(14.dp)
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    imageVector = Icons.Filled.Bolt,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.tertiary,
                    modifier = Modifier.size(14.dp)
                )
                Spacer(modifier = Modifier.width(6.dp))
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        group.title,
                        fontSize = 13.sp,
                        fontWeight = FontWeight.Bold,
                        color = MaterialTheme.colorScheme.onSurface,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )
                    Text(
                        "${tally.terminal} of ${group.childMissionIDs.size} done · ${tally.live} live · ${tally.awaitingApproval} need approval",
                        fontSize = 11.sp,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )
                }
                Surface(
                    shape = RoundedCornerShape(999.dp),
                    color = MaterialTheme.colorScheme.surface
                ) {
                    Text(
                        snapshot.derivedPhase ?: group.phase,
                        fontSize = 10.sp,
                        fontWeight = FontWeight.Bold,
                        color = MaterialTheme.colorScheme.onSurface,
                        modifier = Modifier.padding(horizontal = 8.dp, vertical = 2.dp)
                    )
                }
            }

            for (childID in group.childMissionIDs) {
                val child = snapshot.childSnapshots[childID]
                ChildMissionRow(
                    childID = childID,
                    snapshot = child,
                    onTapWinner = { onPickWinner(childID) }
                )
            }

            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                MergeActionPill(
                    label = "Keep all",
                    onClick = { onMergeAction(MissionGroup.MergeAction.KEEP_ALL) }
                )
                MergeActionPill(
                    label = "Synthesize",
                    onClick = { onMergeAction(MissionGroup.MergeAction.SYNTHESIZE) }
                )
            }
        }
    }
}

@Composable
private fun ChildMissionRow(
    childID: String,
    snapshot: CLIAgentMissionSnapshot?,
    onTapWinner: () -> Unit
) {
    val status = snapshot?.displayStatus ?: "queued"
    val title = snapshot?.title ?: childID.take(12)
    Surface(
        shape = RoundedCornerShape(8.dp),
        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.55f),
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(8.dp))
            .clickable(onClick = onTapWinner)
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.padding(horizontal = 10.dp, vertical = 8.dp)
        ) {
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    title,
                    fontSize = 12.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = MaterialTheme.colorScheme.onSurface,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
                Text(
                    snapshot?.runtimeLabel ?: "Awaiting Mac",
                    fontSize = 10.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
            }
            Surface(
                shape = RoundedCornerShape(999.dp),
                color = phaseColor(status).copy(alpha = 0.18f)
            ) {
                Text(
                    status.replace('_', ' '),
                    fontSize = 9.sp,
                    fontWeight = FontWeight.Bold,
                    color = phaseColor(status),
                    modifier = Modifier.padding(horizontal = 8.dp, vertical = 2.dp)
                )
            }
        }
    }
}

@Composable
private fun MergeActionPill(label: String, onClick: () -> Unit) {
    Surface(
        shape = RoundedCornerShape(999.dp),
        color = MaterialTheme.colorScheme.tertiary.copy(alpha = 0.12f),
        modifier = Modifier
            .clip(RoundedCornerShape(999.dp))
            .clickable(onClick = onClick)
    ) {
        Text(
            label,
            fontSize = 11.sp,
            fontWeight = FontWeight.Bold,
            color = MaterialTheme.colorScheme.tertiary,
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp)
        )
    }
}

private fun phaseColor(status: String): Color = when (status.lowercase()) {
    "completed" -> AuroraColors.success
    "failed", "agent_launch_failed", "unauthorized" -> AuroraColors.error
    "waiting_for_approval" -> AuroraColors.warning
    "mac_offline" -> AuroraColors.warning
    else -> AuroraColors.whimsy
}
