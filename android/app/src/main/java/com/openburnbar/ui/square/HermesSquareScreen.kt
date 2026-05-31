package com.openburnbar.ui.square

import android.content.SharedPreferences
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.background
import androidx.compose.foundation.border
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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Inbox
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material.icons.filled.PushPin
import androidx.compose.material.icons.outlined.PushPin
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material.icons.filled.ArrowDownward
import androidx.compose.material.icons.outlined.RecordVoiceOver
import androidx.compose.material.icons.outlined.ViewAgenda
import androidx.compose.material3.CenterAlignedTopAppBar
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.TextButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.width
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.openburnbar.data.cloud.CloudConversationSearchRow
import com.openburnbar.data.stores.ActivityStore
import com.openburnbar.ui.components.AuroraBackdrop
import com.openburnbar.ui.components.AuroraBottomSheet
import com.openburnbar.ui.components.rememberAuroraSheetState
import com.openburnbar.ui.theme.AuroraColors
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
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
import com.openburnbar.data.hermes.HermesService
import com.openburnbar.data.assistants.CLIAgentRelayChatTransport
import com.openburnbar.data.assistants.CLIAgentSessionActionKind
import com.openburnbar.data.assistants.CLIAgentSessionActionRequest
import com.openburnbar.data.assistants.CLIAgentSessionActionStatus
import com.openburnbar.data.missions.ApprovalAsk
import com.openburnbar.data.missions.ApprovalDecision
import com.openburnbar.data.missions.ApprovalPolicy
import com.openburnbar.data.missions.ApprovalPolicyStore
import com.openburnbar.data.missions.MissionGroupObserver
import com.openburnbar.data.missions.MobileMissionConsoleHost
import com.openburnbar.data.missions.RollbackService
import com.openburnbar.data.projects.ProjectsStore
import com.openburnbar.data.square.AgentAvailability
import com.openburnbar.data.square.AgentIdentity
import com.openburnbar.data.square.AgentIdentityRegistry
import com.openburnbar.data.square.CLIAgentMessage
import com.openburnbar.data.square.CLIAgentSessionRecord
import com.openburnbar.data.square.MercuryPairedMacTilePreference
import com.openburnbar.data.square.PinnedAgentGridConfig
import com.openburnbar.data.square.ThreadInboxItem
import com.openburnbar.data.square.ThreadInboxStore
import kotlinx.coroutines.delay
import com.openburnbar.data.square.splitForInbox
import kotlinx.coroutines.launch
import java.util.UUID

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
    onOpenPairedMac: (String) -> Unit = {}
) {
    val context = LocalContext.current
    val registry = remember { AgentIdentityRegistry.shared() }
    val hermesService = remember(context) { HermesService(appContext = context.applicationContext) }
    val inbox = remember { ThreadInboxStore.shared() }
    val activityStore: ActivityStore = viewModel()
    val cloudHits by activityStore.cloudSearchHits.collectAsStateWithLifecycle()

    val missionHost = remember { MobileMissionConsoleHost.shared() }
    val rollbackService = remember { RollbackService.shared() }
    val approvalPolicyStore = remember(context) { ApprovalPolicyStore.shared(context) }
    val projectsStore = remember { ProjectsStore.shared() }
    val missionGroupObserver = remember { MissionGroupObserver() }

    val missionSnapshot by missionHost.snapshot.collectAsStateWithLifecycle()
    val groupSnapshot by missionGroupObserver.snapshot.collectAsStateWithLifecycle()
    val snapshotsBySession by rollbackService.snapshotsBySession.collectAsStateWithLifecycle()
    val projectSummaries by projectsStore.summaries.collectAsStateWithLifecycle()
    val hermesConnections by hermesService.connections.collectAsStateWithLifecycle()
    val scope = rememberCoroutineScope()

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

    val mercuryTilePrefs = remember(context) {
        context.applicationContext.getSharedPreferences(
            MercuryPairedMacTilePreference.PREFS_NAME,
            android.content.Context.MODE_PRIVATE
        )
    }
    var mercuryPinnedTileEnabled by remember(context) {
        mutableStateOf(MercuryPairedMacTilePreference.isEnabled(context))
    }
    DisposableEffect(mercuryTilePrefs) {
        val listener = SharedPreferences.OnSharedPreferenceChangeListener { _, key ->
            if (key == MercuryPairedMacTilePreference.ENABLED_KEY) {
                mercuryPinnedTileEnabled = MercuryPairedMacTilePreference.isEnabled(context)
            }
        }
        mercuryTilePrefs.registerOnSharedPreferenceChangeListener(listener)
        onDispose { mercuryTilePrefs.unregisterOnSharedPreferenceChangeListener(listener) }
    }

    val flags = remember(context) { com.openburnbar.data.square.HermesSquareFeatureFlags.shared(context) }
    var query by remember { mutableStateOf("") }
    var showDiscover by remember { mutableStateOf(false) }
    var showSubscriptions by remember { mutableStateOf(false) }
    var showBrandZoneURI by remember { mutableStateOf<String?>(null) }
    var showFanOut by remember { mutableStateOf(false) }
    var showVoice by remember { mutableStateOf(false) }
    var voiceBanner by remember { mutableStateOf<AndroidVoiceIntent?>(null) }
    var selectedCloudRow by remember { mutableStateOf<CloudConversationSearchRow?>(null) }
    var selectedCliSession by remember { mutableStateOf<CLIAgentSessionRecord?>(null) }

    val historyStore = remember(context) { com.openburnbar.data.assistants.AssistantChatHistoryStore.shared(context.applicationContext) }

    var threadToManage by remember { mutableStateOf<ThreadInboxItem?>(null) }
    var showRenameDialogForThread by remember { mutableStateOf<ThreadInboxItem?>(null) }
    var renameDialogText by remember { mutableStateOf("") }
    var missionToManage by remember { mutableStateOf<com.openburnbar.data.missions.ActiveMission?>(null) }
    var pinnedAgentToManage by remember { mutableStateOf<String?>(null) }

    fun updateThreadItemMetadata(
        item: ThreadInboxItem,
        customTitle: String? = null,
        labelColorHex: String? = null,
        isPinned: Boolean? = null,
        priorityOrder: Int? = null
    ) {
        scope.launch {
            if (item.id.startsWith("cli:")) {
                inbox.updateSessionMetadata(
                    id = item.id.removePrefix("cli:"),
                    customTitle = customTitle,
                    labelColorHex = labelColorHex,
                    isPinned = isPinned,
                    priorityOrder = priorityOrder
                )
            } else {
                historyStore.updateThreadMetadata(
                    id = item.id.substringAfter(":"),
                    customTitle = customTitle,
                    labelColorHex = labelColorHex,
                    isPinned = isPinned,
                    priorityOrder = priorityOrder
                )
            }
        }
    }

    // Phase A/3: hydrate availability for built-ins + bring up the mission
    // host + projects store + rollback service so the new sections have
    // live data on first paint.
    LaunchedEffect(Unit) {
        inbox.bind(historyStore = historyStore, missionHost = missionHost)
        inbox.refreshFromCloud()
        registry.refreshAvailability(
            mapOf(
                AgentIdentity.builtInURI(AssistantRuntimeID.HERMES) to AgentAvailability.ONLINE,
                AgentIdentity.builtInURI(AssistantRuntimeID.PI) to AgentAvailability.ONLINE
            )
        )
        missionHost.start()
        rollbackService.startObservingRequests()
        projectsStore.load()
        while (true) {
            hermesService.refreshRelayConnections()
            delay(10_000)
        }
    }

    LaunchedEffect(hermesConnections, mercuryPinnedTileEnabled) {
        if (!mercuryPinnedTileEnabled) {
            if (pinned.hasPairedMacPin()) {
                persistPinned(pinned.removingPairedMacPins())
            }
            return@LaunchedEffect
        }

        val mac = AgentIdentity.preferredPairedMacConnection(hermesConnections)
        if (mac != null) {
            val identity = registry.upsertPairedMac(mac)
            val next = pinned.pinningPairedMac(identity.id)
            if (next != pinned) {
                persistPinned(next)
            }
        } else if (!pinned.hasPairedMacPin()) {
            val next = pinned.pinningPairedMac(PinnedAgentGridConfig.DEFAULT_PAIRED_MAC_URI)
            if (next != pinned) {
                persistPinned(next)
            }
        }
    }

    // Whenever the mission host surfaces new active missions, observe each
    // session's rollback snapshots so the rollback card shows up the
    // moment the Mac writes one.
    LaunchedEffect(missionSnapshot.activeMissions) {
        for (mission in missionSnapshot.activeMissions) {
            rollbackService.startObservingSession(mission.id)
        }
    }

    LaunchedEffect(query) {
        activityStore.updateSearch(query)
    }

    val splitInbox by remember(inbox.items) {
        derivedStateOf { inbox.items.splitForInbox() }
    }

    fun moveThreadItem(item: ThreadInboxItem, direction: Int) {
        val (service, _) = splitInbox
        val index = service.indexOfFirst { it.id == item.id }
        if (index == -1) return
        val targetIndex = index + direction
        if (targetIndex !in service.indices) return

        val list = service.toMutableList()
        val temp = list[index]
        list[index] = list[targetIndex]
        list[targetIndex] = temp

        list.forEachIndexed { i, threadItem ->
            val newOrder = i + 1
            updateThreadItemMetadata(threadItem, priorityOrder = newOrder)
        }
    }
    val filteredHits by remember(query, inbox.items, registry.identities, cloudHits) {
        derivedStateOf {
            val q = query.trim()
            if (q.isBlank()) {
                emptyList()
            } else {
                (runQuickSearch(q, registry, inbox) + cloudHits.map { it.toHermesSquareHit() })
                    .sortedByDescending { it.score }
                    .take(30)
            }
        }
    }

    Scaffold(
        containerColor = androidx.compose.ui.graphics.Color.Transparent,
        topBar = {
            CenterAlignedTopAppBar(
                title = {
                    Text(
                        "Hermes Square",
                        fontWeight = FontWeight.SemiBold,
                        color = MaterialTheme.colorScheme.onSurface
                    )
                },
                colors = TopAppBarDefaults.centerAlignedTopAppBarColors(
                    containerColor = androidx.compose.ui.graphics.Color.Transparent,
                    scrolledContainerColor = androidx.compose.ui.graphics.Color.Transparent
                ),
                actions = {
                    if (flags.phaseB) {
                        IconButton(
                            onClick = { showFanOut = true }
                        ) {
                            Icon(
                                imageVector = Icons.Outlined.ViewAgenda,
                                contentDescription = "Fan-out dispatch",
                                tint = AuroraColors.ember
                            )
                        }
                    }
                    if (flags.phaseD) {
                        IconButton(
                            onClick = { showVoice = true }
                        ) {
                            Icon(
                                imageVector = Icons.Outlined.RecordVoiceOver,
                                contentDescription = "Voice command",
                                tint = AuroraColors.amber
                            )
                        }
                    }
                }
            )
        }
    ) { innerPadding ->
    Box(
        modifier = Modifier
            .fillMaxSize()
    ) {
        // Warm aurora behind everything — same backdrop the rest of the app
        // uses, so the Square feels like a peer of Pulse / Burn / Streams
        // rather than a different app.
        AuroraBackdrop()

        LazyColumn(
            contentPadding = PaddingValues(
                top = innerPadding.calculateTopPadding() + 12.dp,
                bottom = 88.dp
            ),
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
                                        onOpenLegacyRuntime(runtime, null)
                                    } else {
                                        showBrandZoneURI = hit.id
                                    }
                                }
                                HermesSquareHit.Kind.THREAD -> {
                                    val item = inbox.items.firstOrNull { it.id == hit.id }
                                    val cliSession = item?.takeIf { it.source == ThreadInboxItem.Source.CLI_MIRROR }
                                        ?.let { inbox.cliSessionFor(it) }
                                    val runtime = item?.agentURI?.let { AgentIdentity.builtInRuntime(it) }
                                    if (cliSession != null) {
                                        selectedCliSession = cliSession
                                    } else if (runtime != null) {
                                        onOpenLegacyRuntime(runtime, hit.id)
                                    }
                                }
                                HermesSquareHit.Kind.CLOUD_SESSION -> {
                                    selectedCloudRow = hit.cloudRow
                                }
                            }
                        },
                        modifier = Modifier.padding(horizontal = 16.dp)
                    )
                }
            } else {
                // 1. Approval inbox strip
                if (missionSnapshot.approvalQueue.isNotEmpty()) {
                    item {
                        ApprovalInboxStrip(
                            asks = missionSnapshot.approvalQueue,
                            onApprove = { ask ->
                                scope.launch { missionHost.respond(ask, approve = true) }
                            },
                            onDeny = { ask ->
                                scope.launch { missionHost.respond(ask, approve = false) }
                            },
                            onApproveAlways = { ask ->
                                recordApprovalPolicy(approvalPolicyStore, ask, ApprovalDecision.REMEMBER_ALLOW)
                                scope.launch { missionHost.respond(ask, approve = true) }
                            },
                            onDenyAlways = { ask ->
                                recordApprovalPolicy(approvalPolicyStore, ask, ApprovalDecision.REMEMBER_DENY)
                                scope.launch { missionHost.respond(ask, approve = false) }
                            },
                            modifier = Modifier.padding(horizontal = 16.dp)
                        )
                    }
                }

                // 2. Fan-out group card (only when there's an active group)
                if (groupSnapshot.group != null) {
                    item {
                        MissionFanOutGroupCard(
                            snapshot = groupSnapshot,
                            onPickWinner = { /* drilldown deferred to follow-up */ },
                            onMergeAction = { /* merge wiring deferred to follow-up */ },
                            modifier = Modifier.padding(horizontal = 16.dp)
                        )
                    }
                }

                // 3. Pinned grid
                item {
                    PinnedGridSection(
                        config = pinned,
                        registry = registry,
                        onTap = { uri ->
                            // Tapping a pinned agent opens its chat
                            // surface (the user's primary intent).
                            // `AssistantsScreen` handles every known
                            // runtime: Hermes / Pi natively, Codex /
                            // Claude / OpenClaw via the Mac-bridged
                            // tile. Long-press still routes to the
                            // brand zone for capability / subscription
                            // / dispatch flows. Pinned URIs without a
                            // recognized runtime fall through to brand
                            // zone since they have no chat surface.
                            val runtime = registry.identity(uri)?.runtimeID
                            when {
                                uri.startsWith(AgentIdentity.PAIRED_MAC_URI_PREFIX) -> {
                                    onOpenPairedMac(uri.removePrefix(AgentIdentity.PAIRED_MAC_URI_PREFIX))
                                }
                                runtime != null -> {
                                    onOpenLegacyRuntime(runtime, null)
                                }
                                else -> {
                                    showBrandZoneURI = uri
                                }
                            }
                        },
                        onLongPress = { uri -> pinnedAgentToManage = uri },
                        onAdd = { showDiscover = true },
                        modifier = Modifier.padding(horizontal = 16.dp)
                    )
                }

                // 4. Project Memory Wiki
                item {
                    ProjectMemoryWikiSection(
                        projects = projectSummaries.sortedByDescending { it.totalCost }.take(3),
                        onOpenProject = { _ -> /* drilldown deferred */ },
                        onAskWiki = { _ -> /* /wiki stash deferred */ },
                        modifier = Modifier.padding(horizontal = 16.dp)
                    )
                }

                // 5. Active missions strip
                item {
                    ActiveMissionsStrip(
                        missions = missionSnapshot.activeMissions,
                        onLongPress = { mission ->
                            missionToManage = mission
                        },
                        onComposeMission = { showFanOut = true },
                        modifier = Modifier.padding(start = 16.dp, end = 0.dp)
                    )
                }

                // 6. Rollback sections
                if (snapshotsBySession.any { it.value.isNotEmpty() }) {
                    item {
                        RollbackSectionsList(
                            snapshotsBySession = snapshotsBySession,
                            onSubmit = { sessionID, scopeChoice ->
                                scope.launch {
                                    rollbackService.submit(
                                        sessionID = sessionID,
                                        scope = scopeChoice,
                                        requestedBy = android.os.Build.MODEL ?: "android-device",
                                    )
                                }
                            },
                            modifier = Modifier.padding(horizontal = 16.dp)
                        )
                    }
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
                                val cliSession = item.takeIf { it.source == ThreadInboxItem.Source.CLI_MIRROR }
                                    ?.let { inbox.cliSessionFor(it) }
                                val runtime = AgentIdentity.builtInRuntime(item.agentURI)
                                if (cliSession != null) {
                                    selectedCliSession = cliSession
                                } else if (runtime != null) {
                                    onOpenLegacyRuntime(runtime, item.id)
                                } else {
                                    showBrandZoneURI = item.agentURI
                                }
                            },
                            onLongPress = {
                                threadToManage = item
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

        // Voice intent banner — slides in at the top of the Square when a
        // voice command resolves. Mirrors the iOS .overlay(alignment: .top).
        AnimatedVisibility(
            visible = voiceBanner != null,
            enter = slideInVertically(initialOffsetY = { -it }) + fadeIn(),
            exit = slideOutVertically(targetOffsetY = { -it }) + fadeOut(),
            modifier = Modifier
                .align(Alignment.TopCenter)
                .padding(top = innerPadding.calculateTopPadding() + 8.dp)
                .padding(horizontal = 16.dp)
        ) {
            voiceBanner?.let { intent ->
                VoiceIntentBannerView(
                    intent = intent,
                    onDismiss = { voiceBanner = null }
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

    if (showFanOut) {
        HermesSquareFanOutSheet(
            registry = registry,
            onDispatched = {
                showFanOut = false
            },
            onDismiss = { showFanOut = false }
        )
    }

    if (showVoice) {
        HermesSquareVoiceSheet(
            registry = registry,
            currentThreadAgentURI = null,
            onIntent = { intent ->
                voiceBanner = intent
                showVoice = false
            },
            onDismiss = { showVoice = false }
        )
    }

    if (showSubscriptions) {
        HermesSquareSubscriptionsSheet(onDismiss = { showSubscriptions = false })
    }

    selectedCloudRow?.let { row ->
        CloudSessionResultSheet(
            row = row,
            activityStore = activityStore,
            onDismiss = { selectedCloudRow = null }
        )
    }

    selectedCliSession?.let { session ->
        CLIAgentSessionSheet(
            session = session,
            hermesService = hermesService,
            onDismiss = { selectedCliSession = null }
        )
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

    // --- Bottom Sheets & Dialogs for Living Inbox Features ---

    threadToManage?.let { item ->
        AuroraBottomSheet(
            onDismissRequest = { threadToManage = null }
        ) {
            Column(
                verticalArrangement = Arrangement.spacedBy(16.dp),
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(vertical = 16.dp, horizontal = 8.dp)
            ) {
                Text(
                    text = item.customTitle ?: item.title,
                    fontSize = 18.sp,
                    fontWeight = FontWeight.Bold,
                    color = MaterialTheme.colorScheme.onSurface,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )

                HorizontalDivider(color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.08f))

                // Rename Button
                TextButton(
                    onClick = {
                        renameDialogText = item.customTitle ?: item.title
                        showRenameDialogForThread = item
                        threadToManage = null
                    },
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        Text(
                            text = "Rename Conversation",
                            color = MaterialTheme.colorScheme.onSurface,
                            fontSize = 15.sp,
                            fontWeight = FontWeight.Medium,
                            modifier = Modifier.weight(1f)
                        )
                    }
                }

                // Pin / Unpin Button
                TextButton(
                    onClick = {
                        updateThreadItemMetadata(item, isPinned = !item.isPinned)
                        threadToManage = null
                    },
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        Text(
                            text = if (item.isPinned) "Unpin from Top" else "Pin to Top",
                            color = MaterialTheme.colorScheme.onSurface,
                            fontSize = 15.sp,
                            fontWeight = FontWeight.Medium,
                            modifier = Modifier.weight(1f)
                        )
                        Icon(
                            imageVector = if (item.isPinned) Icons.Outlined.PushPin else Icons.Filled.PushPin,
                            contentDescription = null,
                            tint = AuroraColors.ember,
                            modifier = Modifier.size(18.dp)
                        )
                    }
                }

                // Move Up / Move Down Buttons
                Row(
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                    modifier = Modifier.fillMaxWidth()
                ) {
                    TextButton(
                        onClick = {
                            moveThreadItem(item, -1)
                            threadToManage = null
                        },
                        modifier = Modifier.weight(1f)
                    ) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.Filled.ArrowUpward, contentDescription = null, modifier = Modifier.size(16.dp))
                            Spacer(Modifier.width(4.dp))
                            Text("Move Up", fontSize = 14.sp)
                        }
                    }

                    TextButton(
                        onClick = {
                            moveThreadItem(item, 1)
                            threadToManage = null
                        },
                        modifier = Modifier.weight(1f)
                    ) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.Filled.ArrowDownward, contentDescription = null, modifier = Modifier.size(16.dp))
                            Spacer(Modifier.width(4.dp))
                            Text("Move Down", fontSize = 14.sp)
                        }
                    }
                }

                HorizontalDivider(color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.08f))

                // Color Swatches Row
                Text(
                    text = "Label Color",
                    fontSize = 13.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )

                val colorLabels = listOf(
                    ColorLabelOption("None", "#NONE#", Color.Gray.copy(alpha = 0.5f)),
                    ColorLabelOption("Amber", "#f59e0b", Color(0xFFF59E0B)),
                    ColorLabelOption("Teal", "#14b8a6", Color(0xFF14B8A6)),
                    ColorLabelOption("Red", "#ef4444", Color(0xFFEF4444)),
                    ColorLabelOption("Purple", "#a855f7", Color(0xFFA855F7)),
                    ColorLabelOption("Emerald", "#10b981", Color(0xFF10B981))
                )

                Row(
                    horizontalArrangement = Arrangement.SpaceBetween,
                    modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp)
                ) {
                    colorLabels.forEach { option ->
                        val isSelected = (item.labelColorHex ?: "#NONE#") == option.hex
                        Box(
                            contentAlignment = Alignment.Center,
                            modifier = Modifier
                                .size(42.dp)
                                .clip(RoundedCornerShape(50))
                                .background(option.color)
                                .border(
                                    width = if (isSelected) 3.dp else 1.dp,
                                    color = if (isSelected) MaterialTheme.colorScheme.primary else Color.Transparent,
                                    shape = RoundedCornerShape(50)
                                )
                                .clickableUnit {
                                    updateThreadItemMetadata(item, labelColorHex = option.hex)
                                    threadToManage = null
                                }
                        ) {
                            if (isSelected) {
                                Icon(
                                    imageVector = Icons.Filled.Check,
                                    contentDescription = "Selected",
                                    tint = Color.White,
                                    modifier = Modifier.size(18.dp)
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    showRenameDialogForThread?.let { item ->
        AlertDialog(
            onDismissRequest = { showRenameDialogForThread = null },
            title = { Text("Rename Conversation") },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("Enter a new custom title for this thread. Leave blank to reset to default.")
                    OutlinedTextField(
                        value = renameDialogText,
                        onValueChange = { renameDialogText = it },
                        placeholder = { Text(item.title) },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth()
                    )
                }
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        updateThreadItemMetadata(item, customTitle = renameDialogText)
                        showRenameDialogForThread = null
                    }
                ) {
                    Text("Save")
                }
            },
            dismissButton = {
                TextButton(
                    onClick = { showRenameDialogForThread = null }
                ) {
                    Text("Cancel")
                }
            }
        )
    }

    missionToManage?.let { mission ->
        AlertDialog(
            onDismissRequest = { missionToManage = null },
            title = { Text("Manage Mission") },
            text = { Text("Would you like to cancel this active mission or dismiss it from your console?") },
            confirmButton = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    TextButton(
                        onClick = {
                            scope.launch {
                                missionHost.cancelMission(mission.id)
                                missionHost.dismissMission(mission.id)
                            }
                            missionToManage = null
                        },
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        Text("Cancel & Dismiss", color = MaterialTheme.colorScheme.error)
                    }
                    TextButton(
                        onClick = {
                            missionHost.dismissMission(mission.id)
                            missionToManage = null
                        },
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        Text("Just Dismiss")
                    }
                    TextButton(
                        onClick = { missionToManage = null },
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        Text("Keep Running")
                    }
                }
            }
        )
    }

    pinnedAgentToManage?.let { uri ->
        val identity = registry.identity(uri)
        val index = pinned.pinnedURIs.indexOf(uri)
        AlertDialog(
            onDismissRequest = { pinnedAgentToManage = null },
            title = { Text("Rearrange ${identity?.displayName ?: "Agent"}") },
            text = { Text("Move this pinned agent within your grid or unpin it completely.") },
            confirmButton = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    if (index > 0) {
                        TextButton(
                            onClick = {
                                persistPinned(pinned.moving(index, index - 1))
                                pinnedAgentToManage = null
                            },
                            modifier = Modifier.fillMaxWidth()
                        ) {
                            Text("Move Left")
                        }
                    }
                    if (index < pinned.pinnedURIs.size - 1) {
                        TextButton(
                            onClick = {
                                persistPinned(pinned.moving(index, index + 1))
                                pinnedAgentToManage = null
                            },
                            modifier = Modifier.fillMaxWidth()
                        ) {
                            Text("Move Right")
                        }
                    }
                    TextButton(
                        onClick = {
                            persistPinned(pinned.unpinning(uri))
                            pinnedAgentToManage = null
                        },
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        Text("Unpin Agent", color = MaterialTheme.colorScheme.error)
                    }
                    TextButton(
                        onClick = { pinnedAgentToManage = null },
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        Text("Cancel")
                    }
                }
            }
        )
    }
}

