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
import com.openburnbar.ui.components.AuroraNavDestination
import com.openburnbar.ui.components.AuroraNavIcon
import com.openburnbar.ui.components.FloatingChatMode
import com.openburnbar.ui.components.FloatingChatPill
import com.openburnbar.ui.hermes.HermesView
import com.openburnbar.ui.pulse.PulseView
import com.openburnbar.ui.streams.StreamsView
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.you.YouView

/**
 * Tab catalog. Route strings are deep-link addressable via `burnbar://`.
 */
sealed class BurnBarTab(
    val route: String,
    val label: String,
    val destination: AuroraNavDestination
) {
    object PULSE   : BurnBarTab("pulse",   "Pulse",   AuroraNavDestination.PULSE)
    object BURN    : BurnBarTab("burn",    "Burn",    AuroraNavDestination.BURN)
    object STREAMS : BurnBarTab("streams", "Streams", AuroraNavDestination.STREAMS)
    object HERMES  : BurnBarTab("hermes",  "Hermes",  AuroraNavDestination.HERMES)
    object YOU     : BurnBarTab("you",     "You",     AuroraNavDestination.YOU)

    companion object {
        val all: List<BurnBarTab> = listOf(PULSE, BURN, STREAMS, HERMES, YOU)
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
        if (currentUser.isSignedIn) {
            if (isWideScreen) {
                // Two-pane: NavigationRail (sidebar) + content
                Row(modifier = Modifier.fillMaxSize()) {
                    BurnBarNavigationRail(
                        currentTab = currentTab,
                        onSelect = navigateTo
                    )
                    Box(modifier = Modifier.weight(1f)) {
                        BurnBarContent(
                            navController = navController,
                            navigateToBurn = { navigateTo(BurnBarTab.BURN) },
                            navigateToHermes = { navigateTo(BurnBarTab.HERMES) },
                            navigateToStreams = { navigateTo(BurnBarTab.STREAMS) }
                        )
                    }
                }
            } else {
                // Phone: full content + bottom nav pill
                Column(modifier = Modifier.fillMaxSize()) {
                    Box(modifier = Modifier.weight(1f)) {
                        BurnBarContent(
                            navController = navController,
                            navigateToBurn = { navigateTo(BurnBarTab.BURN) },
                            navigateToHermes = { navigateTo(BurnBarTab.HERMES) },
                            navigateToStreams = { navigateTo(BurnBarTab.STREAMS) }
                        )
                    }
                    AuroraNavigationTray(
                        destinations = BurnBarTab.all.map { it.destination },
                        selectedDestination = currentTab.destination,
                        onDestinationSelected = { dest ->
                            BurnBarTab.all.firstOrNull { it.destination == dest }?.let(navigateTo)
                        },
                        userDisplayName = currentUser.displayName
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
                navDeepLink { uriPattern = "burnbar://chat" }
            )
        ) { HermesView() }
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
    onSelect: (BurnBarTab) -> Unit
) {
    NavigationRail(
        modifier = Modifier
            .fillMaxHeight()
            .width(96.dp),
        containerColor = MaterialTheme.colorScheme.surface.copy(alpha = 0.6f)
    ) {
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
