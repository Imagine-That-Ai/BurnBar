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
import androidx.compose.foundation.layout.Box
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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.ui.res.painterResource
import com.openburnbar.R
import com.openburnbar.ui.theme.UIMode
import com.openburnbar.ui.settings.rememberUIMode
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.NavigateNext
import androidx.compose.material.icons.filled.Clear
import androidx.compose.material.icons.filled.Cloud
import androidx.compose.material.icons.filled.Computer
import androidx.compose.material.icons.filled.Devices
import androidx.compose.material.icons.filled.Notifications
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material.icons.filled.Tv
import androidx.compose.material.icons.filled.Wallpaper
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
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.GridOn
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import com.openburnbar.data.models.AgentProvider
import com.openburnbar.ui.components.AuroraSettingsToggle
import com.openburnbar.ui.components.ProviderLogo
import com.openburnbar.ui.components.WebsiteBackground
import com.openburnbar.ui.smartdisplay.SmartDisplayView
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.settings.rememberExcludeBrandShapesFromSwarm
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
            SettingsPageRoute.THEME_PREFS -> ThemePrefsScreen(
                router = router,
                onBack = { router.page = SettingsPageRoute.ROOT }
            )
            SettingsPageRoute.WALLPAPER_GENERATOR -> WallpaperGeneratorScreen(
                onBack = { router.page = SettingsPageRoute.THEME_PREFS }
            )
            SettingsPageRoute.QUOTA_PREFS -> QuotaCustomizationScreen(
                router = router,
                onBack = { router.page = SettingsPageRoute.ROOT }
            )
            SettingsPageRoute.BUDGET_PREFS -> BudgetSettingsScreen(
                onBack = { router.page = SettingsPageRoute.ROOT }
            )
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
    val useWebsiteBackground by rememberWebsiteBackground()

    LaunchedEffect(searchMode) {
        if (searchMode) {
            try { searchFocusRequester.requestFocus() } catch (_: Throwable) {}
        }
    }

    Box(modifier = Modifier.fillMaxSize()) {
        if (useWebsiteBackground) {
            WebsiteBackground(accentColor = AuroraColors.hermesMercury)
        }

        Column(
            modifier = Modifier
                .fillMaxSize()
                .background(
                    if (useWebsiteBackground) Color.Transparent
                    else if (isDark) AuroraColors.darkBackground
                    else AuroraColors.lightBackground
                )
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
                            contentDescription = "Back",
                            tint = if (useWebsiteBackground) Color.White else MaterialTheme.colorScheme.onSurface
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
                        color = if (useWebsiteBackground) Color.White else MaterialTheme.colorScheme.onSurface,
                        modifier = Modifier.weight(1f)
                    )
                    IconButton(onClick = { searchMode = true }) {
                        Icon(
                            Icons.Filled.Search,
                            contentDescription = "Search settings",
                            tint = if (useWebsiteBackground) Color.White else MaterialTheme.colorScheme.onSurface
                        )
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
}

@Composable
private fun SettingsRootList(
    router: SettingsRouter,
    onComputerUse: (() -> Unit)?,
) {
    val listState = rememberLazyListState()

    var providersExpanded by rememberSaveable { mutableStateOf(false) }
    var hermesExpanded by rememberSaveable { mutableStateOf(false) }
    var smartDisplaysExpanded by rememberSaveable { mutableStateOf(false) }
    var notificationsExpanded by rememberSaveable { mutableStateOf(false) }

    val pending = router.pendingAnchor
    LaunchedEffect(pending) {
        if (pending != null) {
            if (pending.startsWith("root.provider.")) {
                providersExpanded = true
            } else if (pending.startsWith("hermes.")) {
                hermesExpanded = true
            } else if (pending == SettingsAnchor.GOOGLE_SMART_DISPLAY || pending == SettingsAnchor.PIXEL_CLOCK) {
                smartDisplaysExpanded = true
            } else if (pending == SettingsAnchor.PERSISTENT_NOTIFICATION) {
                notificationsExpanded = true
            }
        }
    }

    // Define groups
    val systemGroup = remember {
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
                anchor = SettingsAnchor.CONNECTED_DEVICES,
                icon = Icons.Filled.Devices,
                title = "Connected Devices",
                subtitle = "Manage which devices can read your data",
                pageRoute = SettingsPageRoute.ROOT,
                onTap = {}
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
                anchor = SettingsAnchor.BUDGET_ROW,
                icon = Icons.Filled.Tune,
                title = "Budgeting & Rules",
                subtitle = "Set hard limits and warnings on usage spends",
                pageRoute = SettingsPageRoute.BUDGET_PREFS,
                onTap = { router.page = SettingsPageRoute.BUDGET_PREFS }
            )
        )
    }

    val visualGroup = remember {
        listOf(
            RootRow(
                anchor = SettingsAnchor.THEME_ROW,
                icon = Icons.Filled.AutoAwesome,
                title = "Theme & SOTA UX",
                subtitle = "Customise visual appearance, spring physics, and grid backdrops",
                pageRoute = SettingsPageRoute.THEME_PREFS,
                onTap = { router.page = SettingsPageRoute.THEME_PREFS }
            ),
            RootRow(
                anchor = SettingsAnchor.QUOTA_CUSTOMIZATION_ROW,
                icon = Icons.Filled.GridOn,
                title = "Quota Customisation",
                subtitle = "Rearrange providers, toggle visible buckets, and format percentage displays",
                pageRoute = SettingsPageRoute.QUOTA_PREFS,
                onTap = { router.page = SettingsPageRoute.QUOTA_PREFS }
            )
        )
    }

    val integrationsGroup = remember(smartDisplaysExpanded, notificationsExpanded) {
        val list = mutableListOf<RootRow>()
        list.add(
            RootRow(
                anchor = SettingsAnchor.SMART_DISPLAYS_ROW,
                icon = Icons.Filled.Tv,
                title = "Smart Displays",
                subtitle = "Google Smart Display · Pixel Clock",
                pageRoute = SettingsPageRoute.SMART_DISPLAYS,
                isCollapsibleHeader = true,
                isExpanded = smartDisplaysExpanded,
                onTap = { smartDisplaysExpanded = !smartDisplaysExpanded }
            )
        )
        if (smartDisplaysExpanded) {
            list.add(
                RootRow(
                    anchor = SettingsAnchor.GOOGLE_SMART_DISPLAY,
                    icon = Icons.Filled.Tv,
                    title = "Google Smart Display",
                    subtitle = "Nest Hub and Pixel Tablet glance",
                    pageRoute = SettingsPageRoute.SMART_DISPLAYS,
                    isNested = true,
                    onTap = { router.page = SettingsPageRoute.SMART_DISPLAYS }
                )
            )
            list.add(
                RootRow(
                    anchor = SettingsAnchor.PIXEL_CLOCK,
                    icon = Icons.Filled.Tv,
                    title = "Pixel Clock",
                    subtitle = "Pixel Clock cost glance",
                    pageRoute = SettingsPageRoute.SMART_DISPLAYS,
                    isNested = true,
                    onTap = { router.page = SettingsPageRoute.SMART_DISPLAYS }
                )
            )
        }
        list.add(
            RootRow(
                anchor = SettingsAnchor.QUICK_GLANCE_ROW,
                icon = Icons.Filled.Notifications,
                title = "Quick-Glance Notification",
                subtitle = "BurnBar persistent cost glance",
                pageRoute = SettingsPageRoute.MENU_BAR_PREFS,
                isCollapsibleHeader = true,
                isExpanded = notificationsExpanded,
                onTap = { notificationsExpanded = !notificationsExpanded }
            )
        )
        if (notificationsExpanded) {
            list.add(
                RootRow(
                    anchor = SettingsAnchor.PERSISTENT_NOTIFICATION,
                    icon = Icons.Filled.Notifications,
                    title = "Show quick-glance notification",
                    subtitle = "Live cost glance in the notification shade",
                    pageRoute = SettingsPageRoute.MENU_BAR_PREFS,
                    isNested = true,
                    onTap = { router.page = SettingsPageRoute.MENU_BAR_PREFS }
                )
            )
        }
        list
    }

    val providersGroup = remember(providersExpanded) {
        val list = mutableListOf<RootRow>()
        list.add(
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
                isCollapsibleHeader = true,
                isExpanded = providersExpanded,
                onTap = { providersExpanded = !providersExpanded }
            )
        )
        if (providersExpanded) {
            AgentProvider.entries
                .sortedBy { it.displayName.lowercase() }
                .forEach { provider ->
                    list.add(
                        RootRow(
                            anchor = SettingsAnchor.provider(provider.key),
                            icon = Icons.Filled.Search,
                            title = provider.displayName,
                            subtitle = "${provider.displayName} quota, usage, and signal",
                            pageRoute = SettingsPageRoute.ROOT,
                            logoProviderKeys = listOf(provider.key),
                            isNested = true,
                            onTap = {}
                        )
                    )
                }
        }
        list
    }

    val hermesGroup = remember(hermesExpanded) {
        val list = mutableListOf<RootRow>()
        list.add(
            RootRow(
                anchor = "root.hermes_dev_suite",
                icon = Icons.Filled.Search,
                title = "Hermes Developer Suite",
                subtitle = "Configure gateway, connections, and system pretext",
                pageRoute = SettingsPageRoute.ROOT,
                logoProviderKeys = listOf(AgentProvider.HERMES.key),
                isCollapsibleHeader = true,
                isExpanded = hermesExpanded,
                onTap = { hermesExpanded = !hermesExpanded }
            )
        )
        if (hermesExpanded) {
            list.add(
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
                    isNested = true,
                    onTap = {}
                )
            )
            list.add(
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
                    isNested = true,
                    onTap = {}
                )
            )
            list.add(
                RootRow(
                    anchor = SettingsAnchor.HERMES_DISPLAY,
                    icon = Icons.Filled.Search,
                    title = "Hermes Display",
                    subtitle = "TPS overlay and pretext",
                    pageRoute = SettingsPageRoute.ROOT,
                    logoProviderKeys = listOf(AgentProvider.HERMES.key),
                    isNested = true,
                    onTap = {}
                )
            )
            list.add(
                RootRow(
                    anchor = SettingsAnchor.HERMES_GATEWAY,
                    icon = Icons.Filled.Search,
                    title = "Hermes Gateway",
                    subtitle = "URL and token for the Hermes webapi gateway",
                    pageRoute = SettingsPageRoute.ROOT,
                    logoProviderKeys = listOf(AgentProvider.HERMES.key),
                    isNested = true,
                    onTap = {}
                )
            )
            list.add(
                RootRow(
                    anchor = SettingsAnchor.HERMES_STATUS,
                    icon = Icons.Filled.Search,
                    title = "Hermes Status",
                    subtitle = "Live Hermes connection state",
                    pageRoute = SettingsPageRoute.ROOT,
                    logoProviderKeys = listOf(AgentProvider.HERMES.key),
                    isNested = true,
                    onTap = {}
                )
            )
        }
        list
    }

    val visibleRows = remember(systemGroup, visualGroup, integrationsGroup, providersGroup, hermesGroup) {
        val list = mutableListOf<RowWithGroupInfo>()

        fun addGroup(title: String, items: List<RootRow>) {
            items.forEachIndexed { index, row ->
                list.add(
                    RowWithGroupInfo(
                        row = row,
                        groupTitle = if (index == 0) title else null,
                        itemIndex = index,
                        groupCount = items.size
                    )
                )
            }
        }

        addGroup("System & Security", systemGroup)
        addGroup("Appearance & Quota", visualGroup)
        addGroup("Integrations & Displays", integrationsGroup)
        addGroup("AI Quota Providers", providersGroup)
        addGroup("Developer Settings", hermesGroup)

        list
    }

    val anchorIndex = remember(visibleRows) {
        visibleRows.withIndex().associate { (i, r) -> r.row.anchor to i }
    }

    // Scroll to pending anchor on arrival.
    LaunchedEffect(pending, visibleRows) {
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
        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.xs.dp),
        modifier = Modifier.fillMaxSize()
    ) {
        visibleRows.forEach { rowWithInfo ->
            val groupTitle = rowWithInfo.groupTitle
            if (groupTitle != null) {
                item(key = "header_${groupTitle}") {
                    SettingsSectionHeader(title = groupTitle)
                }
            }

            item(key = "row_${rowWithInfo.row.anchor}_${rowWithInfo.row.title}") {
                val shape = getGroupShape(rowWithInfo.itemIndex, rowWithInfo.groupCount)
                val showDivider = rowWithInfo.itemIndex < rowWithInfo.groupCount - 1

                SettingsRow(
                    icon = rowWithInfo.row.icon,
                    title = rowWithInfo.row.title,
                    subtitle = rowWithInfo.row.subtitle,
                    highlighted = router.highlightedAnchor == rowWithInfo.row.anchor,
                    shape = shape,
                    logoProviderKeys = rowWithInfo.row.logoProviderKeys,
                    isCollapsibleHeader = rowWithInfo.row.isCollapsibleHeader,
                    isExpanded = rowWithInfo.row.isExpanded,
                    isNested = rowWithInfo.row.isNested,
                    showDivider = showDivider,
                    onClick = rowWithInfo.row.onTap
                )
            }
        }

        // Add a beautiful footer spacer
        item {
            Spacer(modifier = Modifier.height(AuroraSpacing.lg.dp))
        }
    }
}

