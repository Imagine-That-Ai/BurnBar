// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.navigation

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.NavGraph.Companion.findStartDestination
import androidx.navigation.NavHostController
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import com.openburnbar.data.stores.HostedQuotaProductDetails
import com.openburnbar.data.stores.HostedQuotaSubscriptionStore
import com.openburnbar.data.stores.UserStore
import com.openburnbar.ui.auth.LoginScreen
import com.openburnbar.ui.components.AuroraBackdrop
import com.openburnbar.ui.components.AuroraNavDestination
import com.openburnbar.ui.components.EasterEggController
import com.openburnbar.ui.components.EasterEggOverlay
import com.openburnbar.ui.components.FloatingChatMode
import com.openburnbar.ui.components.rememberEasterEggController

/**
 * Tab catalog. Route strings are deep-link addressable via `burnbar://`.
 */
sealed class BurnBarTab(
    val route: String,
    val label: String,
    val destination: AuroraNavDestination,
) {
    object PULSE : BurnBarTab("pulse", "Pulse", AuroraNavDestination.PULSE)

    object BURN : BurnBarTab("burn", "Burn", AuroraNavDestination.BURN)

    object INSIGHTS : BurnBarTab("insights", "Budget & Insights", AuroraNavDestination.INSIGHTS)

    object STREAMS : BurnBarTab("streams", "Streams", AuroraNavDestination.STREAMS)

    // Plan 2: tab renamed to "Assistants" — the route stays `hermes` so deep
    // links (`burnbar://hermes`, `burnbar://chat`) and bookmarks continue to
    // resolve to the same destination.
    object HERMES : BurnBarTab("hermes", "Assistants", AuroraNavDestination.HERMES)

    object YOU : BurnBarTab("you", "Store", AuroraNavDestination.YOU)

    companion object {
        val allCandidates: List<BurnBarTab> = listOf(PULSE, BURN, INSIGHTS, STREAMS, HERMES, YOU)
        val all: List<BurnBarTab> get() {
            try {
                val primary = com.openburnbar.ui.settings.GlobalVisualSettings.primaryTabs.value
                val secondary = com.openburnbar.ui.settings.GlobalVisualSettings.secondaryTabs.value
                val keys = (primary.split(",") + secondary.split(",")).map { it.trim() }.filter { it.isNotEmpty() }
                val mapped = keys.mapNotNull { key -> allCandidates.firstOrNull { it.route == key } }
                if (mapped.isEmpty()) return allCandidates
                // Add any missing
                val missing = allCandidates.filter { !mapped.contains(it) }
                return mapped + missing
            } catch (_: IllegalStateException) {
                return allCandidates
            }
        }

        fun fromRoute(route: String?): BurnBarTab? = allCandidates.firstOrNull { it.route == route }
    }
}

/** Simple singleton to pass a pending prompt to HermesView at navigation time. */
object HermesPendingPrompt {
    var pending: String? = null
}

/**
 * Shared state for the floating chat pill — owned by the nav host so the pill
 * survives across tab changes. Phase E will hydrate `streaming` and `snippet`
 * from the real chat stream; for now this is a hand-driven state container.
 */
class FloatingChatState {
    var mode by mutableStateOf(FloatingChatMode.Idle)
    var snippet by mutableStateOf("")

    fun startStreaming(text: String = "") {
        mode = FloatingChatMode.Streaming
        snippet = text
    }

    fun show(snippet: String) {
        mode = FloatingChatMode.Idle
        this.snippet = snippet
    }

    fun hide() {
        mode = FloatingChatMode.Hidden
    }
}

@Composable
fun rememberFloatingChatState(): FloatingChatState = remember { FloatingChatState() }

