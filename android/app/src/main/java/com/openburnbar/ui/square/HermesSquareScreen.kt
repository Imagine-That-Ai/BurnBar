package com.openburnbar.ui.square

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.background
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
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.ExperimentalFoundationApi
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
import androidx.compose.material.icons.filled.Inbox
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.hermes.AssistantRuntimeID
import com.openburnbar.data.square.AgentAvailability
import com.openburnbar.data.square.AgentIdentity
import com.openburnbar.data.square.AgentIdentityRegistry
import com.openburnbar.data.square.PinnedAgentGridConfig
import com.openburnbar.data.square.ThreadInboxItem
import com.openburnbar.data.square.ThreadInboxStore
import com.openburnbar.data.square.splitForInbox

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

@Composable
fun HermesSquareScreen(
    onOpenLegacyRuntime: (AssistantRuntimeID) -> Unit = {},
    onOpenBrandZone: (String) -> Unit = {}
) {
    val context = LocalContext.current
    val registry = remember { AgentIdentityRegistry.shared() }
    val inbox = remember { ThreadInboxStore.shared() }

    val pinnedPrefs = remember {
        context.applicationContext.getSharedPreferences("square.pinned_grid", android.content.Context.MODE_PRIVATE)
    }
    var pinned by remember {
        mutableStateOf(
            PinnedAgentGridConfig.fromJsonString(
                pinnedPrefs.getString(PinnedAgentGridConfig.SHARED_PREFS_KEY, null)
            )
        )
    }
    fun persistPinned(next: PinnedAgentGridConfig) {
        pinned = next
        pinnedPrefs.edit().putString(PinnedAgentGridConfig.SHARED_PREFS_KEY, next.toJsonString()).apply()
    }

    var query by remember { mutableStateOf("") }
    var showDiscover by remember { mutableStateOf(false) }
    var showSubscriptions by remember { mutableStateOf(false) }
    var showBrandZoneURI by remember { mutableStateOf<String?>(null) }

    // Phase A: hydrate availability for built-ins. (Mac-relay runtimes
    // remain UNKNOWN until the Android mission host publishes.)
    LaunchedEffect(Unit) {
        registry.refreshAvailability(
            mapOf(
                AgentIdentity.builtInURI(AssistantRuntimeID.HERMES) to AgentAvailability.ONLINE,
                AgentIdentity.builtInURI(AssistantRuntimeID.PI) to AgentAvailability.ONLINE
            )
        )
    }

    val splitInbox by remember(inbox.items) {
        derivedStateOf { inbox.items.splitForInbox() }
    }
    val filteredHits by remember(query, inbox.items, registry.identities) {
        derivedStateOf {
            val q = query.trim()
            if (q.isBlank()) emptyList() else runQuickSearch(q, registry, inbox)
        }
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
    ) {
        LazyColumn(
            contentPadding = PaddingValues(top = 12.dp, bottom = 88.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
            modifier = Modifier.fillMaxSize()
        ) {
            item {
                FederatedSearchBar(
                    query = query,
                    onQueryChange = { query = it },
                    modifier = Modifier.padding(horizontal = 16.dp)
                )
            }

            if (query.isNotBlank()) {
                item {
                    SearchResultsSection(
                        hits = filteredHits,
                        onTap = { hit ->
                            when (hit.kind) {
                                HermesSquareHit.Kind.AGENT -> {
                                    val identity = registry.identity(hit.id)
                                    val runtime = identity?.runtimeID
                                    if (runtime != null && (runtime == AssistantRuntimeID.HERMES || runtime == AssistantRuntimeID.PI)) {
                                        onOpenLegacyRuntime(runtime)
                                    } else {
                                        showBrandZoneURI = hit.id
                                    }
                                }
                                HermesSquareHit.Kind.THREAD -> {
                                    val item = inbox.items.firstOrNull { it.id == hit.id }
                                    val runtime = item?.agentURI?.let { AgentIdentity.builtInRuntime(it) }
                                    if (runtime != null) {
                                        onOpenLegacyRuntime(runtime)
                                    }
                                }
                            }
                        },
                        modifier = Modifier.padding(horizontal = 16.dp)
                    )
                }
            } else {
                item {
                    PinnedGridSection(
                        config = pinned,
                        registry = registry,
                        onTap = { uri ->
                            val identity = registry.identity(uri)
                            val runtime = identity?.runtimeID
                            if (runtime == AssistantRuntimeID.HERMES || runtime == AssistantRuntimeID.PI) {
                                onOpenLegacyRuntime(runtime)
                            } else {
                                showBrandZoneURI = uri
                            }
                        },
                        onLongPress = { uri -> showBrandZoneURI = uri },
                        onAdd = { showDiscover = true },
                        modifier = Modifier.padding(horizontal = 16.dp)
                    )
                }

                item {
                    ActiveMissionsStrip(
                        modifier = Modifier.padding(start = 16.dp, end = 0.dp)
                    )
                }

                item {
                    SectionHeader(
                        label = "Conversations",
                        isLoading = inbox.isLoading,
                        modifier = Modifier.padding(horizontal = 16.dp)
                    )
                }

                val (service, _) = splitInbox
                if (service.isEmpty()) {
                    item {
                        EmptyConversationsCard(modifier = Modifier.padding(horizontal = 16.dp))
                    }
                } else {
                    items(items = service, key = { it.id }) { item ->
                        ThreadInboxRow(
                            item = item,
                            registry = registry,
                            onTap = {
                                val runtime = AgentIdentity.builtInRuntime(item.agentURI)
                                if (runtime != null) {
                                    onOpenLegacyRuntime(runtime)
                                } else {
                                    showBrandZoneURI = item.agentURI
                                }
                            },
                            modifier = Modifier.padding(horizontal = 16.dp)
                        )
                    }
                }

                item {
                    SubscriptionsEntry(
                        count = splitInbox.second.size,
                        onTap = { showSubscriptions = true },
                        modifier = Modifier.padding(horizontal = 16.dp)
                    )
                }

                item {
                    DiscoverEntry(
                        onTap = { showDiscover = true },
                        modifier = Modifier.padding(horizontal = 16.dp)
                    )
                }
            }
        }
    }

    if (showDiscover) {
        HermesSquareDiscoverSheet(
            registry = registry,
            pinned = pinned,
            onPin = { persistPinned(pinned.pinning(it)) },
            onUnpin = { persistPinned(pinned.unpinning(it)) },
            onDismiss = { showDiscover = false }
        )
    }

    if (showSubscriptions) {
        HermesSquareSubscriptionsSheet(onDismiss = { showSubscriptions = false })
    }

    showBrandZoneURI?.let { uri ->
        val identity = registry.identity(uri)
        if (identity != null) {
            HermesSquareBrandZoneSheet(
                identity = identity,
                onDismiss = { showBrandZoneURI = null }
            )
        }
    }
}

// MARK: - Federated search bar

@Composable
private fun FederatedSearchBar(
    query: String,
    onQueryChange: (String) -> Unit,
    modifier: Modifier = Modifier
) {
    Surface(
        shape = RoundedCornerShape(14.dp),
        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.85f),
        tonalElevation = 1.dp,
        modifier = modifier.fillMaxWidth()
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 12.dp)
        ) {
            Icon(
                imageVector = Icons.Filled.Search,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.size(18.dp)
            )
            Spacer(modifier = Modifier.width(8.dp))
            TextField(
                value = query,
                onValueChange = onQueryChange,
                placeholder = {
                    Text(
                        "Search agents · threads · missions · cards",
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        fontSize = 13.sp
                    )
                },
                singleLine = true,
                colors = TextFieldDefaults.colors(
                    focusedContainerColor = Color.Transparent,
                    unfocusedContainerColor = Color.Transparent,
                    focusedIndicatorColor = Color.Transparent,
                    unfocusedIndicatorColor = Color.Transparent
                ),
                modifier = Modifier.weight(1f)
            )
            if (query.isNotEmpty()) {
                IconButton(onClick = { onQueryChange("") }) {
                    Icon(
                        imageVector = Icons.Filled.Close,
                        contentDescription = "Clear search",
                        modifier = Modifier.size(16.dp),
                        tint = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            }
        }
    }
}

