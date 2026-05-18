package com.openburnbar.ui.settings

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.NavigateNext
import androidx.compose.material.icons.filled.Clear
import androidx.compose.material.icons.filled.Cloud
import androidx.compose.material.icons.filled.Computer
import androidx.compose.material.icons.filled.Devices
import androidx.compose.material.icons.filled.Notifications
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Tv
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.models.AgentProvider
import com.openburnbar.ui.components.ProviderLogo
import com.openburnbar.ui.smartdisplay.SmartDisplayView
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraRadius
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraType
import com.openburnbar.ui.theme.AuroraTypography

/**
 * Top-level Android Settings surface. Owns the [SettingsRouter] and switches
 * between the root row list, the search results list, and the sub-screens.
 *
 * Wired into the You tab so the existing "Settings" row pushes here.
 */
@Composable
fun SettingsRootScreen(
    onBack: (() -> Unit)? = null,
    onComputerUse: (() -> Unit)? = null,
    onMenuBarPrefs: @Composable (onBack: () -> Unit) -> Unit,
) {
    val router = remember { SettingsRouter() }

    AnimatedContent(
        targetState = router.page,
        transitionSpec = { fadeIn() togetherWith fadeOut() },
        label = "settings-page"
    ) { page ->
        when (page) {
            SettingsPageRoute.ROOT -> SettingsRootContent(router = router, onBack = onBack, onComputerUse = onComputerUse)
            SettingsPageRoute.SMART_DISPLAYS -> SmartDisplayDeepLinkWrapper(
                router = router,
                onBack = { router.page = SettingsPageRoute.ROOT }
            )
            SettingsPageRoute.MENU_BAR_PREFS -> onMenuBarPrefs { router.page = SettingsPageRoute.ROOT }
        }
    }
}

@Composable
private fun SettingsRootContent(
    router: SettingsRouter,
    onBack: (() -> Unit)?,
    onComputerUse: (() -> Unit)?,
) {
    val isDark = isSystemInDarkTheme()
    var searchMode by rememberSaveable { mutableStateOf(false) }
    val searchFocusRequester = remember { FocusRequester() }

    LaunchedEffect(searchMode) {
        if (searchMode) {
            try { searchFocusRequester.requestFocus() } catch (_: Throwable) {}
        }
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(if (isDark) AuroraColors.darkBackground else AuroraColors.lightBackground)
            .padding(horizontal = AuroraSpacing.lg.dp),
        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.md.dp)
    ) {
        Spacer(modifier = Modifier.height(AuroraSpacing.lg.dp))

        // Top bar — Back + Title + Search toggle, OR back + search field.
        Row(verticalAlignment = Alignment.CenterVertically) {
            if (onBack != null && !searchMode) {
                IconButton(onClick = onBack) {
                    Icon(
                        imageVector = Icons.AutoMirrored.Filled.ArrowBack,
                        contentDescription = "Back"
                    )
                }
            }
            if (searchMode) {
                OutlinedTextField(
                    value = router.query,
                    onValueChange = { router.query = it },
                    placeholder = { Text("Search settings") },
                    leadingIcon = {
                        Icon(Icons.Filled.Search, contentDescription = null)
                    },
                    trailingIcon = {
                        IconButton(onClick = {
                            if (router.query.isEmpty()) {
                                searchMode = false
                            } else {
                                router.query = ""
                            }
                        }) {
                            Icon(Icons.Filled.Clear, contentDescription = "Clear")
                        }
                    },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                    modifier = Modifier
                        .weight(1f)
                        .focusRequester(searchFocusRequester)
                )
            } else {
                Text(
                    "Settings",
                    style = AuroraType.displayLarge,
                    color = MaterialTheme.colorScheme.onSurface,
                    modifier = Modifier.weight(1f)
                )
                IconButton(onClick = { searchMode = true }) {
                    Icon(Icons.Filled.Search, contentDescription = "Search settings")
                }
            }
        }

        if (router.isSearching) {
            SettingsSearchResultsScreen(router = router)
        } else {
            SettingsRootList(router = router, onComputerUse = onComputerUse)
        }
    }
}