@Composable
private fun SettingsSectionHeader(title: String) {
    Text(
        text = title.uppercase(),
        fontSize = 11.sp,
        fontWeight = FontWeight.Bold,
        color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f),
        modifier = Modifier.padding(start = AuroraSpacing.md.dp, top = AuroraSpacing.md.dp, bottom = AuroraSpacing.xs.dp)
    )
}

private fun getGroupShape(index: Int, count: Int): RoundedCornerShape {
    return when {
        count == 1 -> RoundedCornerShape(AuroraRadius.lg.dp)
        index == 0 -> RoundedCornerShape(topStart = AuroraRadius.lg.dp, topEnd = AuroraRadius.lg.dp)
        index == count - 1 -> RoundedCornerShape(bottomStart = AuroraRadius.lg.dp, bottomEnd = AuroraRadius.lg.dp)
        else -> RoundedCornerShape(0.dp)
    }
}

private data class RootRow(
    val anchor: String,
    val icon: ImageVector,
    val title: String,
    val subtitle: String,
    val pageRoute: SettingsPageRoute,
    val logoProviderKeys: List<String> = emptyList(),
    val isCollapsibleHeader: Boolean = false,
    val isExpanded: Boolean = false,
    val isNested: Boolean = false,
    val onTap: () -> Unit,
)