// MARK: - Pinned grid section

@Composable
private fun PinnedGridSection(
    config: PinnedAgentGridConfig,
    registry: AgentIdentityRegistry,
    onTap: (String) -> Unit,
    onLongPress: (String) -> Unit,
    onAdd: () -> Unit,
    modifier: Modifier = Modifier
) {
    Column(modifier = modifier.fillMaxWidth()) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.fillMaxWidth()
        ) {
            Text(
                "Pinned",
                fontSize = 11.sp,
                fontWeight = FontWeight.Bold,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            Spacer(modifier = Modifier.weight(1f))
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.clip(RoundedCornerShape(8.dp))
                    .background(Color.Transparent)
                    .clickableUnit(onClick = onAdd)
                    .padding(horizontal = 6.dp, vertical = 4.dp)
            ) {
                Icon(
                    imageVector = Icons.Filled.Add,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.size(14.dp)
                )
                Spacer(modifier = Modifier.width(2.dp))
                Text(
                    "Add",
                    color = MaterialTheme.colorScheme.primary,
                    fontSize = 11.sp,
                    fontWeight = FontWeight.SemiBold
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
            modifier = Modifier
                .fillMaxWidth()
                .height(((config.pinnedURIs.size + config.displayMode.columns - 1) / config.displayMode.columns * 88).dp)
        ) {
            gridItems(items = config.pinnedURIs, key = { it }) { uri ->
                val identity = registry.identity(uri)
                if (identity != null) {
                    PinnedCell(
                        identity = identity,
                        onTap = { onTap(uri) },
                        onLongPress = { onLongPress(uri) }
                    )
                }
            }
        }
    }
}

