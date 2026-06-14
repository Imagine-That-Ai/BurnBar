// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.square

import android.content.SharedPreferences
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Scaffold
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.openburnbar.data.assistants.AssistantChatHistoryStore
import com.openburnbar.data.cloud.CloudConversationSearchRow
import com.openburnbar.data.hermes.AssistantRuntimeID
import com.openburnbar.data.hermes.HermesConnectionRecord
import com.openburnbar.data.hermes.HermesService
import com.openburnbar.data.hermes.refreshRelayConnections
import com.openburnbar.data.missions.ActiveMission
import com.openburnbar.data.missions.ApprovalAsk
import com.openburnbar.data.missions.ApprovalDecision
import com.openburnbar.data.missions.ApprovalPolicyStore
import com.openburnbar.data.missions.MissionConsoleSnapshot
import com.openburnbar.data.missions.MissionGroupObserver
import com.openburnbar.data.missions.MissionGroupSnapshot
import com.openburnbar.data.missions.MobileMissionConsoleHost
import com.openburnbar.data.missions.RollbackScope
import com.openburnbar.data.missions.RollbackService
import com.openburnbar.data.missions.RollbackSnapshot
import com.openburnbar.data.models.ProjectSummary
import com.openburnbar.data.projects.ProjectsStore
import com.openburnbar.data.square.AgentAvailability
import com.openburnbar.data.square.AgentIdentity
import com.openburnbar.data.square.AgentIdentityRegistry
import com.openburnbar.data.square.CLIAgentSessionRecord
import com.openburnbar.data.square.HermesSquareFeatureFlags
import com.openburnbar.data.square.MercuryPairedMacTilePreference
import com.openburnbar.data.square.PinnedAgentGridConfig
import com.openburnbar.data.square.ThreadInboxItem
import com.openburnbar.data.square.ThreadInboxStore
import com.openburnbar.data.square.splitForInbox
import com.openburnbar.data.stores.ActivityStore
import com.openburnbar.ui.components.AuroraBackdrop
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun HermesSquareScreenContent(
    onOpenLegacyRuntime: (AssistantRuntimeID, String?) -> Unit = { _, _ -> },
    onOpenBrandZone: (String) -> Unit = {},
    onOpenPairedMac: (String) -> Unit = {},
) {
    val (state, actions) =
        rememberHermesSquareUiState(
            onOpenLegacyRuntime = onOpenLegacyRuntime,
            onOpenBrandZone = onOpenBrandZone,
            onOpenPairedMac = onOpenPairedMac,
        )
    HermesSquareScaffold(
        state = state,
        actions = actions,
    )
    HermesSquareOverlays(state = state, actions = actions)
}

internal data class HermesSquareUiState(
    val registry: AgentIdentityRegistry,
    val hermesService: HermesService,
    val inbox: ThreadInboxStore,
    val activityStore: ActivityStore,
    val missionHost: MobileMissionConsoleHost,
    val rollbackService: RollbackService,
    val approvalPolicyStore: ApprovalPolicyStore,
    val scope: CoroutineScope,
    val flags: HermesSquareFeatureFlags,
    val cloudHits: List<CloudConversationSearchRow>,
    val missionSnapshot: MissionConsoleSnapshot,
    val groupSnapshot: MissionGroupSnapshot,
    val snapshotsBySession: Map<String, List<RollbackSnapshot>>,
    val projectSummaries: List<ProjectSummary>,
    val pinned: PinnedAgentGridConfig,
    val query: String,
    val showDiscover: Boolean,
    val showSubscriptions: Boolean,
    val showBrandZoneURI: String?,
    val showFanOut: Boolean,
    val showVoice: Boolean,
    val voiceBanner: AndroidVoiceIntent?,
    val selectedCloudRow: CloudConversationSearchRow?,
    val selectedCliSession: CLIAgentSessionRecord?,
    val threadToManage: ThreadInboxItem?,
    val showRenameDialogForThread: ThreadInboxItem?,
    val renameDialogText: String,
    val missionToManage: ActiveMission?,
    val pinnedAgentToManage: String?,
    val splitInbox: Pair<List<ThreadInboxItem>, List<ThreadInboxItem>>,
    val filteredHits: List<HermesSquareHit>,
)

