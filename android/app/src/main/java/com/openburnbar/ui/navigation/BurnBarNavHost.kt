package com.openburnbar.ui.navigation

import androidx.compose.animation.*
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.NavHostController
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import com.openburnbar.ui.burn.BurnView
import com.openburnbar.ui.hermes.HermesView
import com.openburnbar.ui.pulse.PulseView
import com.openburnbar.ui.streams.StreamsView
import com.openburnbar.ui.you.YouView
import com.openburnbar.ui.auth.LoginScreen
import com.openburnbar.data.stores.UserStore
import com.openburnbar.ui.theme.*

sealed class BurnBarTab(val route: String, val label: String, val icon: @Composable () -> Unit) {
    object PULSE : BurnBarTab("pulse", "Pulse", {})
    object BURN : BurnBarTab("burn", "Burn", {})
    object STREAMS : BurnBarTab("streams", "Streams", {})
    object HERMES : BurnBarTab("hermes", "Hermes", {})
    object YOU : BurnBarTab("you", "You", {})
}

// Simple singleton to pass a pending prompt to HermesView
object HermesPendingPrompt {
    var pending: String? = null
}

@Composable
fun BurnBarNavHost(
    modifier: Modifier = Modifier,
    navController: NavHostController = rememberNavController(),
    userStore: UserStore = viewModel()
) {
    val isDark = isSystemInDarkTheme()
    val currentUser by userStore.user.collectAsState()

    val navBackStackEntry by navController.currentBackStackEntryAsState()
    val currentRoute = navBackStackEntry?.destination?.route

    var currentTab by remember { mutableStateOf<BurnBarTab>(BurnBarTab.PULSE) }

    LaunchedEffect(currentRoute) {
        when (currentRoute) {
            BurnBarTab.PULSE.route -> currentTab = BurnBarTab.PULSE
            BurnBarTab.BURN.route -> currentTab = BurnBarTab.BURN
            BurnBarTab.STREAMS.route -> currentTab = BurnBarTab.STREAMS
            BurnBarTab.HERMES.route -> currentTab = BurnBarTab.HERMES
            BurnBarTab.YOU.route -> currentTab = BurnBarTab.YOU
        }
    }

    val navigateToBurn: () -> Unit = {
        navController.navigate(BurnBarTab.BURN.route) { launchSingleTop = true }
    }

    val navigateToHermes: () -> Unit = {
        navController.navigate(BurnBarTab.HERMES.route) { launchSingleTop = true }
    }

    val navigateToStreams: () -> Unit = {
        navController.navigate(BurnBarTab.STREAMS.route) { launchSingleTop = true }
    }

    Column(modifier = modifier.fillMaxSize()) {
        if (currentUser.isSignedIn) {
            // Content area
            Box(modifier = Modifier.weight(1f)) {
                NavHost(
                    navController = navController,
                    startDestination = BurnBarTab.PULSE.route
                ) {
                    composable(BurnBarTab.PULSE.route) {
                        PulseView(
                            onNavigateToBurn = navigateToBurn,
                            onNavigateToHermes = navigateToHermes,
                            onNavigateToStreams = navigateToStreams
                        )
                    }
                    composable(BurnBarTab.BURN.route) {
                        BurnView()
                    }
                    composable(BurnBarTab.STREAMS.route) {
                        StreamsView()
                    }
                    composable(BurnBarTab.HERMES.route) {
                        HermesView()
                    }
                    composable(BurnBarTab.YOU.route) {
                        YouView()
                    }
                }
            }

            // Bottom navigation bar
            AuroraBottomBar(
                tabs = listOf(BurnBarTab.PULSE, BurnBarTab.BURN, BurnBarTab.STREAMS, BurnBarTab.HERMES, BurnBarTab.YOU),
                selectedTab = currentTab,
                onTabSelected = { tab ->
                    currentTab = tab
                    navController.navigate(tab.route) {
                        launchSingleTop = true
                        restoreState = true
                    }
                }
            )
        } else {
            // Auth gate
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
fun AuroraBottomBar(
    tabs: List<BurnBarTab>,
    selectedTab: BurnBarTab,
    onTabSelected: (BurnBarTab) -> Unit,
    modifier: Modifier = Modifier
) {
    Row(
        modifier = modifier.fillMaxWidth().padding(AuroraSpacing.sm.dp),
        horizontalArrangement = Arrangement.SpaceEvenly
    ) {
        tabs.forEach { tab ->
            val selected = tab == selectedTab
            androidx.compose.material3.TextButton(
                onClick = { onTabSelected(tab) },
                modifier = Modifier.weight(1f)
            ) {
                androidx.compose.material3.Text(
                    text = tab.label,
                    color = if (selected) AuroraColors.ember else AuroraColors.hermesMercury
                )
            }
        }
    }
}
