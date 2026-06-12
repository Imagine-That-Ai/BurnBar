// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.square

import androidx.compose.foundation.background
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
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.PushPin
import androidx.compose.material.icons.outlined.PushPin
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.models.ProjectSummary
import com.openburnbar.data.square.AgentCapabilities
import com.openburnbar.data.square.AgentIdentity
import com.openburnbar.data.square.AgentIdentityRegistry
import com.openburnbar.data.square.AgentSubscriptionTopic
import com.openburnbar.data.square.AgentSubscriptionTopicStore
import com.openburnbar.data.square.AgentSubscriptionUnsubscribeResult
import com.openburnbar.data.square.AgentTier
import com.openburnbar.data.square.PinnedAgentGridConfig
import kotlinx.coroutines.launch

@Composable
internal fun RecentList(recent: List<AgentIdentity>) {
    if (recent.isEmpty()) {
        RecentListEmptyState()
        return
    }
    LazyColumn(
        verticalArrangement = Arrangement.spacedBy(8.dp),
        modifier = Modifier.padding(horizontal = 16.dp),
    ) {
        items(recent, key = { it.id }) { identity ->
            RecentAgentRow(identity = identity)
        }
    }
}

@Composable
internal fun RecentListEmptyState() {
    Column(
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier = Modifier.fillMaxWidth().padding(horizontal = 32.dp, vertical = 28.dp),
    ) {
        Text(
            "No recent activity yet.",
            fontSize = 13.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
internal fun RecentAgentRow(identity: AgentIdentity) {
    Surface(
        shape = RoundedCornerShape(10.dp),
        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.55f),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 10.dp),
        ) {
            AgentGlyphAvatar(identity = identity, size = 28.dp, glyphFontSize = 14.sp)
            Spacer(modifier = Modifier.width(10.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    identity.displayName,
                    fontSize = 13.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = MaterialTheme.colorScheme.onSurface,
                )
                identity.tagline?.let {
                    Text(
                        it,
                        fontSize = 11.sp,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
        }
    }
}

@Composable
internal fun ProjectMemoryList(
    projects: List<ProjectSummary>,
    onOpenProject: (ProjectSummary) -> Unit,
    onAskWiki: (ProjectSummary) -> Unit,
) {
    if (projects.isEmpty()) {
        ProjectMemoryEmptyState()
        return
    }
    LazyColumn(
        verticalArrangement = Arrangement.spacedBy(8.dp),
        modifier = Modifier.padding(horizontal = 16.dp),
    ) {
        items(projects, key = { it.id }) { project ->
            ProjectMemoryCard(
                project = project,
                onOpenProject = onOpenProject,
                onAskWiki = onAskWiki,
            )
        }
    }
}

@Composable
internal fun ProjectMemoryEmptyState() {
    Column(
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier = Modifier.fillMaxWidth().padding(horizontal = 32.dp, vertical = 28.dp),
    ) {
        Text(
            "Project Memory",
            fontSize = 16.sp,
            fontWeight = FontWeight.Bold,
            color = MaterialTheme.colorScheme.onSurface,
        )
        Spacer(modifier = Modifier.height(6.dp))
        Text(
            "No project memory available yet. Start with /wiki in Hermes to build one.",
            fontSize = 12.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
internal fun ProjectMemoryCard(
    project: ProjectSummary,
    onOpenProject: (ProjectSummary) -> Unit,
    onAskWiki: (ProjectSummary) -> Unit,
) {
    Surface(
        shape = RoundedCornerShape(10.dp),
        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.6f),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(
            verticalArrangement = Arrangement.spacedBy(6.dp),
            modifier = Modifier.padding(12.dp),
        ) {
            Text(
                project.name.ifBlank { project.id },
                fontSize = 14.sp,
                fontWeight = FontWeight.Bold,
                color = MaterialTheme.colorScheme.onSurface,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                "${project.totalSessions} sessions · ${project.totalTokens} tokens · $${
                    "%.2f".format(project.totalCost)
                }",
                fontSize = 11.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                ProjectActionPill(
                    label = "Open",
                    fillColor = MaterialTheme.colorScheme.surface.copy(alpha = 0.8f),
                    textColor = MaterialTheme.colorScheme.onSurface,
                    onClick = { onOpenProject(project) },
                )
                ProjectActionPill(
                    label = "Ask /wiki",
                    fillColor = MaterialTheme.colorScheme.primary.copy(alpha = 0.15f),
                    textColor = MaterialTheme.colorScheme.primary,
                    onClick = { onAskWiki(project) },
                )
            }
        }
    }
}

@Composable
internal fun ProjectActionPill(
    label: String,
    fillColor: Color,
    textColor: Color,
    onClick: () -> Unit,
) {
    Surface(
        shape = RoundedCornerShape(999.dp),
        color = fillColor,
        modifier =
        Modifier
            .clip(RoundedCornerShape(999.dp))
            .clickable(onClick = onClick),
    ) {
        Text(
            label,
            fontSize = 11.sp,
            fontWeight = FontWeight.Bold,
            color = textColor,
            modifier = Modifier.padding(horizontal = 10.dp, vertical = 5.dp),
        )
    }
}

@Composable
internal fun AgentsList(
    registry: AgentIdentityRegistry,
    pinned: PinnedAgentGridConfig,
    onPin: (String) -> Unit,
    onUnpin: (String) -> Unit,
) {
    LazyColumn(
        verticalArrangement = Arrangement.spacedBy(8.dp),
        modifier = Modifier.padding(horizontal = 16.dp),
    ) {
        items(registry.identities, key = { it.id }) { identity ->
            AgentListRow(
                identity = identity,
                isPinned = pinned.pinnedURIs.contains(identity.id),
                onPinToggle = {
                    if (pinned.pinnedURIs.contains(identity.id)) {
                        onUnpin(identity.id)
                    } else {
                        onPin(identity.id)
                    }
                },
            )
        }
    }
}

@Composable
internal fun AgentListRow(
    identity: AgentIdentity,
    isPinned: Boolean,
    onPinToggle: () -> Unit,
) {
    Surface(
        shape = RoundedCornerShape(10.dp),
        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.6f),
        tonalElevation = 0.5.dp,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier =
            Modifier
                .fillMaxWidth()
                .padding(horizontal = 12.dp, vertical = 10.dp),
        ) {
            AgentGlyphAvatar(identity = identity, size = 30.dp, glyphFontSize = 14.sp)
            Spacer(modifier = Modifier.width(10.dp))
            AgentListRowDetails(identity = identity, modifier = Modifier.weight(1f))
            AgentPinToggleButton(isPinned = isPinned, onPinToggle = onPinToggle)
        }
    }
}

@Composable
internal fun AgentListRowDetails(identity: AgentIdentity, modifier: Modifier = Modifier) {
    val accent = hexColor(identity.paletteHex)
    Column(modifier = modifier) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                identity.displayName,
                fontSize = 13.sp,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurface,
            )
            Spacer(modifier = Modifier.width(6.dp))
            AgentTierBadge(label = identity.tier.displayLabel, accent = accent)
        }
        identity.tagline?.let {
            Text(
                it,
                fontSize = 11.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

@Composable
internal fun AgentTierBadge(label: String, accent: Color) {
    Surface(
        shape = RoundedCornerShape(50),
        color = accent.copy(alpha = 0.18f),
    ) {
        Text(
            label,
            color = accent,
            fontSize = 9.sp,
            fontWeight = FontWeight.Bold,
            modifier = Modifier.padding(horizontal = 6.dp, vertical = 1.dp),
        )
    }
}

@Composable
internal fun AgentPinToggleButton(isPinned: Boolean, onPinToggle: () -> Unit) {
    IconButton(onClick = onPinToggle) {
        Icon(
            imageVector = if (isPinned) Icons.Filled.PushPin else Icons.Outlined.PushPin,
            contentDescription = if (isPinned) "Unpin" else "Pin",
            tint =
            if (isPinned) {
                MaterialTheme.colorScheme.primary
            } else {
                MaterialTheme.colorScheme.onSurfaceVariant
            },
            modifier = Modifier.size(18.dp),
        )
    }
}

@Composable
internal fun AgentGlyphAvatar(
    identity: AgentIdentity,
    size: Dp,
    glyphFontSize: TextUnit,
) {
    Box(
        contentAlignment = Alignment.Center,
        modifier =
        Modifier
            .size(size)
            .clip(RoundedCornerShape(50))
            .background(hexColor(identity.paletteHex)),
    ) {
        Text(
            identity.glyph,
            color = Color.White,
            fontSize = glyphFontSize,
            fontWeight = FontWeight.Bold,
        )
    }
}

@Composable
internal fun CapabilitiesList(registry: AgentIdentityRegistry) {
    val all =
        listOf(
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
            AgentCapabilities.MCP_UI,
        )
    LazyColumn(
        verticalArrangement = Arrangement.spacedBy(8.dp),
        modifier = Modifier.padding(horizontal = 16.dp),
    ) {
        items(all) { cap ->
            CapabilityRow(
                label = cap.displayPills.firstOrNull() ?: "Capability",
                ownerCount = registry.identities.count { it.capabilities.contains(cap) },
            )
        }
    }
}

@Composable
internal fun CapabilityRow(label: String, ownerCount: Int) {
    Surface(
        shape = RoundedCornerShape(10.dp),
        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.5f),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier =
            Modifier
                .fillMaxWidth()
                .padding(horizontal = 12.dp, vertical = 10.dp),
        ) {
            Text(
                label,
                fontSize = 13.sp,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurface,
            )
            Spacer(modifier = Modifier.weight(1f))
            Text(
                "$ownerCount agents",
                fontSize = 11.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
internal fun MarketplacePlaceholder() {
    Column(
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier =
        Modifier
            .fillMaxWidth()
            .padding(horizontal = 32.dp, vertical = 28.dp),
    ) {
        Text(
            "Marketplace",
            fontSize = 18.sp,
            fontWeight = FontWeight.Bold,
            color = MaterialTheme.colorScheme.onSurface,
        )
        Spacer(modifier = Modifier.height(8.dp))
        Text(
            "Install third-party agents from a manifest URL or QR code. Coming in Phase C — first-party only at GA.",
            fontSize = 13.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
internal fun SubscriptionsSheetContent(
    topics: List<AgentSubscriptionTopic>,
    store: AgentSubscriptionTopicStore,
) {
    val coroutineScope = rememberCoroutineScope()
    var unsubscribeNotice by remember { mutableStateOf<String?>(null) }
    Column(
        modifier =
        Modifier
            .fillMaxWidth()
            .padding(horizontal = 20.dp, vertical = 18.dp),
    ) {
        Text(
            "Subscriptions",
            fontSize = 18.sp,
            fontWeight = FontWeight.Bold,
            color = MaterialTheme.colorScheme.onSurface,
        )
        Spacer(modifier = Modifier.height(8.dp))
        Text(
            "Subscription-tier agents broadcast on a schedule.",
            fontSize = 12.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        unsubscribeNotice?.let { notice ->
            Spacer(modifier = Modifier.height(8.dp))
            Text(
                notice,
                fontSize = 12.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        Spacer(modifier = Modifier.height(14.dp))
        if (topics.isEmpty()) {
            SubscriptionsEmptyState()
        } else {
            SubscriptionsTopicList(
                topics = topics,
                onUnsubscribe = { agentURI ->
                    unsubscribeNotice = "Removing subscription..."
                    coroutineScope.launch {
                        val message =
                            runCatching {
                                when (store.unsubscribe(agentURI)) {
                                    AgentSubscriptionUnsubscribeResult.REMOVED -> "Subscription removed."
                                    AgentSubscriptionUnsubscribeResult.LOCAL_ONLY_REMOVED -> "Local subscription removed."
                                    AgentSubscriptionUnsubscribeResult.MISSING_CLOUD_KEY ->
                                        "Connect this device to private cloud backup, then try again."
                                }
                            }.getOrElse {
                                "Could not remove subscription. Try again."
                            }
                        unsubscribeNotice = message
                    }
                },
            )
        }
    }
}

@Composable
internal fun SubscriptionsEmptyState() {
    Text(
        "Nothing subscribed yet. Open an agent in Discover to subscribe to its updates.",
        fontSize = 12.sp,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
    )
    Spacer(modifier = Modifier.height(6.dp))
    Text(
        "Platform-enforced cap: ${AgentTier.SUBSCRIPTION_MONTHLY_BUDGET} deliveries / agent / month by default.",
        fontSize = 11.sp,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
    )
}

@Composable
internal fun SubscriptionsTopicList(
    topics: List<AgentSubscriptionTopic>,
    onUnsubscribe: (String) -> Unit,
) {
    LazyColumn(
        verticalArrangement = Arrangement.spacedBy(8.dp),
        modifier = Modifier.fillMaxWidth().height(360.dp),
    ) {
        items(topics, key = { it.agentURI }) { topic ->
            SubscriptionTopicRow(
                topic = topic,
                onUnsubscribe = { onUnsubscribe(topic.agentURI) },
            )
        }
    }
}

@Composable
internal fun SubscriptionTopicRow(
    topic: AgentSubscriptionTopic,
    onUnsubscribe: () -> Unit,
) {
    Surface(
        shape = RoundedCornerShape(10.dp),
        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.55f),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 10.dp),
        ) {
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    topic.displayName.ifBlank { topic.agentURI },
                    fontSize = 13.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = MaterialTheme.colorScheme.onSurface,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    "${topic.cadence.displayLabel} · ${topic.deliveryMode.displayLabel.lowercase()}${if (topic.muted) " · muted" else ""}",
                    fontSize = 11.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            Surface(
                shape = RoundedCornerShape(999.dp),
                color = MaterialTheme.colorScheme.error.copy(alpha = 0.14f),
                modifier =
                Modifier
                    .clip(RoundedCornerShape(999.dp))
                    .clickable(onClick = onUnsubscribe),
            ) {
                Text(
                    "Unsubscribe",
                    fontSize = 10.sp,
                    fontWeight = FontWeight.Bold,
                    color = MaterialTheme.colorScheme.error,
                    modifier = Modifier.padding(horizontal = 10.dp, vertical = 4.dp),
                )
            }
        }
    }
}

@Composable
internal fun BrandZoneSheetContent(identity: AgentIdentity) {
    val accent = hexColor(identity.paletteHex)
    Column(
        modifier =
        Modifier
            .fillMaxWidth()
            .padding(horizontal = 20.dp, vertical = 16.dp),
    ) {
        BrandZoneHero(identity = identity, accent = accent)
        Spacer(modifier = Modifier.height(16.dp))
        BrandZoneCapabilitiesSection(identity = identity, accent = accent)
        Spacer(modifier = Modifier.height(12.dp))
        BrandZoneAboutSection(identity = identity)
    }
}

@Composable
internal fun BrandZoneHero(identity: AgentIdentity, accent: Color) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Box(
            contentAlignment = Alignment.Center,
            modifier =
            Modifier
                .size(60.dp)
                .clip(RoundedCornerShape(50))
                .background(accent),
        ) {
            Text(
                identity.glyph,
                color = Color.White,
                fontSize = 28.sp,
                fontWeight = FontWeight.Bold,
            )
        }
        Spacer(modifier = Modifier.width(14.dp))
        Column {
            Text(
                identity.displayName,
                fontSize = 18.sp,
                fontWeight = FontWeight.Bold,
                color = MaterialTheme.colorScheme.onSurface,
            )
            Text(
                "${identity.tier.displayLabel} • ${identity.availability.displayLabel}",
                fontSize = 11.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            identity.tagline?.let {
                Text(
                    it,
                    fontSize = 12.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

@Composable
internal fun BrandZoneCapabilitiesSection(identity: AgentIdentity, accent: Color) {
    Text(
        "Capabilities",
        fontSize = 11.sp,
        fontWeight = FontWeight.Bold,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
    )
    Spacer(modifier = Modifier.height(6.dp))
    val pills = identity.capabilities.displayPills
    if (pills.isEmpty()) {
        Text(
            "No declared capabilities yet.",
            fontSize = 12.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    } else {
        BrandZoneCapabilityPills(pills = pills, accent = accent)
    }
}

@Composable
internal fun BrandZoneCapabilityPills(pills: List<String>, accent: Color) {
    pills.chunked(3).forEach { row ->
        Row(
            horizontalArrangement = Arrangement.spacedBy(6.dp),
            modifier = Modifier.padding(bottom = 6.dp),
        ) {
            row.forEach { pill ->
                Surface(
                    shape = RoundedCornerShape(50),
                    color = accent.copy(alpha = 0.14f),
                ) {
                    Text(
                        pill,
                        color = accent,
                        fontSize = 10.sp,
                        fontWeight = FontWeight.Bold,
                        modifier = Modifier.padding(horizontal = 8.dp, vertical = 3.dp),
                    )
                }
            }
        }
    }
}

@Composable
internal fun BrandZoneAboutSection(identity: AgentIdentity) {
    Text(
        "About",
        fontSize = 11.sp,
        fontWeight = FontWeight.Bold,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
    )
    Spacer(modifier = Modifier.height(6.dp))
    BrandZoneRow("URI", identity.id)
    BrandZoneRow("Install", identity.installSource.displayLabel)
    BrandZoneRow("Transport", identity.dispatchTransport.displayLabel)
}

@Composable
internal fun BrandZoneRow(label: String, value: String) {
    Row(modifier = Modifier.padding(vertical = 2.dp)) {
        Text(
            label,
            fontSize = 11.sp,
            fontWeight = FontWeight.Bold,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.width(96.dp),
        )
        Text(
            value,
            fontSize = 11.sp,
            color = MaterialTheme.colorScheme.onSurface,
        )
    }
}