@Composable
fun BurnBarNavHost(
    modifier: Modifier = Modifier,
    navController: NavHostController = rememberNavController(),
    userStore: UserStore = viewModel(),
    chatState: FloatingChatState = rememberFloatingChatState(),
    subscriptionStore: HostedQuotaSubscriptionStore = viewModel(),
    // Hidden delight: a hit-test-disabled overlay that idles at zero cost and plays a
    // theme-appropriate celebration when the user rapidly scrolls up-and-down (or a
    // cute token bounce at the top/bottom boundary). Its nested-scroll connection,
    // installed on the root below, receives reports from every scrollable child.
    easterEggController: EasterEggController = rememberEasterEggController(),
) {
    val currentUser by userStore.user.collectAsState()
    val context = LocalContext.current
    LaunchedEffect(context) {
        subscriptionStore.initialize(context)
        subscriptionStore.load()
    }
    val isCloudMember by subscriptionStore.isActive.collectAsState()
    val currentTier by subscriptionStore.currentTier.collectAsState()
    val proPrice by subscriptionStore.productDetailsByID.collectAsState()
    val navBackStackEntry by navController.currentBackStackEntryAsState()
    val currentRoute = navBackStackEntry?.destination?.route
    val currentTab =
        remember(currentRoute) {
            when (currentRoute) {
                "cloud_store",
                "computer_use_agent",
                -> BurnBarTab.YOU

                else -> BurnBarTab.fromRoute(currentRoute) ?: BurnBarTab.PULSE
            }
        }

    val isWideScreen = LocalConfiguration.current.screenWidthDp > 600

    val navigateTo: (BurnBarTab) -> Unit = { tab ->
        // Canonical bottom-nav navigation: pop-with-save to the start
        // destination + restore, so each tab keeps exactly one (state-saved)
        // back-stack entry and tab returns restore warm ViewModels instead of
        // reloading. See burnBarTabNavOptions for the full contract.
        navController.navigate(
            tab.route,
            burnBarTabNavOptions(navController.graph.findStartDestination().id),
        )
    }

    Box(modifier = modifier.fillMaxSize().nestedScroll(easterEggController.nestedScrollConnection)) {
        AuroraBackdrop()

        if (currentUser.isSignedIn) {
            BurnBarSignedInShell(
                state =
                BurnBarSignedInShellState(
                    isWideScreen = isWideScreen,
                    currentTab = currentTab,
                    isCloudMember = isCloudMember,
                    currentTier = currentTier,
                    priceForTier = { tier -> monthlyPriceForTier(proPrice, tier) },
                    userDisplayName = currentUser.displayName,
                    userPhotoUrl = currentUser.photoUrl,
                    chatState = chatState,
                ),
                navController = navController,
                navigateTo = navigateTo,
            )
        } else {
            val isSigningIn by userStore.isSigningIn.collectAsState()
            val authError by userStore.authError.collectAsState()
            LoginScreen(
                userStore = userStore,
                isSigningIn = isSigningIn,
                authError = authError,
                onDismissError = { userStore.clearError() },
            )
        }

        // TOP layer, over all content. No pointer modifier, so touches pass through.
        EasterEggOverlay(controller = easterEggController)
    }
}

/**
 * The live monthly Play price for a tier's unlock CTA, or null when Play prices
 * haven't loaded (the unlock UI then shows no amount — never a hardcoded dollar
 * figure). Maps the gating tier to its monthly subscription SKU.
 */
private fun monthlyPriceForTier(
    prices: Map<String, HostedQuotaProductDetails>,
    tier: com.openburnbar.ui.pro.CloudTier,
): String? {
    val productID =
        when (tier) {
            com.openburnbar.ui.pro.CloudTier.ULTRA -> HostedQuotaSubscriptionStore.CLOUD_ULTRA_MONTHLY_PRODUCT_ID
            com.openburnbar.ui.pro.CloudTier.PRO -> HostedQuotaSubscriptionStore.CLOUD_PRO_MONTHLY_PRODUCT_ID
            com.openburnbar.ui.pro.CloudTier.CLOUD -> HostedQuotaSubscriptionStore.PRODUCT_ID
            com.openburnbar.ui.pro.CloudTier.NONE -> return null
        }
    return prices[productID]?.formattedPrice
}
