// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.settings

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.NavigateNext
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Clear
import androidx.compose.material.icons.filled.Cloud
import androidx.compose.material.icons.filled.Computer
import androidx.compose.material.icons.filled.Devices
import androidx.compose.material.icons.filled.GridOn
import androidx.compose.material.icons.filled.Keyboard
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.Notifications
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Storage
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material.icons.filled.Tv
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
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
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.models.AgentProvider
import com.openburnbar.ui.components.ProviderLogo
import com.openburnbar.ui.components.WebsiteBackground
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraRadius
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraType
import com.openburnbar.ui.theme.AuroraTypography

@Composable
internal fun SettingsRootContent(router: SettingsRouter, onBack: (() -> Unit)?, onComputerUse: (() -> Unit)?) {
    val isDark = isSystemInDarkTheme()
    var searchMode by rememberSaveable { mutableStateOf(false) }
    val searchFocusRequester = remember { FocusRequester() }
    val useWebsiteBackground by rememberWebsiteBackground()

    LaunchedEffect(searchMode) {
        if (searchMode) {
            try {
                searchFocusRequester.requestFocus()
            } catch (_: Throwable) {}
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
                    if (useWebsiteBackground) {
                        Color.Transparent
                    } else if (isDark) {
                        AuroraColors.darkBackground
                    } else {
                        AuroraColors.lightBackground
                    },
                )
                .padding(horizontal = AuroraSpacing.LG.dp),
            verticalArrangement = Arrangement.spacedBy(AuroraSpacing.MD.dp),
        ) {
            Spacer(modifier = Modifier.height(AuroraSpacing.LG.dp))

            SettingsRootTopBar(
                router = router,
                onBack = onBack,
                searchMode = searchMode,
                onSearchModeChange = { searchMode = it },
                useWebsiteBackground = useWebsiteBackground,
                searchFocusRequester = searchFocusRequester,
            )

            if (router.isSearching) {
                SettingsSearchResultsScreen(router = router)
            } else {
                SettingsRootList(router = router, onComputerUse = onComputerUse)
            }
        }
    }
}

@Composable
internal fun SettingsRootTopBar(
    router: SettingsRouter,
    onBack: (() -> Unit)?,
    searchMode: Boolean,
    onSearchModeChange: (Boolean) -> Unit,
    useWebsiteBackground: Boolean,
    searchFocusRequester: FocusRequester,
) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        if (onBack != null && !searchMode) {
            IconButton(onClick = onBack) {
                Icon(
                    imageVector = Icons.AutoMirrored.Filled.ArrowBack,
                    contentDescription = "Back",
                    tint = if (useWebsiteBackground) Color.White else MaterialTheme.colorScheme.onSurface,
                )
            }
        }
        if (searchMode) {
            SettingsRootSearchField(router, searchFocusRequester, onSearchModeChange)
        } else {
            Text(
                "Settings",
                style = AuroraType.displayLarge,
                color = if (useWebsiteBackground) Color.White else MaterialTheme.colorScheme.onSurface,
                modifier = Modifier.weight(1f),
            )
            IconButton(onClick = { onSearchModeChange(true) }) {
                Icon(
                    Icons.Filled.Search,
                    contentDescription = "Search settings",
                    tint = if (useWebsiteBackground) Color.White else MaterialTheme.colorScheme.onSurface,
                )
            }
        }
    }
}

