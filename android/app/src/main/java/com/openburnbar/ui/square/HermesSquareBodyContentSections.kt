// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.square

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Inbox
import androidx.compose.material.icons.filled.PushPin
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material.icons.outlined.PushPin
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.missions.ActiveMission
import com.openburnbar.data.missions.RollbackScope
import com.openburnbar.data.missions.RollbackSnapshot
import com.openburnbar.data.models.ProjectSummary
import com.openburnbar.data.square.AgentIdentityRegistry
import com.openburnbar.data.square.ThreadInboxItem
import com.openburnbar.ui.theme.AuroraColors

// MARK: - Active missions strip (Phase A placeholder)

@Composable
internal fun ActiveMissionsStrip(
    missions: List<com.openburnbar.data.missions.ActiveMission>,
    onLongPress: (com.openburnbar.data.missions.ActiveMission) -> Unit,
    onComposeMission: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(modifier = modifier.fillMaxWidth()) {
        ActiveMissionsStripHeader(onComposeMission = onComposeMission)
        Spacer(modifier = Modifier.height(8.dp))
        if (missions.isEmpty()) {
            ActiveMissionsEmptyCard(onComposeMission = onComposeMission)
        } else {
            ActiveMissionsRow(missions = missions, onLongPress = onLongPress)
        }
    }
}

@Composable
private fun ActiveMissionsStripHeader(onComposeMission: () -> Unit) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth().padding(end = 16.dp),
    ) {
        Text(
            "Active missions",
            fontSize = 11.sp,
            fontWeight = FontWeight.Bold,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(modifier = Modifier.weight(1f))
        TextButton(
            onClick = onComposeMission,
            contentPadding = PaddingValues(horizontal = 4.dp, vertical = 2.dp),
            modifier = Modifier.height(24.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    imageVector = Icons.Filled.Add,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.size(10.dp),
                )
                Spacer(modifier = Modifier.width(3.dp))
                Text(
                    "Compose",
                    fontSize = 10.sp,
                    fontWeight = FontWeight.Bold,
                    color = MaterialTheme.colorScheme.primary,
                )
            }
        }
    }
}

@Composable
private fun ActiveMissionsEmptyCard(onComposeMission: () -> Unit) {
    Surface(
        shape = RoundedCornerShape(12.dp),
        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.6f),
        tonalElevation = 0.5.dp,
        modifier =
        Modifier
            .width(280.dp)
            .height(110.dp)
            .clickable { onComposeMission() },
    ) {
        Column(
            verticalArrangement = Arrangement.Center,
            horizontalAlignment = Alignment.Start,
            modifier =
            Modifier
                .fillMaxSize()
                .padding(14.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    imageVector = Icons.Filled.Bolt,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.size(14.dp),
                )
                Spacer(modifier = Modifier.width(6.dp))
                Text(
                    "No live missions",
                    color = MaterialTheme.colorScheme.onSurface,
                    fontSize = 13.sp,
                    fontWeight = FontWeight.SemiBold,
                )
            }
            Spacer(modifier = Modifier.height(6.dp))
            Text(
                "No live missions. Tap here to compose one.",
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                fontSize = 11.sp,
                maxLines = 3,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

@Composable
private fun ActiveMissionsRow(
    missions: List<com.openburnbar.data.missions.ActiveMission>,
    onLongPress: (com.openburnbar.data.missions.ActiveMission) -> Unit,
) {
    LazyRow(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        items(missions, key = { it.id }) { mission ->
            HermesSquareMissionTile(
                tile = mission,
                onLongPress = { onLongPress(mission) },
                modifier = Modifier.width(260.dp),
            )
        }
        item { Spacer(modifier = Modifier.width(0.dp)) }
    }
}

// MARK: - Project Memory Wiki

@Composable
internal fun ProjectMemoryWikiSection(
    projects: List<com.openburnbar.data.models.ProjectSummary>,
    onOpenProject: (com.openburnbar.data.models.ProjectSummary) -> Unit,
    onAskWiki: (com.openburnbar.data.models.ProjectSummary) -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(modifier = modifier.fillMaxWidth()) {
        ProjectMemoryWikiHeader()
        Spacer(modifier = Modifier.height(8.dp))
        if (projects.isEmpty()) {
            Text(
                "No project memory yet. Start with `/wiki` in Hermes to build one.",
                fontSize = 11.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(vertical = 6.dp),
            )
        } else {
            projects.forEach { project ->
                ProjectMemoryWikiRow(
                    project = project,
                    onOpenProject = onOpenProject,
                    onAskWiki = onAskWiki,
                )
            }
        }
    }
}

@Composable
private fun ProjectMemoryWikiHeader() {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(
            "Project Memory Wiki",
            fontSize = 11.sp,
            fontWeight = FontWeight.Bold,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(modifier = Modifier.weight(1f))
        Text(
            "Ask /wiki",
            fontSize = 11.sp,
            fontWeight = FontWeight.Bold,
            color = MaterialTheme.colorScheme.primary,
        )
    }
}

@Composable
private fun ProjectMemoryWikiRow(
    project: com.openburnbar.data.models.ProjectSummary,
    onOpenProject: (com.openburnbar.data.models.ProjectSummary) -> Unit,
    onAskWiki: (com.openburnbar.data.models.ProjectSummary) -> Unit,
) {
    Surface(
        shape = RoundedCornerShape(10.dp),
        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.5f),
        modifier =
        Modifier
            .fillMaxWidth()
            .padding(bottom = 6.dp)
            .clickable { onOpenProject(project) },
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 10.dp),
        ) {
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    project.name.ifBlank { project.id },
                    fontSize = 13.sp,
                    fontWeight = FontWeight.Bold,
                    color = MaterialTheme.colorScheme.onSurface,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    "${project.totalSessions} sessions · ${project.totalTokens} tokens · $${"%.2f".format(project.totalCost)}",
                    fontSize = 10.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            Surface(
                shape = RoundedCornerShape(999.dp),
                color = MaterialTheme.colorScheme.primary.copy(alpha = 0.15f),
                modifier =
                Modifier
                    .clip(RoundedCornerShape(999.dp))
                    .clickable { onAskWiki(project) },
            ) {
                Text(
                    "/wiki",
                    fontSize = 11.sp,
                    fontWeight = FontWeight.Bold,
                    color = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.padding(horizontal = 10.dp, vertical = 5.dp),
                )
            }
        }
    }
}

