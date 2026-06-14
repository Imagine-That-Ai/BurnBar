// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.square

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
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
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items as gridItems
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.cloud.CloudConversationSearchRow
import com.openburnbar.data.hermes.AssistantRuntimeID
import com.openburnbar.data.square.AgentAvailability
import com.openburnbar.data.square.AgentIdentity
import com.openburnbar.data.square.AgentIdentityRegistry
import com.openburnbar.data.square.PinnedAgentGridConfig
import com.openburnbar.data.square.ThreadInboxStore

// MARK: - Hermes Square Root (Android composable, Hermes Square §3 / §6.2)
//
// Phase A composable that mirrors the iOS `HermesSquareRoot` and replaces
// the runtime-pill `AssistantsScreen` when `phaseA` is enabled. Carries:
//   • Federated search bar
//   • 12-slot pinned agent grid
//   • Active missions strip (placeholder until Android mission host lands)
//   • Unified thread inbox
//   • Subscriptions folder entry
//   • Discover drawer entry

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HermesSquareScreen(
    onOpenLegacyRuntime: (AssistantRuntimeID, String?) -> Unit = { _, _ -> },
    onOpenBrandZone: (String) -> Unit = {},
    onOpenPairedMac: (String) -> Unit = {},
) {
    HermesSquareScreenContent(
        onOpenLegacyRuntime = onOpenLegacyRuntime,
        onOpenBrandZone = onOpenBrandZone,
        onOpenPairedMac = onOpenPairedMac,
    )
}

// MARK: - Phase D voice entry

@Composable
private fun PhaseDVoiceEntry(onTap: () -> Unit, modifier: Modifier = Modifier) {
    Surface(
        shape = RoundedCornerShape(12.dp),
        color = MaterialTheme.colorScheme.tertiary.copy(alpha = 0.12f),
        tonalElevation = 0.5.dp,
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
                imageVector = Icons.Filled.Mic,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.tertiary,
                modifier = Modifier.size(20.dp),
            )
            Spacer(modifier = Modifier.width(10.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    "Voice command",
                    fontSize = 13.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = MaterialTheme.colorScheme.onSurface,
                )
                Text(
                    "Hold to talk — \"open Claude\", \"what's important?\", or dispatch a brief.",
                    fontSize = 11.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            Icon(
                imageVector = Icons.Filled.ChevronRight,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.size(16.dp),
            )
        }
    }
}

// MARK: - Phase B fan-out entry

@Composable
private fun PhaseBFanOutEntry(onTap: () -> Unit, modifier: Modifier = Modifier) {
    Surface(
        shape = RoundedCornerShape(12.dp),
        color = MaterialTheme.colorScheme.primary.copy(alpha = 0.12f),
        tonalElevation = 0.5.dp,
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
                imageVector = Icons.Filled.Bolt,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.primary,
                modifier = Modifier.size(20.dp),
            )
            Spacer(modifier = Modifier.width(10.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    "Fan-out to multiple runtimes",
                    fontSize = 13.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = MaterialTheme.colorScheme.onSurface,
                )
                Text(
                    "Dispatch the same brief to Claude + Codex + Hermes in parallel.",
                    fontSize = 11.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            Icon(
                imageVector = Icons.Filled.ChevronRight,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.size(16.dp),
            )
        }
    }
}

// MARK: - Federated search bar

