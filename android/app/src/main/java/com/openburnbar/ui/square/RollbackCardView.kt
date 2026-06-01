package com.openburnbar.ui.square

import androidx.compose.foundation.border
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.openburnbar.data.missions.RollbackScope
import com.openburnbar.data.missions.RollbackSnapshot
import com.openburnbar.ui.theme.AuroraColors

// MARK: - Rollback Card View (Android parity, Hermes Square §6.10)
//
// Inline rollback affordance — three quick actions (whole session / last
// action / per-file) plus the latest snapshot description.

@Suppress("UnusedParameter")
@Composable
internal fun RollbackCardView(sessionID: String, snapshots: List<RollbackSnapshot>, onSubmit: (RollbackScope) -> Unit, modifier: Modifier = Modifier) {
    var pickerOpen by remember { mutableStateOf(false) }
    val newest = remember(snapshots) { snapshots.maxByOrNull { it.sequence } }
    val touchedFiles =
        remember(snapshots) {
            snapshots.flatMap { it.touchedFiles }.distinct().sorted()
        }
    Surface(
        shape = RoundedCornerShape(10.dp),
        color = AuroraColors.whimsy.copy(alpha = 0.08f),
        modifier =
        modifier
            .fillMaxWidth()
            .border(0.5.dp, AuroraColors.whimsy.copy(alpha = 0.30f), RoundedCornerShape(10.dp)),
    ) {
        RollbackCardContent(
            snapshots = snapshots,
            newest = newest,
            onSubmit = onSubmit,
            onOpenFilePicker = { pickerOpen = true },
        )
    }
    if (pickerOpen) {
        RollbackFilePickerSheet(
            files = touchedFiles,
            onPick = { path ->
                onSubmit(RollbackScope.SingleFile(path))
                pickerOpen = false
            },
            onDismiss = { pickerOpen = false },
        )
    }
}
