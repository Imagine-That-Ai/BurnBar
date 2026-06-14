// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.square

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.RecordVoiceOver
import androidx.compose.material.icons.outlined.ViewAgenda
import androidx.compose.material3.CenterAlignedTopAppBar
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.openburnbar.ui.theme.AuroraColors

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun HermesSquareTopBar(state: HermesSquareUiState, actions: HermesSquareUiActions) {
    CenterAlignedTopAppBar(
        title = {
            Text("Hermes Square", fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.onSurface)
        },
        colors =
        TopAppBarDefaults.centerAlignedTopAppBarColors(
            containerColor = Color.Transparent,
            scrolledContainerColor = Color.Transparent,
        ),
        actions = {
            if (state.flags.phaseB) {
                IconButton(onClick = { actions.setShowFanOut(true) }) {
                    Icon(Icons.Outlined.ViewAgenda, contentDescription = "Fan-out dispatch", tint = AuroraColors.ember)
                }
            }
            if (state.flags.phaseD) {
                IconButton(onClick = { actions.setShowVoice(true) }) {
                    Icon(Icons.Outlined.RecordVoiceOver, contentDescription = "Voice command", tint = AuroraColors.amber)
                }
            }
        },
    )
}

@Composable
internal fun HermesSquareLazyContent(state: HermesSquareUiState, actions: HermesSquareUiActions, innerPadding: PaddingValues) {
    LazyColumn(
        contentPadding = PaddingValues(top = innerPadding.calculateTopPadding() + 12.dp, bottom = 88.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
        modifier = Modifier.fillMaxSize(),
    ) {
        item {
            FederatedSearchBar(query = state.query, onQueryChange = actions.onQueryChange, modifier = Modifier.padding(horizontal = 16.dp))
        }
        if (state.query.isNotBlank()) {
            hermesSquareSearchItems(state, actions)
        } else {
            hermesSquareMainItems(state, actions)
        }
    }
}

private fun LazyListScope.hermesSquareSearchItems(state: HermesSquareUiState, actions: HermesSquareUiActions) {
    item {
        SearchResultsSection(
            hits = state.filteredHits,
            onTap = actions.onSearchHitTap,
            modifier = Modifier.padding(horizontal = 16.dp),
        )
    }
}

private fun LazyListScope.hermesSquareMainItems(state: HermesSquareUiState, actions: HermesSquareUiActions) {
    hermesSquareMissionItems(state, actions)
    hermesSquarePinnedWikiItems(state, actions)
    hermesSquareConversationItems(state, actions)
}

private fun LazyListScope.hermesSquareMissionItems(state: HermesSquareUiState, actions: HermesSquareUiActions) {
    if (state.missionSnapshot.approvalQueue.isNotEmpty()) {
        item {
            ApprovalInboxStrip(
                asks = state.missionSnapshot.approvalQueue,
                onApprove = { actions.onApproveAsk(it, true) },
                onDeny = { actions.onApproveAsk(it, false) },
                onApproveAlways = actions.onApproveAlways,
                onDenyAlways = actions.onDenyAlways,
                modifier = Modifier.padding(horizontal = 16.dp),
            )
        }
    }
    if (state.groupSnapshot.group != null) {
        item {
            MissionFanOutGroupCard(
                snapshot = state.groupSnapshot,
                onPickWinner = { },
                onMergeAction = { },
                modifier = Modifier.padding(horizontal = 16.dp),
            )
        }
    }
    if (state.snapshotsBySession.any { it.value.isNotEmpty() }) {
        item {
            RollbackSectionsList(
                snapshotsBySession = state.snapshotsBySession,
                onSubmit = actions.onRollbackSubmit,
                modifier = Modifier.padding(horizontal = 16.dp),
            )
        }
    }
}

private fun LazyListScope.hermesSquarePinnedWikiItems(state: HermesSquareUiState, actions: HermesSquareUiActions) {
    item {
        PinnedGridSection(
            config = state.pinned,
            registry = state.registry,
            onTap = actions.onPinnedTap,
            onLongPress = actions.onPinnedLongPress,
            onAdd = { actions.setShowDiscover(true) },
            modifier = Modifier.padding(horizontal = 16.dp),
        )
    }
    item {
        ProjectMemoryWikiSection(
            projects = state.projectSummaries.sortedByDescending { it.totalCost }.take(3),
            onOpenProject = { },
            onAskWiki = { },
            modifier = Modifier.padding(horizontal = 16.dp),
        )
    }
    item {
        ActiveMissionsStrip(
            missions = state.missionSnapshot.activeMissions,
            onLongPress = { actions.setMissionToManage(it) },
            onComposeMission = { actions.setShowFanOut(true) },
            modifier = Modifier.padding(start = 16.dp, end = 0.dp),
        )
    }
}

private fun LazyListScope.hermesSquareConversationItems(state: HermesSquareUiState, actions: HermesSquareUiActions) {
    item {
        SectionHeader(label = "Conversations", isLoading = state.inbox.isLoading, modifier = Modifier.padding(horizontal = 16.dp))
    }
    val (service, subscriptions) = state.splitInbox
    if (service.isEmpty()) {
        item { EmptyConversationsCard(modifier = Modifier.padding(horizontal = 16.dp)) }
    } else {
        items(items = service, key = { it.id }) { item ->
            ThreadInboxRow(
                item = item,
                registry = state.registry,
                onTap = { actions.onThreadTap(item) },
                onLongPress = { actions.onThreadLongPress(item) },
                modifier = Modifier.padding(horizontal = 16.dp),
            )
        }
    }
    item {
        SubscriptionsEntry(count = subscriptions.size, onTap = { actions.setShowSubscriptions(true) }, modifier = Modifier.padding(horizontal = 16.dp))
    }
    item {
        DiscoverEntry(onTap = { actions.setShowDiscover(true) }, modifier = Modifier.padding(horizontal = 16.dp))
    }
}
