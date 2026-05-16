package com.openburnbar.ui.navigation

import androidx.compose.foundation.background
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.*
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationRail
import androidx.compose.material3.NavigationRailItem
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.NavHostController
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import androidx.navigation.navDeepLink
import com.openburnbar.data.hermes.AssistantRuntimeID
import com.openburnbar.data.stores.HostedQuotaSubscriptionStore
import com.openburnbar.data.stores.UserStore
import com.openburnbar.ui.auth.LoginScreen
import com.openburnbar.ui.burn.BurnView
import com.openburnbar.ui.components.AuroraBackdrop
import com.openburnbar.ui.components.AuroraNavDestination
import com.openburnbar.ui.components.AuroraNavIcon
import com.openburnbar.ui.components.BurnBarLogo
import com.openburnbar.ui.components.FloatingChatMode
import com.openburnbar.ui.components.FloatingChatPill
import com.openburnbar.data.square.AgentIdentityRegistry
import com.openburnbar.data.square.HermesSquareFeatureFlags
import com.openburnbar.data.missions.MobileMissionConsoleHost
import com.openburnbar.ui.hermes.AssistantsScreen
import com.openburnbar.ui.hermes.HermesView
import com.openburnbar.ui.square.AgentBrandZoneScreen
import com.openburnbar.ui.square.HermesSquareScreen
import com.openburnbar.ui.square.HermesSquareSplitLayout
import androidx.compose.ui.platform.LocalContext
import com.openburnbar.ui.insights.MissionActivityOverlay
import com.openburnbar.ui.media.CallHUDView
import com.openburnbar.ui.pulse.PulseView
import com.openburnbar.ui.streams.StreamsView
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.insights.InsightsScreen
import com.openburnbar.ui.you.YouView

/**
 * Tab catalog. Route strings are deep-link addressable via `burnbar://`.
 */
sealed class BurnBarTab(
    val route: String,
    val label: String,
    val destination: AuroraNavDestination
) {
    object PULSE    : BurnBarTab("pulse",    "Pulse",    AuroraNavDestination.PULSE)
    object BURN     : BurnBarTab("burn",     "Burn",     AuroraNavDestination.BURN)
    object INSIGHTS : BurnBarTab("insights", "Insights", AuroraNavDestination.INSIGHTS)
    object STREAMS  : BurnBarTab("streams",  "Streams",  AuroraNavDestination.STREAMS)
    // Plan 2: tab renamed to "Assistants" — the route stays `hermes` so deep
    // links (`burnbar://hermes`, `burnbar://chat`) and bookmarks continue to
    // resolve to the same destination.
    object HERMES   : BurnBarTab("hermes",   "Assistants",  AuroraNavDestination.HERMES)
    object YOU      : BurnBarTab("you",      "You",      AuroraNavDestination.YOU)

    companion object {
        val all: List<BurnBarTab> = listOf(PULSE, BURN, INSIGHTS, STREAMS, HERMES, YOU)
        fun fromRoute(route: String?): BurnBarTab? = all.firstOrNull { it.route == route }
    }
}

/** Simple singleton to pass a pending prompt to HermesView at navigation time. */
object HermesPendingPrompt { var pending: String? = null }

/**
 * Shared state for the floating chat pill — owned by the nav host so the pill
 * survives across tab changes. Phase E will hydrate `streaming` and `snippet`
 * from the real chat stream; for now this is a hand-driven state container.
 */
class FloatingChatState {
    var mode by mutableStateOf(FloatingChatMode.Idle)
    var snippet by mutableStateOf("")
    fun startStreaming(text: String = "") { mode = FloatingChatMode.Streaming; snippet = text }
    fun show(snippet: String) { mode = FloatingChatMode.Idle; this.snippet = snippet }
    fun hide() { mode = FloatingChatMode.Hidden }
}

@Composable
fun rememberFloatingChatState(): FloatingChatState = remember { FloatingChatState() }

/// Static glassy panes that suggest the Insights canvas without driving any
/// data. The LockedFeatureVeil blurs them, so a free user only ever sees
/// shape and color — enough to feel "I want what's behind this veil."
@Composable
private fun InsightsTeaserBackground() {
    androidx.compose.foundation.layout.Column(
        verticalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(12.dp),
        modifier = Modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
            .padding(16.dp)
    ) {
        repeat(6) { idx ->
            val firstAlpha = (0.16f - idx * 0.015f).coerceAtLeast(0f)
            androidx.compose.foundation.layout.Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(if (idx == 0) 180.dp else 92.dp)
                    .background(
                        brush = androidx.compose.ui.graphics.Brush.linearGradient(
                            colors = listOf(
                                com.openburnbar.ui.theme.AuroraColors.ember.copy(alpha = firstAlpha),
                                com.openburnbar.ui.theme.AuroraColors.amber.copy(alpha = 0.10f),
                                com.openburnbar.ui.theme.AuroraColors.whimsy.copy(alpha = 0.08f)
                            )
                        ),
                        shape = androidx.compose.foundation.shape.RoundedCornerShape(16.dp)
                    )
            )
        }
    }
}

