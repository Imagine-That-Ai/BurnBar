package com.openburnbar.ui.square

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.PushPin
import androidx.compose.material.icons.outlined.PushPin
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Surface
import androidx.compose.material3.Tab
import androidx.compose.material3.TabRow
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
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.models.ProjectSummary
import com.openburnbar.data.square.AgentCapabilities
import com.openburnbar.data.square.AgentIdentity
import com.openburnbar.data.square.AgentIdentityRegistry
import com.openburnbar.data.square.AgentTier
import com.openburnbar.data.square.PinnedAgentGridConfig

// MARK: - Discover Sheet (Hermes Square §3 / §6.2)
//
// Phase 3 parity: 5 tabs — Recent · Project Memory · Capabilities ·
// Marketplace · Agents. Project Memory is backed by `ProjectsStore`.

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun HermesSquareDiscoverSheet(
    registry: AgentIdentityRegistry,
    pinned: PinnedAgentGridConfig,
    projectSummaries: List<ProjectSummary> = emptyList(),
    recentAgents: List<AgentIdentity> = registry.identities.take(8),
    onPin: (String) -> Unit,
    onUnpin: (String) -> Unit,
    onOpenProject: (ProjectSummary) -> Unit = {},
    onAskWiki: (ProjectSummary) -> Unit = {},
    onDismiss: () -> Unit
) {
    val state = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    var tab by remember { mutableStateOf(DiscoverTab.AGENTS) }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = state,
        containerColor = MaterialTheme.colorScheme.surface
    ) {
        Column(modifier = Modifier.padding(top = 4.dp, bottom = 16.dp)) {
            androidx.compose.material3.ScrollableTabRow(selectedTabIndex = tab.ordinal) {
                DiscoverTab.values().forEach { t ->
                    Tab(
                        selected = tab == t,
                        onClick = { tab = t },
                        text = { Text(t.label, fontSize = 12.sp, fontWeight = FontWeight.SemiBold) }
                    )
                }
            }
            Spacer(modifier = Modifier.height(12.dp))
            when (tab) {
                DiscoverTab.RECENT -> RecentList(recentAgents)
                DiscoverTab.PROJECT_MEMORY -> ProjectMemoryList(
                    projects = projectSummaries,
                    onOpenProject = onOpenProject,
                    onAskWiki = onAskWiki
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

@Composable
private fun RecentList(recent: List<AgentIdentity>) {
    if (recent.isEmpty()) {
        Column(
            verticalArrangement = Arrangement.Center,
            horizontalAlignment = Alignment.CenterHorizontally,
            modifier = Modifier.fillMaxWidth().padding(horizontal = 32.dp, vertical = 28.dp)
        ) {
            Text(
                "No recent activity yet.",
                fontSize = 13.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
        return
    }
    LazyColumn(
        verticalArrangement = Arrangement.spacedBy(8.dp),
        modifier = Modifier.padding(horizontal = 16.dp)
    ) {
        items(recent, key = { it.id }) { identity ->
            Surface(
                shape = RoundedCornerShape(10.dp),
                color = MaterialTheme.colorScheme.surface.copy(alpha = 0.55f),
                modifier = Modifier.fillMaxWidth()
            ) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier.padding(horizontal = 12.dp, vertical = 10.dp)
                ) {
                    Box(
                        contentAlignment = Alignment.Center,
                        modifier = Modifier
                            .size(28.dp)
                            .clip(RoundedCornerShape(50))
                            .background(hexColor(identity.paletteHex))
                    ) {
                        Text(identity.glyph, color = Color.White, fontSize = 14.sp, fontWeight = FontWeight.Bold)
                    }
                    Spacer(modifier = Modifier.width(10.dp))
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            identity.displayName,
                            fontSize = 13.sp,
                            fontWeight = FontWeight.SemiBold,
                            color = MaterialTheme.colorScheme.onSurface
                        )
                        identity.tagline?.let {
                            Text(
                                it,
                                fontSize = 11.sp,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun ProjectMemoryList(
    projects: List<ProjectSummary>,
    onOpenProject: (ProjectSummary) -> Unit,
    onAskWiki: (ProjectSummary) -> Unit
) {
    if (projects.isEmpty()) {
        Column(
            verticalArrangement = Arrangement.Center,
            horizontalAlignment = Alignment.CenterHorizontally,
            modifier = Modifier.fillMaxWidth().padding(horizontal = 32.dp, vertical = 28.dp)
        ) {
            Text(
                "Project Memory",
                fontSize = 16.sp,
                fontWeight = FontWeight.Bold,
                color = MaterialTheme.colorScheme.onSurface
            )
            Spacer(modifier = Modifier.height(6.dp))
            Text(
                "No project memory available yet. Start with /wiki in Hermes to build one.",
                fontSize = 12.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
        return
    }
    LazyColumn(
        verticalArrangement = Arrangement.spacedBy(8.dp),
        modifier = Modifier.padding(horizontal = 16.dp)
    ) {
        items(projects, key = { it.id }) { project ->
            Surface(
                shape = RoundedCornerShape(10.dp),
                color = MaterialTheme.colorScheme.surface.copy(alpha = 0.6f),
                modifier = Modifier.fillMaxWidth()
            ) {
                Column(
                    verticalArrangement = Arrangement.spacedBy(6.dp),
                    modifier = Modifier.padding(12.dp)
                ) {
                    Text(
                        project.name.ifBlank { project.id },
                        fontSize = 14.sp,
                        fontWeight = FontWeight.Bold,
                        color = MaterialTheme.colorScheme.onSurface,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )
                    Text(
                        "${project.totalSessions} sessions · ${project.totalTokens} tokens · $${
                            "%.2f".format(project.totalCost)
                        }",
                        fontSize = 11.sp,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    Row(
                        horizontalArrangement = Arrangement.spacedBy(6.dp)
                    ) {
                        ProjectActionPill(
                            label = "Open",
                            fillColor = MaterialTheme.colorScheme.surface.copy(alpha = 0.8f),
                            textColor = MaterialTheme.colorScheme.onSurface,
                            onClick = { onOpenProject(project) }
                        )
                        ProjectActionPill(
                            label = "Ask /wiki",
                            fillColor = MaterialTheme.colorScheme.primary.copy(alpha = 0.15f),
                            textColor = MaterialTheme.colorScheme.primary,
                            onClick = { onAskWiki(project) }
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun ProjectActionPill(
    label: String,
    fillColor: Color,
    textColor: Color,
    onClick: () -> Unit
) {
    Surface(
        shape = RoundedCornerShape(999.dp),
        color = fillColor,
        modifier = Modifier
            .clip(RoundedCornerShape(999.dp))
            .clickable(onClick = onClick)
    ) {
        Text(
            label,
            fontSize = 11.sp,
            fontWeight = FontWeight.Bold,
            color = textColor,
            modifier = Modifier.padding(horizontal = 10.dp, vertical = 5.dp)
        )
    }
}

@Composable
private fun AgentsList(
    registry: AgentIdentityRegistry,
    pinned: PinnedAgentGridConfig,
    onPin: (String) -> Unit,
    onUnpin: (String) -> Unit
) {
    LazyColumn(
        verticalArrangement = Arrangement.spacedBy(8.dp),
        modifier = Modifier.padding(horizontal = 16.dp)
    ) {
        items(registry.identities, key = { it.id }) { identity ->
            Surface(
                shape = RoundedCornerShape(10.dp),
                color = MaterialTheme.colorScheme.surface.copy(alpha = 0.6f),
                tonalElevation = 0.5.dp,
                modifier = Modifier.fillMaxWidth()
            ) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 12.dp, vertical = 10.dp)
                ) {
                    Box(
                        contentAlignment = Alignment.Center,
                        modifier = Modifier
                            .size(30.dp)
                            .clip(RoundedCornerShape(50))
                            .background(hexColor(identity.paletteHex))
                    ) {
                        Text(
                            identity.glyph,
                            color = Color.White,
                            fontSize = 14.sp,
                            fontWeight = FontWeight.Bold
                        )
                    }
                    Spacer(modifier = Modifier.width(10.dp))
                    Column(modifier = Modifier.weight(1f)) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(
                                identity.displayName,
                                fontSize = 13.sp,
                                fontWeight = FontWeight.SemiBold,
                                color = MaterialTheme.colorScheme.onSurface
                            )
                            Spacer(modifier = Modifier.width(6.dp))
                            Surface(
                                shape = RoundedCornerShape(50),
                                color = hexColor(identity.paletteHex).copy(alpha = 0.18f)
                            ) {
                                Text(
                                    identity.tier.displayLabel,
                                    color = hexColor(identity.paletteHex),
                                    fontSize = 9.sp,
                                    fontWeight = FontWeight.Bold,
                                    modifier = Modifier.padding(horizontal = 6.dp, vertical = 1.dp)
                                )
                            }
                        }
                        identity.tagline?.let {
                            Text(
                                it,
                                fontSize = 11.sp,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                maxLines = 2,
                                overflow = TextOverflow.Ellipsis
                            )
                        }
                    }
                    val isPinned = pinned.pinnedURIs.contains(identity.id)
                    IconButton(onClick = {
                        if (isPinned) onUnpin(identity.id) else onPin(identity.id)
                    }) {
                        Icon(
                            imageVector = if (isPinned) Icons.Filled.PushPin else Icons.Outlined.PushPin,
                            contentDescription = if (isPinned) "Unpin" else "Pin",
                            tint = if (isPinned) MaterialTheme.colorScheme.primary
                            else MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.size(18.dp)
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun CapabilitiesList(registry: AgentIdentityRegistry) {
    val all = listOf(
        AgentCapabilities.TOOL_USE,
        AgentCapabilities.VISION,
        AgentCapabilities.AUDIO,
        AgentCapabilities.AGENT_LOOPS,
        AgentCapabilities.FILE_EDITS,
        AgentCapabilities.SHELL,
        AgentCapabilities.WEB_BROWSE,
        AgentCapabilities.CODE_EXECUTION,
        AgentCapabilities.IMAGE_GEN,
        AgentCapabilities.MEMORY,
        AgentCapabilities.STREAMING_DIFF,
        AgentCapabilities.MCP_UI
    )
    LazyColumn(
        verticalArrangement = Arrangement.spacedBy(8.dp),
        modifier = Modifier.padding(horizontal = 16.dp)
    ) {
        items(all) { cap ->
            val owners = registry.identities.filter { it.capabilities.contains(cap) }
            Surface(
                shape = RoundedCornerShape(10.dp),
                color = MaterialTheme.colorScheme.surface.copy(alpha = 0.5f),
                modifier = Modifier.fillMaxWidth()
            ) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 12.dp, vertical = 10.dp)
                ) {
                    Text(
                        cap.displayPills.firstOrNull() ?: "Capability",
                        fontSize = 13.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = MaterialTheme.colorScheme.onSurface
                    )
                    Spacer(modifier = Modifier.weight(1f))
                    Text(
                        "${owners.size} agents",
                        fontSize = 11.sp,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            }
        }
    }
}

@Composable
private fun MarketplacePlaceholder() {
    Column(
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 32.dp, vertical = 28.dp)
    ) {
        Text(
            "Marketplace",
            fontSize = 18.sp,
            fontWeight = FontWeight.Bold,
            color = MaterialTheme.colorScheme.onSurface
        )
        Spacer(modifier = Modifier.height(8.dp))
        Text(
            "Install third-party agents from a manifest URL or QR code. Coming in Phase C — first-party only at GA.",
            fontSize = 13.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun HermesSquareSubscriptionsSheet(onDismiss: () -> Unit) {
    val state = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val context = androidx.compose.ui.platform.LocalContext.current
    val store = remember(context) { com.openburnbar.data.square.AgentSubscriptionTopicStore.shared(context) }
    val topics by store.topics.collectAsStateWithLifecycle()
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = state,
        containerColor = MaterialTheme.colorScheme.surface
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 20.dp, vertical = 18.dp)
        ) {
            Text(
                "Subscriptions",
                fontSize = 18.sp,
                fontWeight = FontWeight.Bold,
                color = MaterialTheme.colorScheme.onSurface
            )
            Spacer(modifier = Modifier.height(8.dp))
            Text(
                "Subscription-tier agents broadcast on a schedule.",
                fontSize = 12.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            Spacer(modifier = Modifier.height(14.dp))
            if (topics.isEmpty()) {
                Text(
                    "Nothing subscribed yet. Open an agent in Discover to subscribe to its updates.",
                    fontSize = 12.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
                Spacer(modifier = Modifier.height(6.dp))
                Text(
                    "Platform-enforced cap: ${AgentTier.SUBSCRIPTION_MONTHLY_BUDGET} deliveries / agent / month by default.",
                    fontSize = 11.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            } else {
                LazyColumn(
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                    modifier = Modifier.fillMaxWidth().height(360.dp)
                ) {
                    items(topics, key = { it.agentURI }) { topic ->
                        Surface(
                            shape = RoundedCornerShape(10.dp),
                            color = MaterialTheme.colorScheme.surface.copy(alpha = 0.55f),
                            modifier = Modifier.fillMaxWidth()
                        ) {
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                modifier = Modifier.padding(horizontal = 12.dp, vertical = 10.dp)
                            ) {
                                Column(modifier = Modifier.weight(1f)) {
                                    Text(
                                        topic.displayName.ifBlank { topic.agentURI },
                                        fontSize = 13.sp,
                                        fontWeight = FontWeight.SemiBold,
                                        color = MaterialTheme.colorScheme.onSurface,
                                        maxLines = 1,
                                        overflow = TextOverflow.Ellipsis
                                    )
                                    Text(
                                        "${topic.cadence.displayLabel}${if (topic.muted) " · muted" else ""}",
                                        fontSize = 11.sp,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant
                                    )
                                }
                                Surface(
                                    shape = RoundedCornerShape(999.dp),
                                    color = MaterialTheme.colorScheme.error.copy(alpha = 0.14f),
                                    modifier = Modifier
                                        .clip(RoundedCornerShape(999.dp))
                                        .clickable { store.unsubscribe(topic.agentURI) }
                                ) {
                                    Text(
                                        "Unsubscribe",
                                        fontSize = 10.sp,
                                        fontWeight = FontWeight.Bold,
                                        color = MaterialTheme.colorScheme.error,
                                        modifier = Modifier.padding(horizontal = 10.dp, vertical = 4.dp)
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun HermesSquareBrandZoneSheet(
    identity: AgentIdentity,
    onDismiss: () -> Unit
) {
    val state = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val accent = hexColor(identity.paletteHex)
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
            // Hero
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(
                    contentAlignment = Alignment.Center,
                    modifier = Modifier
                        .size(60.dp)
                        .clip(RoundedCornerShape(50))
                        .background(accent)
                ) {
                    Text(
                        identity.glyph,
                        color = Color.White,
                        fontSize = 28.sp,
                        fontWeight = FontWeight.Bold
                    )
                }
                Spacer(modifier = Modifier.width(14.dp))
                Column {
                    Text(
                        identity.displayName,
                        fontSize = 18.sp,
                        fontWeight = FontWeight.Bold,
                        color = MaterialTheme.colorScheme.onSurface
                    )
                    Text(
                        "${identity.tier.displayLabel} • ${identity.availability.displayLabel}",
                        fontSize = 11.sp,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    identity.tagline?.let {
                        Text(
                            it,
                            fontSize = 12.sp,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }
            }

            Spacer(modifier = Modifier.height(16.dp))

            // Capability pills
            Text(
                "Capabilities",
                fontSize = 11.sp,
                fontWeight = FontWeight.Bold,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            Spacer(modifier = Modifier.height(6.dp))
            val pills = identity.capabilities.displayPills
            if (pills.isEmpty()) {
                Text(
                    "No declared capabilities yet.",
                    fontSize = 12.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            } else {
                // Simple inline pill row — wraps via FlowRow alternative
                // built from rows of 3.
                pills.chunked(3).forEach { row ->
                    Row(
                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                        modifier = Modifier.padding(bottom = 6.dp)
                    ) {
                        row.forEach { pill ->
                            Surface(
                                shape = RoundedCornerShape(50),
                                color = accent.copy(alpha = 0.14f)
                            ) {
                                Text(
                                    pill,
                                    color = accent,
                                    fontSize = 10.sp,
                                    fontWeight = FontWeight.Bold,
                                    modifier = Modifier.padding(horizontal = 8.dp, vertical = 3.dp)
                                )
                            }
                        }
                    }
                }
            }

            Spacer(modifier = Modifier.height(12.dp))

            // About rows
            Text(
                "About",
                fontSize = 11.sp,
                fontWeight = FontWeight.Bold,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            Spacer(modifier = Modifier.height(6.dp))
            BrandZoneRow("URI", identity.id)
            BrandZoneRow("Install", identity.installSource.displayLabel)
            BrandZoneRow("Transport", identity.dispatchTransport.displayLabel)
        }
    }
}

@Composable
private fun BrandZoneRow(label: String, value: String) {
    Row(modifier = Modifier.padding(vertical = 2.dp)) {
        Text(
            label,
            fontSize = 11.sp,
            fontWeight = FontWeight.Bold,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.width(96.dp)
        )
        Text(
            value,
            fontSize = 11.sp,
            color = MaterialTheme.colorScheme.onSurface
        )
    }
}