private data class RowWithGroupInfo(
    val row: RootRow,
    val groupTitle: String?,
    val itemIndex: Int,
    val groupCount: Int,
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
    shape: RoundedCornerShape = RoundedCornerShape(AuroraRadius.lg.dp),
    logoProviderKeys: List<String> = emptyList(),
    isCollapsibleHeader: Boolean = false,
    isExpanded: Boolean = false,
    isNested: Boolean = false,
    showDivider: Boolean = false,
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

    val contentAlpha = if (isNested) 0.85f else 1f

    Surface(
        onClick = onClick,
        modifier = Modifier
            .fillMaxWidth()
            .padding(start = if (isNested) 16.dp else 0.dp),
        shape = shape,
        color = MaterialTheme.colorScheme.surface.copy(alpha = if (isNested) 0.4f else 0.6f)
    ) {
        Surface(
            color = haloColor,
            shape = shape,
        ) {
            Column(modifier = Modifier.fillMaxWidth()) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(
                            horizontal = AuroraSpacing.md.dp,
                            vertical = if (isNested) AuroraSpacing.sm.dp else AuroraSpacing.md.dp
                        ),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    val logoProviders = logoProviderKeys.mapNotNull { AgentProvider.fromKey(it) }
                    if (logoProviders.isNotEmpty()) {
                        SettingsProviderLogoStack(
                            providers = logoProviders,
                            maxVisible = if (isNested) 1 else 4
                        )
                    } else {
                        Icon(
                            imageVector = icon,
                            contentDescription = null,
                            modifier = Modifier.size(if (isNested) 20.dp else 24.dp),
                            tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = contentAlpha)
                        )
                    }
                    Spacer(modifier = Modifier.width(AuroraSpacing.md.dp))
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            title,
                            fontSize = (if (isNested) AuroraTypography.caption else AuroraTypography.body).sp,
                            fontWeight = if (isNested) FontWeight.Medium else FontWeight.SemiBold,
                            color = MaterialTheme.colorScheme.onSurface.copy(alpha = contentAlpha)
                        )
                        if (subtitle.isNotEmpty()) {
                            Text(
                                subtitle,
                                fontSize = (if (isNested) 11 else AuroraTypography.caption).sp,
                                color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = contentAlpha * 0.8f)
                            )
                        }
                    }

                    if (isCollapsibleHeader) {
                        val rotation by androidx.compose.animation.core.animateFloatAsState(
                            targetValue = if (isExpanded) 180f else 0f,
                            animationSpec = tween(durationMillis = 200),
                            label = "chevron-rotation"
                        )
                        Icon(
                            imageVector = Icons.Filled.KeyboardArrowDown,
                            contentDescription = if (isExpanded) "Collapse" else "Expand",
                            modifier = Modifier
                                .size(24.dp)
                                .graphicsLayer(rotationZ = rotation),
                            tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f)
                        )
                    } else {
                        Icon(
                            imageVector = Icons.AutoMirrored.Filled.NavigateNext,
                            contentDescription = null,
                            modifier = Modifier.size(18.dp),
                            tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.4f)
                        )
                    }
                }

                if (showDivider) {
                    Spacer(
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(1.dp)
                            .padding(horizontal = AuroraSpacing.md.dp)
                            .background(MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.25f))
                    )
                }
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