@Composable
private fun SettingsRootList(
    router: SettingsRouter,
    onComputerUse: (() -> Unit)?,
) {
    val listState = rememberLazyListState()

    // Map anchor ids to LazyColumn indexes so the router can scroll.
    val rootRows = remember {
        val providerRows = AgentProvider.entries
            .sortedBy { it.displayName.lowercase() }
            .map { provider ->
                RootRow(
                    anchor = SettingsAnchor.provider(provider.key),
                    icon = Icons.Filled.Search,
                    title = provider.displayName,
                    subtitle = "Provider quota, usage, and connection signal",
                    pageRoute = SettingsPageRoute.ROOT,
                    logoProviderKeys = listOf(provider.key),
                    onTap = {}
                )
            }

        listOf(
            RootRow(
                anchor = SettingsAnchor.CLOUD_SYNC,
                icon = Icons.Filled.Cloud,
                title = "Cloud Sync",
                subtitle = "Sync usage and conversations to OpenBurnBar Cloud",
                pageRoute = SettingsPageRoute.ROOT,
                onTap = {}
            ),
            RootRow(
                anchor = SettingsAnchor.PROVIDERS_ROW,
                icon = Icons.Filled.Search,
                title = "Provider connections",
                subtitle = "Find OpenCode, Codex, Claude, and other quota providers",
                pageRoute = SettingsPageRoute.ROOT,
                logoProviderKeys = listOf(
                    AgentProvider.CLAUDE_CODE.key,
                    AgentProvider.OPENCODE.key,
                    AgentProvider.FACTORY.key,
                    AgentProvider.OPEN_AI.key,
                ),
                onTap = {}
            ),
        ) + providerRows + listOf(
            RootRow(
                anchor = SettingsAnchor.CONNECTED_DEVICES,
                icon = Icons.Filled.Devices,
                title = "Connected Devices",
                subtitle = "Manage which devices can read your data",
                pageRoute = SettingsPageRoute.ROOT,
                onTap = {}
            ),
            RootRow(
                anchor = SettingsAnchor.SMART_DISPLAYS_ROW,
                icon = Icons.Filled.Tv,
                title = "Smart Displays",
                subtitle = "Google Smart Display · Pixel Clock",
                pageRoute = SettingsPageRoute.SMART_DISPLAYS,
                onTap = { router.page = SettingsPageRoute.SMART_DISPLAYS }
            ),
            RootRow(
                anchor = SettingsAnchor.GOOGLE_SMART_DISPLAY,
                icon = Icons.Filled.Tv,
                title = "Google Smart Display",
                subtitle = "Nest Hub and Pixel Tablet glance",
                pageRoute = SettingsPageRoute.SMART_DISPLAYS,
                onTap = { router.page = SettingsPageRoute.SMART_DISPLAYS }
            ),
            RootRow(
                anchor = SettingsAnchor.PIXEL_CLOCK,
                icon = Icons.Filled.Tv,
                title = "Pixel Clock",
                subtitle = "Pixel Clock cost glance",
                pageRoute = SettingsPageRoute.SMART_DISPLAYS,
                onTap = { router.page = SettingsPageRoute.SMART_DISPLAYS }
            ),
            RootRow(
                anchor = SettingsAnchor.QUICK_GLANCE_ROW,
                icon = Icons.Filled.Notifications,
                title = "Quick-Glance Notification",
                subtitle = "BurnBar persistent cost glance",
                pageRoute = SettingsPageRoute.MENU_BAR_PREFS,
                onTap = { router.page = SettingsPageRoute.MENU_BAR_PREFS }
            ),
            RootRow(
                anchor = SettingsAnchor.COMPUTER_USE_ROW,
                icon = Icons.Filled.Computer,
                title = "Computer Use",
                subtitle = "Agent Watch, phone takeover, approvals, and audit chain",
                pageRoute = SettingsPageRoute.ROOT,
                onTap = { onComputerUse?.invoke() }
            ),
            RootRow(
                anchor = SettingsAnchor.PERSISTENT_NOTIFICATION,
                icon = Icons.Filled.Notifications,
                title = "Show quick-glance notification",
                subtitle = "Live cost glance in the notification shade",
                pageRoute = SettingsPageRoute.MENU_BAR_PREFS,
                onTap = { router.page = SettingsPageRoute.MENU_BAR_PREFS }
            ),
            RootRow(
                anchor = SettingsAnchor.HERMES_CONNECTIONS,
                icon = Icons.Filled.Search,
                title = "Hermes Connections",
                subtitle = "Connected Hermes endpoints and tokens",
                pageRoute = SettingsPageRoute.ROOT,
                logoProviderKeys = listOf(
                    AgentProvider.HERMES.key,
                    AgentProvider.CLAUDE_CODE.key,
                    AgentProvider.CODEX.key,
                    AgentProvider.OPEN_CLAW.key,
                ),
                onTap = {}
            ),
            RootRow(
                anchor = SettingsAnchor.HERMES_MODELS,
                icon = Icons.Filled.Search,
                title = "Hermes Models",
                subtitle = "Default models exposed by Hermes",
                pageRoute = SettingsPageRoute.ROOT,
                logoProviderKeys = listOf(
                    AgentProvider.HERMES.key,
                    AgentProvider.CLAUDE_CODE.key,
                    AgentProvider.OPEN_AI.key,
                    AgentProvider.GEMINI_CLI.key,
                ),
                onTap = {}
            ),
            RootRow(
                anchor = SettingsAnchor.HERMES_DISPLAY,
                icon = Icons.Filled.Search,
                title = "Hermes Display",
                subtitle = "TPS overlay and pretext",
                pageRoute = SettingsPageRoute.ROOT,
                logoProviderKeys = listOf(AgentProvider.HERMES.key),
                onTap = {}
            ),
            RootRow(
                anchor = SettingsAnchor.HERMES_GATEWAY,
                icon = Icons.Filled.Search,
                title = "Hermes Gateway",
                subtitle = "URL and token for the Hermes webapi gateway",
                pageRoute = SettingsPageRoute.ROOT,
                logoProviderKeys = listOf(AgentProvider.HERMES.key),
                onTap = {}
            ),
            RootRow(
                anchor = SettingsAnchor.HERMES_STATUS,
                icon = Icons.Filled.Search,
                title = "Hermes Status",
                subtitle = "Live Hermes connection state",
                pageRoute = SettingsPageRoute.ROOT,
                logoProviderKeys = listOf(AgentProvider.HERMES.key),
                onTap = {}
            ),
        )
    }

    val anchorIndex = remember(rootRows) {
        rootRows.withIndex().associate { (i, r) -> r.anchor to i }
    }

    // Scroll to pending anchor on arrival.
    val pending = router.pendingAnchor
    LaunchedEffect(pending) {
        if (pending != null) {
            val idx = anchorIndex[pending]
            if (idx != null) {
                listState.animateScrollToItem(idx)
                router.consumePendingAnchor(pending)
                // Clear halo after ~1.4s.
                kotlinx.coroutines.delay(1_400)
                router.clearHighlight(pending)
            }
        }
    }

    LazyColumn(
        state = listState,
        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.md.dp),
        modifier = Modifier.fillMaxSize()
    ) {
        itemsIndexed(rootRows) { _, row ->
            SettingsRow(
                icon = row.icon,
                title = row.title,
                subtitle = row.subtitle,
                logoProviderKeys = row.logoProviderKeys,
                onClick = row.onTap,
                highlighted = router.highlightedAnchor == row.anchor
            )
        }
    }
}