internal fun buildSettingsSystemGroup(router: SettingsRouter, onComputerUse: (() -> Unit)?): List<RootRow> = listOf(
    RootRow(
        anchor = SettingsAnchor.CLOUD_SYNC,
        icon = Icons.Filled.Cloud,
        title = "Cloud Sync",
        subtitle = "Sync usage and conversations to OpenBurnBar Cloud",
        pageRoute = SettingsPageRoute.ROOT,
        onTap = {},
    ),
    RootRow(
        anchor = SettingsAnchor.TRANSCRIPT_CACHE,
        icon = Icons.Filled.Storage,
        title = "Transcript Cache",
        subtitle = "Encrypted stream downloads, default 250 MB",
        pageRoute = SettingsPageRoute.TRANSCRIPT_CACHE,
        onTap = { router.page = SettingsPageRoute.TRANSCRIPT_CACHE },
    ),
    RootRow(
        anchor = SettingsAnchor.CONNECTED_DEVICES,
        icon = Icons.Filled.Devices,
        title = "Connected Devices",
        subtitle = "Manage which devices can read your data",
        pageRoute = SettingsPageRoute.ROOT,
        onTap = {},
    ),
    RootRow(
        anchor = SettingsAnchor.COMPUTER_USE_ROW,
        icon = Icons.Filled.Computer,
        title = "Computer Use",
        subtitle = "Agent Watch, phone takeover, approvals, and audit chain",
        pageRoute = SettingsPageRoute.ROOT,
        onTap = { onComputerUse?.invoke() },
    ),
    RootRow(
        anchor = SettingsAnchor.BUDGET_ROW,
        icon = Icons.Filled.Tune,
        title = "Budgeting & Rules",
        subtitle = "Set hard limits and warnings on usage spends",
        pageRoute = SettingsPageRoute.BUDGET_PREFS,
        onTap = { router.page = SettingsPageRoute.BUDGET_PREFS },
    ),
    RootRow(
        anchor = SettingsAnchor.TEXT_EXPANSION_ROW,
        icon = Icons.Filled.Keyboard,
        title = "Text Expansion",
        subtitle = "Manage && snippets and the OpenBurnBar snippets keyboard",
        pageRoute = SettingsPageRoute.TEXT_EXPANSION,
        onTap = { router.page = SettingsPageRoute.TEXT_EXPANSION },
    ),
)

internal fun buildSettingsVisualGroup(router: SettingsRouter): List<RootRow> = listOf(
    RootRow(
        anchor = SettingsAnchor.THEME_ROW,
        icon = Icons.Filled.AutoAwesome,
        title = "Theme & SOTA UX",
        subtitle = "Customise visual appearance, spring physics, and grid backdrops",
        pageRoute = SettingsPageRoute.THEME_PREFS,
        onTap = { router.page = SettingsPageRoute.THEME_PREFS },
    ),
    RootRow(
        anchor = SettingsAnchor.QUOTA_CUSTOMIZATION_ROW,
        icon = Icons.Filled.GridOn,
        title = "Quota Customisation",
        subtitle = "Rearrange providers, toggle visible buckets, and format percentage displays",
        pageRoute = SettingsPageRoute.QUOTA_PREFS,
        onTap = { router.page = SettingsPageRoute.QUOTA_PREFS },
    ),
)

internal fun buildSettingsSmartDisplayRows(
    router: SettingsRouter,
    smartDisplaysExpanded: Boolean,
    onSmartDisplaysExpandedChange: (Boolean) -> Unit,
): List<RootRow> {
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
            onTap = { onSmartDisplaysExpandedChange(!smartDisplaysExpanded) },
        ),
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
                onTap = { router.page = SettingsPageRoute.SMART_DISPLAYS },
            ),
        )
        list.add(
            RootRow(
                anchor = SettingsAnchor.PIXEL_CLOCK,
                icon = Icons.Filled.Tv,
                title = "Pixel Clock",
                subtitle = "Pixel Clock cost glance",
                pageRoute = SettingsPageRoute.SMART_DISPLAYS,
                isNested = true,
                onTap = { router.page = SettingsPageRoute.SMART_DISPLAYS },
            ),
        )
    }
    return list
}

internal fun buildSettingsNotificationRows(
    notificationsExpanded: Boolean,
    onNotificationsExpandedChange: (Boolean) -> Unit,
    onOpenMenuBarPrefs: () -> Unit,
): List<RootRow> {
    val list = mutableListOf<RootRow>()
    list.add(
        RootRow(
            anchor = SettingsAnchor.QUICK_GLANCE_ROW,
            icon = Icons.Filled.Notifications,
            title = "Quick-Glance Notification",
            subtitle = "BurnBar persistent cost glance",
            pageRoute = SettingsPageRoute.MENU_BAR_PREFS,
            isCollapsibleHeader = true,
            isExpanded = notificationsExpanded,
            onTap = { onNotificationsExpandedChange(!notificationsExpanded) },
        ),
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
                onTap = onOpenMenuBarPrefs,
            ),
        )
    }
    return list
}

