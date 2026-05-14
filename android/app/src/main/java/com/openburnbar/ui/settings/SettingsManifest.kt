package com.openburnbar.ui.settings

/**
 * Hand-authored index of every searchable control in the Android Settings
 * surface and its sub-screens.
 *
 * Adding a new searchable row:
 * 1. Add an entry to [all].
 * 2. Reference a stable [SettingsAnchor] id (extend that object if needed).
 * 3. Have the destination composable wire the anchor id into its scroll
 *    state via [SettingsRouter.registerAnchorIndex].
 */
object SettingsManifest {

    val all: List<SettingsItem> = listOf(

        // Cloud / Sync
        SettingsItem(
            id = "root.cloudSync",
            section = SettingsSection.CLOUD,
            pageRoute = SettingsPageRoute.ROOT,
            anchorId = SettingsAnchor.CLOUD_SYNC,
            title = "Cloud Sync",
            subtitle = "Sync usage and conversations to OpenBurnBar Cloud",
            keywords = listOf("sync", "cloud", "firebase", "backup"),
        ),
        SettingsItem(
            id = "root.providers",
            section = SettingsSection.PROVIDERS,
            pageRoute = SettingsPageRoute.ROOT,
            anchorId = SettingsAnchor.PROVIDERS_ROW,
            title = "Provider connections",
            subtitle = "Find OpenCode, Codex, Claude, and other quota providers",
            keywords = listOf("providers", "opencode", "open code", "opencode go", "codex", "claude", "quota", "connections"),
        ),

        // Connected devices
        SettingsItem(
            id = "root.connectedDevices",
            section = SettingsSection.DEVICES,
            pageRoute = SettingsPageRoute.ROOT,
            anchorId = SettingsAnchor.CONNECTED_DEVICES,
            title = "Connected Devices",
            subtitle = "Manage which devices can read your data",
            keywords = listOf("devices", "trusted", "phone", "tablet"),
        ),

        // Smart displays row + sub-screen
        SettingsItem(
            id = "root.smartDisplays",
            section = SettingsSection.SMART_DISPLAYS,
            pageRoute = SettingsPageRoute.ROOT,
            anchorId = SettingsAnchor.SMART_DISPLAYS_ROW,
            title = "Smart Displays",
            subtitle = "Google Smart Display · Pixel Clock",
            keywords = listOf("nest", "hub", "pixel", "display", "cast"),
        ),
        SettingsItem(
            id = "smartDisplays.google",
            section = SettingsSection.SMART_DISPLAYS,
            pageRoute = SettingsPageRoute.SMART_DISPLAYS,
            anchorId = SettingsAnchor.GOOGLE_SMART_DISPLAY,
            title = "Google Smart Display",
            subtitle = "Nest Hub and Pixel Tablet glance",
            keywords = listOf("google", "nest", "hub", "tablet"),
        ),
        SettingsItem(
            id = "smartDisplays.pixelClock",
            section = SettingsSection.SMART_DISPLAYS,
            pageRoute = SettingsPageRoute.SMART_DISPLAYS,
            anchorId = SettingsAnchor.PIXEL_CLOCK,
            title = "Pixel Clock",
            subtitle = "Pixel Clock cost glance",
            keywords = listOf("pixel", "clock", "ambient"),
        ),

        // Quick-glance notification
        SettingsItem(
            id = "root.quickGlance",
            section = SettingsSection.NOTIFICATIONS,
            pageRoute = SettingsPageRoute.ROOT,
            anchorId = SettingsAnchor.QUICK_GLANCE_ROW,
            title = "Quick-Glance Notification",
            subtitle = "BurnBar persistent cost glance",
            keywords = listOf("notification", "menubar", "persistent", "shade"),
        ),
        SettingsItem(
            id = "menuBarPrefs.persistent",
            section = SettingsSection.NOTIFICATIONS,
            pageRoute = SettingsPageRoute.MENU_BAR_PREFS,
            anchorId = SettingsAnchor.PERSISTENT_NOTIFICATION,
            title = "Show quick-glance notification",
            subtitle = "Live cost glance in the notification shade",
            keywords = listOf("notification", "persistent", "shade", "glance"),
        ),

        // Hermes (covered for parity with iOS/macOS even where the Android
        // app only exposes a subset today — search should still surface
        // future entries gracefully).
        SettingsItem(
            id = "hermes.connections",
            section = SettingsSection.HERMES,
            pageRoute = SettingsPageRoute.ROOT,
            anchorId = SettingsAnchor.HERMES_CONNECTIONS,
            title = "Hermes Connections",
            subtitle = "Connected Hermes endpoints and tokens",
            keywords = listOf("hermes", "connection", "endpoint"),
        ),
        SettingsItem(
            id = "hermes.models",
            section = SettingsSection.HERMES,
            pageRoute = SettingsPageRoute.ROOT,
            anchorId = SettingsAnchor.HERMES_MODELS,
            title = "Hermes Models",
            subtitle = "Default models exposed by Hermes",
            keywords = listOf("model", "llm", "hermes"),
        ),
        SettingsItem(
            id = "hermes.display",
            section = SettingsSection.HERMES,
            pageRoute = SettingsPageRoute.ROOT,
            anchorId = SettingsAnchor.HERMES_DISPLAY,
            title = "Hermes Display",
            subtitle = "TPS overlay and pretext",
            keywords = listOf("tps", "pretext", "overlay", "display"),
        ),
        SettingsItem(
            id = "hermes.gateway",
            section = SettingsSection.HERMES,
            pageRoute = SettingsPageRoute.ROOT,
            anchorId = SettingsAnchor.HERMES_GATEWAY,
            focusId = SettingsFocus.HERMES_GATEWAY_URL,
            title = "Hermes Gateway",
            subtitle = "URL and token for the Hermes webapi gateway",
            keywords = listOf("gateway", "url", "token", "webapi"),
        ),
        SettingsItem(
            id = "hermes.status",
            section = SettingsSection.HERMES,
            pageRoute = SettingsPageRoute.ROOT,
            anchorId = SettingsAnchor.HERMES_STATUS,
            title = "Hermes Status",
            subtitle = "Live Hermes connection state",
            keywords = listOf("status", "health", "live"),
        ),
    )

    /** Reverse-index of anchorId -> owning page route. */
    val anchorIndex: Map<String, SettingsPageRoute> =
        all.associate { it.anchorId to it.pageRoute }
}
