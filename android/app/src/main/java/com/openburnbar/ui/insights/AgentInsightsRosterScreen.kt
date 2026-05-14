package com.openburnbar.ui.insights

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Layers
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.models.AgentProvider

/**
 * Roster landing for the per-agent Insights surface on Android.
 *
 * Mirrors the cross-platform `AgentInsightsRosterView` in `OpenBurnBarCore`:
 * groups every `AgentProvider` and surfaces an "All agents" aggregate row.
 * Tapping a row pushes the scoped Insights detail.
 */
@Composable
fun AgentInsightsRosterScreen(
    onSelectProvider: (AgentProvider) -> Unit,
    onSelectAggregate: () -> Unit,
    contentPadding: PaddingValues = PaddingValues()
) {
    val groups = remember()

    LazyColumn(
        modifier = Modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.background),
        contentPadding = contentPadding,
        verticalArrangement = Arrangement.spacedBy(16.dp)
    ) {
        item {
            Spacer(modifier = Modifier.height(8.dp))
            Text(
                "Insights",
                style = MaterialTheme.typography.headlineMedium.copy(fontWeight = FontWeight.SemiBold),
                modifier = Modifier.padding(horizontal = 16.dp)
            )
            Text(
                "Pick an agent to see its scoped KPIs, brief, missions, and saved canvases.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp)
            )
        }

        item {
            AggregateRow(onTap = onSelectAggregate)
        }

        items(groups, key = { it.label }) { group ->
            RosterGroup(group = group, onSelect = onSelectProvider)
        }
    }
}

@Composable
private fun AggregateRow(onTap: () -> Unit) {
    Surface(
        color = MaterialTheme.colorScheme.surface,
        shape = RoundedCornerShape(12.dp),
        modifier = Modifier
            .padding(horizontal = 16.dp)
            .fillMaxWidth()
            .clickable(onClick = onTap)
    ) {
        Row(
            modifier = Modifier.padding(12.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Box(
                modifier = Modifier
                    .size(44.dp)
                    .clip(RoundedCornerShape(10.dp))
                    .background(MaterialTheme.colorScheme.primaryContainer),
                contentAlignment = Alignment.Center
            ) {
                Icon(
                    imageVector = Icons.Filled.Layers,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.primary
                )
            }
            Spacer(modifier = Modifier.size(12.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    "All agents",
                    style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.SemiBold)
                )
                Text(
                    "Combined view across every provider",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
            Icon(
                imageVector = Icons.Filled.ChevronRight,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
    }
}

@Composable
private fun RosterGroup(group: RosterGroupSpec, onSelect: (AgentProvider) -> Unit) {
    Column(modifier = Modifier.padding(horizontal = 16.dp)) {
        Text(
            group.label.uppercase(),
            style = MaterialTheme.typography.labelSmall.copy(letterSpacing = 1.sp),
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(vertical = 8.dp)
        )
        Surface(
            color = MaterialTheme.colorScheme.surface,
            shape = RoundedCornerShape(12.dp),
            modifier = Modifier.fillMaxWidth()
        ) {
            Column {
                group.providers.forEachIndexed { idx, provider ->
                    AgentRow(provider = provider, onTap = { onSelect(provider) })
                    if (idx < group.providers.lastIndex) {
                        Box(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(start = 60.dp)
                                .height(0.5.dp)
                                .background(MaterialTheme.colorScheme.outlineVariant)
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun AgentRow(provider: AgentProvider, onTap: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onTap)
            .padding(horizontal = 12.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Box(
            modifier = Modifier
                .size(36.dp)
                .clip(CircleShape)
                .background(Color(provider.brandColor)),
            contentAlignment = Alignment.Center
        ) {
            Text(
                provider.displayName.first().toString(),
                style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold),
                color = Color.White
            )
        }
        Spacer(modifier = Modifier.size(12.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(
                provider.displayName,
                style = MaterialTheme.typography.bodyLarge
            )
            Text(
                provider.key,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
        Icon(
            imageVector = Icons.Filled.ChevronRight,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.onSurfaceVariant
        )
    }
}

private data class RosterGroupSpec(val label: String, val providers: List<AgentProvider>)

private val mobileConnectableKeys = setOf(
    "claude-code", "codex", "opencode", "factory", "cursor", "minimax", "zai", "openai"
)

private val quotaSignalKeys = setOf(
    "codex", "opencode", "claude-code", "openai", "copilot", "minimax", "zai",
    "factory", "cursor", "warp", "ollama", "kimi"
)

private val localKeys = setOf("ollama", "hermes", "pi-agent")

@Composable
private fun remember(): List<RosterGroupSpec> {
    val all = AgentProvider.entries.toList()
    val mobile = all.filter { it.key in mobileConnectableKeys }
    val quota = all.filter { it.key in quotaSignalKeys && it.key !in mobileConnectableKeys }
    val local = all.filter { it.key in localKeys && it.key !in mobileConnectableKeys && it.key !in quotaSignalKeys }
    val other = all.filter { it.key !in mobileConnectableKeys && it.key !in quotaSignalKeys && it.key !in localKeys }

    return buildList {
        if (mobile.isNotEmpty()) add(RosterGroupSpec("Connect on mobile", mobile))
        if (quota.isNotEmpty()) add(RosterGroupSpec("Quota-aware", quota))
        if (local.isNotEmpty()) add(RosterGroupSpec("Local & on-device", local))
        if (other.isNotEmpty()) add(RosterGroupSpec("Other agents", other))
    }
}
