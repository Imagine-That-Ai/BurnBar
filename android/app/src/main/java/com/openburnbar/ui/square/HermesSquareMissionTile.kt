package com.openburnbar.ui.square

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.openburnbar.data.missions.ActiveMission

// MARK: - Hermes Square Mission Tile (Android parity)
//
// Compact horizontally-scrolling mission card for the Active Missions strip.

@OptIn(ExperimentalFoundationApi::class)
@Composable
internal fun HermesSquareMissionTile(tile: ActiveMission, onLongPress: () -> Unit = {}, modifier: Modifier = Modifier) {
    Surface(
        shape = RoundedCornerShape(12.dp),
        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.65f),
        tonalElevation = 0.5.dp,
        modifier =
        modifier
            .height(120.dp)
            .fillMaxWidth()
            .combinedClickable(onClick = {}, onLongClick = onLongPress),
    ) {
        MissionTileBody(tile = tile)
    }
}