internal data class HermesSquareUiActions(
    val onQueryChange: (String) -> Unit,
    val persistPinned: (PinnedAgentGridConfig) -> Unit,
    val updateThreadItemMetadata: (
        item: ThreadInboxItem,
        customTitle: String?,
        labelColorHex: String?,
        isPinned: Boolean?,
        priorityOrder: Int?,
    ) -> Unit,
    val moveThreadItem: (ThreadInboxItem, Int) -> Unit,
    val onSearchHitTap: (HermesSquareHit) -> Unit,
    val onThreadTap: (ThreadInboxItem) -> Unit,
    val onThreadLongPress: (ThreadInboxItem) -> Unit,
    val onPinnedTap: (String) -> Unit,
    val onPinnedLongPress: (String) -> Unit,
    val setShowDiscover: (Boolean) -> Unit,
    val setShowSubscriptions: (Boolean) -> Unit,
    val setShowBrandZoneURI: (String?) -> Unit,
    val setShowFanOut: (Boolean) -> Unit,
    val setShowVoice: (Boolean) -> Unit,
    val setVoiceBanner: (AndroidVoiceIntent?) -> Unit,
    val setSelectedCloudRow: (CloudConversationSearchRow?) -> Unit,
    val setSelectedCliSession: (CLIAgentSessionRecord?) -> Unit,
    val setThreadToManage: (ThreadInboxItem?) -> Unit,
    val setShowRenameDialogForThread: (ThreadInboxItem?) -> Unit,
    val setRenameDialogText: (String) -> Unit,
    val setMissionToManage: (ActiveMission?) -> Unit,
    val setPinnedAgentToManage: (String?) -> Unit,
    val onApproveAsk: (ApprovalAsk, Boolean) -> Unit,
    val onApproveAlways: (ApprovalAsk) -> Unit,
    val onDenyAlways: (ApprovalAsk) -> Unit,
    val onRollbackSubmit: (String, RollbackScope) -> Unit,
    val onMissionCancelDismiss: (ActiveMission) -> Unit,
    val onMissionDismiss: (ActiveMission) -> Unit,
)

internal class HermesSquareOverlayFields {
    var query by mutableStateOf("")
    var showDiscover by mutableStateOf(false)
    var showSubscriptions by mutableStateOf(false)
    var showBrandZoneURI by mutableStateOf<String?>(null)
    var showFanOut by mutableStateOf(false)
    var showVoice by mutableStateOf(false)
    var voiceBanner by mutableStateOf<AndroidVoiceIntent?>(null)
    var selectedCloudRow by mutableStateOf<CloudConversationSearchRow?>(null)
    var selectedCliSession by mutableStateOf<CLIAgentSessionRecord?>(null)
    var threadToManage by mutableStateOf<ThreadInboxItem?>(null)
    var showRenameDialogForThread by mutableStateOf<ThreadInboxItem?>(null)
    var renameDialogText by mutableStateOf("")
    var missionToManage by mutableStateOf<ActiveMission?>(null)
    var pinnedAgentToManage by mutableStateOf<String?>(null)
}

internal data class HermesSquareServiceCore(
    val context: android.content.Context,
    val registry: AgentIdentityRegistry,
    val hermesService: HermesService,
    val inbox: ThreadInboxStore,
    val activityStore: ActivityStore,
    val missionHost: MobileMissionConsoleHost,
    val rollbackService: RollbackService,
    val approvalPolicyStore: ApprovalPolicyStore,
    val projectsStore: ProjectsStore,
    val scope: kotlinx.coroutines.CoroutineScope,
    val historyStore: AssistantChatHistoryStore,
    val flags: HermesSquareFeatureFlags,
    val cloudHits: List<CloudConversationSearchRow>,
    val missionSnapshot: MissionConsoleSnapshot,
    val groupSnapshot: MissionGroupSnapshot,
    val snapshotsBySession: Map<String, List<RollbackSnapshot>>,
    val projectSummaries: List<ProjectSummary>,
    val hermesConnections: List<HermesConnectionRecord>,
)

