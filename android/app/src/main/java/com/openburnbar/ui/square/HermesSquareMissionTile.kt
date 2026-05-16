package com.openburnbar.ui.square

import androidx.compose.foundation.layout.Arrangement
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
import androidx.compose.material.icons.filled.Cancel
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.HourglassEmpty
import androidx.compose.material.icons.filled.PanTool
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.missions.ActiveMission
import com.openburnbar.ui.theme.AuroraColors

// MARK: - Hermes Square Mission Tile (Android parity)
//
// Compact horizontally-scrolling mission card for the Active Missions
// strip. Mirrors the iOS `HermesSquareMissionTile`.

@Composable
internal fun HermesSquareMissionTile(
    tile: ActiveMission,
    modifier: Modifier = Modifier
) {
    Surface(
        shape = RoundedCornerShape(12.dp),
        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.65f),
        tonalElevation = 0.5.dp,
        modifier = modifier
            .height(120.dp)
            .fillMaxWidth()
    ) {
        Column(
            verticalArrangement = Arrangement.spacedBy(6.dp),
            modifier = Modifier
                .fillMaxWidth()
                .padding(12.dp)
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    imageVector = iconForPhase(tile.phase),
                    contentDescription = null,
                    tint = colorForPhase(tile.phase),
                    modifier = Modifier.size(14.dp)
                )
                Spacer(modifier = Modifier.width(6.dp))
                Text(
                    tile.runtimeDisplayLabel,
                    fontSize = 10.sp,
                    fontWeight = FontWeight.Bold,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
                Spacer(modifier = Modifier.weight(1f))
                Text(
                    tile.phase.displayLabel,
                    fontSize = 10.sp,
                    fontWeight = FontWeight.Bold,
                    color = colorForPhase(tile.phase)
                )
            }
            Text(
                tile.title,
                fontSize = 13.sp,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurface,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis
            )
            tile.phaseDetail?.let {
                Text(
                    it,
                    fontSize = 10.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis
                )
            }
            tile.progressFraction?.let { fraction ->
                LinearProgressIndicator(
                    progress = { fraction.toFloat() },
                    color = colorForPhase(tile.phase),
                    trackColor = MaterialTheme.colorScheme.surface,
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(2.dp)
                )
            }
        }
    }
}

private fun iconForPhase(phase: ActiveMission.Phase): ImageVector = when (phase) {
    ActiveMission.Phase.COMPLETED -> Icons.Filled.CheckCircle
    ActiveMission.Phase.FAILED, ActiveMission.Phase.BLOCKED, ActiveMission.Phase.CANCELLED, ActiveMission.Phase.MAC_OFFLINE -> Icons.Filled.Cancel
    ActiveMission.Phase.AWAITING_APPROVAL -> Icons.Filled.PanTool
    ActiveMission.Phase.QUEUED, ActiveMission.Phase.STARTING -> Icons.Filled.HourglassEmpty
    else -> Icons.Filled.Bolt
}

private fun colorForPhase(phase: ActiveMission.Phase): Color = when (phase) {
    ActiveMission.Phase.COMPLETED -> AuroraColors.success
    ActiveMission.Phase.FAILED, ActiveMission.Phase.BLOCKED -> AuroraColors.error
    ActiveMission.Phase.CANCELLED, ActiveMission.Phase.MAC_OFFLINE -> AuroraColors.warning
    ActiveMission.Phase.AWAITING_APPROVAL -> AuroraColors.warning
    else -> AuroraColors.ember
}