// MARK: - Rollback sections list

@Composable
internal fun RollbackSectionsList(
    snapshotsBySession: Map<String, List<com.openburnbar.data.missions.RollbackSnapshot>>,
    onSubmit: (sessionID: String, scope: com.openburnbar.data.missions.RollbackScope) -> Unit,
    modifier: Modifier = Modifier,
) {
    val sortedSessions =
        remember(snapshotsBySession) {
            snapshotsBySession
                .filter { it.value.isNotEmpty() }
                .toList()
                .sortedByDescending { (_, list) -> list.maxOfOrNull { it.takenAtEpoch } ?: 0L }
        }
    Column(modifier = modifier.fillMaxWidth()) {
        Text(
            "Rollback",
            fontSize = 11.sp,
            fontWeight = FontWeight.Bold,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(modifier = Modifier.height(8.dp))
        for ((sessionID, snapshots) in sortedSessions) {
            RollbackCardView(
                sessionID = sessionID,
                snapshots = snapshots,
                onSubmit = { scope -> onSubmit(sessionID, scope) },
                modifier = Modifier.padding(bottom = 8.dp),
            )
        }
    }
}

// MARK: - Sections + rows

@Composable
internal fun SectionHeader(label: String, isLoading: Boolean, modifier: Modifier = Modifier) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = modifier.fillMaxWidth(),
    ) {
        Text(
            label,
            fontSize = 11.sp,
            fontWeight = FontWeight.Bold,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(modifier = Modifier.weight(1f))
        if (isLoading) {
            CircularProgressIndicator(
                strokeWidth = 1.dp,
                modifier = Modifier.size(12.dp),
            )
        }
    }
}