internal data class HermesSquarePinnedGridState(
    val pinned: PinnedAgentGridConfig,
    val persistPinned: (PinnedAgentGridConfig) -> Unit,
    val mercuryPinnedTileEnabled: Boolean,
)

internal data class HermesSquareDerivedData(
    val splitInbox: Pair<List<ThreadInboxItem>, List<ThreadInboxItem>>,
    val filteredHits: List<HermesSquareHit>,
    val moveThreadItem: (ThreadInboxItem, Int) -> Unit,
    val updateThreadItemMetadata: (
        ThreadInboxItem,
        String?,
        String?,
        Boolean?,
        Int?,
    ) -> Unit,
)

@Composable
private fun rememberHermesSquareOverlayFields(): HermesSquareOverlayFields = remember { HermesSquareOverlayFields() }

@Composable
private fun rememberHermesSquareServiceCore(): HermesSquareServiceCore {
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
    val historyStore = remember(context) { AssistantChatHistoryStore.shared(context.applicationContext) }
    val flags = remember(context) { HermesSquareFeatureFlags.shared(context) }
    return HermesSquareServiceCore(
        context = context,
        registry = registry,
        hermesService = hermesService,
        inbox = inbox,
        activityStore = activityStore,
        missionHost = missionHost,
        rollbackService = rollbackService,
        approvalPolicyStore = approvalPolicyStore,
        projectsStore = projectsStore,
        scope = scope,
        historyStore = historyStore,
        flags = flags,
        cloudHits = cloudHits,
        missionSnapshot = missionSnapshot,
        groupSnapshot = groupSnapshot,
        snapshotsBySession = snapshotsBySession,
        projectSummaries = projectSummaries,
        hermesConnections = hermesConnections,
    )
}

@Composable
private fun rememberHermesSquarePinnedGridState(context: android.content.Context): HermesSquarePinnedGridState {
    val pinnedPrefs =
        remember {
            context.applicationContext.getSharedPreferences("square.pinned_grid", android.content.Context.MODE_PRIVATE)
        }
    var pinned by remember {
        mutableStateOf(PinnedAgentGridConfig.fromJsonString(pinnedPrefs.getString(PinnedAgentGridConfig.SHARED_PREFS_KEY, null)))
    }
    val persistPinned: (PinnedAgentGridConfig) -> Unit = { next ->
        pinned = next
        pinnedPrefs.edit().putString(PinnedAgentGridConfig.SHARED_PREFS_KEY, next.toJsonString()).apply()
    }
    val mercuryTilePrefs =
        remember(context) {
            context.applicationContext.getSharedPreferences(MercuryPairedMacTilePreference.PREFS_NAME, android.content.Context.MODE_PRIVATE)
        }
    var mercuryPinnedTileEnabled by remember(context) { mutableStateOf(MercuryPairedMacTilePreference.isEnabled(context)) }
    DisposableEffect(mercuryTilePrefs) {
        val listener =
            SharedPreferences.OnSharedPreferenceChangeListener { _, key ->
                if (key == MercuryPairedMacTilePreference.ENABLED_KEY) {
                    mercuryPinnedTileEnabled = MercuryPairedMacTilePreference.isEnabled(context)
                }
            }
        mercuryTilePrefs.registerOnSharedPreferenceChangeListener(listener)
        onDispose { mercuryTilePrefs.unregisterOnSharedPreferenceChangeListener(listener) }
    }
    return HermesSquarePinnedGridState(
        pinned = pinned,
        persistPinned = persistPinned,
        mercuryPinnedTileEnabled = mercuryPinnedTileEnabled,
    )
}

