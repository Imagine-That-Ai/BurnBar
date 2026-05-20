package com.openburnbar.ui.settings

import com.openburnbar.data.models.AgentProvider

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

    private val baseItems: List<SettingsItem> = listOf(

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
            logoProviderKeys = listOf(
                AgentProvider.CLAUDE_CODE.key,
                AgentProvider.OPENCODE.key,
                AgentProvider.FACTORY.key,
                AgentProvider.OPEN_AI.key,
            ),
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
            pageRoute = SettingsPageRoute.ROOT,
            anchorId = SettingsAnchor.GOOGLE_SMART_DISPLAY,
            title = "Google Smart Display",
            subtitle = "Nest Hub and Pixel Tablet glance",
            keywords = listOf("google", "nest", "hub", "tablet"),
        ),
        SettingsItem(
            id = "smartDisplays.pixelClock",
            section = SettingsSection.SMART_DISPLAYS,
            pageRoute = SettingsPageRoute.ROOT,
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
            id = "root.computerUse",
            section = SettingsSection.COMPUTER_USE,
            pageRoute = SettingsPageRoute.ROOT,
            anchorId = SettingsAnchor.COMPUTER_USE_ROW,
            title = "Computer Use",
            subtitle = "Agent Watch, phone takeover, approvals, and audit chain",
            keywords = listOf(
                "computer use",
                "agent watch",
                "phone takeover",
                "approval",
                "audit",
                "mac control",
                "browser driving",
            ),
            helpText = "Android mirrors the iPhone operator seat: watch the Mac stream, approve or reject actions, downgrade trust, and panic halt.",
        ),
        SettingsItem(
            id = "menuBarPrefs.persistent",
            section = SettingsSection.NOTIFICATIONS,
            pageRoute = SettingsPageRoute.ROOT,
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
            logoProviderKeys = listOf(
                AgentProvider.HERMES.key,
                AgentProvider.CLAUDE_CODE.key,
                AgentProvider.CODEX.key,
                AgentProvider.OPEN_CLAW.key,
            ),
        ),
        SettingsItem(
            id = "hermes.models",
            section = SettingsSection.HERMES,
            pageRoute = SettingsPageRoute.ROOT,
            anchorId = SettingsAnchor.HERMES_MODELS,
            title = "Hermes Models",
            subtitle = "Default models exposed by Hermes",
            keywords = listOf("model", "llm", "hermes"),
            logoProviderKeys = listOf(
                AgentProvider.HERMES.key,
                AgentProvider.CLAUDE_CODE.key,
                AgentProvider.OPEN_AI.key,
                AgentProvider.GEMINI_CLI.key,
            ),
        ),
        SettingsItem(
            id = "hermes.display",
            section = SettingsSection.HERMES,
            pageRoute = SettingsPageRoute.ROOT,
            anchorId = SettingsAnchor.HERMES_DISPLAY,
            title = "Hermes Display",
            subtitle = "TPS overlay and pretext",
            keywords = listOf("tps", "pretext", "overlay", "display"),
            logoProviderKeys = listOf(AgentProvider.HERMES.key),
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
            logoProviderKeys = listOf(AgentProvider.HERMES.key),
        ),
        SettingsItem(
            id = "hermes.status",
            section = SettingsSection.HERMES,
            pageRoute = SettingsPageRoute.ROOT,
            anchorId = SettingsAnchor.HERMES_STATUS,
            title = "Hermes Status",
            subtitle = "Live Hermes connection state",
            keywords = listOf("status", "health", "live"),
            logoProviderKeys = listOf(AgentProvider.HERMES.key),
        ),
    )

    private val providerItems: List<SettingsItem> =
        AgentProvider.entries
            .sortedBy { it.displayName.lowercase() }
            .map { provider ->
                SettingsItem(
                    id = "root.provider.${provider.key}",
                    section = SettingsSection.PROVIDERS,
                    pageRoute = SettingsPageRoute.ROOT,
                    anchorId = SettingsAnchor.provider(provider.key),
                    title = provider.displayName,
                    subtitle = "${provider.displayName} provider quota, usage, and connection signal",
                    keywords = providerKeywords(provider),
                    logoProviderKeys = listOf(provider.key),
                )
            }

    val all: List<SettingsItem> = baseItems + providerItems

    /** Reverse-index of anchorId -> owning page route. */
    val anchorIndex: Map<String, SettingsPageRoute> =
        all.associate { it.anchorId to it.pageRoute }

    /**
     * Anchors attached to visible Settings rows. Search tests compare this
     * against [all] so indexed settings cannot drift away from scroll targets.
     */
    val visibleAnchorIds: Set<String> = setOf(
        SettingsAnchor.CLOUD_SYNC,
        SettingsAnchor.PROVIDERS_ROW,
        SettingsAnchor.CONNECTED_DEVICES,
        SettingsAnchor.SMART_DISPLAYS_ROW,
        SettingsAnchor.GOOGLE_SMART_DISPLAY,
        SettingsAnchor.PIXEL_CLOCK,
        SettingsAnchor.QUICK_GLANCE_ROW,
        SettingsAnchor.COMPUTER_USE_ROW,
        SettingsAnchor.PERSISTENT_NOTIFICATION,
        SettingsAnchor.HERMES_CONNECTIONS,
        SettingsAnchor.HERMES_MODELS,
        SettingsAnchor.HERMES_DISPLAY,
        SettingsAnchor.HERMES_GATEWAY,
        SettingsAnchor.HERMES_STATUS,
    ) + providerItems.map { it.anchorId }

    private fun providerKeywords(provider: AgentProvider): List<String> {
        val keywords = mutableSetOf(
            provider.key,
            provider.displayName,
            provider.displayName.replace(" ", ""),
            "provider",
            "quota",
            "usage",
            "connection",
        )

        when (provider) {
            AgentProvider.CLAUDE_CODE -> keywords.addAll(listOf("claude", "anthropic", "claude code", "claude cli", "sonnet", "opus"))
            AgentProvider.CODEX -> keywords.addAll(listOf("openai codex", "codex cli", "chatgpt", "openai"))
            AgentProvider.OPENCODE -> keywords.addAll(listOf("opencode", "open code", "opencode go", "open code go", "cli"))
            AgentProvider.OPEN_AI -> keywords.addAll(listOf("open ai", "openai", "gpt", "chatgpt"))
            AgentProvider.GEMINI_CLI -> keywords.addAll(listOf("gemini", "google", "google ai", "gemini cli"))
            AgentProvider.KILO_CODE -> keywords.addAll(listOf("kilo", "kilo code", "kilocode"))
            AgentProvider.ROO_CODE -> keywords.addAll(listOf("roo", "roo code", "roocode"))
            AgentProvider.FORGE_DEV -> keywords.addAll(listOf("forge", "forge dev", "forgedev"))
            AgentProvider.OPEN_CLAW -> keywords.addAll(listOf("open claw", "openclaw"))
            AgentProvider.KIMI -> keywords.addAll(listOf("moonshot", "kimi k2"))
            AgentProvider.ZAI -> keywords.addAll(listOf("z.ai", "z-ai", "zai"))
            AgentProvider.MINIMAX -> keywords.addAll(listOf("mini max", "minimax"))
            AgentProvider.COPILOT -> keywords.addAll(listOf("github", "github copilot"))
            AgentProvider.ANTIGRAVITY -> keywords.addAll(listOf("antigravity", "antigravity cli", "antigravity-cli", "gemini", "deepmind"))
            else -> Unit
        }

        return keywords.sorted()
    }
}
