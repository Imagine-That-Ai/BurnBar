package com.openburnbar.ui.pro

import android.content.Context
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.openburnbar.R
import com.openburnbar.ui.theme.AuroraColors

// ── Cloud Badge (Android) ──
//
// User-selectable Cloud Member brand mark — parity with the iOS CloudBadge.
// Four PNG drawables (rendered from the same SVG masters as iOS) live under
// res/drawable/cloud_badge_*. The same Composable renders whichever style
// the user picked; selection is persisted in SharedPreferences and applied
// across every surface that needs the badge (You-tab row, Cloud destination,
// future nav-tray chip, etc.).

enum class CloudBadgeStyle(
    val key: String,
    val title: String,
    val blurb: String,
    val drawableRes: Int
) {
    Shield(
        key = "shield",
        title = "Silver Shield",
        blurb = "Pewter heraldry — clean, classic.",
        drawableRes = R.drawable.cloud_badge_shield
    ),
    WaxSeal(
        key = "wax_seal",
        title = "Wax Seal",
        blurb = "Coral wax + silver flame — handcrafted.",
        drawableRes = R.drawable.cloud_badge_wax_seal
    ),
    BrassCoin(
        key = "brass_coin",
        title = "Brass Signet",
        blurb = "Engraved brass coin — coveted signet.",
        drawableRes = R.drawable.cloud_badge_brass_coin
    ),
    SunDisc(
        key = "sun_disc",
        title = "Sun Disc",
        blurb = "Obsidian sunburst — ornate and cinematic.",
        drawableRes = R.drawable.cloud_badge_sun_disc
    );

    companion object {
        val DEFAULT: CloudBadgeStyle = BrassCoin
        fun fromKey(key: String?): CloudBadgeStyle =
            entries.firstOrNull { it.key == key } ?: DEFAULT
    }
}

// ── Selection store ──
//
// Thin SharedPreferences wrapper. A CompositionLocal hands the current
// selection to anything inside `AuroraTheme`, and the picker writes back
// through the same store so every observer recomposes.

private const val PREFS_NAME = "cloud_badge_prefs"
private const val PREFS_KEY = "cloud.badge.style"

class CloudBadgeStore(context: Context) {
    private val prefs = context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    var current: CloudBadgeStyle = CloudBadgeStyle.fromKey(prefs.getString(PREFS_KEY, null))
        private set

    fun set(style: CloudBadgeStyle) {
        current = style
        prefs.edit().putString(PREFS_KEY, style.key).apply()
    }
}

/**
 * CompositionLocal carrying a single shared selection instance for the whole
 * composition tree. `AuroraTheme` provides one so the picker, the You-tab
 * card, and the nav-tray badge all observe the same state — without this,
 * each [rememberCloudBadgeSelection] call would mint its own [MutableState]
 * and the picker's writes would never recompose other call sites.
 */
val LocalCloudBadgeSelection = compositionLocalOf<MutableState<CloudBadgeStyle>?> { null }

/**
 * Returns the shared selection from [LocalCloudBadgeSelection] when one is
 * provided (the production path under `AuroraTheme`); otherwise creates a
 * local instance so the composable still works in previews and isolated tests.
 */
@Composable
fun rememberCloudBadgeSelection(): MutableState<CloudBadgeStyle> {
    LocalCloudBadgeSelection.current?.let { return it }
    return rememberLocalCloudBadgeSelection()
}

/**
 * Creates a fresh selection bound to [CloudBadgeStore]. Call this exactly
 * once at the top of the composition (e.g. in `AuroraTheme`) and pipe the
 * result into [LocalCloudBadgeSelection] so all observers share state.
 */
@Composable
fun rememberLocalCloudBadgeSelection(): MutableState<CloudBadgeStyle> {
    val context = LocalContext.current
    val store = remember { CloudBadgeStore(context) }
    val state = remember { mutableStateOf(store.current) }
    return remember(state, store) {
        object : MutableState<CloudBadgeStyle> by state {
            override var value: CloudBadgeStyle
                get() = state.value
                set(newValue) {
                    state.value = newValue
                    store.set(newValue)
                }
        }
    }
}

// ── Badge view ──

enum class CloudBadgeSize(val dp: Dp) {
    Small(28.dp),
    Medium(56.dp),
    Large(104.dp);
}

/**
 * Renders the user's current Cloud badge at the requested size.
 * Pass [styleOverride] from the picker preview to show a specific style.
 */
@Composable
fun CloudBadge(
    size: CloudBadgeSize = CloudBadgeSize.Medium,
    styleOverride: CloudBadgeStyle? = null,
    modifier: Modifier = Modifier
) {
    val style = styleOverride ?: rememberCloudBadgeSelection().value
    Image(
        painter = painterResource(id = style.drawableRes),
        contentDescription = "OpenBurnBar Cloud member badge",
        modifier = modifier.size(size.dp),
        contentScale = ContentScale.Fit
    )
}

/**
 * Convenience variant for use inside the aurora membership card —
 * adds a soft ember halo behind the badge so it lifts off the gradient.
 */
@Composable
fun CloudBadgeWithHalo(
    size: CloudBadgeSize = CloudBadgeSize.Medium,
    styleOverride: CloudBadgeStyle? = null,
    modifier: Modifier = Modifier
) {
    Box(
        modifier = modifier
            .size(size.dp + 16.dp),
        contentAlignment = Alignment.Center
    ) {
        Box(
            modifier = Modifier
                .size(size.dp + 8.dp)
                .clip(androidx.compose.foundation.shape.CircleShape)
                .background(
                    Brush.radialGradient(
                        colors = listOf(
                            AuroraColors.amber.copy(alpha = 0.55f),
                            AuroraColors.ember.copy(alpha = 0.25f),
                            Color.Transparent
                        )
                    )
                )
        )
        CloudBadge(size = size, styleOverride = styleOverride)
    }
}