@Composable
private fun PinnedCell(
    identity: AgentIdentity,
    onTap: () -> Unit,
    onLongPress: () -> Unit
) {
    Surface(
        shape = RoundedCornerShape(12.dp),
        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.55f),
        tonalElevation = 0.5.dp,
        modifier = Modifier
            .fillMaxWidth()
            .height(78.dp)
            .clickableLongPress(onClick = onTap, onLongClick = onLongPress)
    ) {
        Column(
            verticalArrangement = Arrangement.Center,
            horizontalAlignment = Alignment.CenterHorizontally,
            modifier = Modifier
                .fillMaxSize()
                .padding(vertical = 6.dp)
        ) {
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier
                    .size(38.dp)
                    .clip(RoundedCornerShape(50))
                    .background(
                        Brush.linearGradient(
                            listOf(
                                hexColor(identity.paletteHex),
                                hexColor(identity.paletteHex).copy(alpha = 0.66f)
                            )
                        )
                    )
            ) {
                Text(
                    identity.glyph,
                    color = Color.White,
                    fontSize = 18.sp,
                    fontWeight = FontWeight.Bold
                )
                if (identity.availability != AgentAvailability.UNKNOWN) {
                    Box(
                        modifier = Modifier
                            .size(8.dp)
                            .clip(RoundedCornerShape(50))
                            .background(availabilityColor(identity.availability))
                            .padding(start = 28.dp, top = 28.dp)
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
                overflow = TextOverflow.Ellipsis
            )
        }
    }
}

// MARK: - Active missions strip (Phase A placeholder)

@Composable
private fun ActiveMissionsStrip(modifier: Modifier = Modifier) {
    Column(modifier = modifier.fillMaxWidth()) {
        Text(
            "Active missions",
            fontSize = 11.sp,
            fontWeight = FontWeight.Bold,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(start = 0.dp, end = 16.dp)
        )
        Spacer(modifier = Modifier.height(8.dp))
        LazyRow(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            item {
                Surface(
                    shape = RoundedCornerShape(12.dp),
                    color = MaterialTheme.colorScheme.surface.copy(alpha = 0.6f),
                    tonalElevation = 0.5.dp,
                    modifier = Modifier
                        .width(280.dp)
                        .height(110.dp)
                ) {
                    Column(
                        verticalArrangement = Arrangement.Center,
                        horizontalAlignment = Alignment.Start,
                        modifier = Modifier
                            .fillMaxSize()
                            .padding(14.dp)
                    ) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Icon(
                                imageVector = Icons.Filled.Bolt,
                                contentDescription = null,
                                tint = MaterialTheme.colorScheme.primary,
                                modifier = Modifier.size(14.dp)
                            )
                            Spacer(modifier = Modifier.width(6.dp))
                            Text(
                                "No live missions",
                                color = MaterialTheme.colorScheme.onSurface,
                                fontSize = 13.sp,
                                fontWeight = FontWeight.SemiBold
                            )
                        }
                        Spacer(modifier = Modifier.height(6.dp))
                        Text(
                            "Dispatch from the FAB. Phase B wires fan-out dispatch into this strip.",
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            fontSize = 11.sp,
                            maxLines = 3,
                            overflow = TextOverflow.Ellipsis
                        )
                    }
                }
            }
            item { Spacer(modifier = Modifier.width(0.dp)) }
        }
    }
}

