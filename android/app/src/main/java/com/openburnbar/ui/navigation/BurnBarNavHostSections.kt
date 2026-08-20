// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.navigation

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.navigation.NavGraph.Companion.findStartDestination
import androidx.navigation.NavHostController
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.navArgument
import androidx.navigation.navDeepLink
import com.openburnbar.data.hermes.AssistantRuntimeID
import com.openburnbar.data.missions.MobileMissionConsoleHost
import com.openburnbar.data.square.AgentIdentityRegistry
import com.openburnbar.services.media.IncomingCallActivity
import com.openburnbar.ui.burn.BurnView
import com.openburnbar.ui.components.AuroraNavIcon
import com.openburnbar.ui.components.BurnBarLogo
import com.openburnbar.ui.computeruse.ComputerUseAgentWatchScreen
import com.openburnbar.ui.hermes.AccountScopedHermesServiceProvider
import com.openburnbar.ui.hermes.AssistantsScreen
import com.openburnbar.ui.hermes.rememberAccountScopedHermesService
import com.openburnbar.ui.inbox.InboxScreen
import com.openburnbar.ui.insights.InsightsScreen
import com.openburnbar.ui.media.CallHUDState
import com.openburnbar.ui.media.CallHUDView
import com.openburnbar.ui.media.MercuryIncomingSheet
import com.openburnbar.ui.media.PairedMacControlsScreen
import com.openburnbar.ui.pulse.PulseView
import com.openburnbar.ui.square.AgentBrandZoneScreen
import com.openburnbar.ui.square.HermesSquareSplitLayout
import com.openburnbar.ui.streams.StreamsView
import com.openburnbar.ui.you.YouView

@Composable
internal fun InsightsTeaserBackground() {
    Column(
        verticalArrangement = Arrangement.spacedBy(12.dp),
        modifier =
        Modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
            .padding(16.dp),
    ) {
        repeat(6) { idx ->
            val firstAlpha = (0.16f - idx * 0.015f).coerceAtLeast(0f)
            Box(
                modifier =
                Modifier
                    .fillMaxWidth()
                    .height(if (idx == 0) 180.dp else 92.dp)
                    .background(
                        brush =
                        androidx.compose.ui.graphics.Brush.linearGradient(
                            colors =
                            listOf(
                                com.openburnbar.ui.theme.AuroraColors.ember.copy(alpha = firstAlpha),
                                com.openburnbar.ui.theme.AuroraColors.amber.copy(alpha = 0.10f),
                                com.openburnbar.ui.theme.AuroraColors.whimsy.copy(alpha = 0.08f),
                            ),
                        ),
                        shape = RoundedCornerShape(16.dp),
                    ),
            )
        }
    }
}

@Composable
internal fun BurnBarContent(
    navController: NavHostController,
    navigateToBurn: () -> Unit,
    navigateToHermes: () -> Unit,
    navigateToStreams: () -> Unit,
    isCloudMember: Boolean = false,
    currentTier: com.openburnbar.ui.pro.CloudTier = com.openburnbar.ui.pro.CloudTier.NONE,
    priceForTier: (com.openburnbar.ui.pro.CloudTier) -> String? = { null },
) {
    NavHost(
        navController = navController,
        startDestination = BurnBarTab.PULSE.route,
    ) {
        burnBarPulseRoute(navigateToBurn, navigateToHermes, navigateToStreams)
        burnBarBurnRoute()
        burnBarInboxRoute(navController)
        burnBarInsightsRoutes(navController, isCloudMember)
        burnBarStreamsRoute(navController, isCloudMember)
        burnBarHermesRoutes(navController, currentTier)
        burnBarYouRoute()
        burnBarStoreRoute(navController)
        burnBarControlCenterRoute(navController, priceForTier)
        burnBarComputerUseRoute(navController, navigateToHermes, currentTier, priceForTier)
        burnBarPairedMacRoutes(navController, currentTier, priceForTier)
        burnBarDashboardRedirectRoute(navController)
    }
}

