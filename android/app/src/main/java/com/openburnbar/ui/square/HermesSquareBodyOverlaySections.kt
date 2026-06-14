// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.square

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowDownward
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.PushPin
import androidx.compose.material.icons.outlined.PushPin
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.missions.ApprovalAsk
import com.openburnbar.data.missions.ApprovalDecision
import com.openburnbar.data.missions.ApprovalPolicy
import com.openburnbar.data.missions.ApprovalPolicyStore
import com.openburnbar.data.square.ThreadInboxItem
import com.openburnbar.ui.components.AuroraBottomSheet
import com.openburnbar.ui.theme.AuroraColors

@Composable
internal fun BoxScope.HermesSquareVoiceBannerOverlay(state: HermesSquareUiState, actions: HermesSquareUiActions, innerPadding: PaddingValues) {
    AnimatedVisibility(
        visible = state.voiceBanner != null,
        enter = slideInVertically(initialOffsetY = { -it }) + fadeIn(),
        exit = slideOutVertically(targetOffsetY = { -it }) + fadeOut(),
        modifier =
        Modifier
            .align(Alignment.TopCenter)
            .padding(top = innerPadding.calculateTopPadding() + 8.dp)
            .padding(horizontal = 16.dp),
    ) {
        state.voiceBanner?.let { intent ->
            VoiceIntentBannerView(intent = intent, onDismiss = { actions.setVoiceBanner(null) })
        }
    }
}

@Composable
internal fun HermesSquareOverlays(state: HermesSquareUiState, actions: HermesSquareUiActions) {
    HermesSquareSheetOverlays(state, actions)
    HermesSquareThreadManageOverlay(state, actions)
    HermesSquareRenameDialogOverlay(state, actions)
    HermesSquareMissionManageDialog(state, actions)
    HermesSquarePinnedAgentManageDialog(state, actions)
}

@Composable
private fun HermesSquareSheetOverlays(state: HermesSquareUiState, actions: HermesSquareUiActions) {
    if (state.showDiscover) {
        HermesSquareDiscoverSheet(
            registry = state.registry,
            pinned = state.pinned,
            onPin = { actions.persistPinned(state.pinned.pinning(it)) },
            onUnpin = { actions.persistPinned(state.pinned.unpinning(it)) },
            onDismiss = { actions.setShowDiscover(false) },
        )
    }
    if (state.showFanOut) {
        HermesSquareFanOutSheet(
            registry = state.registry,
            onDispatched = { actions.setShowFanOut(false) },
            onDismiss = { actions.setShowFanOut(false) },
        )
    }
    if (state.showVoice) {
        HermesSquareVoiceSheet(
            registry = state.registry,
            currentThreadAgentURI = null,
            onIntent = { intent ->
                actions.setVoiceBanner(intent)
                actions.setShowVoice(false)
            },
            onDismiss = { actions.setShowVoice(false) },
        )
    }
    if (state.showSubscriptions) {
        HermesSquareSubscriptionsSheet(onDismiss = { actions.setShowSubscriptions(false) })
    }
    state.selectedCloudRow?.let { row ->
        CloudSessionResultSheet(row = row, activityStore = state.activityStore, onDismiss = { actions.setSelectedCloudRow(null) })
    }
    state.selectedCliSession?.let { session ->
        CLIAgentSessionSheet(session = session, hermesService = state.hermesService, onDismiss = { actions.setSelectedCliSession(null) })
    }
    state.showBrandZoneURI?.let { uri ->
        state.registry.identity(uri)?.let { identity ->
            HermesSquareBrandZoneSheet(identity = identity, onDismiss = { actions.setShowBrandZoneURI(null) })
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun HermesSquareThreadManageOverlay(state: HermesSquareUiState, actions: HermesSquareUiActions) {
    state.threadToManage?.let { item ->
        AuroraBottomSheet(onDismissRequest = { actions.setThreadToManage(null) }) {
            HermesSquareThreadManageSheetContent(item = item, actions = actions)
        }
    }
}

@Composable
private fun HermesSquareThreadManageSheetContent(item: ThreadInboxItem, actions: HermesSquareUiActions) {
    Column(
        verticalArrangement = Arrangement.spacedBy(16.dp),
        modifier = Modifier.fillMaxWidth().padding(vertical = 16.dp, horizontal = 8.dp),
    ) {
        Text(
            text = item.customTitle ?: item.title,
            fontSize = 18.sp,
            fontWeight = FontWeight.Bold,
            color = MaterialTheme.colorScheme.onSurface,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        HorizontalDivider(color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.08f))
        HermesSquareThreadManageActions(item = item, actions = actions)
        HermesSquareThreadManageReorder(item = item, actions = actions)
        HorizontalDivider(color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.08f))
        HermesSquareThreadManageColors(item = item, actions = actions)
    }
}

@Composable
private fun HermesSquareThreadManageActions(item: ThreadInboxItem, actions: HermesSquareUiActions) {
    TextButton(
        onClick = {
            actions.setRenameDialogText(item.customTitle ?: item.title)
            actions.setShowRenameDialogForThread(item)
            actions.setThreadToManage(null)
        },
        modifier = Modifier.fillMaxWidth(),
    ) {
        Text(
            "Rename Conversation",
            color = MaterialTheme.colorScheme.onSurface,
            fontSize = 15.sp,
            fontWeight = FontWeight.Medium,
            modifier = Modifier.fillMaxWidth(),
        )
    }
    TextButton(
        onClick = {
            actions.updateThreadItemMetadata(item, null, null, !item.isPinned, null)
            actions.setThreadToManage(null)
        },
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
            Text(
                text = if (item.isPinned) "Unpin from Top" else "Pin to Top",
                color = MaterialTheme.colorScheme.onSurface,
                fontSize = 15.sp,
                fontWeight = FontWeight.Medium,
                modifier = Modifier.weight(1f),
            )
            Icon(
                imageVector = if (item.isPinned) Icons.Outlined.PushPin else Icons.Filled.PushPin,
                contentDescription = null,
                tint = AuroraColors.ember,
                modifier = Modifier.size(18.dp),
            )
        }
    }
}

@Composable
private fun HermesSquareThreadManageReorder(item: ThreadInboxItem, actions: HermesSquareUiActions) {
    Row(horizontalArrangement = Arrangement.spacedBy(12.dp), modifier = Modifier.fillMaxWidth()) {
        TextButton(onClick = {
            actions.moveThreadItem(item, -1)
            actions.setThreadToManage(null)
        }, modifier = Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Filled.ArrowUpward, contentDescription = null, modifier = Modifier.size(16.dp))
                Spacer(Modifier.width(4.dp))
                Text("Move Up", fontSize = 14.sp)
            }
        }
        TextButton(onClick = {
            actions.moveThreadItem(item, 1)
            actions.setThreadToManage(null)
        }, modifier = Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Filled.ArrowDownward, contentDescription = null, modifier = Modifier.size(16.dp))
                Spacer(Modifier.width(4.dp))
                Text("Move Down", fontSize = 14.sp)
            }
        }
    }
}