// MARK: - Sections + rows

@Composable
private fun SectionHeader(
    label: String,
    isLoading: Boolean,
    modifier: Modifier = Modifier
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = modifier.fillMaxWidth()
    ) {
        Text(
            label,
            fontSize = 11.sp,
            fontWeight = FontWeight.Bold,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
        Spacer(modifier = Modifier.weight(1f))
        if (isLoading) {
            CircularProgressIndicator(
                strokeWidth = 1.dp,
                modifier = Modifier.size(12.dp)
            )
        }
    }
}

@Composable
private fun EmptyConversationsCard(modifier: Modifier = Modifier) {
    Surface(
        shape = RoundedCornerShape(10.dp),
        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.4f),
        modifier = modifier.fillMaxWidth()
    ) {
        Column(
            verticalArrangement = Arrangement.Center,
            horizontalAlignment = Alignment.CenterHorizontally,
            modifier = Modifier
                .fillMaxWidth()
                .padding(vertical = 22.dp, horizontal = 16.dp)
        ) {
            Icon(
                imageVector = Icons.Filled.Inbox,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.size(28.dp)
            )
            Spacer(modifier = Modifier.height(8.dp))
            Text(
                "No conversations yet",
                fontSize = 13.sp,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurface
            )
            Text(
                "Pick an agent above to begin.",
                fontSize = 11.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
    }
}

@Composable
private fun ThreadInboxRow(
    item: ThreadInboxItem,
    registry: AgentIdentityRegistry,
    onTap: () -> Unit,
    modifier: Modifier = Modifier
) {
    val identity = registry.identity(item.agentURI)
    Surface(
        shape = RoundedCornerShape(10.dp),
        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.5f),
        tonalElevation = 0.5.dp,
        modifier = modifier
            .fillMaxWidth()
            .clickableUnit(onClick = onTap)
    ) {
        Row(
            verticalAlignment = Alignment.Top,
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 12.dp, vertical = 10.dp)
        ) {
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier
                    .size(28.dp)
                    .clip(RoundedCornerShape(50))
                    .background(identity?.paletteHex?.let { hexColor(it) } ?: MaterialTheme.colorScheme.surfaceVariant)
            ) {
                Text(
                    identity?.glyph ?: "?",
                    color = Color.White,
                    fontSize = 14.sp,
                    fontWeight = FontWeight.Bold
                )
            }
            Spacer(modifier = Modifier.width(10.dp))
            Column(modifier = Modifier.weight(1f)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        identity?.displayName ?: "Agent",
                        fontSize = 11.sp,
                        fontWeight = FontWeight.Bold,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    Spacer(modifier = Modifier.weight(1f))
                    Text(
                        relativeTime(item.lastActivityAtEpoch),
                        fontSize = 10.sp,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
                Text(
                    item.title,
                    fontSize = 13.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = MaterialTheme.colorScheme.onSurface,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
                Text(
                    item.preview,
                    fontSize = 11.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis
                )
                if (item.needsAttention) {
                    Spacer(modifier = Modifier.height(2.dp))
                    Text(
                        "Needs attention",
                        color = MaterialTheme.colorScheme.tertiary,
                        fontSize = 10.sp,
                        fontWeight = FontWeight.Bold
                    )
                }
            }
        }
    }
}

@Composable
private fun SubscriptionsEntry(
    count: Int,
    onTap: () -> Unit,
    modifier: Modifier = Modifier
) {
    Surface(
        shape = RoundedCornerShape(10.dp),
        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.6f),
        modifier = modifier
            .fillMaxWidth()
            .clickableUnit(onClick = onTap)
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 14.dp, vertical = 12.dp)
        ) {
            Icon(
                imageVector = Icons.Filled.Inbox,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.size(18.dp)
            )
            Spacer(modifier = Modifier.width(10.dp))
            Text(
                "Subscriptions",
                fontSize = 13.sp,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurface
            )
            Spacer(modifier = Modifier.weight(1f))
            Text(
                "$count",
                fontSize = 12.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            Spacer(modifier = Modifier.width(6.dp))
            Icon(
                imageVector = Icons.Filled.ChevronRight,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.size(14.dp)
            )
        }
    }
}