private fun androidx.navigation.NavGraphBuilder.burnBarPulseRoute(navigateToBurn: () -> Unit, navigateToHermes: () -> Unit, navigateToStreams: () -> Unit) {
    composable(
        BurnBarTab.PULSE.route,
        deepLinks = listOf(navDeepLink { uriPattern = "burnbar://pulse" }),
    ) {
        PulseView(
            onNavigateToBurn = navigateToBurn,
            onNavigateToHermes = navigateToHermes,
            onNavigateToStreams = navigateToStreams,
        )
    }
}

private fun androidx.navigation.NavGraphBuilder.burnBarBurnRoute() {
    composable(
        BurnBarTab.BURN.route,
        deepLinks = listOf(
            navDeepLink { uriPattern = "burnbar://burn" },
            navDeepLink { uriPattern = "burnbar://quota" },
        ),
    ) { BurnView() }
}

private fun androidx.navigation.NavGraphBuilder.burnBarInboxRoute(navController: NavHostController) {
    composable(
        BurnBarTab.INBOX.route,
        // Both shapes route to the same tab. The `/{itemId}` variant is what an
        // AI Inbox P1 push emits, and WITHOUT it Navigation finds no match and
        // silently leaves the launch intent on the start destination — the push
        // opens the app to Pulse and the alert that fired is nowhere in sight.
        // The id is not consumed as a nav argument: MainActivity stashes it (see
        // `InboxPendingItem`) and `InboxScreen` claims it once its rows exist,
        // which is the only point at which the row can actually be resolved.
        deepLinks =
        listOf(
            navDeepLink { uriPattern = "burnbar://inbox" },
            navDeepLink { uriPattern = "burnbar://inbox/{itemId}" },
        ),
    ) {
        InboxScreen(
            // Evidence and actions address other surfaces by route (`streams`,
            // `you`, …). Routing them through the tab nav options — rather than
            // a bare `navigate` — keeps a deep link from an inbox item behaving
            // exactly like tapping that tab, back stack included.
            onOpenRoute = { route ->
                val tab = BurnBarTab.fromRoute(route)
                if (tab != null) {
                    navController.navigate(tab.route, burnBarTabNavOptions(navController.graph.findStartDestination().id))
                } else {
                    navController.navigate(route) { launchSingleTop = true }
                }
            },
        )
    }
}

private fun androidx.navigation.NavGraphBuilder.burnBarInsightsRoutes(navController: NavHostController, isCloudMember: Boolean) {
    composable(
        BurnBarTab.INSIGHTS.route,
        deepLinks = listOf(navDeepLink { uriPattern = "burnbar://insights" }),
    ) {
        com.openburnbar.ui.insights.BifurcatedInsightsScreen(
            onSelectProvider = { provider ->
                navController.navigate("agent_insights/${provider.key}")
            },
            onSelectAggregate = {
                navController.navigate("agent_insights/all")
            },
        )
    }
    composable(
        "agent_insights/{slug}",
        deepLinks = listOf(navDeepLink { uriPattern = "burnbar://insights/{slug}" }),
    ) { entry ->
        val slug = entry.arguments?.getString("slug") ?: "all"
        val scope =
            com.openburnbar.ui.insights.AgentInsightsScope.fromRouteSlug(slug)
                ?: com.openburnbar.ui.insights.AgentInsightsScope.Aggregate
        com.openburnbar.ui.insights.AgentInsightsHost(
            scope = scope,
            onOpenWorkspace = {
                navController.navigate("insights_workspace")
            },
            onBack = { navController.popBackStack() },
        )
    }
    composable("insights_workspace") {
        if (isCloudMember) {
            InsightsScreen()
        } else {
            com.openburnbar.ui.pro.LockedFeatureVeil(
                headline = "Insights, surfaced.",
                detail = "Cross-agent patterns, weekly retros, and forecast cohorts — included with OpenBurnBar Cloud.",
                onCta = { navController.navigate("cloud_store") },
            ) {
                InsightsTeaserBackground()
            }
        }
    }
}

private fun androidx.navigation.NavGraphBuilder.burnBarStreamsRoute(navController: NavHostController, isCloudMember: Boolean) {
    composable(
        BurnBarTab.STREAMS.route,
        deepLinks =
        listOf(
            navDeepLink { uriPattern = "burnbar://streams" },
            navDeepLink { uriPattern = "burnbar://search" },
        ),
    ) {
        StreamsView(
            isCloudMember = isCloudMember,
            onOpenCloudStore = { navController.navigate("cloud_store") },
        )
    }
}

