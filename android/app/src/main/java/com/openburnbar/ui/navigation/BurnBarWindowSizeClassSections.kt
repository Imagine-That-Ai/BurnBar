// Material 3 adaptive WindowSizeClass mapping and layout utilities.
// Provides clean COMPACT / MEDIUM / EXPANDED breakpoint models.

package com.openburnbar.ui.navigation

import androidx.compose.runtime.Composable
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/**
 * Material 3 window width size classes.
 * - COMPACT: < 600dp (standard phone portrait)
 * - MEDIUM: 600dp..<840dp (tablets portrait, foldables unfolded)
 * - EXPANDED: >= 840dp (tablets landscape, desktop, chromebook)
 */
enum class BurnBarWindowWidthClass {
    COMPACT,
    MEDIUM,
    EXPANDED;

    val isCompact: Boolean get() = this == COMPACT
    val isMedium: Boolean get() = this == MEDIUM
    val isExpanded: Boolean get() = this == EXPANDED
    val isWide: Boolean get() = this != COMPACT
}

data class BurnBarWindowSizeClass(
    val widthClass: BurnBarWindowWidthClass,
    val widthDp: Dp,
) {
    companion object {
        fun calculate(widthDp: Dp): BurnBarWindowSizeClass {
            val widthClass = when {
                widthDp < 600.dp -> BurnBarWindowWidthClass.COMPACT
                widthDp < 840.dp -> BurnBarWindowWidthClass.MEDIUM
                else -> BurnBarWindowWidthClass.EXPANDED
            }
            return BurnBarWindowSizeClass(widthClass = widthClass, widthDp = widthDp)
        }
    }
}

val LocalWindowSizeClass = compositionLocalOf {
    BurnBarWindowSizeClass(
        widthClass = BurnBarWindowWidthClass.COMPACT,
        widthDp = 360.dp,
    )
}

@Composable
fun rememberWindowSizeClass(): BurnBarWindowSizeClass {
    val configuration = LocalConfiguration.current
    return BurnBarWindowSizeClass.calculate(configuration.screenWidthDp.dp)
}