internal fun buildSettingsIntegrationsGroup(
    router: SettingsRouter,
    smartDisplaysExpanded: Boolean,
    notificationsExpanded: Boolean,
    onSmartDisplaysExpandedChange: (Boolean) -> Unit,
    onNotificationsExpandedChange: (Boolean) -> Unit,
): List<RootRow> = buildSettingsSmartDisplayRows(router, smartDisplaysExpanded, onSmartDisplaysExpandedChange) +
    buildSettingsNotificationRows(notificationsExpanded, onNotificationsExpandedChange) { router.page = SettingsPageRoute.MENU_BAR_PREFS }

internal fun buildSettingsProvidersGroup(providersExpanded: Boolean, onProvidersExpandedChange: (Boolean) -> Unit): List<RootRow> {
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
            onTap = { onProvidersExpandedChange(!providersExpanded) },
        ),
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
                        onTap = {},
                    ),
                )
            }
    }
    return list
}

internal fun buildSettingsHermesExpandedRows(): List<RootRow> = listOf(
    RootRow(
        anchor = SettingsAnchor.HERMES_CONNECTIONS,
        icon = Icons.Filled.Search,
        title = "Hermes Connections",
        subtitle = "Connected Hermes endpoints and tokens",
        pageRoute = SettingsPageRoute.ROOT,
        logoProviderKeys = listOf(AgentProvider.HERMES.key, AgentProvider.CLAUDE_CODE.key, AgentProvider.CODEX.key, AgentProvider.OPEN_CLAW.key),
        isNested = true,
        onTap = {},
    ),
    RootRow(
        anchor = SettingsAnchor.HERMES_MODELS,
        icon = Icons.Filled.Search,
        title = "Hermes Models",
        subtitle = "Default models exposed by Hermes",
        pageRoute = SettingsPageRoute.ROOT,
        logoProviderKeys = listOf(AgentProvider.HERMES.key, AgentProvider.CLAUDE_CODE.key, AgentProvider.OPEN_AI.key, AgentProvider.GEMINI_CLI.key),
        isNested = true,
        onTap = {},
    ),
    RootRow(
        anchor = SettingsAnchor.HERMES_DISPLAY,
        icon = Icons.Filled.Search,
        title = "Hermes Display",
        subtitle = "TPS overlay and pretext",
        pageRoute = SettingsPageRoute.ROOT,
        logoProviderKeys = listOf(AgentProvider.HERMES.key),
        isNested = true,
        onTap = {},
    ),
    RootRow(
        anchor = SettingsAnchor.HERMES_GATEWAY,
        icon = Icons.Filled.Search,
        title = "Hermes Gateway",
        subtitle = "URL and token for the Hermes webapi gateway",
        pageRoute = SettingsPageRoute.ROOT,
        logoProviderKeys = listOf(AgentProvider.HERMES.key),
        isNested = true,
        onTap = {},
    ),
    RootRow(
        anchor = SettingsAnchor.HERMES_STATUS,
        icon = Icons.Filled.Search,
        title = "Hermes Status",
        subtitle = "Live Hermes connection state",
        pageRoute = SettingsPageRoute.ROOT,
        logoProviderKeys = listOf(AgentProvider.HERMES.key),
        isNested = true,
        onTap = {},
    ),
)

internal fun buildSettingsHermesGroup(hermesExpanded: Boolean, onHermesExpandedChange: (Boolean) -> Unit): List<RootRow> {
    val list = mutableListOf(
        RootRow(
            anchor = "root.hermes_dev_suite",
            icon = Icons.Filled.Search,
            title = "Hermes Developer Suite",
            subtitle = "Configure gateway, connections, and system pretext",
            pageRoute = SettingsPageRoute.ROOT,
            logoProviderKeys = listOf(AgentProvider.HERMES.key),
            isCollapsibleHeader = true,
            isExpanded = hermesExpanded,
            onTap = { onHermesExpandedChange(!hermesExpanded) },
        ),
    )
    if (hermesExpanded) list.addAll(buildSettingsHermesExpandedRows())
    return list
}

internal fun mergeSettingsRootVisibleRows(
    systemGroup: List<RootRow>,
    visualGroup: List<RootRow>,
    integrationsGroup: List<RootRow>,
    providersGroup: List<RootRow>,
    hermesGroup: List<RootRow>,
): List<RowWithGroupInfo> {
    val list = mutableListOf<RowWithGroupInfo>()

    fun addGroup(title: String, items: List<RootRow>) {
        items.forEachIndexed { index, row ->
            list.add(
                RowWithGroupInfo(
                    row = row,
                    groupTitle = if (index == 0) title else null,
                    itemIndex = index,
                    groupCount = items.size,
                ),
            )
        }
    }

    addGroup("System & Security", systemGroup)
    addGroup("Appearance & Quota", visualGroup)
    addGroup("Integrations & Displays", integrationsGroup)
    addGroup("AI Quota Providers", providersGroup)
    addGroup("Developer Settings", hermesGroup)

    return list
}