@Composable
private fun HermesSquareThreadManageColors(item: ThreadInboxItem, actions: HermesSquareUiActions) {
    Text("Label Color", fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.onSurfaceVariant)
    val colorLabels =
        listOf(
            ColorLabelOption("None", "#NONE#", Color.Gray.copy(alpha = 0.5f)),
            ColorLabelOption("Amber", "#f59e0b", Color(0xFFF59E0B)),
            ColorLabelOption("Teal", "#14b8a6", Color(0xFF14B8A6)),
            ColorLabelOption("Red", "#ef4444", Color(0xFFEF4444)),
            ColorLabelOption("Purple", "#a855f7", Color(0xFFA855F7)),
            ColorLabelOption("Emerald", "#10b981", Color(0xFF10B981)),
        )
    Row(horizontalArrangement = Arrangement.SpaceBetween, modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp)) {
        colorLabels.forEach { option ->
            val isSelected = item.labelColorHex ?: "#NONE#" == option.hex
            Box(
                contentAlignment = Alignment.Center,
                modifier =
                Modifier
                    .size(42.dp)
                    .clip(androidx.compose.foundation.shape.RoundedCornerShape(50))
                    .background(option.color)
                    .border(
                        width = if (isSelected) 3.dp else 1.dp,
                        color = if (isSelected) MaterialTheme.colorScheme.primary else Color.Transparent,
                        shape = androidx.compose.foundation.shape.RoundedCornerShape(50),
                    )
                    .clickableUnit {
                        actions.updateThreadItemMetadata(item, null, option.hex, null, null)
                        actions.setThreadToManage(null)
                    },
            ) {
                if (isSelected) {
                    Icon(Icons.Filled.Check, contentDescription = "Selected", tint = Color.White, modifier = Modifier.size(18.dp))
                }
            }
        }
    }
}

