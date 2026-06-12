@file:Suppress("MagicNumber")
// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.pro

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithCache

/**
 * Pro vocabulary — the cinematic stage. Obsidian base + descending darkened
 * aurora ribbon + soft upper-center halo + film grain. Mirrors iOS poster.
 */
@Composable
fun ProPosterScaffold(modifier: Modifier = Modifier, includeGrain: Boolean = true, includeRibbon: Boolean = true, content: @Composable () -> Unit) {
    Box(
        modifier =
        modifier
            .fillMaxSize()
            .background(ProPalette.obsidian)
            .drawWithCache {
                val ribbonHeight = 360f
                val haloRadius = 320f
                onDrawWithContent {
                    if (includeRibbon) {
                        drawProPosterRibbon(ribbonHeight)
                    }
                    drawProPosterHalo(haloRadius)
                    drawContent()
                    if (includeGrain) {
                        drawProPosterGrain()
                    }
                }
            },
        contentAlignment = Alignment.Center,
    ) {
        content()
    }
}