internal fun LazyListScope.settingsRootListItems(router: SettingsRouter, visibleRows: List<RowWithGroupInfo>) {
    visibleRows.forEach { rowWithInfo ->
        val groupTitle = rowWithInfo.groupTitle
        if (groupTitle != null) {
            item(key = "header_$groupTitle") {
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
                onClick = rowWithInfo.row.onTap,
            )
        }
    }

    item {
        Spacer(modifier = Modifier.height(AuroraSpacing.LG.dp))
    }
}

internal fun settingsRootExpandGroupsForPendingAnchor(
    pending: String?,
    onProvidersExpanded: () -> Unit,
    onHermesExpanded: () -> Unit,
    onSmartDisplaysExpanded: () -> Unit,
    onNotificationsExpanded: () -> Unit,
) {
    if (pending == null) return
    when {
        pending.startsWith("root.provider.") -> onProvidersExpanded()
        pending.startsWith("hermes.") -> onHermesExpanded()
        pending == SettingsAnchor.GOOGLE_SMART_DISPLAY || pending == SettingsAnchor.PIXEL_CLOCK -> onSmartDisplaysExpanded()
        pending == SettingsAnchor.PERSISTENT_NOTIFICATION -> onNotificationsExpanded()
    }
}

@Composable
internal fun RowScope.SettingsRootSearchField(router: SettingsRouter, searchFocusRequester: FocusRequester, onSearchModeChange: (Boolean) -> Unit) {
    OutlinedTextField(
        value = router.query,
        onValueChange = { router.query = it },
        placeholder = { Text("Search settings") },
        leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null) },
        trailingIcon = {
            IconButton(onClick = {
                if (router.query.isEmpty()) onSearchModeChange(false) else router.query = ""
            }) {
                Icon(Icons.Filled.Clear, contentDescription = "Clear")
            }
        },
        singleLine = true,
        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
        modifier = Modifier.weight(1f).focusRequester(searchFocusRequester),
    )
}

@Composable
internal fun SettingsRootList(router: SettingsRouter, onComputerUse: (() -> Unit)?) {
    val listState = rememberLazyListState()
    var providersExpanded by rememberSaveable { mutableStateOf(false) }
    var hermesExpanded by rememberSaveable { mutableStateOf(false) }
    var smartDisplaysExpanded by rememberSaveable { mutableStateOf(false) }
    var notificationsExpanded by rememberSaveable { mutableStateOf(false) }
    val pending = router.pendingAnchor

    LaunchedEffect(pending) {
        settingsRootExpandGroupsForPendingAnchor(
            pending,
            onProvidersExpanded = { providersExpanded = true },
            onHermesExpanded = { hermesExpanded = true },
            onSmartDisplaysExpanded = { smartDisplaysExpanded = true },
            onNotificationsExpanded = { notificationsExpanded = true },
        )
    }

    val visibleRows =
        settingsRootVisibleRows(
            router = router,
            onComputerUse = onComputerUse,
            expansion =
            SettingsRootExpansionState(
                providersExpanded = providersExpanded,
                hermesExpanded = hermesExpanded,
                smartDisplaysExpanded = smartDisplaysExpanded,
                notificationsExpanded = notificationsExpanded,
                onProvidersExpandedChange = { providersExpanded = it },
                onHermesExpandedChange = { hermesExpanded = it },
                onSmartDisplaysExpandedChange = { smartDisplaysExpanded = it },
                onNotificationsExpandedChange = { notificationsExpanded = it },
            ),
        )

    SettingsRootPendingAnchorScroll(router, pending, visibleRows, listState)

    LazyColumn(
        state = listState,
        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.XS.dp),
        modifier = Modifier.fillMaxSize(),
    ) {
        settingsRootListItems(router = router, visibleRows = visibleRows)
    }
}