@Composable
fun ThemePrefsScreen(
    router: SettingsRouter,
    onBack: () -> Unit
) {
    val isDark = isSystemInDarkTheme()
    val haptic = LocalHapticFeedback.current
    val useWebsiteBackground by rememberWebsiteBackground()
    val usePremiumSOTAUX by rememberPremiumSOTAUX()
    val enableSwarmSparkles by rememberSwarmSparkles()
    val excludeBrandShapes by rememberExcludeBrandShapesFromSwarm()
    var customizeProviderGlyphs by rememberSaveable { mutableStateOf(false) }

    // Retrieve pending anchor for halo highlight
    val pending = router.pendingAnchor
    LaunchedEffect(pending) {
        if (pending != null && (pending == SettingsAnchor.USE_PREMIUM_SOTA_UX ||
            pending == SettingsAnchor.USE_WEBSITE_BACKGROUND ||
            pending == SettingsAnchor.ENABLE_SWARM_SPARKLES)) {
            router.consumePendingAnchor(pending)
            kotlinx.coroutines.delay(1_400)
            router.clearHighlight(pending)
        }
    }

    Box(modifier = Modifier.fillMaxSize()) {
        if (useWebsiteBackground) {
            WebsiteBackground(accentColor = AuroraColors.hermesMercury)
        }

        Column(
            modifier = Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .background(
                    if (useWebsiteBackground) Color.Transparent
                    else if (isDark) AuroraColors.darkBackground
                    else AuroraColors.lightBackground
                )
                .padding(horizontal = AuroraSpacing.lg.dp),
            verticalArrangement = Arrangement.spacedBy(AuroraSpacing.md.dp)
        ) {
            Spacer(modifier = Modifier.height(AuroraSpacing.lg.dp))

            // Header
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth()
            ) {
                IconButton(onClick = onBack) {
                    Icon(
                        imageVector = Icons.AutoMirrored.Filled.ArrowBack,
                        contentDescription = "Back",
                        tint = if (useWebsiteBackground) Color.White else MaterialTheme.colorScheme.onSurface
                    )
                }
                Spacer(modifier = Modifier.width(AuroraSpacing.sm.dp))
                Text(
                    text = "Theme & SOTA UX",
                    style = AuroraType.displayLarge,
                    color = if (useWebsiteBackground) Color.White else MaterialTheme.colorScheme.onSurface
                )
            }

            Spacer(modifier = Modifier.height(AuroraSpacing.sm.dp))

            // Main Settings Content in a Glassmorphic Card container
            Surface(
                modifier = Modifier.fillMaxWidth(),
                shape = RoundedCornerShape(AuroraRadius.lg.dp),
                color = MaterialTheme.colorScheme.surface.copy(alpha = if (useWebsiteBackground) 0.35f else 0.6f)
            ) {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(AuroraSpacing.md.dp),
                    verticalArrangement = Arrangement.spacedBy(AuroraSpacing.md.dp)
                ) {
                    // 1. Premium SOTA UX Toggle
                    val premiumHaloColor by animateColorAsState(
                        targetValue = if (router.highlightedAnchor == SettingsAnchor.USE_PREMIUM_SOTA_UX) {
                            Color(0xFFFFA800).copy(alpha = 0.18f)
                        } else {
                            Color.Transparent
                        },
                        animationSpec = tween(durationMillis = 350),
                        label = "premium-halo"
                    )

                    Surface(
                        color = premiumHaloColor,
                        shape = RoundedCornerShape(AuroraRadius.md.dp)
                    ) {
                        AuroraSettingsToggle(
                            icon = Icons.Filled.AutoAwesome,
                            label = "Premium SOTA UX",
                            subtitle = "Cinematic tactile spring physics and high-fidelity haptics",
                            checked = usePremiumSOTAUX,
                            onCheckedChange = {
                                GlobalVisualSettings.setPremiumSOTAUX(it)
                                haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                            },
                            tint = AuroraColors.blaze
                        )
                    }

                    // Divider
                    Spacer(
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(1.dp)
                            .background(MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.4f))
                    )

                    // 2. Website Background Toggle
                    val backgroundHaloColor by animateColorAsState(
                        targetValue = if (router.highlightedAnchor == SettingsAnchor.USE_WEBSITE_BACKGROUND) {
                            Color(0xFFFFA800).copy(alpha = 0.18f)
                        } else {
                            Color.Transparent
                        },
                        animationSpec = tween(durationMillis = 350),
                        label = "background-halo"
                    )

                    Surface(
                        color = backgroundHaloColor,
                        shape = RoundedCornerShape(AuroraRadius.md.dp)
                    ) {
                        AuroraSettingsToggle(
                            icon = Icons.Filled.AutoAwesome,
                            label = "Swarm Background",
                            subtitle = "Active, reconverging token-ember swarms pulled from burnbar.ai",
                            checked = useWebsiteBackground,
                            onCheckedChange = {
                                GlobalVisualSettings.setWebsiteBackground(it)
                                haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                            },
                            tint = AuroraColors.hermesMercury
                        )
                    }

                    // Divider
                    Spacer(
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(1.dp)
                            .background(MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.4f))
                    )

                    // 3. Screensaver Sparkles Toggle
                    val sparklesHaloColor by animateColorAsState(
                        targetValue = if (router.highlightedAnchor == SettingsAnchor.ENABLE_SWARM_SPARKLES) {
                            Color(0xFFFFA800).copy(alpha = 0.18f)
                        } else {
                            Color.Transparent
                        },
                        animationSpec = tween(durationMillis = 350),
                        label = "sparkles-halo"
                    )

                    Surface(
                        color = sparklesHaloColor,
                        shape = RoundedCornerShape(AuroraRadius.md.dp)
                    ) {
                        AuroraSettingsToggle(
                            icon = Icons.Filled.AutoAwesome,
                            label = "Enable Screensaver Sparkles",
                            subtitle = "Render an elegant, gentle twinkling shimmer on particles while they hold a reformed shape.",
                            checked = enableSwarmSparkles,
                            onCheckedChange = {
                                GlobalVisualSettings.setSwarmSparkles(it)
                                haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                            },
                            tint = Color.White
                        )
                    }

                    // Divider
                    Spacer(
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(1.dp)
                            .background(MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.4f))
                    )

                    // Exclude Brand Shapes Toggle
                    AuroraSettingsToggle(
                        icon = Icons.Filled.AutoAwesome,
                        label = "Exclude Brand Shapes",
                        subtitle = "Skip BurnBar, money, code symbols, rings, and router flow cycles, leaving only AI providers",
                        checked = excludeBrandShapes,
                        onCheckedChange = {
                            GlobalVisualSettings.setExcludeBrandShapesFromSwarm(it)
                            haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                        },
                        tint = Color.White
                    )

                    // Divider
                    Spacer(
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(1.dp)
                            .background(MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.4f))
                    )

                    Surface(
                        onClick = { router.page = SettingsPageRoute.WALLPAPER_GENERATOR },
                        shape = RoundedCornerShape(AuroraRadius.md.dp),
                        color = Color.Transparent
                    ) {
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(vertical = 8.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(16.dp)
                        ) {
                            Surface(
                                shape = RoundedCornerShape(12.dp),
                                color = AuroraColors.ember.copy(alpha = 0.15f)
                            ) {
                                Box(
                                    modifier = Modifier.size(42.dp),
                                    contentAlignment = Alignment.Center
                                ) {
                                    Icon(
                                        Icons.Filled.Wallpaper,
                                        contentDescription = null,
                                        modifier = Modifier.size(24.dp),
                                        tint = AuroraColors.ember
                                    )
                                }
                            }

                            Column(modifier = Modifier.weight(1f)) {
                                Text(
                                    "Generate Wallpaper",
                                    fontWeight = FontWeight.Bold,
                                    color = if (useWebsiteBackground) Color.White else MaterialTheme.colorScheme.onSurface
                                )
                                Text(
                                    "Create a swarm wallpaper colored by your AI usage",
                                    fontSize = 13.sp,
                                    color = if (useWebsiteBackground) Color.White.copy(alpha = 0.7f) else MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            }

                            Icon(
                                Icons.AutoMirrored.Filled.NavigateNext,
                                contentDescription = "Open",
                                tint = if (useWebsiteBackground) Color.White.copy(alpha = 0.5f) else MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.5f)
                            )
                        }
                    }

                    // Divider
                    Spacer(
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(1.dp)
                            .background(MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.4f))
                    )

                    // UI Mode Selector (Standard vs Cooking)
                    val activeUiMode by rememberUIMode()
                    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        Text(
                            text = "UI Mode",
                            fontWeight = FontWeight.Bold,
                            color = if (useWebsiteBackground) Color.White else MaterialTheme.colorScheme.onSurface
                        )
                        Row(
                            horizontalArrangement = Arrangement.spacedBy(12.dp),
                            modifier = Modifier.fillMaxWidth()
                        ) {
                            UIMode.entries.forEach { mode ->
                                val isSelected = activeUiMode == mode
                                val primaryColor = MaterialTheme.colorScheme.primary

                                Surface(
                                    modifier = Modifier
                                        .weight(1f)
                                        .height(115.dp),
                                    shape = RoundedCornerShape(AuroraRadius.md.dp),
                                    color = if (isSelected) primaryColor.copy(alpha = 0.12f) else MaterialTheme.colorScheme.surface.copy(alpha = 0.4f),
                                    border = if (isSelected) androidx.compose.foundation.BorderStroke(2.dp, primaryColor) else androidx.compose.foundation.BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.3f)),
                                    onClick = {
                                        GlobalVisualSettings.setUIMode(mode)
                                        haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                                    }
                                ) {
                                    Column(
                                        modifier = Modifier
                                            .fillMaxSize()
                                            .padding(12.dp),
                                        verticalArrangement = Arrangement.SpaceBetween
                                    ) {
                                        Row(
                                            modifier = Modifier.fillMaxWidth(),
                                            horizontalArrangement = Arrangement.SpaceBetween,
                                            verticalAlignment = Alignment.CenterVertically
                                        ) {
                                            if (mode == UIMode.COOKING) {
                                                Icon(
                                                    painter = painterResource(id = R.drawable.ic_cooking_skillet),
                                                    contentDescription = null,
                                                    modifier = Modifier.size(24.dp),
                                                    tint = Color.Unspecified
                                                )
                                            } else {
                                                Icon(
                                                    imageVector = Icons.Filled.AutoAwesome,
                                                    contentDescription = null,
                                                    modifier = Modifier.size(20.dp),
                                                    tint = if (isSelected) primaryColor else MaterialTheme.colorScheme.onSurfaceVariant
                                                )
                                            }

                                            // Selection indicator dot
                                            if (isSelected) {
                                                Surface(
                                                    modifier = Modifier.size(8.dp),
                                                    shape = CircleShape,
                                                    color = primaryColor
                                                ) {}
                                            }
                                        }

                                        Column {
                                            Text(
                                                text = mode.displayName,
                                                fontWeight = FontWeight.Bold,
                                                fontSize = 14.sp,
                                                color = if (useWebsiteBackground) Color.White else MaterialTheme.colorScheme.onSurface
                                            )
                                            Spacer(modifier = Modifier.height(2.dp))
                                            Text(
                                                text = mode.description,
                                                fontSize = 11.sp,
                                                lineHeight = 13.sp,
                                                color = if (useWebsiteBackground) Color.White.copy(alpha = 0.7f) else MaterialTheme.colorScheme.onSurfaceVariant
                                            )
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // Divider
                    Spacer(
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(1.dp)
                            .background(MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.4f))
                    )

                    // 3. Color Palette
                    val themePalette by rememberThemePalette()
                    val providerGlyphs by rememberProviderGlyphs()
                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text("Color Palette", fontWeight = FontWeight.Bold, color = if (useWebsiteBackground) Color.White else MaterialTheme.colorScheme.onSurface)
                        androidx.compose.foundation.lazy.LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            itemsIndexed(AppThemePalette.entries) { _, palette ->
                                val isSelected = themePalette == palette.name
                                Surface(
                                    color = if (isSelected) AuroraColors.amber.copy(alpha = 0.3f) else Color.Transparent,
                                    shape = RoundedCornerShape(16.dp),
                                    onClick = { GlobalVisualSettings.setThemePalette(palette.name) }
                                ) {
                                    Text(
                                        text = palette.displayName,
                                        modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp),
                                        color = if (useWebsiteBackground) Color.White else MaterialTheme.colorScheme.onSurface
                                    )
                                }
                            }
                        }
                    }

                    // Divider
                    Spacer(
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(1.dp)
                            .background(MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.4f))
                    )

                    // 4. Provider Glyphs
                    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        Surface(
                            modifier = Modifier.fillMaxWidth(),
                            shape = RoundedCornerShape(AuroraRadius.lg.dp),
                            color = MaterialTheme.colorScheme.surface.copy(alpha = if (useWebsiteBackground) 0.42f else 0.76f),
                            onClick = { customizeProviderGlyphs = !customizeProviderGlyphs }
                        ) {
                            Row(
                                modifier = Modifier.padding(horizontal = 12.dp, vertical = 10.dp),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(10.dp)
                            ) {
                                SettingsProviderLogoStack(
                                    providers = AgentProvider.swarmGlyphProviders.filter { providerGlyphs.contains(it) }.ifEmpty {
                                        AgentProvider.swarmGlyphProviders.take(4)
                                    },
                                    maxVisible = 4
                                )
                                Column(modifier = Modifier.weight(1f)) {
                                    Text(
                                        "Provider glyphs",
                                        fontWeight = FontWeight.SemiBold,
                                        color = if (useWebsiteBackground) Color.White else MaterialTheme.colorScheme.onSurface
                                    )
                                    Text(
                                        providerGlyphSummary(providerGlyphs),
                                        fontSize = 12.sp,
                                        color = if (useWebsiteBackground) Color.White.copy(alpha = 0.68f) else MaterialTheme.colorScheme.onSurfaceVariant
                                    )
                                }
                                val rotation by androidx.compose.animation.core.animateFloatAsState(
                                    targetValue = if (customizeProviderGlyphs) 180f else 0f,
                                    animationSpec = tween(durationMillis = 200),
                                    label = "provider-glyph-chevron"
                                )
                                Icon(
                                    imageVector = Icons.Filled.KeyboardArrowDown,
                                    contentDescription = if (customizeProviderGlyphs) "Collapse" else "Expand",
                                    modifier = Modifier
                                        .size(22.dp)
                                        .graphicsLayer(rotationZ = rotation),
                                    tint = if (useWebsiteBackground) Color.White.copy(alpha = 0.74f) else MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            }
                        }

                        if (customizeProviderGlyphs) {
                            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                ProviderGlyphQuickAction(
                                    title = "All",
                                    active = providerGlyphs.size == AgentProvider.swarmGlyphProviders.size,
                                    onClick = { GlobalVisualSettings.setProviderGlyphs(AgentProvider.swarmGlyphProviders.toSet()) }
                                )
                                ProviderGlyphQuickAction(
                                    title = "None",
                                    active = providerGlyphs.isEmpty(),
                                    onClick = { GlobalVisualSettings.setProviderGlyphs(emptySet()) }
                                )
                            }

                            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                                AgentProvider.swarmGlyphProviders.forEach { provider ->
                                    val isSelected = providerGlyphs.contains(provider)
                                    ProviderGlyphSelectionRow(
                                        provider = provider,
                                        selected = isSelected,
                                        highContrastText = useWebsiteBackground,
                                    ) {
                                        val next = if (isSelected) {
                                            providerGlyphs - provider
                                        } else {
                                            providerGlyphs + provider
                                        }
                                        GlobalVisualSettings.setProviderGlyphs(next)
                                    }
                                }
                            }
                        }
                    }

                    // Divider
                    Spacer(
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(1.dp)
                            .background(MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.4f))
                    )

                    // 5. Tab Layout Note
                    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Text("Tab Layout", fontWeight = FontWeight.Bold, color = if (useWebsiteBackground) Color.White else MaterialTheme.colorScheme.onSurface)
                        Text("Android Tab arrangement customized via DataStore.", fontSize = 12.sp, color = if (useWebsiteBackground) Color.White.copy(alpha = 0.7f) else MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }

            // Bottom padding for scroll overscroll
            Spacer(modifier = Modifier.height(48.dp))
        }
    }
}