@Composable
fun BurnBarNavHost(
    modifier: Modifier = Modifier,
    navController: NavHostController = rememberNavController(),
    userStore: UserStore = viewModel(),
    chatState: FloatingChatState = rememberFloatingChatState(),
    subscriptionStore: HostedQuotaSubscriptionStore = viewModel()
) {
    val isDark = isSystemInDarkTheme()
    val currentUser by userStore.user.collectAsState()
    val context = LocalContext.current
    LaunchedEffect(context) {
        subscriptionStore.initialize(context)
        subscriptionStore.load()
    }
    val isCloudMember by subscriptionStore.isActive.collectAsState()
    val navBackStackEntry by navController.currentBackStackEntryAsState()
    val currentRoute = navBackStackEntry?.destination?.route
    val currentTab = remember(currentRoute) {
        BurnBarTab.fromRoute(currentRoute) ?: BurnBarTab.PULSE
    }

    val isWideScreen = LocalConfiguration.current.screenWidthDp > 600

    val navigateTo: (BurnBarTab) -> Unit = { tab ->
        navController.navigate(tab.route) {
            launchSingleTop = true
            restoreState = true
        }
    }

    Box(modifier = modifier.fillMaxSize()) {
        // Single global AuroraBackdrop behind everything. Painted before the
        // nav scaffold/insets so the warm gradient extends edge-to-edge under
        // the status bar AND the gesture bar — no dark strip behind the nav
        // tray, no gap below the content. Per-screen AuroraBackdrop calls are
        // now redundant but harmless (they overlay an identical gradient).
        AuroraBackdrop()

        if (currentUser.isSignedIn) {
            if (isWideScreen) {
                // Two-pane: NavigationRail (sidebar) + content
                Row(modifier = Modifier.fillMaxSize()) {
                    BurnBarNavigationRail(
                        currentTab = currentTab,
                        onSelect = navigateTo,
                        modifier = Modifier.statusBarsPadding()
                    )
                    Box(
                        modifier = Modifier
                            .weight(1f)
                            .statusBarsPadding()
                            .navigationBarsPadding()
                    ) {
                        BurnBarContent(
                            navController = navController,
                            navigateToBurn = { navigateTo(BurnBarTab.BURN) },
                            navigateToHermes = { navigateTo(BurnBarTab.HERMES) },
                            navigateToStreams = { navigateTo(BurnBarTab.STREAMS) }
                        )
                    }
                }
            } else {
                // Phone: content fills the whole screen behind a floating
                // nav pill. No Column splitting — the pill literally hovers
                // over the same Box as the content, so the gradient runs
                // unbroken from status bar to gesture pill. Content reserves
                // bottom space (≈96dp) so scrollable lists don't get hidden
                // under the floating pill.
                Box(
                    modifier = Modifier
                        .fillMaxSize()
                        .statusBarsPadding()
                        .padding(bottom = 96.dp)
                ) {
                    BurnBarContent(
                        navController = navController,
                        navigateToBurn = { navigateTo(BurnBarTab.BURN) },
                        navigateToHermes = { navigateTo(BurnBarTab.HERMES) },
                        navigateToStreams = { navigateTo(BurnBarTab.STREAMS) },
                        isCloudMember = isCloudMember
                    )
                }
                Box(
                    modifier = Modifier
                        .fillMaxSize()
                        .navigationBarsPadding(),
                    contentAlignment = Alignment.BottomCenter
                ) {
                    AuroraNavigationTray(
                        destinations = BurnBarTab.all.map { it.destination },
                        selectedDestination = currentTab.destination,
                        onDestinationSelected = { dest ->
                            BurnBarTab.all.firstOrNull { it.destination == dest }?.let(navigateTo)
                        },
                        userDisplayName = currentUser.displayName,
                        userPhotoUrl = currentUser.photoUrl,
                        isCloudMember = isCloudMember
                    )
                }
            }

            // Floating chat pill — visible whenever Hermes isn't already the
            // active tab. Tap routes to HermesView.
            if (currentTab != BurnBarTab.HERMES && chatState.mode != FloatingChatMode.Hidden) {
                Box(
                    modifier = Modifier
                        .fillMaxSize()
                        .padding(bottom = if (!isWideScreen) 84.dp else AuroraSpacing.lg.dp),
                    contentAlignment = Alignment.BottomEnd
                ) {
                    FloatingChatPill(
                        snippet = chatState.snippet,
                        mode = chatState.mode,
                        onTap = { navigateTo(BurnBarTab.HERMES) }
                    )
                }
            }

            // Chart Studio overlay — fullscreen when presented, FAB when
            // minimized. Hidden mode is a no-op. Sits above everything else
            // including the floating chat pill.
            val hermesService = remember { com.openburnbar.data.hermes.HermesService() }
            com.openburnbar.ui.chartstudio.ChartStudioOverlay(hermes = hermesService)

            MissionActivityOverlay(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(bottom = if (!isWideScreen) 104.dp else AuroraSpacing.lg.dp)
            )
        } else {
            val isSigningIn by userStore.isSigningIn.collectAsState()
            val authError by userStore.authError.collectAsState()
            LoginScreen(
                userStore = userStore,
                isSigningIn = isSigningIn,
                authError = authError,
                onDismissError = { userStore.clearError() }
            )
        }
    }
}