private fun androidx.navigation.NavGraphBuilder.burnBarHermesRoutes(navController: NavHostController, currentTier: com.openburnbar.ui.pro.CloudTier) {
    burnBarHermesSquareRoute(navController, currentTier)
    burnBarAssistantsAgentRoutes(navController)
    burnBarMercuryCallRoute(navController)
}

private fun androidx.navigation.NavGraphBuilder.burnBarHermesSquareRoute(navController: NavHostController, currentTier: com.openburnbar.ui.pro.CloudTier) {
    composable(
        BurnBarTab.HERMES.route,
        deepLinks =
        listOf(
            navDeepLink { uriPattern = "burnbar://hermes" },
            navDeepLink { uriPattern = "burnbar://chat" },
            navDeepLink { uriPattern = "burnbar://assistants" },
        ),
    ) {
        HermesSquareSplitLayout(
            currentTier = currentTier,
            onOpenBrandZone = { uri ->
                val encoded = java.net.URLEncoder.encode(uri, Charsets.UTF_8.name())
                navController.navigate("agent/$encoded")
            },
            onOpenLegacyRuntime = { runtime, threadId ->
                val route =
                    if (threadId != null) {
                        "assistants/${runtime.token}?threadId=$threadId"
                    } else {
                        "assistants/${runtime.token}"
                    }
                navController.navigate(route)
            },
            onOpenPairedMac = { connectionId ->
                val encoded =
                    android.util.Base64.encodeToString(
                        connectionId.toByteArray(Charsets.UTF_8),
                        android.util.Base64.URL_SAFE or android.util.Base64.NO_WRAP or android.util.Base64.NO_PADDING,
                    )
                navController.navigate("paired_mac_token/$encoded") {
                    launchSingleTop = true
                }
            },
        )
    }
}

private fun androidx.navigation.NavGraphBuilder.burnBarAssistantsAgentRoutes(navController: NavHostController) {
    composable(
        "assistants/{runtime}?threadId={threadId}",
        arguments =
        listOf(
            navArgument("runtime") { type = NavType.StringType },
            navArgument("threadId") {
                type = NavType.StringType
                nullable = true
                defaultValue = null
            },
        ),
        deepLinks =
        listOf(
            navDeepLink { uriPattern = "burnbar://assistants/{runtime}?threadId={threadId}" },
        ),
    ) { entry ->
        val token = entry.arguments?.getString("runtime").orEmpty()
        val runtime = AssistantRuntimeID.fromToken(token)
        val threadId = entry.arguments?.getString("threadId")
        AssistantsScreen(initialRuntime = runtime, initialThreadId = threadId)
    }
    composable(
        "agent/{uri}",
        arguments = listOf(navArgument("uri") { type = NavType.StringType }),
        deepLinks = listOf(navDeepLink { uriPattern = "burnbar://agent/{uri}" }),
    ) { entry ->
        val raw = entry.arguments?.getString("uri").orEmpty()
        val decoded =
            runCatching { java.net.URLDecoder.decode(raw, Charsets.UTF_8.name()) }
                .getOrDefault(raw)
        val registry = remember { AgentIdentityRegistry.shared() }
        val identity = registry.identity(decoded)
        if (identity != null) {
            AgentBrandZoneScreen(
                identity = identity,
                registry = registry,
                missionHost = MobileMissionConsoleHost.shared(),
                modifier = Modifier.fillMaxSize(),
            )
        } else {
            LaunchedEffect(decoded) { navController.popBackStack() }
        }
    }
}

private fun androidx.navigation.NavGraphBuilder.burnBarMercuryCallRoute(navController: NavHostController) {
    composable(
        "mercury/call/{connectionId}",
        arguments = listOf(navArgument("connectionId") { type = NavType.StringType }),
        deepLinks = listOf(navDeepLink { uriPattern = "burnbar://mercury/call/{connectionId}" }),
    ) { entry ->
        MercuryCallDestination(navController, entry)
    }
    composable(
        "mission/{missionId}",
        arguments = listOf(navArgument("missionId") { type = NavType.StringType }),
        deepLinks = listOf(navDeepLink { uriPattern = "burnbar://mission/{missionId}" }),
    ) { entry ->
        val missionId = entry.arguments?.getString("missionId")
        MissionConsoleDestination(missionId = missionId, onClose = { navController.popBackStack() })
    }
}