@Composable
private fun HermesSquareRenameDialogOverlay(state: HermesSquareUiState, actions: HermesSquareUiActions) {
    state.showRenameDialogForThread?.let { item ->
        AlertDialog(
            onDismissRequest = { actions.setShowRenameDialogForThread(null) },
            title = { Text("Rename Conversation") },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("Enter a new custom title for this thread. Leave blank to reset to default.")
                    OutlinedTextField(
                        value = state.renameDialogText,
                        onValueChange = actions.setRenameDialogText,
                        placeholder = { Text(item.title) },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
            },
            confirmButton = {
                TextButton(onClick = {
                    actions.updateThreadItemMetadata(item, state.renameDialogText, null, null, null)
                    actions.setShowRenameDialogForThread(null)
                }) { Text("Save") }
            },
            dismissButton = { TextButton(onClick = { actions.setShowRenameDialogForThread(null) }) { Text("Cancel") } },
        )
    }
}

@Composable
private fun HermesSquareMissionManageDialog(state: HermesSquareUiState, actions: HermesSquareUiActions) {
    state.missionToManage?.let { mission ->
        AlertDialog(
            onDismissRequest = { actions.setMissionToManage(null) },
            title = { Text("Manage Mission") },
            text = { Text("Would you like to cancel this active mission or dismiss it from your console?") },
            confirmButton = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    TextButton(onClick = {
                        actions.onMissionCancelDismiss(mission)
                        actions.setMissionToManage(null)
                    }, modifier = Modifier.fillMaxWidth()) {
                        Text("Cancel & Dismiss", color = MaterialTheme.colorScheme.error)
                    }
                    TextButton(onClick = {
                        actions.onMissionDismiss(mission)
                        actions.setMissionToManage(null)
                    }, modifier = Modifier.fillMaxWidth()) {
                        Text("Just Dismiss")
                    }
                    TextButton(onClick = { actions.setMissionToManage(null) }, modifier = Modifier.fillMaxWidth()) { Text("Keep Running") }
                }
            },
        )
    }
}

@Composable
private fun HermesSquarePinnedAgentManageDialog(state: HermesSquareUiState, actions: HermesSquareUiActions) {
    state.pinnedAgentToManage?.let { uri ->
        val identity = state.registry.identity(uri)
        val index = state.pinned.pinnedURIs.indexOf(uri)
        AlertDialog(
            onDismissRequest = { actions.setPinnedAgentToManage(null) },
            title = { Text("Rearrange ${identity?.displayName ?: "Agent"}") },
            text = { Text("Move this pinned agent within your grid or unpin it completely.") },
            confirmButton = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    if (index > 0) {
                        TextButton(onClick = {
                            actions.persistPinned(state.pinned.moving(index, index - 1))
                            actions.setPinnedAgentToManage(null)
                        }, modifier = Modifier.fillMaxWidth()) {
                            Text("Move Left")
                        }
                    }
                    if (index < state.pinned.pinnedURIs.size - 1) {
                        TextButton(onClick = {
                            actions.persistPinned(state.pinned.moving(index, index + 1))
                            actions.setPinnedAgentToManage(null)
                        }, modifier = Modifier.fillMaxWidth()) {
                            Text("Move Right")
                        }
                    }
                    TextButton(onClick = {
                        actions.persistPinned(state.pinned.unpinning(uri))
                        actions.setPinnedAgentToManage(null)
                    }, modifier = Modifier.fillMaxWidth()) {
                        Text("Unpin Agent", color = MaterialTheme.colorScheme.error)
                    }
                    TextButton(onClick = { actions.setPinnedAgentToManage(null) }, modifier = Modifier.fillMaxWidth()) { Text("Cancel") }
                }
            },
        )
    }
}

private data class ColorLabelOption(
    val name: String,
    val hex: String,
    val color: Color,
)

internal fun recordApprovalPolicy(store: ApprovalPolicyStore, ask: ApprovalAsk, decision: ApprovalDecision) {
    val scopeKey = "runtime=${ask.runtimeID ?: "any"}"
    val policy =
        ApprovalPolicy(
            id = ApprovalPolicyStore.classKey(agentURI = null, scopeKey = scopeKey) + ":" + decision.token,
            agentURI = null,
            scopeKey = scopeKey,
            missionKind = null,
            toolName = null,
            fileGlob = null,
            runtimeID = ask.runtimeID,
            targetProject = null,
            decision = decision,
            displayLabel = "${if (decision == ApprovalDecision.REMEMBER_ALLOW) "Always approve" else "Always deny"} for ${ask.runtimeDisplayLabel}",
        )
    store.record(policy)
}