@Composable
private fun BurnBarContent(
    navController: NavHostController,
    navigateToBurn: () -> Unit,
    navigateToHermes: () -> Unit,
    navigateToStreams: () -> Unit,
    isCloudMember: Boolean = false
) {
    NavHost(
        navController = navController,
        startDestination = BurnBarTab.PULSE.route
    ) {
        composable(
            BurnBarTab.PULSE.route,
            deepLinks = listOf(navDeepLink { uriPattern = "burnbar://pulse" })
        ) {
            PulseView(
                onNavigateToBurn = navigateToBurn,
                onNavigateToHermes = navigateToHermes,
                onNavigateToStreams = navigateToStreams
            )
        }
        composable(
            BurnBarTab.BURN.route,
            deepLinks = listOf(navDeepLink { uriPattern = "burnbar://burn" })
        ) { BurnView() }
        composable(
            BurnBarTab.INSIGHTS.route,
            deepLinks = listOf(navDeepLink { uriPattern = "burnbar://insights" })
        ) {
            com.openburnbar.ui.insights.AgentInsightsRosterScreen(
                onSelectProvider = { provider ->
                    navController.navigate("agent_insights/${provider.key}")
                },
                onSelectAggregate = {
                    navController.navigate("agent_insights/all")
                }
            )
        }
        composable(
            "agent_insights/{slug}",
            deepLinks = listOf(navDeepLink { uriPattern = "burnbar://insights/{slug}" })
        ) { entry ->
            val slug = entry.arguments?.getString("slug") ?: "all"
            val scope = com.openburnbar.ui.insights.AgentInsightsScope.fromRouteSlug(slug)
                ?: com.openburnbar.ui.insights.AgentInsightsScope.Aggregate
            com.openburnbar.ui.insights.AgentInsightsHost(
                scope = scope,
                onOpenWorkspace = {
                    navController.navigate("insights_workspace")
                },
                onBack = { navController.popBackStack() }
            )
        }
        composable("insights_workspace") {
            // Pro vocabulary — gate Insights behind OpenBurnBar Cloud. Free
            // users see a frosted mercury veil over a teaser; members see
            // the live workspace.
            if (isCloudMember) {
                InsightsScreen()
            } else {
                com.openburnbar.ui.pro.LockedFeatureVeil(
                    headline = "Insights, surfaced.",
                    detail = "Cross-agent patterns, weekly retros, and forecast cohorts — included with OpenBurnBar Cloud.",
                    onCta = { navController.navigate("cloud_store") }
                ) {
                    InsightsTeaserBackground()
                }
            }
        }
        composable(
            BurnBarTab.STREAMS.route,
            deepLinks = listOf(
                navDeepLink { uriPattern = "burnbar://streams" },
                navDeepLink { uriPattern = "burnbar://search" }
            )
        ) { StreamsView() }
        composable(
            BurnBarTab.HERMES.route,
            deepLinks = listOf(
                navDeepLink { uriPattern = "burnbar://hermes" },
                navDeepLink { uriPattern = "burnbar://chat" },
                navDeepLink { uriPattern = "burnbar://assistants" }
            )
        ) {
            // Hermes Square is the only Assistants surface. Tablet /
            // foldable widths render the two-column split layout via
            // `HermesSquareSplitLayout`; phones fall back to the
            // single-column `HermesSquareScreen` inside that helper.
            HermesSquareSplitLayout(
                onOpenBrandZone = { uri ->
                    val encoded = java.net.URLEncoder.encode(uri, Charsets.UTF_8.name())
                    navController.navigate("agent/$encoded")
                },
                onOpenLegacyRuntime = { runtime ->
                    // Pinned agent tap → push the AssistantsScreen
                    // chat surface with the right runtime preselected.
                    // The same route also serves long-press "Open chat"
                    // affordances from `AgentBrandZoneScreen`.
                    navController.navigate("assistants/${runtime.token}")
                }
            )
        }
        composable(
            "assistants/{runtime}",
            arguments = listOf(navArgument("runtime") { type = NavType.StringType }),
            deepLinks = listOf(
                navDeepLink { uriPattern = "burnbar://assistants/{runtime}" }
            )
        ) { entry ->
            val token = entry.arguments?.getString("runtime").orEmpty()
            val runtime = AssistantRuntimeID.fromToken(token)
            AssistantsScreen(initialRuntime = runtime)
        }
        composable(
            "agent/{uri}",
            arguments = listOf(navArgument("uri") { type = NavType.StringType }),
            deepLinks = listOf(navDeepLink { uriPattern = "burnbar://agent/{uri}" })
        ) { entry ->
            val raw = entry.arguments?.getString("uri").orEmpty()
            val decoded = runCatching { java.net.URLDecoder.decode(raw, Charsets.UTF_8.name()) }
                .getOrDefault(raw)
            val registry = remember { AgentIdentityRegistry.shared() }
            val identity = registry.identity(decoded)
            if (identity != null) {
                AgentBrandZoneScreen(
                    identity = identity,
                    registry = registry,
                    missionHost = MobileMissionConsoleHost.shared(),
                    modifier = Modifier.fillMaxSize()
                )
            } else {
                LaunchedEffect(decoded) { navController.popBackStack() }
            }
        }
        composable(
            "mercury/call/{connectionId}",
            arguments = listOf(navArgument("connectionId") { type = NavType.StringType }),
            deepLinks = listOf(navDeepLink { uriPattern = "burnbar://mercury/call/{connectionId}" })
        ) { entry ->
            val connectionId = entry.arguments?.getString("connectionId").orEmpty()
            // The CallSessionCoordinator is dialed by services/media when the
            // call accepts; this destination just hosts the HUD. Until the
            // coordinator surfaces a shared StateFlow we render with a
            // local state so accept / mute / end flow through the same
            // bindings as the in-call surface.
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
        composable(
            BurnBarTab.YOU.route,
            deepLinks = listOf(navDeepLink { uriPattern = "burnbar://you" })
        ) { YouView() }
        composable(
            "cloud_store",
            deepLinks = listOf(navDeepLink { uriPattern = "burnbar://cloud" })
        ) {
            com.openburnbar.ui.store.CloudStoreView(
                onClose = { navController.popBackStack() }
            )
        }
        // Open Dashboard deep link → land on Pulse (closest analog to iOS dashboard).
        composable(
            "dashboard",
            deepLinks = listOf(navDeepLink { uriPattern = "burnbar://dashboard" })
        ) {
            LaunchedEffect(Unit) {
                navController.navigate(BurnBarTab.PULSE.route) {
                    launchSingleTop = true
                    popUpTo("dashboard") { inclusive = true }
                }
            }
        }
    }
}

@Composable
private fun BurnBarNavigationRail(
    currentTab: BurnBarTab,
    onSelect: (BurnBarTab) -> Unit,
    modifier: Modifier = Modifier
) {
    NavigationRail(
        modifier = modifier
            .fillMaxHeight()
            .width(96.dp),
        containerColor = MaterialTheme.colorScheme.surface.copy(alpha = 0.6f)
    ) {
        BurnBarLogo(
            size = 44.dp,
            modifier = Modifier.padding(top = 18.dp, bottom = 18.dp)
        )
        BurnBarTab.all.forEach { tab ->
            NavigationRailItem(
                selected = currentTab == tab,
                onClick = { onSelect(tab) },
                icon = {
                    AuroraNavIcon(
                        destination = tab.destination,
                        size = 24,
                        isSelected = currentTab == tab,
                        userDisplayName = null
                    )
                },
                label = { Text(tab.label) }
            )
        }
    }
}