internal data class SettingsRootExpansionState(
    val providersExpanded: Boolean,
    val hermesExpanded: Boolean,
    val smartDisplaysExpanded: Boolean,
    val notificationsExpanded: Boolean,
    val onProvidersExpandedChange: (Boolean) -> Unit,
    val onHermesExpandedChange: (Boolean) -> Unit,
    val onSmartDisplaysExpandedChange: (Boolean) -> Unit,
    val onNotificationsExpandedChange: (Boolean) -> Unit,
)

@Composable
internal fun settingsRootVisibleRows(router: SettingsRouter, onComputerUse: (() -> Unit)?, expansion: SettingsRootExpansionState): List<RowWithGroupInfo> {
    val systemGroup = remember(onComputerUse) { buildSettingsSystemGroup(router, onComputerUse) }
    val visualGroup = remember(router) { buildSettingsVisualGroup(router) }
    val integrationsGroup = remember(expansion.smartDisplaysExpanded, expansion.notificationsExpanded) {
        buildSettingsIntegrationsGroup(
            router,
            expansion.smartDisplaysExpanded,
            expansion.notificationsExpanded,
            expansion.onSmartDisplaysExpandedChange,
            expansion.onNotificationsExpandedChange,
        )
    }
    val providersGroup = remember(expansion.providersExpanded) {
        buildSettingsProvidersGroup(expansion.providersExpanded, expansion.onProvidersExpandedChange)
    }
    val hermesGroup = remember(expansion.hermesExpanded) {
        buildSettingsHermesGroup(expansion.hermesExpanded, expansion.onHermesExpandedChange)
    }
    return remember(systemGroup, visualGroup, integrationsGroup, providersGroup, hermesGroup) {
        mergeSettingsRootVisibleRows(systemGroup, visualGroup, integrationsGroup, providersGroup, hermesGroup)
    }
}

@Composable
internal fun SettingsRootPendingAnchorScroll(
    router: SettingsRouter,
    pending: String?,
    visibleRows: List<RowWithGroupInfo>,
    listState: androidx.compose.foundation.lazy.LazyListState,
) {
    val anchorIndex = remember(visibleRows) { visibleRows.withIndex().associate { (i, r) -> r.row.anchor to i } }
    LaunchedEffect(pending, visibleRows) {
        if (pending != null) {
            val idx = anchorIndex[pending]
            if (idx != null) {
                listState.animateScrollToItem(idx)
                router.consumePendingAnchor(pending)
                kotlinx.coroutines.delay(1_400)
                router.clearHighlight(pending)
            }
        }
    }
}

@Composable
internal fun SettingsSectionHeader(title: String) {
    Text(
        text = title.uppercase(),
        fontSize = 11.sp,
        fontWeight = FontWeight.Bold,
        color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f),
        modifier = Modifier.padding(start = AuroraSpacing.MD.dp, top = AuroraSpacing.MD.dp, bottom = AuroraSpacing.XS.dp),
    )
}

internal fun getGroupShape(index: Int, count: Int): RoundedCornerShape {
    return when {
        count == 1 -> RoundedCornerShape(AuroraRadius.LG.dp)
        index == 0 -> RoundedCornerShape(topStart = AuroraRadius.LG.dp, topEnd = AuroraRadius.LG.dp)
        index == count - 1 -> RoundedCornerShape(bottomStart = AuroraRadius.LG.dp, bottomEnd = AuroraRadius.LG.dp)
        else -> RoundedCornerShape(0.dp)
    }
}

internal data class RootRow(
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

internal data class RowWithGroupInfo(
    val row: RootRow,
    val groupTitle: String?,
    val itemIndex: Int,
    val groupCount: Int,
)

@Composable
internal fun SettingsRow(
    icon: ImageVector,
    title: String,
    subtitle: String,
    highlighted: Boolean,
    shape: RoundedCornerShape = RoundedCornerShape(AuroraRadius.LG.dp),
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
        label = "settings-row-halo",
    )

    val contentAlpha = if (isNested) 0.85f else 1f

    Surface(
        onClick = onClick,
        modifier = Modifier
            .fillMaxWidth()
            .padding(start = if (isNested) 16.dp else 0.dp),
        shape = shape,
        color = MaterialTheme.colorScheme.surface.copy(alpha = if (isNested) 0.4f else 0.6f),
    ) {
        Surface(
            color = haloColor,
            shape = shape,
        ) {
            Column(modifier = Modifier.fillMaxWidth()) {
                SettingsRowBody(
                    SettingsRowBodyModel(
                        icon = icon,
                        title = title,
                        subtitle = subtitle,
                        logoProviderKeys = logoProviderKeys,
                        isCollapsibleHeader = isCollapsibleHeader,
                        isExpanded = isExpanded,
                        isNested = isNested,
                        contentAlpha = contentAlpha,
                    ),
                )
                if (showDivider) {
                    SettingsRowDivider()
                }
            }
        }
    }
}