@Composable
private fun MissionConsoleDestination(missionId: String?, onClose: () -> Unit) {
    val host = remember { MobileMissionConsoleHost.shared() }
    LaunchedEffect(Unit) { host.start() }
    LaunchedEffect(missionId) {
        if (!missionId.isNullOrBlank()) host.focusMission(missionId)
    }
    val snapshot by host.snapshot.collectAsState()
    val focused = snapshot.activeMissions.firstOrNull { it.id == missionId }
        ?: snapshot.activeMissions.firstOrNull()
    Column(
        modifier = Modifier
            .fillMaxSize()
            .statusBarsPadding()
            .padding(20.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text("Mission console", style = MaterialTheme.typography.headlineSmall)
        Text(
            focused?.title ?: missionId ?: "No mission selected",
            style = MaterialTheme.typography.titleMedium,
        )
        if (focused != null) {
            Text(focused.phase.displayLabel, style = MaterialTheme.typography.bodyMedium)
            focused.phaseDetail?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
        }
        Text(
            "Open ${snapshot.openMissions} · queued ${snapshot.queuedMissions} · blocked ${snapshot.blockedMissions}",
            style = MaterialTheme.typography.bodySmall,
        )
        Text(
            "Close",
            modifier = Modifier.clickable(onClick = onClose),
            color = MaterialTheme.colorScheme.primary,
        )
    }
}

@Composable
private fun MercuryCallDestination(navController: NavHostController, entry: androidx.navigation.NavBackStackEntry) {
    val connectionId = entry.arguments?.getString("connectionId").orEmpty()
    val context = LocalContext.current
    var accepted by remember(connectionId) { mutableStateOf(false) }
    if (!accepted) {
        val callerName = connectionId.ifBlank { "Paired Mac" }
        MercuryIncomingSheet(
            pairedDeviceName = callerName,
            callerInitial = callerName.firstOrNull()?.uppercaseChar()?.toString() ?: "M",
            onAccept = {
                IncomingCallActivity.acceptRoutedCall(context, connectionId)
                accepted = true
            },
            onDecline = {
                IncomingCallActivity.declineRoutedCall(context, connectionId)
                navController.popBackStack()
            },
        )
        return
    }
    val hudState = remember(connectionId) { CallHUDState() }
    CallHUDView(
        state = hudState,
        onMuteMic = { hudState.setMicMuted(!hudState.isMicMuted.value) },
        onMuteCamera = { hudState.setCameraMuted(!hudState.isCameraMuted.value) },
        onShareScreen = { hudState.setSharingScreen(!hudState.isSharingScreen.value) },
        onEnd = { navController.popBackStack() },
        modifier = Modifier.fillMaxSize(),
    )
}

private fun androidx.navigation.NavGraphBuilder.burnBarYouRoute() {
    composable(
        BurnBarTab.YOU.route,
        deepLinks = listOf(navDeepLink { uriPattern = "burnbar://you" }),
    ) { YouView() }
}

private fun androidx.navigation.NavGraphBuilder.burnBarStoreRoute(navController: NavHostController) {
    composable(
        "cloud_store",
        deepLinks = listOf(navDeepLink { uriPattern = "burnbar://cloud" }),
    ) {
        com.openburnbar.ui.store.CloudStoreView(
            onClose = { navController.popBackStack() },
        )
    }
}

private fun androidx.navigation.NavGraphBuilder.burnBarControlCenterRoute(
    navController: NavHostController,
    priceForTier: (com.openburnbar.ui.pro.CloudTier) -> String?,
) {
    composable(
        "control_center",
        deepLinks = listOf(navDeepLink { uriPattern = "burnbar://data" }),
    ) {
        com.openburnbar.ui.control.ControlCenterScreen(
            modifier = Modifier.fillMaxSize(),
            onBack = { navController.popBackStack() },
            onManagePlan = { navController.navigate("cloud_store") },
            onDomainDeepLink = { _, _ -> },
            priceForTier = priceForTier,
        )
    }
}

private fun androidx.navigation.NavGraphBuilder.burnBarComputerUseRoute(
    navController: NavHostController,
    navigateToHermes: () -> Unit,
    currentTier: com.openburnbar.ui.pro.CloudTier,
    priceForTier: (com.openburnbar.ui.pro.CloudTier) -> String?,
) {
    composable(
        "computer_use",
        deepLinks = listOf(navDeepLink { uriPattern = "burnbar://computer-use" }),
    ) {
        val agentControl = com.openburnbar.ui.pro.GatedFeatureCatalog.feature(com.openburnbar.ui.pro.GatedFeatureID.AGENT_CONTROL)
        if (currentTier.satisfies(agentControl.requiredTier)) {
            ComputerUseAgentWatchScreen(
                modifier = Modifier.fillMaxSize(),
                onOpenHermes = navigateToHermes,
                onOpenSettings = {
                    navController.navigate(BurnBarTab.YOU.route) {
                        launchSingleTop = true
                        restoreState = true
                    }
                },
            )
        } else {
            com.openburnbar.ui.pro.LockedFeatureVeil(
                feature = agentControl,
                livePrice = priceForTier(agentControl.requiredTier),
                onUnlock = { navController.navigate("cloud_store") },
                onMaybeLater = { navController.popBackStack() },
            ) {
                ComputerUseAgentWatchScreen(modifier = Modifier.fillMaxSize())
            }
        }
    }
}

private fun androidx.navigation.NavGraphBuilder.burnBarPairedMacRoutes(
    navController: NavHostController,
    currentTier: com.openburnbar.ui.pro.CloudTier,
    priceForTier: (com.openburnbar.ui.pro.CloudTier) -> String?,
) {
    composable(
        "paired_mac",
        deepLinks = listOf(navDeepLink { uriPattern = "burnbar://paired-mac" }),
    ) {
        FlooGatedPairedMac(navController, currentTier, priceForTier, connectionID = null)
    }
    composable(
        "paired_mac/{connectionId}",
        arguments = listOf(navArgument("connectionId") { type = NavType.StringType }),
        deepLinks = listOf(navDeepLink { uriPattern = "burnbar://paired-mac/{connectionId}" }),
    ) { entry ->
        val raw = entry.arguments?.getString("connectionId").orEmpty()
        val decoded =
            runCatching { java.net.URLDecoder.decode(raw, Charsets.UTF_8.name()) }
                .getOrDefault(raw)
        FlooGatedPairedMac(navController, currentTier, priceForTier, connectionID = decoded.takeIf { it.isNotBlank() })
    }
    composable(
        "paired_mac_token/{connectionToken}",
        arguments = listOf(navArgument("connectionToken") { type = NavType.StringType }),
    ) { entry ->
        val token = entry.arguments?.getString("connectionToken").orEmpty()
        val decoded =
            runCatching {
                String(
                    android.util.Base64.decode(
                        token,
                        android.util.Base64.URL_SAFE or android.util.Base64.NO_WRAP or android.util.Base64.NO_PADDING,
                    ),
                    Charsets.UTF_8,
                )
            }.getOrDefault(token)
        FlooGatedPairedMac(navController, currentTier, priceForTier, connectionID = decoded.takeIf { it.isNotBlank() })
    }
}

/**
 * Floo (phone ↔ Mac) is a Cloud Pro feature. When the member's tier doesn't
 * satisfy it, the live screen rides behind the tier-aware unlock veil; otherwise
 * the real paired-Mac controls render.
 */
@Composable
private fun FlooGatedPairedMac(
    navController: NavHostController,
    currentTier: com.openburnbar.ui.pro.CloudTier,
    priceForTier: (com.openburnbar.ui.pro.CloudTier) -> String?,
    connectionID: String?,
) {
    val floo = com.openburnbar.ui.pro.GatedFeatureCatalog.feature(com.openburnbar.ui.pro.GatedFeatureID.FLOO)
    if (currentTier.satisfies(floo.requiredTier)) {
        PairedMacControlsScreen(connectionID = connectionID, modifier = Modifier.fillMaxSize())
    } else {
        com.openburnbar.ui.pro.LockedFeatureVeil(
            feature = floo,
            livePrice = priceForTier(floo.requiredTier),
            onUnlock = { navController.navigate("cloud_store") },
            onMaybeLater = { navController.popBackStack() },
        ) {
            PairedMacControlsScreen(connectionID = connectionID, modifier = Modifier.fillMaxSize())
        }
    }
}

private fun androidx.navigation.NavGraphBuilder.burnBarDashboardRedirectRoute(navController: NavHostController) {
    composable(
        "dashboard",
        deepLinks = listOf(navDeepLink { uriPattern = "burnbar://dashboard" }),
    ) {
        LaunchedEffect(Unit) {
            navController.navigate(BurnBarTab.PULSE.route) {
                launchSingleTop = true
                popUpTo("dashboard") { inclusive = true }
            }
        }
    }
}

@Composable
internal fun BurnBarNavigationRail(
    currentTab: BurnBarTab,
    onSelect: (BurnBarTab) -> Unit,
    modifier: Modifier = Modifier,
    isExpanded: Boolean = false,
) {
    val railWidth = if (isExpanded) 96.dp else 80.dp
    Column(
        modifier =
        modifier
            .fillMaxHeight()
            .width(railWidth)
            .background(MaterialTheme.colorScheme.surface.copy(alpha = 0.6f))
            .padding(vertical = 10.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        BurnBarLogo(
            size = if (isExpanded) 42.dp else 36.dp,
            modifier = Modifier.padding(bottom = 6.dp),
        )
        Column(
            modifier = Modifier.fillMaxSize(),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.SpaceEvenly,
        ) {
            BurnBarTab.all.forEach { tab ->
                BurnBarNavigationRailItem(
                    tab = tab,
                    selected = currentTab == tab,
                    onSelect = { onSelect(tab) },
                )
            }
        }
    }
}

@Composable
private fun BurnBarNavigationRailItem(tab: BurnBarTab, selected: Boolean, onSelect: () -> Unit) {
    Column(
        modifier =
        Modifier
            .fillMaxWidth()
            .padding(horizontal = 6.dp)
            .height(48.dp)
            .clip(RoundedCornerShape(16.dp))
            .background(if (selected) MaterialTheme.colorScheme.primary.copy(alpha = 0.18f) else Color.Transparent)
            .clickable(onClick = onSelect)
            .padding(horizontal = 4.dp, vertical = 3.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Box(
            modifier =
            Modifier
                .size(20.dp)
                .clip(CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            AuroraNavIcon(
                destination = tab.destination,
                size = 18,
                isSelected = selected,
                userDisplayName = null,
            )
        }
        Text(
            tab.railLabel,
            color = if (selected) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.onSurface.copy(alpha = 0.72f),
            fontSize = 9.sp,
            lineHeight = 10.sp,
            fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Medium,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            textAlign = TextAlign.Center,
        )
    }
}

private val BurnBarTab.railLabel: String
    get() =
        when (this) {
            BurnBarTab.INSIGHTS -> "Insights"
            BurnBarTab.HERMES -> "Agents"
            BurnBarTab.YOU -> "Store"
            else -> label
        }

internal data class BurnBarSignedInShellState(
    val windowSizeClass: BurnBarWindowSizeClass = BurnBarWindowSizeClass(BurnBarWindowWidthClass.COMPACT, 360.dp),
    val isWideScreen: Boolean = windowSizeClass.widthClass.isWide,
    val currentTab: BurnBarTab,
    val isCloudMember: Boolean,
    val currentTier: com.openburnbar.ui.pro.CloudTier = com.openburnbar.ui.pro.CloudTier.NONE,
    val priceForTier: (com.openburnbar.ui.pro.CloudTier) -> String? = { null },
    val userUid: String,
    val userDisplayName: String?,
    val userPhotoUrl: String?,
    val chatState: FloatingChatState,
)

@Composable
internal fun BurnBarSignedInShell(state: BurnBarSignedInShellState, navController: NavHostController, navigateTo: (BurnBarTab) -> Unit) {
    AccountScopedHermesServiceProvider(accountUid = state.userUid) {
        if (state.isWideScreen) {
            BurnBarWideScreenShell(state = state, navController = navController, navigateTo = navigateTo)
        } else {
            BurnBarPhoneShell(state = state, navController = navController, navigateTo = navigateTo)
        }
        BurnBarSignedInOverlays(state = state, navigateTo = navigateTo)
    }
}

@Composable
private fun BurnBarWideScreenShell(state: BurnBarSignedInShellState, navController: NavHostController, navigateTo: (BurnBarTab) -> Unit) {
    androidx.compose.foundation.layout.Row(modifier = Modifier.fillMaxSize()) {
        BurnBarNavigationRail(
            currentTab = state.currentTab,
            onSelect = navigateTo,
            isExpanded = state.windowSizeClass.widthClass.isExpanded,
            modifier = Modifier.statusBarsPadding(),
        )
        Box(
            modifier =
            Modifier
                .weight(1f)
                .statusBarsPadding()
                .navigationBarsPadding(),
        ) {
            BurnBarContent(
                navController = navController,
                navigateToBurn = { navigateTo(BurnBarTab.BURN) },
                navigateToHermes = { navigateTo(BurnBarTab.HERMES) },
                navigateToStreams = { navigateTo(BurnBarTab.STREAMS) },
                isCloudMember = state.isCloudMember,
                currentTier = state.currentTier,
                priceForTier = state.priceForTier,
            )
        }
    }
}

private const val CANONICAL_TRAY_BOTTOM_PADDING_DP = 80

@Composable
private fun BurnBarPhoneShell(state: BurnBarSignedInShellState, navController: NavHostController, navigateTo: (BurnBarTab) -> Unit) {
    Box(
        modifier =
        Modifier
            .fillMaxSize()
            .statusBarsPadding()
            .padding(bottom = CANONICAL_TRAY_BOTTOM_PADDING_DP.dp),
    ) {
        BurnBarContent(
            navController = navController,
            navigateToBurn = { navigateTo(BurnBarTab.BURN) },
            navigateToHermes = { navigateTo(BurnBarTab.HERMES) },
            navigateToStreams = { navigateTo(BurnBarTab.STREAMS) },
            isCloudMember = state.isCloudMember,
            currentTier = state.currentTier,
            priceForTier = state.priceForTier,
        )
    }
    Box(
        modifier =
        Modifier
            .fillMaxSize()
            .navigationBarsPadding(),
        contentAlignment = androidx.compose.ui.Alignment.BottomCenter,
    ) {
        AuroraNavigationTray(
            destinations = BurnBarTab.all.map { it.destination },
            selectedDestination = state.currentTab.destination,
            onDestinationSelected = { dest ->
                BurnBarTab.all.firstOrNull { it.destination == dest }?.let(navigateTo)
            },
            userDisplayName = state.userDisplayName,
            userPhotoUrl = state.userPhotoUrl,
            isCloudMember = state.isCloudMember,
        )
    }
}

@Composable
private fun BurnBarSignedInOverlays(state: BurnBarSignedInShellState, navigateTo: (BurnBarTab) -> Unit) {
    val overlayBottomInset = if (!state.isWideScreen) {
        (CANONICAL_TRAY_BOTTOM_PADDING_DP + 8).dp
    } else {
        com.openburnbar.ui.theme.AuroraSpacing.LG.dp
    }

    if (state.currentTab != BurnBarTab.HERMES && state.chatState.mode != com.openburnbar.ui.components.FloatingChatMode.Hidden) {
        Box(
            modifier =
            Modifier
                .fillMaxSize()
                .padding(bottom = overlayBottomInset),
            contentAlignment = androidx.compose.ui.Alignment.BottomEnd,
        ) {
            com.openburnbar.ui.components.FloatingChatPill(
                snippet = state.chatState.snippet,
                mode = state.chatState.mode,
                onTap = { navigateTo(BurnBarTab.HERMES) },
            )
        }
    }

    val hermesService = rememberAccountScopedHermesService()
    com.openburnbar.ui.chartstudio.ChartStudioOverlay(hermes = hermesService)

    com.openburnbar.ui.insights.MissionActivityOverlay(
        modifier =
        Modifier
            .fillMaxSize()
            .padding(bottom = overlayBottomInset),
    )
}