private fun hermesSquareThreadMetadataUpdater(
    core: HermesSquareServiceCore,
): (
    ThreadInboxItem,
    String?,
    String?,
    Boolean?,
    Int?,
) -> Unit = { item, customTitle, labelColorHex, isPinned, priorityOrder ->
    core.scope.launch {
        if (item.id.startsWith("cli:")) {
            core.inbox.updateSessionMetadata(
                id = item.id.removePrefix("cli:"),
                customTitle = customTitle,
                labelColorHex = labelColorHex,
                isPinned = isPinned,
                priorityOrder = priorityOrder,
            )
        } else {
            core.historyStore.updateThreadMetadata(
                id = item.id.substringAfter(":"),
                customTitle = customTitle,
                labelColorHex = labelColorHex,
                isPinned = isPinned,
                priorityOrder = priorityOrder,
            )
        }
    }
}

private fun hermesSquareMoveThreadItem(
    splitInbox: Pair<List<ThreadInboxItem>, List<ThreadInboxItem>>,
    updateThreadItemMetadata: (ThreadInboxItem, String?, String?, Boolean?, Int?) -> Unit,
): (ThreadInboxItem, Int) -> Unit = moveThreadItem@{ item, direction ->
    val (service, _) = splitInbox
    val index = service.indexOfFirst { it.id == item.id }
    if (index == -1) return@moveThreadItem
    val targetIndex = index + direction
    if (targetIndex !in service.indices) return@moveThreadItem
    val list = service.toMutableList()
    val temp = list[index]
    list[index] = list[targetIndex]
    list[targetIndex] = temp
    list.forEachIndexed { i, threadItem -> updateThreadItemMetadata(threadItem, null, null, null, i + 1) }
}

@Composable
private fun rememberHermesSquareFilteredHits(core: HermesSquareServiceCore, overlay: HermesSquareOverlayFields) =
    remember(overlay.query, core.inbox.items, core.registry.identities, core.cloudHits) {
        derivedStateOf {
            val q = overlay.query.trim()
            if (q.isBlank()) {
                emptyList()
            } else {
                (runQuickSearch(q, core.registry, core.inbox) + core.cloudHits.map { it.toHermesSquareHit() })
                    .sortedByDescending { it.score }
                    .take(30)
            }
        }
    }

@Composable
private fun rememberHermesSquareDerivedData(core: HermesSquareServiceCore, overlay: HermesSquareOverlayFields): HermesSquareDerivedData {
    val updateThreadItemMetadata = remember(core) { hermesSquareThreadMetadataUpdater(core) }
    val splitInbox by remember(core.inbox.items) { derivedStateOf { core.inbox.items.splitForInbox() } }
    val moveThreadItem = remember(splitInbox, updateThreadItemMetadata) {
        hermesSquareMoveThreadItem(splitInbox, updateThreadItemMetadata)
    }
    val filteredHits by rememberHermesSquareFilteredHits(core, overlay)
    return HermesSquareDerivedData(
        splitInbox = splitInbox,
        filteredHits = filteredHits,
        moveThreadItem = moveThreadItem,
        updateThreadItemMetadata = updateThreadItemMetadata,
    )
}

@Composable
private fun HermesSquareUiRuntimeEffects(core: HermesSquareServiceCore, pinned: HermesSquarePinnedGridState, overlay: HermesSquareOverlayFields) {
    HermesSquareBootstrapEffects(
        HermesSquareBootstrapDeps(
            inbox = core.inbox,
            historyStore = core.historyStore,
            missionHost = core.missionHost,
            rollbackService = core.rollbackService,
            projectsStore = core.projectsStore,
            registry = core.registry,
            hermesService = core.hermesService,
        ),
    )
    HermesSquareMercuryPinEffect(
        hermesConnections = core.hermesConnections,
        mercuryPinnedTileEnabled = pinned.mercuryPinnedTileEnabled,
        pinned = pinned.pinned,
        persistPinned = pinned.persistPinned,
        registry = core.registry,
    )
    HermesSquareMissionRollbackEffect(missionSnapshot = core.missionSnapshot, rollbackService = core.rollbackService)
    LaunchedEffect(overlay.query) { core.activityStore.updateSearch(overlay.query) }
}