private data class RootRow(
    val anchor: String,
    val icon: ImageVector,
    val title: String,
    val subtitle: String,
    val pageRoute: SettingsPageRoute,
    val logoProviderKeys: List<String> = emptyList(),
    val onTap: () -> Unit,
)

@Composable
private fun SmartDisplayDeepLinkWrapper(
    router: SettingsRouter,
    onBack: () -> Unit,
) {
    // SmartDisplayView already has its own scroll surface — we surface the
    // halo via highlightedAnchor but leave scroll behavior up to it.
    LaunchedEffect(router.pendingAnchor) {
        val pending = router.pendingAnchor ?: return@LaunchedEffect
        if (SettingsManifest.anchorIndex[pending] == SettingsPageRoute.SMART_DISPLAYS) {
            // Consume so we don't re-fire; halo fades on its own.
            router.consumePendingAnchor(pending)
            kotlinx.coroutines.delay(1_400)
            router.clearHighlight(pending)
        }
    }
    SmartDisplayView(onBack = onBack)
}

@Composable
internal fun SettingsRow(
    icon: ImageVector,
    title: String,
    subtitle: String,
    highlighted: Boolean,
    logoProviderKeys: List<String> = emptyList(),
    onClick: () -> Unit = {},
) {
    val haloColor by animateColorAsState(
        targetValue = if (highlighted) {
            Color(0xFFFFA800).copy(alpha = 0.18f)
        } else {
            Color.Transparent
        },
        animationSpec = tween(durationMillis = 350),
        label = "settings-row-halo"
    )

    Surface(
        onClick = onClick,
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(AuroraRadius.lg.dp),
        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.6f)
    ) {
        Surface(
            color = haloColor,
            shape = RoundedCornerShape(AuroraRadius.lg.dp),
        ) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(AuroraSpacing.md.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                val logoProviders = logoProviderKeys.mapNotNull { AgentProvider.fromKey(it) }
                if (logoProviders.isNotEmpty()) {
                    SettingsProviderLogoStack(providers = logoProviders)
                } else {
                    Icon(
                        imageVector = icon,
                        contentDescription = null,
                        modifier = Modifier.size(24.dp),
                        tint = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
                Spacer(modifier = Modifier.width(AuroraSpacing.md.dp))
                Column(modifier = Modifier.weight(1f)) {
                    Text(title, fontSize = AuroraTypography.body.sp, fontWeight = FontWeight.SemiBold)
                    Text(
                        subtitle,
                        fontSize = AuroraTypography.caption.sp,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
                Icon(
                    imageVector = Icons.AutoMirrored.Filled.NavigateNext,
                    contentDescription = null,
                    modifier = Modifier.size(20.dp),
                    tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.5f)
                )
            }
        }
    }
}

@Composable
private fun SettingsProviderLogoStack(
    providers: List<AgentProvider>,
    maxVisible: Int = 4,
) {
    Row(horizontalArrangement = Arrangement.spacedBy((-7).dp)) {
        providers.take(maxVisible).forEach { provider ->
            ProviderLogo(provider = provider, size = 28.dp)
        }
    }
}
