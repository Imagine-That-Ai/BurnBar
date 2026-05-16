package com.openburnbar.ui.square

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Cancel
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.Restore
import androidx.compose.material.icons.filled.Undo
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.missions.RollbackScope
import com.openburnbar.data.missions.RollbackSnapshot
import com.openburnbar.ui.theme.AuroraColors

// MARK: - Rollback Card View (Android parity, Hermes Square §6.10)
//
// Inline rollback affordance — three quick actions (whole session / last
// action / per-file) plus the latest snapshot description. Mirrors the
// iOS surface; the success-checkmark animation simplifies to a fade
// pulse on Android (no PhaseAnimator equivalent in Compose 1.7).

@Composable
internal fun RollbackCardView(
    sessionID: String,
    snapshots: List<RollbackSnapshot>,
    onSubmit: (RollbackScope) -> Unit,
    modifier: Modifier = Modifier
) {
    var pickerOpen by remember { mutableStateOf(false) }
    val newest = remember(snapshots) { snapshots.maxByOrNull { it.sequence } }
    val touchedFiles = remember(snapshots) {
        snapshots.flatMap { it.touchedFiles }.distinct().sorted()
    }
    Surface(
        shape = RoundedCornerShape(10.dp),
        color = AuroraColors.whimsy.copy(alpha = 0.08f),
        modifier = modifier
            .fillMaxWidth()
            .border(0.5.dp, AuroraColors.whimsy.copy(alpha = 0.30f), RoundedCornerShape(10.dp))
    ) {
        Column(
            verticalArrangement = Arrangement.spacedBy(8.dp),
            modifier = Modifier.padding(12.dp)
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    imageVector = Icons.Filled.History,
                    contentDescription = null,
                    tint = AuroraColors.whimsy,
                    modifier = Modifier.size(14.dp)
                )
                Spacer(modifier = Modifier.width(6.dp))
                Text(
                    "Rollback",
                    fontSize = 11.sp,
                    fontWeight = FontWeight.Bold,
                    color = MaterialTheme.colorScheme.onSurface
                )
                Spacer(modifier = Modifier.weight(1f))
                Text(
                    "${snapshots.size} snapshots",
                    fontSize = 10.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
            if (snapshots.isEmpty()) {
                Text(
                    "No snapshots yet — the Mac writes them as the agent acts.",
                    fontSize = 11.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            } else {
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    RollbackAction(
                        label = "Whole session",
                        icon = Icons.Filled.Restore,
                        onClick = { onSubmit(RollbackScope.FullSession) }
                    )
                    RollbackAction(
                        label = "Last action",
                        icon = Icons.Filled.Undo,
                        onClick = { onSubmit(RollbackScope.LastN(count = 1)) }
                    )
                    RollbackAction(
                        label = "Per-file…",
                        icon = Icons.Filled.Description,
                        onClick = { pickerOpen = true }
                    )
                }
                if (newest != null) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Surface(
                            shape = RoundedCornerShape(999.dp),
                            color = AuroraColors.whimsy,
                            modifier = Modifier.size(5.dp)
                        ) {}
                        Spacer(modifier = Modifier.width(4.dp))
                        Text(
                            "Latest: ${newest.actionLabel}",
                            fontSize = 10.sp,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis
                        )
                    }
                }
            }
        }
    }
    if (pickerOpen) {
        RollbackFilePickerSheet(
            files = touchedFiles,
            onPick = { path ->
                onSubmit(RollbackScope.SingleFile(path))
                pickerOpen = false
            },
            onDismiss = { pickerOpen = false }
        )
    }
}

@Composable
private fun RowScopedAction(
    label: String,
    icon: ImageVector,
    onClick: () -> Unit,
    modifier: Modifier = Modifier
) {
    Surface(
        shape = RoundedCornerShape(8.dp),
        color = AuroraColors.whimsy.copy(alpha = 0.10f),
        modifier = modifier
            .clip(RoundedCornerShape(8.dp))
            .clickable(onClick = onClick)
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
            modifier = Modifier.padding(horizontal = 8.dp, vertical = 8.dp)
        ) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                tint = AuroraColors.whimsy,
                modifier = Modifier.size(18.dp)
            )
            Spacer(modifier = Modifier.height(2.dp))
            Text(
                label,
                fontSize = 10.sp,
                fontWeight = FontWeight.Bold,
                color = AuroraColors.whimsy,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis
            )
        }
    }
}

@Composable
private fun androidx.compose.foundation.layout.RowScope.RollbackAction(
    label: String,
    icon: ImageVector,
    onClick: () -> Unit
) {
    RowScopedAction(label = label, icon = icon, onClick = onClick, modifier = Modifier.weight(1f))
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun RollbackFilePickerSheet(
    files: List<String>,
    onPick: (String) -> Unit,
    onDismiss: () -> Unit
) {
    val state = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = state,
        containerColor = MaterialTheme.colorScheme.surface
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 20.dp, vertical = 16.dp)
        ) {
            Text(
                "Pick a file to revert",
                fontSize = 16.sp,
                fontWeight = FontWeight.Bold,
                color = MaterialTheme.colorScheme.onSurface
            )
            Spacer(modifier = Modifier.height(10.dp))
            if (files.isEmpty()) {
                Text(
                    "No files in any snapshot yet.",
                    fontSize = 12.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            } else {
                LazyColumn(
                    verticalArrangement = Arrangement.spacedBy(6.dp),
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(360.dp)
                ) {
                    items(files, key = { it }) { path ->
                        Surface(
                            shape = RoundedCornerShape(8.dp),
                            color = MaterialTheme.colorScheme.surface.copy(alpha = 0.6f),
                            modifier = Modifier
                                .fillMaxWidth()
                                .clickable { onPick(path) }
                        ) {
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                modifier = Modifier.padding(horizontal = 12.dp, vertical = 10.dp)
                            ) {
                                Icon(
                                    imageVector = Icons.Filled.Description,
                                    contentDescription = null,
                                    tint = AuroraColors.whimsy,
                                    modifier = Modifier.size(14.dp)
                                )
                                Spacer(modifier = Modifier.width(8.dp))
                                Text(
                                    path,
                                    fontSize = 12.sp,
                                    fontFamily = FontFamily.Monospace,
                                    color = MaterialTheme.colorScheme.onSurface,
                                    modifier = Modifier.weight(1f),
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis
                                )
                                Icon(
                                    imageVector = Icons.Filled.Undo,
                                    contentDescription = null,
                                    tint = AuroraColors.whimsy,
                                    modifier = Modifier.size(14.dp)
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}