private fun providerGlyphSummary(providers: Set<AgentProvider>): String {
    val total = AgentProvider.swarmGlyphProviders.size
    val count = providers.size
    return when (count) {
        total -> "All providers selected"
        0 -> "Provider logos hidden"
        else -> "$count/$total providers selected"
    }
}

@Composable
private fun ProviderGlyphQuickAction(
    title: String,
    active: Boolean,
    onClick: () -> Unit,
) {
    Surface(
        shape = RoundedCornerShape(999.dp),
        color = if (active) AuroraColors.ember else MaterialTheme.colorScheme.surface.copy(alpha = 0.72f),
        onClick = onClick,
    ) {
        Text(
            text = title,
            modifier = Modifier.padding(horizontal = 14.dp, vertical = 8.dp),
            fontSize = 12.sp,
            fontWeight = FontWeight.Bold,
            color = if (active) Color.White else MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun ProviderGlyphSelectionRow(
    provider: AgentProvider,
    selected: Boolean,
    highContrastText: Boolean,
    onClick: () -> Unit,
) {
    val providerColor = Color(provider.brandColor)
    Surface(
        modifier = Modifier.fillMaxWidth(),
        color = if (selected) providerColor.copy(alpha = 0.16f) else MaterialTheme.colorScheme.surface.copy(alpha = 0.58f),
        shape = RoundedCornerShape(16.dp),
        onClick = onClick,
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 10.dp, vertical = 9.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Surface(
                shape = RoundedCornerShape(12.dp),
                color = MaterialTheme.colorScheme.surface,
            ) {
                Box(
                    modifier = Modifier
                        .size(42.dp)
                        .padding(6.dp),
                    contentAlignment = Alignment.Center,
                ) {
                    ProviderLogo(provider = provider, size = 30.dp)
                }
            }
            Text(
                text = provider.displayName,
                color = if (highContrastText) Color.White else MaterialTheme.colorScheme.onSurface,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.weight(1f),
            )
            Surface(
                shape = RoundedCornerShape(999.dp),
                color = if (selected) providerColor else MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.35f),
            ) {
                Text(
                    text = if (selected) "On" else "Off",
                    modifier = Modifier.padding(horizontal = 10.dp, vertical = 5.dp),
                    fontSize = 11.sp,
                    fontWeight = FontWeight.Bold,
                    color = if (selected) Color.White else MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}