private data class ColorLabelOption(
    val name: String,
    val hex: String,
    val color: Color
)

@Composable
private fun CLIAgentSessionSheet(
    session: CLIAgentSessionRecord,
    hermesService: HermesService,
    onDismiss: () -> Unit
) {
    val scope = rememberCoroutineScope()
    val transport = remember(hermesService) { CLIAgentRelayChatTransport(hermesService) }
    var isStarting by remember(session.id) { mutableStateOf(false) }
    var actionMessage by remember(session.id) { mutableStateOf<String?>(null) }
    var actionIsError by remember(session.id) { mutableStateOf(false) }

    fun startSessionAction(action: CLIAgentSessionActionKind, targetRuntime: String? = null) {
        if (isStarting) return
        isStarting = true
        actionIsError = false
        actionMessage = "Sending ${session.title} to your Mac..."
        scope.launch {
            try {
                val response = transport.performSessionAction(
                    CLIAgentSessionActionRequest(
                        sessionID = session.resumeLookupID,
                        action = action,
                        targetRuntime = targetRuntime ?: session.agent,
                    )
                )
                actionIsError = response.status == CLIAgentSessionActionStatus.ERROR
                actionMessage = if (actionIsError) {
                    response.errorRecovery ?: response.errorCode ?: "The Mac could not restart this session."
                } else {
                    when (response.status) {
                        CLIAgentSessionActionStatus.NATIVE_RESUME -> "Native resume opened on your Mac."
                        CLIAgentSessionActionStatus.HANDOFF -> "Handoff package opened on your Mac."
                        CLIAgentSessionActionStatus.PACKAGE_ONLY -> "Resume package is open on your Mac."
                        CLIAgentSessionActionStatus.SPAWNED -> "Mac session opened."
                        CLIAgentSessionActionStatus.ERROR -> "The Mac could not restart this session."
                    }
                }
            } catch (t: Throwable) {
                actionIsError = true
                actionMessage = t.message ?: "The Mac could not restart this session."
            } finally {
                isStarting = false
            }
        }
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black.copy(alpha = 0.48f))
            .clickableUnit(onClick = onDismiss)
    ) {
        Surface(
            shape = RoundedCornerShape(topStart = 24.dp, topEnd = 24.dp),
            color = MaterialTheme.colorScheme.surface.copy(alpha = 0.96f),
            tonalElevation = 4.dp,
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .fillMaxWidth()
                .height(560.dp)
        ) {
            Column(
                verticalArrangement = Arrangement.spacedBy(10.dp),
                modifier = Modifier
                    .fillMaxSize()
                    .padding(18.dp)
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            session.title,
                            fontSize = 17.sp,
                            fontWeight = FontWeight.Bold,
                            color = MaterialTheme.colorScheme.onSurface,
                            maxLines = 2,
                            overflow = TextOverflow.Ellipsis
                        )
                        Text(
                            listOf(session.agent, session.modelName.orEmpty(), session.workspaceLabel.orEmpty())
                                .filter { it.isNotBlank() }
                                .joinToString(" · "),
                            fontSize = 11.sp,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis
                        )
                    }
                    IconButton(onClick = onDismiss) {
                        Icon(
                            imageVector = Icons.Filled.Close,
                            contentDescription = "Close",
                            tint = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }

                HorizontalDivider(color = MaterialTheme.colorScheme.outline.copy(alpha = 0.22f))

                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth()) {
                        Button(
                            onClick = { startSessionAction(CLIAgentSessionActionKind.RESUME) },
                            enabled = !isStarting,
                            modifier = Modifier.weight(1f)
                        ) {
                            Text(if (isStarting) "Starting..." else "Resume on Mac")
                        }
                        TextButton(
                            onClick = { startSessionAction(CLIAgentSessionActionKind.PACKAGE_ONLY) },
                            enabled = !isStarting,
                            modifier = Modifier.weight(1f)
                        ) {
                            Text("Open package")
                        }
                    }
                    Text(
                        text = actionMessage ?: if (session.canResume) "Native resume is available when the Mac validates this handle." else "This provider uses a Mac-local handoff package.",
                        fontSize = 11.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = if (actionIsError) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis
                    )
                }

                if (session.messages.isEmpty()) {
                    Text(
                        session.preview.ifBlank { "No mirrored messages yet." },
                        fontSize = 12.sp,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(top = 8.dp)
                    )
                } else {
                    Column(
                        verticalArrangement = Arrangement.spacedBy(10.dp),
                        modifier = Modifier
                            .fillMaxWidth()
                            .weight(1f)
                            .verticalScroll(rememberScrollState())
                    ) {
                        session.messages.forEach { message ->
                            CLIAgentMessageBubble(message = message)
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun CLIAgentMessageBubble(message: CLIAgentMessage) {
    val isUser = message.role.equals("user", ignoreCase = true)
    Surface(
        shape = RoundedCornerShape(12.dp),
        color = if (isUser) MaterialTheme.colorScheme.primary.copy(alpha = 0.16f)
        else MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.55f),
        modifier = Modifier.fillMaxWidth()
    ) {
        Column(
            verticalArrangement = Arrangement.spacedBy(6.dp),
            modifier = Modifier.padding(12.dp)
        ) {
            Text(
                message.role.uppercase(),
                fontSize = 10.sp,
                fontWeight = FontWeight.Bold,
                color = if (message.isError) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant
            )
            if (message.text.isNotBlank()) {
                Text(
                    message.text,
                    fontSize = 12.sp,
                    color = MaterialTheme.colorScheme.onSurface
                )
            }
            if (message.toolUses.isNotEmpty()) {
                LazyRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    items(message.toolUses, key = { it.id }) { tool ->
                        Surface(
                            shape = RoundedCornerShape(999.dp),
                            color = MaterialTheme.colorScheme.primary.copy(alpha = 0.12f)
                        ) {
                            Text(
                                listOf(tool.name, tool.status, tool.detail.orEmpty())
                                    .filter { it.isNotBlank() }
                                    .joinToString(" · "),
                                fontSize = 10.sp,
                                color = MaterialTheme.colorScheme.primary,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                                modifier = Modifier.padding(horizontal = 9.dp, vertical = 5.dp)
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun CloudSessionResultSheet(
    row: CloudConversationSearchRow,
    activityStore: ActivityStore,
    onDismiss: () -> Unit
) {
    var bodyText by remember(row.id) { mutableStateOf<String?>(null) }
    var errorText by remember(row.id) { mutableStateOf<String?>(null) }
    var isLoading by remember(row.id) { mutableStateOf(true) }

    LaunchedEffect(row.id) {
        isLoading = true
        errorText = null
        bodyText = null
        runCatching { activityStore.loadCloudConversationBody(row) }
            .onSuccess { bodyText = it }
            .onFailure { errorText = it.message ?: it::class.java.simpleName }
        isLoading = false
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black.copy(alpha = 0.48f))
            .clickableUnit(onClick = onDismiss)
    ) {
        Surface(
            shape = RoundedCornerShape(topStart = 24.dp, topEnd = 24.dp),
            color = MaterialTheme.colorScheme.surface.copy(alpha = 0.96f),
            tonalElevation = 4.dp,
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .fillMaxWidth()
                .height(520.dp)
        ) {
            Column(
                verticalArrangement = Arrangement.spacedBy(10.dp),
                modifier = Modifier
                    .fillMaxSize()
                    .padding(18.dp)
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            row.title,
                            fontSize = 17.sp,
                            fontWeight = FontWeight.Bold,
                            color = MaterialTheme.colorScheme.onSurface,
                            maxLines = 2,
                            overflow = TextOverflow.Ellipsis
                        )
                        Text(
                            listOfNotNull(row.provider, row.projectName).joinToString(" · ")
                                .ifBlank { "Encrypted cloud session" },
                            fontSize = 11.sp,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis
                        )
                    }
                    IconButton(onClick = onDismiss) {
                        Icon(
                            imageVector = Icons.Filled.Close,
                            contentDescription = "Close",
                            tint = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }

                Text(
                    row.snippet,
                    fontSize = 12.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 3,
                    overflow = TextOverflow.Ellipsis
                )

                HorizontalDivider(color = MaterialTheme.colorScheme.outline.copy(alpha = 0.22f))

                when {
                    isLoading -> {
                        Row(
                            horizontalArrangement = Arrangement.spacedBy(10.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier.padding(top = 12.dp)
                        ) {
                            CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp)
                            Text(
                                "Decrypting transcript…",
                                fontSize = 12.sp,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        }
                    }
                    errorText != null -> {
                        Text(
                            errorText ?: "Unable to open encrypted transcript.",
                            fontSize = 12.sp,
                            color = MaterialTheme.colorScheme.error
                        )
                    }
                    else -> {
                        Text(
                            bodyText.orEmpty(),
                            fontSize = 12.sp,
                            color = MaterialTheme.colorScheme.onSurface,
                            modifier = Modifier
                                .fillMaxWidth()
                                .weight(1f)
                                .verticalScroll(rememberScrollState())
                        )
                    }
                }
            }
        }
    }
}

// MARK: - Phase D voice entry

@Composable
private fun PhaseDVoiceEntry(
    onTap: () -> Unit,
    modifier: Modifier = Modifier
) {
    Surface(
        shape = RoundedCornerShape(12.dp),
        color = MaterialTheme.colorScheme.tertiary.copy(alpha = 0.12f),
        tonalElevation = 0.5.dp,
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
                imageVector = Icons.Filled.Mic,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.tertiary,
                modifier = Modifier.size(20.dp)
            )
            Spacer(modifier = Modifier.width(10.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    "Voice command",
                    fontSize = 13.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = MaterialTheme.colorScheme.onSurface
                )
                Text(
                    "Hold to talk — \"open Claude\", \"what's important?\", or dispatch a brief.",
                    fontSize = 11.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis
                )
            }
            Icon(
                imageVector = Icons.Filled.ChevronRight,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.size(16.dp)
            )
        }
    }
}

// MARK: - Phase B fan-out entry

@Composable
private fun PhaseBFanOutEntry(
    onTap: () -> Unit,
    modifier: Modifier = Modifier
) {
    Surface(
        shape = RoundedCornerShape(12.dp),
        color = MaterialTheme.colorScheme.primary.copy(alpha = 0.12f),
        tonalElevation = 0.5.dp,
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
                imageVector = Icons.Filled.Bolt,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.primary,
                modifier = Modifier.size(20.dp)
            )
            Spacer(modifier = Modifier.width(10.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    "Fan-out to multiple runtimes",
                    fontSize = 13.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = MaterialTheme.colorScheme.onSurface
                )
                Text(
                    "Dispatch the same brief to Claude + Codex + Hermes in parallel.",
                    fontSize = 11.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis
                )
            }
            Icon(
                imageVector = Icons.Filled.ChevronRight,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.size(16.dp)
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
            Box(contentAlignment = Alignment.BottomEnd, modifier = Modifier.size(40.dp)) {
                com.openburnbar.ui.components.BurnBarAgentAvatar(
                    identity = identity,
                    size = 40.dp
                )
                if (identity.availability != AgentAvailability.UNKNOWN) {
                    Box(
                        modifier = Modifier
                            .size(10.dp)
                            .clip(RoundedCornerShape(50))
                            .background(availabilityColor(identity.availability))
                            .border(1.5.dp, MaterialTheme.colorScheme.surface, RoundedCornerShape(50))
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
private fun ActiveMissionsStrip(
    missions: List<com.openburnbar.data.missions.ActiveMission>,
    onLongPress: (com.openburnbar.data.missions.ActiveMission) -> Unit,
    onComposeMission: () -> Unit,
    modifier: Modifier = Modifier
) {
    Column(modifier = modifier.fillMaxWidth()) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.fillMaxWidth().padding(end = 16.dp)
        ) {
            Text(
                "Active missions",
                fontSize = 11.sp,
                fontWeight = FontWeight.Bold,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            Spacer(modifier = Modifier.weight(1f))
            TextButton(
                onClick = onComposeMission,
                contentPadding = PaddingValues(horizontal = 4.dp, vertical = 2.dp),
                modifier = Modifier.height(24.dp)
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(
                        imageVector = Icons.Filled.Add,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.primary,
                        modifier = Modifier.size(10.dp)
                    )
                    Spacer(modifier = Modifier.width(3.dp))
                    Text(
                        "Compose",
                        fontSize = 10.sp,
                        fontWeight = FontWeight.Bold,
                        color = MaterialTheme.colorScheme.primary
                    )
                }
            }
        }
        Spacer(modifier = Modifier.height(8.dp))
        if (missions.isEmpty()) {
            Surface(
                shape = RoundedCornerShape(12.dp),
                color = MaterialTheme.colorScheme.surface.copy(alpha = 0.6f),
                tonalElevation = 0.5.dp,
                modifier = Modifier
                    .width(280.dp)
                    .height(110.dp)
                    .clickable { onComposeMission() }
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
                        "No live missions. Tap here to compose one.",
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        fontSize = 11.sp,
                        maxLines = 3,
                        overflow = TextOverflow.Ellipsis
                    )
                }
            }
        } else {
            LazyRow(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                items(missions, key = { it.id }) { mission ->
                    HermesSquareMissionTile(
                        tile = mission,
                        onLongPress = { onLongPress(mission) },
                        modifier = Modifier.width(260.dp)
                    )
                }
                item { Spacer(modifier = Modifier.width(0.dp)) }
            }
        }
    }
}

// MARK: - Project Memory Wiki

@Composable
private fun ProjectMemoryWikiSection(
    projects: List<com.openburnbar.data.models.ProjectSummary>,
    onOpenProject: (com.openburnbar.data.models.ProjectSummary) -> Unit,
    onAskWiki: (com.openburnbar.data.models.ProjectSummary) -> Unit,
    modifier: Modifier = Modifier
) {
    Column(modifier = modifier.fillMaxWidth()) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                "Project Memory Wiki",
                fontSize = 11.sp,
                fontWeight = FontWeight.Bold,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            Spacer(modifier = Modifier.weight(1f))
            Text(
                "Ask /wiki",
                fontSize = 11.sp,
                fontWeight = FontWeight.Bold,
                color = MaterialTheme.colorScheme.primary
            )
        }
        Spacer(modifier = Modifier.height(8.dp))
        if (projects.isEmpty()) {
            Text(
                "No project memory yet. Start with `/wiki` in Hermes to build one.",
                fontSize = 11.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(vertical = 6.dp)
            )
        } else {
            for (project in projects) {
                Surface(
                    shape = RoundedCornerShape(10.dp),
                    color = MaterialTheme.colorScheme.surface.copy(alpha = 0.5f),
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(bottom = 6.dp)
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier.padding(horizontal = 12.dp, vertical = 10.dp)
                    ) {
                        Column(modifier = Modifier.weight(1f)) {
                            Text(
                                project.name.ifBlank { project.id },
                                fontSize = 13.sp,
                                fontWeight = FontWeight.Bold,
                                color = MaterialTheme.colorScheme.onSurface,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis
                            )
                            Text(
                                "${project.totalSessions} sessions · ${project.totalTokens} tokens · $${"%.2f".format(project.totalCost)}",
                                fontSize = 10.sp,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis
                            )
                        }
                        Surface(
                            shape = RoundedCornerShape(999.dp),
                            color = MaterialTheme.colorScheme.primary.copy(alpha = 0.15f),
                            modifier = Modifier
                                .clip(RoundedCornerShape(999.dp))
                                .clickable { onAskWiki(project) }
                        ) {
                            Text(
                                "/wiki",
                                fontSize = 11.sp,
                                fontWeight = FontWeight.Bold,
                                color = MaterialTheme.colorScheme.primary,
                                modifier = Modifier.padding(horizontal = 10.dp, vertical = 5.dp)
                            )
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Rollback sections list

@Composable
private fun RollbackSectionsList(
    snapshotsBySession: Map<String, List<com.openburnbar.data.missions.RollbackSnapshot>>,
    onSubmit: (sessionID: String, scope: com.openburnbar.data.missions.RollbackScope) -> Unit,
    modifier: Modifier = Modifier
) {
    val sortedSessions = remember(snapshotsBySession) {
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
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
        Spacer(modifier = Modifier.height(8.dp))
        for ((sessionID, snapshots) in sortedSessions) {
            RollbackCardView(
                sessionID = sessionID,
                snapshots = snapshots,
                onSubmit = { scope -> onSubmit(sessionID, scope) },
                modifier = Modifier.padding(bottom = 8.dp)
            )
        }
    }
}

// MARK: - Helper: record an approval policy from an ask

private fun recordApprovalPolicy(
    store: ApprovalPolicyStore,
    ask: ApprovalAsk,
    decision: ApprovalDecision,
) {
    val scopeKey = "runtime=${ask.runtimeID ?: "any"}"
    val policy = ApprovalPolicy(
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
    onLongPress: () -> Unit,
    modifier: Modifier = Modifier
) {
    val identity = registry.identity(item.agentURI)
    Surface(
        shape = RoundedCornerShape(10.dp),
        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.5f),
        tonalElevation = 0.5.dp,
        modifier = modifier
            .fillMaxWidth()
            .clickableLongPress(onClick = onTap, onLongClick = onLongPress)
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .height(IntrinsicSize.Min)
        ) {
            // Left accent color bar if labelColorHex exists
            val colorHex = item.labelColorHex
            if (!colorHex.isNullOrBlank()) {
                val parsedColor = remember(colorHex) {
                    try { hexColor(colorHex) } catch (e: Exception) { Color.Transparent }
                }
                if (parsedColor != Color.Transparent) {
                    Box(
                        modifier = Modifier
                            .fillMaxHeight()
                            .width(4.dp)
                            .background(parsedColor)
                    )
                }
            }

            Row(
                verticalAlignment = Alignment.Top,
                modifier = Modifier
                    .weight(1f)
                    .padding(horizontal = 12.dp, vertical = 10.dp)
            ) {
                if (identity != null) {
                    com.openburnbar.ui.components.BurnBarAgentAvatar(
                        identity = identity,
                        size = 36.dp
                    )
                } else {
                    com.openburnbar.ui.components.ProviderLogoView(
                        drawableRes = com.openburnbar.ui.components.ProviderLogo.drawableForAnyIdentifier(
                            item.agentURI
                        ),
                        size = 36.dp,
                        style = com.openburnbar.ui.components.ProviderLogoStyle.Disc
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
                        if (item.isPinned) {
                            Spacer(modifier = Modifier.width(4.dp))
                            Icon(
                                imageVector = Icons.Filled.PushPin,
                                contentDescription = "Pinned",
                                tint = AuroraColors.ember,
                                modifier = Modifier.size(10.dp)
                            )
                        }
                        Spacer(modifier = Modifier.weight(1f))
                        Text(
                            relativeTime(item.lastActivityAtEpoch),
                            fontSize = 10.sp,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                    Text(
                        item.customTitle ?: item.title,
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
    val score: Double,
    val cloudRow: CloudConversationSearchRow? = null
) {
    enum class Kind { AGENT, THREAD, CLOUD_SESSION }
}

private fun CloudConversationSearchRow.toHermesSquareHit(): HermesSquareHit =
    HermesSquareHit(
        id = "cloud:$id",
        kind = HermesSquareHit.Kind.CLOUD_SESSION,
        title = title,
        preview = listOfNotNull(provider, projectName, snippet)
            .joinToString(" · ")
            .ifBlank { snippet },
        score = score + 0.15,
        cloudRow = this
    )

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
        val haystack = item.searchText.lowercase()
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
                "No matches. Try a name, runtime, file, session text, or tool.",
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
