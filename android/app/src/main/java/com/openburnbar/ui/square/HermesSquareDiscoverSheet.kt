package com.openburnbar.ui.square

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Tab
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.openburnbar.data.models.ProjectSummary
import com.openburnbar.data.square.AgentIdentity
import com.openburnbar.data.square.AgentIdentityRegistry
import com.openburnbar.data.square.AgentSubscriptionTopicStore
import com.openburnbar.data.square.PinnedAgentGridConfig

// MARK: - Discover Sheet (Hermes Square §3 / §6.2)
//
// Phase 3 parity: 5 tabs — Recent · Project Memory · Capabilities ·
// Marketplace · Agents. Project Memory is backed by `ProjectsStore`.

private const val DISCOVER_RECENT_AGENT_LIMIT = 8

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun HermesSquareDiscoverSheet(
    registry: AgentIdentityRegistry,
    pinned: PinnedAgentGridConfig,
    projectSummaries: List<ProjectSummary> = emptyList(),
    recentAgents: List<AgentIdentity> = registry.identities.take(DISCOVER_RECENT_AGENT_LIMIT),
    onPin: (String) -> Unit,
    onUnpin: (String) -> Unit,
    onOpenProject: (ProjectSummary) -> Unit = {},
    onAskWiki: (ProjectSummary) -> Unit = {},
    onDismiss: () -> Unit,
) {
    val state = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    var tab by remember { mutableStateOf(DiscoverTab.AGENTS) }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = state,
        containerColor = MaterialTheme.colorScheme.surface,
    ) {
        Column(modifier = Modifier.padding(top = 4.dp, bottom = 16.dp)) {
            androidx.compose.material3.ScrollableTabRow(selectedTabIndex = tab.ordinal) {
                DiscoverTab.values().forEach { t ->
                    Tab(
                        selected = tab == t,
                        onClick = { tab = t },
                        text = { Text(t.label, fontSize = 12.sp, fontWeight = FontWeight.SemiBold) },
                    )
                }
            }
            Spacer(modifier = Modifier.height(12.dp))
            when (tab) {
                DiscoverTab.RECENT -> RecentList(recentAgents)
                DiscoverTab.PROJECT_MEMORY ->
                    ProjectMemoryList(
                        projects = projectSummaries,
                        onOpenProject = onOpenProject,
                        onAskWiki = onAskWiki,
                    )
                DiscoverTab.CAPABILITIES -> CapabilitiesList(registry)
                DiscoverTab.MARKETPLACE -> MarketplacePlaceholder()
                DiscoverTab.AGENTS -> AgentsList(registry, pinned, onPin, onUnpin)
            }
        }
    }
}

private enum class DiscoverTab(val label: String) {
    RECENT("Recent"),
    PROJECT_MEMORY("Project Memory"),
    CAPABILITIES("Capabilities"),
    MARKETPLACE("Marketplace"),
    AGENTS("Agents"),
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun HermesSquareSubscriptionsSheet(onDismiss: () -> Unit) {
    val state = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val context = androidx.compose.ui.platform.LocalContext.current
    val store = remember(context) { AgentSubscriptionTopicStore.shared(context) }
    val topics by store.topics.collectAsStateWithLifecycle()
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = state,
        containerColor = MaterialTheme.colorScheme.surface,
    ) {
        SubscriptionsSheetContent(topics = topics, store = store)
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun HermesSquareBrandZoneSheet(identity: AgentIdentity, onDismiss: () -> Unit) {
    val state = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = state,
        containerColor = MaterialTheme.colorScheme.surface,
    ) {
        BrandZoneSheetContent(identity = identity)
    }
}