private fun buildHermesSquareNavigationHandlers(
    core: HermesSquareServiceCore,
    overlay: HermesSquareOverlayFields,
    onOpenLegacyRuntime: (AssistantRuntimeID, String?) -> Unit,
    onOpenBrandZone: (String) -> Unit,
    onOpenPairedMac: (String) -> Unit,
): Triple<(HermesSquareHit) -> Unit, (ThreadInboxItem) -> Unit, (String) -> Unit> {
    fun openBrandZone(uri: String) {
        overlay.showBrandZoneURI = uri
        onOpenBrandZone(uri)
    }

    val onSearchHitTap: (HermesSquareHit) -> Unit = { hit ->
        when (hit.kind) {
            HermesSquareHit.Kind.AGENT -> {
                val identity = core.registry.identity(hit.id)
                val runtime = identity?.runtimeID
                if (runtime != null && (runtime == AssistantRuntimeID.HERMES || runtime == AssistantRuntimeID.PI)) {
                    onOpenLegacyRuntime(runtime, null)
                } else {
                    openBrandZone(hit.id)
                }
            }
            HermesSquareHit.Kind.THREAD -> {
                val item = core.inbox.items.firstOrNull { it.id == hit.id }
                val cliSession = item?.takeIf { it.source == ThreadInboxItem.Source.CLI_MIRROR }?.let { core.inbox.cliSessionFor(it) }
                val runtime = item?.agentURI?.let { AgentIdentity.builtInRuntime(it) }
                when {
                    cliSession != null -> overlay.selectedCliSession = cliSession
                    runtime != null -> onOpenLegacyRuntime(runtime, hit.id)
                }
            }
            HermesSquareHit.Kind.CLOUD_SESSION -> overlay.selectedCloudRow = hit.cloudRow
        }
    }
    val onThreadTap: (ThreadInboxItem) -> Unit = { item ->
        val cliSession = item.takeIf { it.source == ThreadInboxItem.Source.CLI_MIRROR }?.let { core.inbox.cliSessionFor(it) }
        val runtime = AgentIdentity.builtInRuntime(item.agentURI)
        when {
            cliSession != null -> overlay.selectedCliSession = cliSession
            runtime != null -> onOpenLegacyRuntime(runtime, item.id)
            else -> openBrandZone(item.agentURI)
        }
    }
    val onPinnedTap: (String) -> Unit = { uri ->
        val runtime = core.registry.identity(uri)?.runtimeID
        when {
            uri.startsWith(AgentIdentity.PAIRED_MAC_URI_PREFIX) -> onOpenPairedMac(uri.removePrefix(AgentIdentity.PAIRED_MAC_URI_PREFIX))
            runtime != null -> onOpenLegacyRuntime(runtime, null)
            else -> openBrandZone(uri)
        }
    }
    return Triple(onSearchHitTap, onThreadTap, onPinnedTap)
}

private fun buildHermesSquareUiState(
    core: HermesSquareServiceCore,
    pinned: HermesSquarePinnedGridState,
    overlay: HermesSquareOverlayFields,
    derived: HermesSquareDerivedData,
): HermesSquareUiState = HermesSquareUiState(
    registry = core.registry,
    hermesService = core.hermesService,
    inbox = core.inbox,
    activityStore = core.activityStore,
    missionHost = core.missionHost,
    rollbackService = core.rollbackService,
    approvalPolicyStore = core.approvalPolicyStore,
    scope = core.scope,
    flags = core.flags,
    cloudHits = core.cloudHits,
    missionSnapshot = core.missionSnapshot,
    groupSnapshot = core.groupSnapshot,
    snapshotsBySession = core.snapshotsBySession,
    projectSummaries = core.projectSummaries,
    pinned = pinned.pinned,
    query = overlay.query,
    showDiscover = overlay.showDiscover,
    showSubscriptions = overlay.showSubscriptions,
    showBrandZoneURI = overlay.showBrandZoneURI,
    showFanOut = overlay.showFanOut,
    showVoice = overlay.showVoice,
    voiceBanner = overlay.voiceBanner,
    selectedCloudRow = overlay.selectedCloudRow,
    selectedCliSession = overlay.selectedCliSession,
    threadToManage = overlay.threadToManage,
    showRenameDialogForThread = overlay.showRenameDialogForThread,
    renameDialogText = overlay.renameDialogText,
    missionToManage = overlay.missionToManage,
    pinnedAgentToManage = overlay.pinnedAgentToManage,
    splitInbox = derived.splitInbox,
    filteredHits = derived.filteredHits,
)

