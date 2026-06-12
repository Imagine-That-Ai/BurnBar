// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.insights

import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Density
import androidx.lifecycle.viewmodel.compose.viewModel

/**
 * Top-level Insights screen. Visual parity target: iOS
 * `InsightsRootView` + `IntelligenceBriefView`.
 *
 * Chrome layout (top → bottom):
 *  • CenterAlignedTopAppBar with canvas title + refresh + brief-options
 *    actions, mirroring the iOS NavigationStack toolbar
 *    (`rectangle.stack`, `arrow.clockwise`, `slider.horizontal.3`).
 *  • Scrolling content: `IntelligenceBriefScreen` (9-section editorial
 *    cascade), followed by mission status banner, canvas grid, error,
 *    and empty state.
 *  • Sticky composer bar pinned to the bottom with a top hairline and
 *    a brand-tinted rounded text field + ember send pill — matches the
 *    iOS `.thinMaterial` composer.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun InsightsScreen(modifier: Modifier = Modifier, viewModel: InsightsViewModel = viewModel()) {
    LaunchedEffect(Unit) {
        viewModel.load()
    }

    val density = LocalDensity.current
    CompositionLocalProvider(
        LocalDensity provides Density(density.density, fontScale = density.fontScale.coerceAtMost(1.15f)),
    ) {
        InsightsScreenRoot(modifier = modifier, viewModel = viewModel)
    }
}
