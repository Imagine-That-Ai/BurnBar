// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.square

import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.openburnbar.data.missions.MissionGroup
import com.openburnbar.data.missions.MissionGroupSnapshot

// MARK: - Mission Fan-Out Group Card (Android parity, Hermes Square §6.4)
//
// List-detail card surfaced beneath the Approval Inbox when a fan-out
// group is active.

@Composable
internal fun MissionFanOutGroupCard(
    snapshot: MissionGroupSnapshot,
    onPickWinner: (childMissionID: String) -> Unit,
    onMergeAction: (MissionGroup.MergeAction) -> Unit,
    modifier: Modifier = Modifier,
) {
    val group = snapshot.group ?: return
    Surface(
        shape = RoundedCornerShape(12.dp),
        color = MaterialTheme.colorScheme.tertiary.copy(alpha = 0.08f),
        modifier =
        modifier
            .fillMaxWidth()
            .border(
                width = 0.5.dp,
                color = MaterialTheme.colorScheme.tertiary.copy(alpha = 0.45f),
                shape = RoundedCornerShape(12.dp),
            ),
    ) {
        Column(
            verticalArrangement = Arrangement.spacedBy(10.dp),
            modifier = Modifier.padding(14.dp),
        ) {
            FanOutGroupCardHeader(snapshot = snapshot)
            for (childID in group.childMissionIDs) {
                ChildMissionRow(
                    childID = childID,
                    snapshot = snapshot.childSnapshots[childID],
                    onTapWinner = { onPickWinner(childID) },
                )
            }
            FanOutMergeActions(onMergeAction = onMergeAction)
        }
    }
}