private fun buildHermesSquareUiActions(
    core: HermesSquareServiceCore,
    pinned: HermesSquarePinnedGridState,
    overlay: HermesSquareOverlayFields,
    derived: HermesSquareDerivedData,
    navigation: Triple<(HermesSquareHit) -> Unit, (ThreadInboxItem) -> Unit, (String) -> Unit>,
): HermesSquareUiActions {
    val (onSearchHitTap, onThreadTap, onPinnedTap) = navigation
    return HermesSquareUiActions(
        onQueryChange = { overlay.query = it },
        persistPinned = pinned.persistPinned,
        updateThreadItemMetadata = derived.updateThreadItemMetadata,
        moveThreadItem = derived.moveThreadItem,
        onSearchHitTap = onSearchHitTap,
        onThreadTap = onThreadTap,
        onThreadLongPress = { overlay.threadToManage = it },
        onPinnedTap = onPinnedTap,
        onPinnedLongPress = { overlay.pinnedAgentToManage = it },
        setShowDiscover = { overlay.showDiscover = it },
        setShowSubscriptions = { overlay.showSubscriptions = it },
        setShowBrandZoneURI = { overlay.showBrandZoneURI = it },
        setShowFanOut = { overlay.showFanOut = it },
        setShowVoice = { overlay.showVoice = it },
        setVoiceBanner = { overlay.voiceBanner = it },
        setSelectedCloudRow = { overlay.selectedCloudRow = it },
        setSelectedCliSession = { overlay.selectedCliSession = it },
        setThreadToManage = { overlay.threadToManage = it },
        setShowRenameDialogForThread = { overlay.showRenameDialogForThread = it },
        setRenameDialogText = { overlay.renameDialogText = it },
        setMissionToManage = { overlay.missionToManage = it },
        setPinnedAgentToManage = { overlay.pinnedAgentToManage = it },
        onApproveAsk = { ask, approve -> core.scope.launch { core.missionHost.respond(ask, approve = approve) } },
        onApproveAlways = { ask ->
            recordApprovalPolicy(core.approvalPolicyStore, ask, ApprovalDecision.REMEMBER_ALLOW)
            core.scope.launch { core.missionHost.respond(ask, approve = true) }
        },
        onDenyAlways = { ask ->
            recordApprovalPolicy(core.approvalPolicyStore, ask, ApprovalDecision.REMEMBER_DENY)
            core.scope.launch { core.missionHost.respond(ask, approve = false) }
        },
        onRollbackSubmit = { sessionID, scopeChoice ->
            core.scope.launch {
                core.rollbackService.submit(
                    sessionID = sessionID,
                    scope = scopeChoice,
                    requestedBy = android.os.Build.MODEL ?: "android-device",
                )
            }
        },
        onMissionCancelDismiss = { mission ->
            core.scope.launch {
                core.missionHost.cancelMission(mission.id)
                core.missionHost.dismissMission(mission.id)
            }
        },
        onMissionDismiss = { mission -> core.missionHost.dismissMission(mission.id) },
    )
}

