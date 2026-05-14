package com.openburnbar.ui.settings

/**
 * A single indexable control inside the Android Settings hierarchy.
 *
 * Mirrors the iOS/macOS `SettingsItem` shape so the cross-platform search
 * UX feels identical. The Android manifest is hand-authored in
 * [SettingsManifest].
 *
 * Adding a new searchable row:
 * 1. Append a `SettingsItem` entry to [SettingsManifest.all].
 * 2. Reference a stable [SettingsAnchor] string id.
 * 3. On the destination composable, attach the same anchor id to the row
 *    using a `Modifier.layout` keyed by it OR by exposing a map of
 *    `anchorId -> LazyList index` so the router can scroll there.
 */
data class SettingsItem(
    /** Stable typed-string id (e.g. `"cloud.sync"`). */
    val id: String,

    /** Logical section the row belongs to (used for breadcrumb display). */
    val section: SettingsSection,

    /** Destination route the search router can navigate to. */
    val pageRoute: SettingsPageRoute,

    /** Anchor id used by destination screens to scroll the row into view. */
    val anchorId: String,

    /** Optional focus target for text fields. */
    val focusId: String? = null,

    /** Primary user-facing label. */
    val title: String,

    /** Optional descriptive line. */
    val subtitle: String? = null,

    /** Synonyms / alternates the user might type. */
    val keywords: List<String> = emptyList(),

    /** Long-form help indexed at the lowest weight. */
    val helpText: String? = null,
)

/**
 * Top-level sections of the Android Settings root screen.
 *
 * Used for breadcrumb display ("Cloud › Sync") in the search results.
 */
enum class SettingsSection(val displayTitle: String) {
    CLOUD("Cloud"),
    PROVIDERS("Providers"),
    DEVICES("Devices"),
    SMART_DISPLAYS("Smart Displays"),
    NOTIFICATIONS("Notifications"),
    HERMES("Hermes"),
}

/**
 * Deep-link destinations the Android settings router knows how to push.
 *
 * `Root` means the row already lives on the Settings root surface.
 */
enum class SettingsPageRoute {
    ROOT,
    SMART_DISPLAYS,
    MENU_BAR_PREFS,
}

/**
 * Stable scroll anchor ids reused across the manifest and destination
 * composables.
 *
 * Keep these grouped by destination so a single grep can confirm
 * manifest/destination parity.
 */
object SettingsAnchor {
    // Root
    const val CLOUD_SYNC = "root.cloudSync"
    const val PROVIDERS_ROW = "root.providers"
    const val CONNECTED_DEVICES = "root.connectedDevices"
    const val SMART_DISPLAYS_ROW = "root.smartDisplays"
    const val QUICK_GLANCE_ROW = "root.quickGlance"

    // Smart Displays
    const val GOOGLE_SMART_DISPLAY = "smartDisplays.google"
    const val PIXEL_CLOCK = "smartDisplays.pixelClock"

    // Quick-glance notification
    const val PERSISTENT_NOTIFICATION = "menuBarPrefs.persistent"

    // Hermes
    const val HERMES_CONNECTIONS = "hermes.connections"
    const val HERMES_MODELS = "hermes.models"
    const val HERMES_DISPLAY = "hermes.display"
    const val HERMES_GATEWAY = "hermes.gateway"
    const val HERMES_STATUS = "hermes.status"
}

object SettingsFocus {
    const val HERMES_GATEWAY_URL = "hermes.gateway.url"
    const val HERMES_GATEWAY_TOKEN = "hermes.gateway.token"
}
