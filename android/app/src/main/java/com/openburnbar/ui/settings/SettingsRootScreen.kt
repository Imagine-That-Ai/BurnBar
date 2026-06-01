package com.openburnbar.ui.settings

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import com.openburnbar.ui.smartdisplay.SmartDisplayView

private const val SMART_DISPLAY_HIGHLIGHT_FADE_DELAY_MS = 1_400L

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
            SettingsPageRoute.TEXT_EXPANSION -> TextExpansionSettingsScreen(
                onBack = { router.page = SettingsPageRoute.ROOT }
            )
            SettingsPageRoute.TRANSCRIPT_CACHE -> TranscriptCacheSettingsScreen(
                router = router,
                onBack = { router.page = SettingsPageRoute.ROOT }
            )
        }
    }
}

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
            kotlinx.coroutines.delay(SMART_DISPLAY_HIGHLIGHT_FADE_DELAY_MS)
            router.clearHighlight(pending)
        }
    }
    SmartDisplayView(onBack = onBack)
}
