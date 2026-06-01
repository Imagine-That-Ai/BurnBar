@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package com.openburnbar.ui.settings

import androidx.compose.runtime.Composable

/**
 * Full-screen wallpaper generator — Android parity with the iOS
 * WallpaperGeneratorView. Shows a live swarm preview at device resolution
 * with the user's provider glyph selections and color palette. Users can:
 *
 *  • Tap the canvas to cycle through provider logo formations
 *  • Hold the canvas to speed up the swarm animation
 *  • Save Still — captures a high-res PNG to the gallery
 *  • Set Live — launches Android's wallpaper picker for the BurnBar live wallpaper
 *  • Pick a style (Dark, Light, AMOLED, Ember Glow)
 *  • Customise which provider glyphs appear
 */
@Composable
fun WallpaperGeneratorScreen(onBack: () -> Unit) {
    val state = rememberWallpaperGeneratorState()
    WallpaperGeneratorScreenContent(onBack = onBack, state = state)
}