@Composable
internal fun FederatedSearchBar(query: String, onQueryChange: (String) -> Unit, modifier: Modifier = Modifier) {
    Surface(
        shape = RoundedCornerShape(14.dp),
        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.85f),
        tonalElevation = 1.dp,
        modifier = modifier.fillMaxWidth(),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier =
            Modifier
                .fillMaxWidth()
                .padding(horizontal = 12.dp),
        ) {
            Icon(
                imageVector = Icons.Filled.Search,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.size(18.dp),
            )
            Spacer(modifier = Modifier.width(8.dp))
            TextField(
                value = query,
                onValueChange = onQueryChange,
                placeholder = {
                    Text(
                        "Search agents · threads · missions · cards",
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        fontSize = 13.sp,
                    )
                },
                singleLine = true,
                colors =
                TextFieldDefaults.colors(
                    focusedContainerColor = Color.Transparent,
                    unfocusedContainerColor = Color.Transparent,
                    focusedIndicatorColor = Color.Transparent,
                    unfocusedIndicatorColor = Color.Transparent,
                ),
                modifier = Modifier.weight(1f),
            )
            if (query.isNotEmpty()) {
                IconButton(onClick = { onQueryChange("") }) {
                    Icon(
                        imageVector = Icons.Filled.Close,
                        contentDescription = "Clear search",
                        modifier = Modifier.size(16.dp),
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }
    }
}

// MARK: - Pinned grid section

@Composable
internal fun PinnedGridSection(
    config: PinnedAgentGridConfig,
    registry: AgentIdentityRegistry,
    onTap: (String) -> Unit,
    onLongPress: (String) -> Unit,
    onAdd: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(modifier = modifier.fillMaxWidth()) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.fillMaxWidth(),
        ) {
            Text(
                "Pinned",
                fontSize = 11.sp,
                fontWeight = FontWeight.Bold,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Spacer(modifier = Modifier.weight(1f))
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier =
                Modifier.clip(RoundedCornerShape(8.dp))
                    .background(Color.Transparent)
                    .clickableUnit(onClick = onAdd)
                    .padding(horizontal = 6.dp, vertical = 4.dp),
            ) {
                Icon(
                    imageVector = Icons.Filled.Add,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.size(14.dp),
                )
                Spacer(modifier = Modifier.width(2.dp))
                Text(
                    "Add",
                    color = MaterialTheme.colorScheme.primary,
                    fontSize = 11.sp,
                    fontWeight = FontWeight.SemiBold,
                )
            }
        }
        Spacer(modifier = Modifier.height(8.dp))
        LazyVerticalGrid(
            columns = GridCells.Fixed(config.displayMode.columns),
            verticalArrangement = Arrangement.spacedBy(10.dp),
            horizontalArrangement = Arrangement.spacedBy(10.dp),
            // Wrap-height: derive a max content height from rows. Phase A
            // ships with at most 12 slots; 3 rows × 80dp easily fits.
            modifier =
            Modifier
                .fillMaxWidth()
                .height(((config.pinnedURIs.size + config.displayMode.columns - 1) / config.displayMode.columns * 88).dp),
        ) {
            gridItems(items = config.pinnedURIs, key = { it }) { uri ->
                val identity = registry.identity(uri)
                if (identity != null) {
                    PinnedCell(
                        identity = identity,
                        onTap = { onTap(uri) },
                        onLongPress = { onLongPress(uri) },
                    )
                }
            }
        }
    }
}

