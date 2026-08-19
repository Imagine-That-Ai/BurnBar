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
import com.openburnbar.InboxPendingNavigation
import com.openburnbar.OsPendingNavigation
import com.openburnbar.data.policy.MobileOsDestination
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

    /**
     * The AI Inbox earns a top-level tab rather than living inside another
     * surface. Its whole premise — "what happened while I wasn't watching" — is
     * the reason a phone gets picked up in the first place, so burying it one
     * level down would put the app's most time-sensitive content behind the
     * least time-sensitive gesture. It also carries an unread count, and a badge
     * nobody can see is not a badge.
     *
     * The cost is a seventh item in the tray. At a 360dp handset that is 48dp
     * per item after the pill's insets — exactly Material's minimum touch
     * target, not below it — and the tray order is user-customizable through
     * the visual settings, so anyone who disagrees can reorder or drop it.
     */
    object INBOX : BurnBarTab("inbox", "Inbox", AuroraNavDestination.INBOX)

    object INSIGHTS : BurnBarTab("insights", "Budget & Insights", AuroraNavDestination.INSIGHTS)

    object STREAMS : BurnBarTab("streams", "Streams", AuroraNavDestination.STREAMS)

    // Plan 2: tab renamed to "Assistants" — the route stays `hermes` so deep
    // links (`burnbar://hermes`, `burnbar://chat`) and bookmarks continue to
    // resolve to the same destination.
    object HERMES : BurnBarTab("hermes", "Assistants", AuroraNavDestination.HERMES)

    object YOU : BurnBarTab("you", "Store", AuroraNavDestination.YOU)

    /**
     * The Agent Fleet dashboard, mirrored from the Mac through the sealed
     * `fleet_snapshot` Firestore document. Not part of the default tray —
     * users add it through Settings → Navigation — so [allCandidates] (the
     * default set) does not list it while [addableCandidates] does.
     */
    object FLEET : BurnBarTab("fleet", "Fleet", AuroraNavDestination.FLEET)

    companion object {
        /** The default tray, in default order. */
        val allCandidates: List<BurnBarTab> = listOf(PULSE, BURN, INBOX, INSIGHTS, STREAMS, HERMES, YOU)

        /** Every tab the customization screen may place in the tray. */
        val addableCandidates: List<BurnBarTab> = allCandidates + FLEET

        /** The route `you` can never be removed: it hosts Settings, the only way back. */
        val PERMANENT_ROUTE: String = YOU.route

        /** A tray below this many tabs stops being a tray. */
        const val MINIMUM_TAB_COUNT: Int = 2

        val all: List<BurnBarTab> get() {
            return try {
                resolveCustomizedTabs(
                    orderedRoutes = com.openburnbar.ui.settings.GlobalVisualSettings.orderedTabRoutes,
                    removedRoutes = com.openburnbar.ui.settings.GlobalVisualSettings.removedTabRoutes,
                )
            } catch (_: IllegalStateException) {
                allCandidates
            }
        }

        /**
         * Resolves the visible tray from the stored order + removal prefs.
         *
         * - [orderedRoutes] wins for ordering; unknown tokens are dropped.
         * - Every DEFAULT tab missing from the order is re-appended unless the
         *   user explicitly removed it (so a tab added in an app update still
         *   shows up, while a deliberate removal sticks).
         * - Non-default tabs (Fleet) appear only when explicitly ordered.
         * - Guards: `you` is always present, and a result below
         *   [MINIMUM_TAB_COUNT] falls back to the defaults rather than
         *   rendering an unusable tray.
         */
        fun resolveCustomizedTabs(orderedRoutes: List<String>, removedRoutes: List<String>): List<BurnBarTab> {
            val removed = removedRoutes.toSet() - PERMANENT_ROUTE
            val ordered = orderedRoutes
                .mapNotNull { route -> addableCandidates.firstOrNull { it.route == route } }
                .distinct()
                .filter { it.route !in removed }
            val reAppended = allCandidates.filter { it !in ordered && it.route !in removed }
            val merged = ordered + reAppended
            val visible = if (BurnBarTab.YOU in merged) merged else merged + YOU
            if (visible.size < MINIMUM_TAB_COUNT) return allCandidates
            return visible
        }

        fun fromRoute(route: String?): BurnBarTab? = addableCandidates.firstOrNull { it.route == route }
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

/**
 * Single instrumentation point for `screen.viewed` + `nav.route.changed`. The
 * nav back-stack route is the one source of route truth, so emitting here (vs.
 * per-screen) keeps coverage complete and collapses ~all per-screen
 * `screen_view` candidates into one parameterized event. Every route is mapped
 * to a BOUNDED surface via [com.openburnbar.analytics.AnalyticsSurface.forRoute]
 * — raw route strings (which can carry object slugs/ids) never reach the wire.
 * Each call is dropped unless analytics consent is granted, so nothing leaks
 * pre-opt-in.
 */
@Composable
private fun AnalyticsRouteTracker(currentRoute: String?) {
    val viewedSurfaces = remember { mutableStateOf(emptySet<String>()) }
    val previousSurface = remember { mutableStateOf<String?>(null) }
    LaunchedEffect(currentRoute) {
        if (currentRoute == null) return@LaunchedEffect
        val surface = com.openburnbar.analytics.AnalyticsSurface.forRoute(currentRoute)
        val from = previousSurface.value
        if (from != null && from != surface.wire) {
            com.openburnbar.analytics.AnalyticsManager.track(
                com.openburnbar.analytics.AnalyticsEvent.NAV_ROUTE_CHANGED,
                mapOf(
                    "from_route" to com.openburnbar.analytics.AnalyticsValue.Str(from),
                    "to_route" to com.openburnbar.analytics.AnalyticsValue.Str(surface.wire),
                ),
            )
        }
        val isFirstView = !viewedSurfaces.value.contains(surface.wire)
        if (isFirstView) viewedSurfaces.value = viewedSurfaces.value + surface.wire
        com.openburnbar.analytics.AnalyticsManager.track(
            com.openburnbar.analytics.AnalyticsEvent.SCREEN_VIEWED,
            mapOf(
                "surface" to com.openburnbar.analytics.AnalyticsValue.Str(surface.wire),
                "is_first_view" to com.openburnbar.analytics.AnalyticsValue.Bool(isFirstView),
            ),
        )
        previousSurface.value = surface.wire
    }
}

@Composable
fun BurnBarNavHost(
    modifier: Modifier = Modifier,
    navController: NavHostController = rememberNavController(),
    userStore: UserStore = viewModel(),
    chatState: FloatingChatState = rememberFloatingChatState(),
    subscriptionStore: HostedQuotaSubscriptionStore = viewModel(),
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
    AnalyticsRouteTracker(currentRoute)
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

    val navigateTo: (BurnBarTab) -> Unit = { tab -> navigateToTab(navController, tab) }

    InboxWarmDeepLinkNavigator(navController = navController, isSignedIn = currentUser.isSignedIn)
    OsWarmDeepLinkNavigator(navController = navController, isSignedIn = currentUser.isSignedIn)

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
                    userUid = currentUser.uid,
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
 * Moves the nav host to the Inbox tab when a WARM `burnbar://inbox` deep link
 * asked for it.
 *
 * The navDeepLink machinery only inspects the LAUNCH intent, so a link
 * delivered via `onNewIntent` never navigates on its own; MainActivity raises
 * [InboxPendingNavigation] instead, and this claims it (once the signed-in
 * graph exists) and moves to the Inbox tab exactly as a tab tap would.
 * `claim()` consumes the request, so recomposition cannot re-navigate.
 */
@Composable
private fun InboxWarmDeepLinkNavigator(navController: NavHostController, isSignedIn: Boolean) {
    val requested by InboxPendingNavigation.requested.collectAsState()
    LaunchedEffect(requested, isSignedIn) {
        if (requested && isSignedIn && InboxPendingNavigation.claim()) {
            navigateToTab(navController, BurnBarTab.INBOX)
        }
    }
}

@Composable
private fun OsWarmDeepLinkNavigator(navController: NavHostController, isSignedIn: Boolean) {
    val pending by OsPendingNavigation.pending.collectAsState()
    LaunchedEffect(pending, isSignedIn) {
        if (!isSignedIn || pending == null) return@LaunchedEffect
        val request = OsPendingNavigation.claim() ?: return@LaunchedEffect
        when (request.destination) {
            MobileOsDestination.BURN ->
                navigateToTab(navController, BurnBarTab.BURN)
            MobileOsDestination.INBOX ->
                navigateToTab(navController, BurnBarTab.INBOX)
            MobileOsDestination.FLEET ->
                navigateToTab(navController, BurnBarTab.FLEET)
            MobileOsDestination.MISSION,
            MobileOsDestination.MERCURY_CALL,
            ->
                navController.navigate(request.route) { launchSingleTop = true }
            else -> Unit
        }
    }
}

private fun navigateToTab(navController: NavHostController, tab: BurnBarTab) {
    navController.navigate(
        tab.route,
        burnBarTabNavOptions(navController.graph.findStartDestination().id),
    )
}

/**
 * The live monthly Play price for a tier's unlock CTA, or null when Play prices
 * haven't loaded (the unlock UI then shows no amount — never a hardcoded dollar
 * figure). Maps the gating tier to its monthly subscription SKU.
 */
private fun monthlyPriceForTier(prices: Map<String, HostedQuotaProductDetails>, tier: com.openburnbar.ui.pro.CloudTier): String? {
    val productID =
        when (tier) {
            com.openburnbar.ui.pro.CloudTier.ULTRA -> HostedQuotaSubscriptionStore.CLOUD_ULTRA_MONTHLY_PRODUCT_ID
            com.openburnbar.ui.pro.CloudTier.PRO -> HostedQuotaSubscriptionStore.CLOUD_PRO_MONTHLY_PRODUCT_ID
            com.openburnbar.ui.pro.CloudTier.CLOUD -> HostedQuotaSubscriptionStore.PRODUCT_ID
            com.openburnbar.ui.pro.CloudTier.NONE -> return null
        }
    return prices[productID]?.formattedPrice
}
