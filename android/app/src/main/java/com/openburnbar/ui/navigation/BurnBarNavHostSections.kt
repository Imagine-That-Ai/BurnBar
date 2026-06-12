@file:Suppress("MagicNumber")
// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.navigation

import androidx.compose.foundation.clickable
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.navigation.NavHostController
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.navArgument
import androidx.navigation.navDeepLink
import com.openburnbar.data.hermes.AssistantRuntimeID
import com.openburnbar.data.missions.MobileMissionConsoleHost
import com.openburnbar.data.square.AgentIdentityRegistry
import com.openburnbar.ui.burn.BurnView
import com.openburnbar.ui.components.AuroraNavIcon
import com.openburnbar.ui.components.BurnBarLogo
import com.openburnbar.ui.computeruse.ComputerUseAgentWatchScreen
import com.openburnbar.ui.hermes.AssistantsScreen
import com.openburnbar.ui.insights.InsightsScreen
import com.openburnbar.ui.media.CallHUDView
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
        burnBarInsightsRoutes(navController, isCloudMember)
        burnBarStreamsRoute(navController, isCloudMember)
        burnBarHermesRoutes(navController)
        burnBarYouRoute()
        burnBarStoreRoute(navController)
        burnBarControlCenterRoute(navController, priceForTier)
        burnBarComputerUseRoute(navController, navigateToHermes, currentTier, priceForTier)
        burnBarPairedMacRoutes(navController, currentTier, priceForTier)
        burnBarDashboardRedirectRoute(navController)
    }
}

private fun androidx.navigation.NavGraphBuilder.burnBarPulseRoute(
    navigateToBurn: () -> Unit,
    navigateToHermes: () -> Unit,
    navigateToStreams: () -> Unit,
) {
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
        deepLinks = listOf(navDeepLink { uriPattern = "burnbar://burn" }),
    ) { BurnView() }
}

private fun androidx.navigation.NavGraphBuilder.burnBarInsightsRoutes(
    navController: NavHostController,
    isCloudMember: Boolean,
) {
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

private fun androidx.navigation.NavGraphBuilder.burnBarStreamsRoute(
    navController: NavHostController,
    isCloudMember: Boolean,
) {
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

private fun androidx.navigation.NavGraphBuilder.burnBarHermesRoutes(navController: NavHostController) {
    burnBarHermesSquareRoute(navController)
    burnBarAssistantsAgentRoutes(navController)
    burnBarMercuryCallRoute(navController)
}

private fun androidx.navigation.NavGraphBuilder.burnBarHermesSquareRoute(navController: NavHostController) {
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
        val connectionId = entry.arguments?.getString("connectionId").orEmpty()
        val hudState = remember(connectionId) { com.openburnbar.ui.media.CallHUDState() }
        CallHUDView(
            state = hudState,
            onMuteMic = { hudState.setMicMuted(!hudState.isMicMuted.value) },
            onMuteCamera = { hudState.setCameraMuted(!hudState.isCameraMuted.value) },
            onShareScreen = { hudState.setSharingScreen(!hudState.isSharingScreen.value) },
            onEnd = { navController.popBackStack() },
            modifier = Modifier.fillMaxSize(),
        )
    }
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
internal fun BurnBarNavigationRail(currentTab: BurnBarTab, onSelect: (BurnBarTab) -> Unit, modifier: Modifier = Modifier) {
    Column(
        modifier =
        modifier
            .fillMaxHeight()
            .width(104.dp)
            .background(MaterialTheme.colorScheme.surface.copy(alpha = 0.6f))
            .padding(vertical = 10.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        BurnBarLogo(
            size = 42.dp,
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
private fun BurnBarNavigationRailItem(
    tab: BurnBarTab,
    selected: Boolean,
    onSelect: () -> Unit,
) {
    Column(
        modifier =
        Modifier
            .width(96.dp)
            .height(44.dp)
            .clip(RoundedCornerShape(18.dp))
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
    val isWideScreen: Boolean,
    val currentTab: BurnBarTab,
    val isCloudMember: Boolean,
    val currentTier: com.openburnbar.ui.pro.CloudTier = com.openburnbar.ui.pro.CloudTier.NONE,
    val priceForTier: (com.openburnbar.ui.pro.CloudTier) -> String? = { null },
    val userDisplayName: String?,
    val userPhotoUrl: String?,
    val chatState: FloatingChatState,
)

@Composable
internal fun BurnBarSignedInShell(
    state: BurnBarSignedInShellState,
    navController: NavHostController,
    navigateTo: (BurnBarTab) -> Unit,
) {
    if (state.isWideScreen) {
        BurnBarWideScreenShell(state = state, navController = navController, navigateTo = navigateTo)
    } else {
        BurnBarPhoneShell(state = state, navController = navController, navigateTo = navigateTo)
    }
    BurnBarSignedInOverlays(state = state, navigateTo = navigateTo)
}

@Composable
private fun BurnBarWideScreenShell(
    state: BurnBarSignedInShellState,
    navController: NavHostController,
    navigateTo: (BurnBarTab) -> Unit,
) {
    androidx.compose.foundation.layout.Row(modifier = Modifier.fillMaxSize()) {
        BurnBarNavigationRail(
            currentTab = state.currentTab,
            onSelect = navigateTo,
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

@Composable
private fun BurnBarPhoneShell(
    state: BurnBarSignedInShellState,
    navController: NavHostController,
    navigateTo: (BurnBarTab) -> Unit,
) {
    Box(
        modifier =
        Modifier
            .fillMaxSize()
            .statusBarsPadding()
            .padding(bottom = 96.dp),
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
    if (state.currentTab != BurnBarTab.HERMES && state.chatState.mode != com.openburnbar.ui.components.FloatingChatMode.Hidden) {
        Box(
            modifier =
            Modifier
                .fillMaxSize()
                .padding(bottom = if (!state.isWideScreen) 84.dp else com.openburnbar.ui.theme.AuroraSpacing.lg.dp),
            contentAlignment = androidx.compose.ui.Alignment.BottomEnd,
        ) {
            com.openburnbar.ui.components.FloatingChatPill(
                snippet = state.chatState.snippet,
                mode = state.chatState.mode,
                onTap = { navigateTo(BurnBarTab.HERMES) },
            )
        }
    }

    val hermesService = remember { com.openburnbar.data.hermes.HermesService() }
    com.openburnbar.ui.chartstudio.ChartStudioOverlay(hermes = hermesService)

    com.openburnbar.ui.insights.MissionActivityOverlay(
        modifier =
        Modifier
            .fillMaxSize()
            .padding(bottom = if (!state.isWideScreen) 104.dp else com.openburnbar.ui.theme.AuroraSpacing.lg.dp),
    )
}