@Composable
internal fun rememberHermesSquareUiState(
    onOpenLegacyRuntime: (AssistantRuntimeID, String?) -> Unit,
    onOpenBrandZone: (String) -> Unit,
    onOpenPairedMac: (String) -> Unit,
): Pair<HermesSquareUiState, HermesSquareUiActions> {
    val core = rememberHermesSquareServiceCore()
    val pinned = rememberHermesSquarePinnedGridState(core.context)
    val overlay = rememberHermesSquareOverlayFields()
    val derived = rememberHermesSquareDerivedData(core, overlay)
    HermesSquareUiRuntimeEffects(core, pinned, overlay)
    val navigation = buildHermesSquareNavigationHandlers(core, overlay, onOpenLegacyRuntime, onOpenBrandZone, onOpenPairedMac)
    return buildHermesSquareUiState(core, pinned, overlay, derived) to
        buildHermesSquareUiActions(core, pinned, overlay, derived, navigation)
}

internal data class HermesSquareBootstrapDeps(
    val inbox: ThreadInboxStore,
    val historyStore: AssistantChatHistoryStore,
    val missionHost: MobileMissionConsoleHost,
    val rollbackService: RollbackService,
    val projectsStore: ProjectsStore,
    val registry: AgentIdentityRegistry,
    val hermesService: HermesService,
)

@Composable
private fun HermesSquareBootstrapEffects(deps: HermesSquareBootstrapDeps) {
    LaunchedEffect(Unit) {
        deps.inbox.bind(historyStore = deps.historyStore, missionHost = deps.missionHost)
        deps.inbox.refreshFromCloud()
        deps.registry.refreshAvailability(
            mapOf(
                AgentIdentity.builtInURI(AssistantRuntimeID.HERMES) to AgentAvailability.ONLINE,
                AgentIdentity.builtInURI(AssistantRuntimeID.PI) to AgentAvailability.ONLINE,
            ),
        )
        deps.missionHost.start()
        deps.rollbackService.startObservingRequests()
        deps.projectsStore.load()
        while (true) {
            deps.hermesService.refreshRelayConnections()
            delay(10_000)
        }
    }
}

@Composable
private fun HermesSquareMercuryPinEffect(
    hermesConnections: List<HermesConnectionRecord>,
    mercuryPinnedTileEnabled: Boolean,
    pinned: PinnedAgentGridConfig,
    persistPinned: (PinnedAgentGridConfig) -> Unit,
    registry: AgentIdentityRegistry,
) {
    LaunchedEffect(hermesConnections, mercuryPinnedTileEnabled) {
        if (!mercuryPinnedTileEnabled) {
            if (pinned.hasPairedMacPin()) persistPinned(pinned.removingPairedMacPins())
            return@LaunchedEffect
        }
        val mac = AgentIdentity.preferredPairedMacConnection(hermesConnections)
        if (mac != null) {
            val identity = registry.upsertPairedMac(mac)
            val next = pinned.pinningPairedMac(identity.id)
            if (next != pinned) persistPinned(next)
        } else if (!pinned.hasPairedMacPin()) {
            val next = pinned.pinningPairedMac(PinnedAgentGridConfig.DEFAULT_PAIRED_MAC_URI)
            if (next != pinned) persistPinned(next)
        }
    }
}

@Composable
private fun HermesSquareMissionRollbackEffect(missionSnapshot: MissionConsoleSnapshot, rollbackService: RollbackService) {
    LaunchedEffect(missionSnapshot.activeMissions) {
        for (mission in missionSnapshot.activeMissions) {
            rollbackService.startObservingSession(mission.id)
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun HermesSquareScaffold(state: HermesSquareUiState, actions: HermesSquareUiActions) {
    Scaffold(
        containerColor = Color.Transparent,
        topBar = { HermesSquareTopBar(state = state, actions = actions) },
    ) { innerPadding ->
        Box(modifier = Modifier.fillMaxSize()) {
            AuroraBackdrop()
            HermesSquareLazyContent(
                state = state,
                actions = actions,
                innerPadding = innerPadding,
            )
            HermesSquareVoiceBannerOverlay(state = state, actions = actions, innerPadding = innerPadding)
        }
    }
}