@Composable
private fun DiscoverEntry(
    onTap: () -> Unit,
    modifier: Modifier = Modifier
) {
    Surface(
        shape = RoundedCornerShape(10.dp),
        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.4f),
        modifier = modifier
            .fillMaxWidth()
            .clickableUnit(onClick = onTap)
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 14.dp, vertical = 12.dp)
        ) {
            Icon(
                imageVector = Icons.Filled.Tune,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.primary,
                modifier = Modifier.size(18.dp)
            )
            Spacer(modifier = Modifier.width(10.dp))
            Text(
                "Discover agents & capabilities",
                fontSize = 13.sp,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurface
            )
            Spacer(modifier = Modifier.weight(1f))
            Icon(
                imageVector = Icons.Filled.ChevronRight,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.size(14.dp)
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
    val score: Double
) {
    enum class Kind { AGENT, THREAD }
}

private fun runQuickSearch(
    query: String,
    registry: AgentIdentityRegistry,
    inbox: ThreadInboxStore
): List<HermesSquareHit> {
    val q = query.lowercase()
    val hits = mutableListOf<HermesSquareHit>()
    for (identity in registry.identities) {
        val haystack = listOf(identity.displayName, identity.tagline ?: "", identity.id)
            .joinToString(" ")
            .lowercase()
        if (haystack.contains(q)) {
            hits.add(
                HermesSquareHit(
                    id = identity.id,
                    kind = HermesSquareHit.Kind.AGENT,
                    title = identity.displayName,
                    preview = identity.tagline ?: identity.installSource.displayLabel,
                    score = scoreFor(haystack, q)
                )
            )
        }
    }
    for (item in inbox.items) {
        val haystack = "${item.title} ${item.preview}".lowercase()
        if (haystack.contains(q)) {
            hits.add(
                HermesSquareHit(
                    id = item.id,
                    kind = HermesSquareHit.Kind.THREAD,
                    title = item.title,
                    preview = item.preview,
                    score = scoreFor(haystack, q)
                )
            )
        }
    }
    return hits.sortedByDescending { it.score }.take(20)
}

private fun scoreFor(haystack: String, q: String): Double {
    val base = 1.0
    val exactBoost = if (haystack.contains(" $q ") || haystack.startsWith("$q ") || haystack.endsWith(" $q")) 0.5 else 0.0
    val prefixBoost = if (haystack.startsWith(q)) 0.3 else 0.0
    return base + exactBoost + prefixBoost
}

@Composable
private fun SearchResultsSection(
    hits: List<HermesSquareHit>,
    onTap: (HermesSquareHit) -> Unit,
    modifier: Modifier = Modifier
) {
    Column(
        verticalArrangement = Arrangement.spacedBy(8.dp),
        modifier = modifier.fillMaxWidth()
    ) {
        if (hits.isEmpty()) {
            Text(
                "No matches. Try a name, runtime, file, or mission title.",
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                fontSize = 12.sp,
                modifier = Modifier.padding(vertical = 18.dp)
            )
        } else {
            hits.forEachIndexed { idx, hit ->
                Surface(
                    shape = RoundedCornerShape(8.dp),
                    color = MaterialTheme.colorScheme.surface.copy(alpha = 0.4f),
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickableUnit(onClick = { onTap(hit) })
                ) {
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 12.dp, vertical = 10.dp)
                    ) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(
                                hit.title,
                                fontSize = 13.sp,
                                fontWeight = FontWeight.Bold,
                                color = MaterialTheme.colorScheme.onSurface
                            )
                            Spacer(modifier = Modifier.weight(1f))
                            Text(
                                hit.kind.name.lowercase(),
                                fontSize = 10.sp,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        }
                        Spacer(modifier = Modifier.height(2.dp))
                        Text(
                            hit.preview,
                            fontSize = 11.sp,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            maxLines = 2,
                            overflow = TextOverflow.Ellipsis
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
    if (delta < 5) return "just now"
    if (delta < 60) return "${delta}s ago"
    if (delta < 3_600) return "${delta / 60}m ago"
    if (delta < 86_400) return "${delta / 3_600}h ago"
    return "${delta / 86_400}d ago"
}

/** Thin wrappers so call sites stay readable. */
internal fun Modifier.clickableUnit(onClick: () -> Unit): Modifier =
    this.clickable(onClick = onClick)

@OptIn(ExperimentalFoundationApi::class)
internal fun Modifier.clickableLongPress(onClick: () -> Unit, onLongClick: () -> Unit): Modifier =
    this.combinedClickable(onClick = onClick, onLongClick = onLongClick)