@Composable
private fun PinnedCell(identity: AgentIdentity, onTap: () -> Unit, onLongPress: () -> Unit) {
    Surface(
        shape = RoundedCornerShape(12.dp),
        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.55f),
        tonalElevation = 0.5.dp,
        modifier =
        Modifier
            .fillMaxWidth()
            .height(78.dp)
            .clickableLongPress(onClick = onTap, onLongClick = onLongPress),
    ) {
        Column(
            verticalArrangement = Arrangement.Center,
            horizontalAlignment = Alignment.CenterHorizontally,
            modifier =
            Modifier
                .fillMaxSize()
                .padding(vertical = 6.dp),
        ) {
            Box(contentAlignment = Alignment.BottomEnd, modifier = Modifier.size(40.dp)) {
                com.openburnbar.ui.components.BurnBarAgentAvatar(
                    identity = identity,
                    size = 40.dp,
                )
                if (identity.availability != AgentAvailability.UNKNOWN) {
                    Box(
                        modifier =
                        Modifier
                            .size(10.dp)
                            .clip(RoundedCornerShape(50))
                            .background(availabilityColor(identity.availability))
                            .border(1.5.dp, MaterialTheme.colorScheme.surface, RoundedCornerShape(50)),
                    )
                }
            }
            Spacer(modifier = Modifier.height(4.dp))
            Text(
                identity.displayName,
                fontSize = 11.sp,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurface,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

// MARK: - Search

internal data class HermesSquareHit(
    val id: String,
    val kind: Kind,
    val title: String,
    val preview: String,
    val score: Double,
    val cloudRow: CloudConversationSearchRow? = null,
) {
    enum class Kind { AGENT, THREAD, CLOUD_SESSION }
}

internal fun CloudConversationSearchRow.toHermesSquareHit(): HermesSquareHit = HermesSquareHit(
    id = "cloud:$id",
    kind = HermesSquareHit.Kind.CLOUD_SESSION,
    title = title,
    preview =
    listOfNotNull(provider, snippet)
        .joinToString(" · ")
        .ifBlank { snippet },
    score = score + 0.15,
    cloudRow = this,
)

internal fun runQuickSearch(query: String, registry: AgentIdentityRegistry, inbox: ThreadInboxStore): List<HermesSquareHit> {
    val q = query.lowercase()
    val hits = mutableListOf<HermesSquareHit>()
    for (identity in registry.identities) {
        val haystack =
            listOf(identity.displayName, identity.tagline ?: "", identity.id)
                .joinToString(" ")
                .lowercase()
        if (haystack.contains(q)) {
            hits.add(
                HermesSquareHit(
                    id = identity.id,
                    kind = HermesSquareHit.Kind.AGENT,
                    title = identity.displayName,
                    preview = identity.tagline ?: identity.installSource.displayLabel,
                    score = scoreFor(haystack, q),
                ),
            )
        }
    }
    for (item in inbox.items) {
        val haystack = item.searchText.lowercase()
        if (haystack.contains(q)) {
            hits.add(
                HermesSquareHit(
                    id = item.id,
                    kind = HermesSquareHit.Kind.THREAD,
                    title = item.title,
                    preview = item.preview,
                    score = scoreFor(haystack, q),
                ),
            )
        }
    }
    return hits.sortedByDescending { it.score }.take(20)
}

internal fun scoreFor(haystack: String, q: String): Double {
    val base = 1.0
    val exactBoost = if (haystack.contains(" $q ") || haystack.startsWith("$q ") || haystack.endsWith(" $q")) 0.5 else 0.0
    val prefixBoost = if (haystack.startsWith(q)) 0.3 else 0.0
    return base + exactBoost + prefixBoost
}

@Composable
internal fun SearchResultsSection(hits: List<HermesSquareHit>, onTap: (HermesSquareHit) -> Unit, modifier: Modifier = Modifier) {
    Column(
        verticalArrangement = Arrangement.spacedBy(8.dp),
        modifier = modifier.fillMaxWidth(),
    ) {
        if (hits.isEmpty()) {
            Text(
                "No matches. Try a name, runtime, file, session text, or tool.",
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                fontSize = 12.sp,
                modifier = Modifier.padding(vertical = 18.dp),
            )
        } else {
            hits.forEachIndexed { idx, hit ->
                Surface(
                    shape = RoundedCornerShape(8.dp),
                    color = MaterialTheme.colorScheme.surface.copy(alpha = 0.4f),
                    modifier =
                    Modifier
                        .fillMaxWidth()
                        .clickableUnit(onClick = { onTap(hit) }),
                ) {
                    Column(
                        modifier =
                        Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 12.dp, vertical = 10.dp),
                    ) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(
                                hit.title,
                                fontSize = 13.sp,
                                fontWeight = FontWeight.Bold,
                                color = MaterialTheme.colorScheme.onSurface,
                            )
                            Spacer(modifier = Modifier.weight(1f))
                            Text(
                                hit.kind.name.lowercase(),
                                fontSize = 10.sp,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                        Spacer(modifier = Modifier.height(2.dp))
                        Text(
                            hit.preview,
                            fontSize = 11.sp,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            maxLines = 2,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                }
            }
        }
    }
}

// MARK: - Helpers

internal fun hexColor(hex: String): Color {
    val clean = hex.trim('#', ' ')
    val parsed = clean.toLong(radix = 16)
    return if (clean.length == 8) {
        Color(parsed)
    } else {
        Color(parsed or 0xFF000000)
    }
}

internal fun availabilityColor(availability: AgentAvailability): Color = when (availability) {
    AgentAvailability.ONLINE -> Color(0xFF38D898)
    AgentAvailability.DEGRADED -> Color(0xFFFFA800)
    AgentAvailability.OFFLINE -> Color(0xFFFA5053)
    AgentAvailability.UNKNOWN -> Color(0x806E7681)
}

internal fun relativeTime(epoch: Long, now: Long = System.currentTimeMillis()): String {
    val delta = (now - epoch) / 1000
    return when {
        delta < 5 -> "just now"
        delta < 60 -> "${delta}s ago"
        delta < 3_600 -> "${delta / 60}m ago"
        delta < 86_400 -> "${delta / 3_600}h ago"
        else -> "${delta / 86_400}d ago"
    }
}

/** Thin wrappers so call sites stay readable. */
internal fun Modifier.clickableUnit(onClick: () -> Unit): Modifier = this.clickable(onClick = onClick)

@OptIn(ExperimentalFoundationApi::class)
internal fun Modifier.clickableLongPress(onClick: () -> Unit, onLongClick: () -> Unit): Modifier =
    this.combinedClickable(onClick = onClick, onLongClick = onLongClick)