@Composable
internal fun SettingsRowLeading(icon: ImageVector, logoProviderKeys: List<String>, isNested: Boolean, contentAlpha: Float) {
    val logoProviders = logoProviderKeys.mapNotNull { AgentProvider.fromKey(it) }
    if (logoProviders.isNotEmpty()) {
        SettingsProviderLogoStack(
            providers = logoProviders,
            maxVisible = if (isNested) 1 else 4,
        )
    } else {
        Icon(
            imageVector = icon,
            contentDescription = null,
            modifier = Modifier.size(if (isNested) 20.dp else 24.dp),
            tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = contentAlpha),
        )
    }
}

@Composable
internal fun RowScope.SettingsRowText(title: String, subtitle: String, isNested: Boolean, contentAlpha: Float) {
    Column(modifier = Modifier.weight(1f)) {
        Text(
            title,
            fontSize = (if (isNested) AuroraTypography.caption else AuroraTypography.body).sp,
            fontWeight = if (isNested) FontWeight.Medium else FontWeight.SemiBold,
            color = MaterialTheme.colorScheme.onSurface.copy(alpha = contentAlpha),
        )
        if (subtitle.isNotEmpty()) {
            Text(
                subtitle,
                fontSize = (if (isNested) 11 else AuroraTypography.caption).sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = contentAlpha * 0.8f),
            )
        }
    }
}

@Composable
internal fun SettingsRowTrailing(isCollapsibleHeader: Boolean, isExpanded: Boolean) {
    if (isCollapsibleHeader) {
        val rotation by animateFloatAsState(
            targetValue = if (isExpanded) 180f else 0f,
            animationSpec = tween(durationMillis = 200),
            label = "chevron-rotation",
        )
        Icon(
            imageVector = Icons.Filled.KeyboardArrowDown,
            contentDescription = if (isExpanded) "Collapse" else "Expand",
            modifier = Modifier
                .size(24.dp)
                .graphicsLayer(rotationZ = rotation),
            tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f),
        )
    } else {
        Icon(
            imageVector = Icons.AutoMirrored.Filled.NavigateNext,
            contentDescription = null,
            modifier = Modifier.size(18.dp),
            tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.4f),
        )
    }
}

@Composable
internal fun SettingsRowBody(model: SettingsRowBodyModel) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(
                horizontal = AuroraSpacing.MD.dp,
                vertical = if (model.isNested) AuroraSpacing.SM.dp else AuroraSpacing.MD.dp,
            ),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        SettingsRowLeading(model.icon, model.logoProviderKeys, model.isNested, model.contentAlpha)
        Spacer(modifier = Modifier.width(AuroraSpacing.MD.dp))
        SettingsRowText(model.title, model.subtitle, model.isNested, model.contentAlpha)
        SettingsRowTrailing(model.isCollapsibleHeader, model.isExpanded)
    }
}

internal data class SettingsRowBodyModel(
    val icon: ImageVector,
    val title: String,
    val subtitle: String,
    val logoProviderKeys: List<String>,
    val isCollapsibleHeader: Boolean,
    val isExpanded: Boolean,
    val isNested: Boolean,
    val contentAlpha: Float,
)

@Composable
internal fun SettingsRowDivider() {
    Spacer(
        modifier = Modifier
            .fillMaxWidth()
            .height(1.dp)
            .padding(horizontal = AuroraSpacing.MD.dp)
            .background(MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.25f)),
    )
}

@Composable
internal fun SettingsProviderLogoStack(providers: List<AgentProvider>, maxVisible: Int = 4) {
    Row(horizontalArrangement = Arrangement.spacedBy((-7).dp)) {
        providers.take(maxVisible).forEach { provider ->
            ProviderLogo(provider = provider, size = 28.dp)
        }
    }
}
