@file:Suppress("MagicNumber")
// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.chartstudio

import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier

@Composable
fun ChartStudioFab(modifier: Modifier = Modifier) {
    ChartStudioFabContent(modifier = modifier)
}
