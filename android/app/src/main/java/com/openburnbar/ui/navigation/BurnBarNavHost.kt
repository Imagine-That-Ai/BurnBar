package com.openburnbar.ui.navigation

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
import androidx.navigation.navDeepLink
import com.openburnbar.data.stores.UserStore
import com.openburnbar.ui.auth.LoginScreen
import com.openburnbar.ui.burn.BurnView
import com.openburnbar.ui.components.AuroraBackdrop
import com.openburnbar.ui.components.AuroraNavDestination
import com.openburnbar.ui.components.AuroraNavIcon
import com.openburnbar.ui.components.BurnBarLogo
import com.openburnbar.ui.components.FloatingChatMode
import com.openburnbar.ui.components.FloatingChatPill
import com.openburnbar.ui.hermes.AssistantsScreen
import com.openburnbar.ui.hermes.HermesView
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

@Composable
fun BurnBarNavHost(
    modifier: Modifier = Modifier,
    navController: NavHostController = rememberNavController(),
    userStore: UserStore = viewModel(),
    chatState: FloatingChatState = rememberFloatingChatState()
) {
    val isDark = isSystemInDarkTheme()
    val currentUser by userStore.user.collectAsState()
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
                        navigateToStreams = { navigateTo(BurnBarTab.STREAMS) }
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
                        userPhotoUrl = currentUser.photoUrl
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
    navigateToStreams: () -> Unit
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
        ) { InsightsScreen() }
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
        ) { AssistantsScreen() }
        composable(
            BurnBarTab.YOU.route,
            deepLinks = listOf(navDeepLink { uriPattern = "burnbar://you" })
        ) { YouView() }
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