@Composable
internal fun EmptyConversationsCard(modifier: Modifier = Modifier) {
    Surface(
        shape = RoundedCornerShape(10.dp),
        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.4f),
        modifier = modifier.fillMaxWidth(),
    ) {
        Column(
            verticalArrangement = Arrangement.Center,
            horizontalAlignment = Alignment.CenterHorizontally,
            modifier =
            Modifier
                .fillMaxWidth()
                .padding(vertical = 22.dp, horizontal = 16.dp),
        ) {
            Icon(
                imageVector = Icons.Filled.Inbox,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.size(28.dp),
            )
            Spacer(modifier = Modifier.height(8.dp))
            Text(
                "No conversations yet",
                fontSize = 13.sp,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurface,
            )
            Text(
                "Pick an agent above to begin.",
                fontSize = 11.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
internal fun ThreadInboxRow(item: ThreadInboxItem, registry: AgentIdentityRegistry, onTap: () -> Unit, onLongPress: () -> Unit, modifier: Modifier = Modifier) {
    Surface(
        shape = RoundedCornerShape(10.dp),
        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.5f),
        tonalElevation = 0.5.dp,
        modifier =
        modifier
            .fillMaxWidth()
            .clickableLongPress(onClick = onTap, onLongClick = onLongPress),
    ) {
        Row(
            modifier =
            Modifier
                .fillMaxWidth()
                .height(IntrinsicSize.Min),
        ) {
            ThreadInboxAccentBar(labelColorHex = item.labelColorHex)
            ThreadInboxRowMain(
                modifier = Modifier.weight(1f),
                item = item,
                registry = registry,
            )
        }
    }
}

@Composable
private fun ThreadInboxAccentBar(labelColorHex: String?) {
    val colorHex = labelColorHex
    if (colorHex.isNullOrBlank()) return
    val parsedColor =
        remember(colorHex) {
            try {
                hexColor(colorHex)
            } catch (_: IllegalStateException) {
                Color.Transparent
            }
        }
    if (parsedColor == Color.Transparent) return
    Box(
        modifier =
        Modifier
            .fillMaxHeight()
            .width(4.dp)
            .background(parsedColor),
    )
}

@Composable
private fun ThreadInboxRowMain(
    modifier: Modifier,
    item: ThreadInboxItem,
    registry: AgentIdentityRegistry,
) {
    val identity = registry.identity(item.agentURI)
    Row(
        verticalAlignment = Alignment.Top,
        modifier = modifier.padding(horizontal = 12.dp, vertical = 10.dp),
    ) {
        if (identity != null) {
            com.openburnbar.ui.components.BurnBarAgentAvatar(
                identity = identity,
                size = 36.dp,
            )
        } else {
            com.openburnbar.ui.components.ProviderLogoView(
                drawableRes =
                com.openburnbar.ui.components.ProviderLogo.drawableForAnyIdentifier(
                    item.agentURI,
                ),
                size = 36.dp,
                style = com.openburnbar.ui.components.ProviderLogoStyle.Disc,
            )
        }
        Spacer(modifier = Modifier.width(10.dp))
        ThreadInboxRowTextColumn(
            modifier = Modifier.weight(1f),
            item = item,
            identityName = identity?.displayName,
        )
    }
}

@Composable
private fun ThreadInboxRowTextColumn(modifier: Modifier, item: ThreadInboxItem, identityName: String?) {
    Column(modifier = modifier) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                identityName ?: "Agent",
                fontSize = 11.sp,
                fontWeight = FontWeight.Bold,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            if (item.isPinned) {
                Spacer(modifier = Modifier.width(4.dp))
                Icon(
                    imageVector = Icons.Filled.PushPin,
                    contentDescription = "Pinned",
                    tint = AuroraColors.ember,
                    modifier = Modifier.size(10.dp),
                )
            }
            Spacer(modifier = Modifier.weight(1f))
            Text(
                relativeTime(item.lastActivityAtEpoch),
                fontSize = 10.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        Text(
            item.customTitle ?: item.title,
            fontSize = 13.sp,
            fontWeight = FontWeight.SemiBold,
            color = MaterialTheme.colorScheme.onSurface,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        Text(
            item.preview,
            fontSize = 11.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )
        if (item.needsAttention) {
            Spacer(modifier = Modifier.height(2.dp))
            Text(
                "Needs attention",
                color = MaterialTheme.colorScheme.tertiary,
                fontSize = 10.sp,
                fontWeight = FontWeight.Bold,
            )
        }
    }
}

@Composable
internal fun SubscriptionsEntry(count: Int, onTap: () -> Unit, modifier: Modifier = Modifier) {
    Surface(
        shape = RoundedCornerShape(10.dp),
        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.6f),
        modifier =
        modifier
            .fillMaxWidth()
            .clickableUnit(onClick = onTap),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier =
            Modifier
                .fillMaxWidth()
                .padding(horizontal = 14.dp, vertical = 12.dp),
        ) {
            Icon(
                imageVector = Icons.Filled.Inbox,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.size(18.dp),
            )
            Spacer(modifier = Modifier.width(10.dp))
            Text(
                "Subscriptions",
                fontSize = 13.sp,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurface,
            )
            Spacer(modifier = Modifier.weight(1f))
            Text(
                "$count",
                fontSize = 12.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Spacer(modifier = Modifier.width(6.dp))
            Icon(
                imageVector = Icons.Filled.ChevronRight,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.size(14.dp),
            )
        }
    }
}

@Composable
internal fun DiscoverEntry(onTap: () -> Unit, modifier: Modifier = Modifier) {
    Surface(
        shape = RoundedCornerShape(10.dp),
        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.4f),
        modifier =
        modifier
            .fillMaxWidth()
            .clickableUnit(onClick = onTap),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier =
            Modifier
                .fillMaxWidth()
                .padding(horizontal = 14.dp, vertical = 12.dp),
        ) {
            Icon(
                imageVector = Icons.Filled.Tune,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.primary,
                modifier = Modifier.size(18.dp),
            )
            Spacer(modifier = Modifier.width(10.dp))
            Text(
                "Discover agents & capabilities",
                fontSize = 13.sp,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurface,
            )
            Spacer(modifier = Modifier.weight(1f))
            Icon(
                imageVector = Icons.Filled.ChevronRight,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.size(14.dp),
            )
        }
    }
}
