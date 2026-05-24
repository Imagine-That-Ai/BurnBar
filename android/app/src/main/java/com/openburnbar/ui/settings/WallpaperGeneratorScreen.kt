package com.openburnbar.ui.settings

import android.app.WallpaperManager
import android.content.ComponentName
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.widget.Toast
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.Palette
import androidx.compose.material.icons.filled.Photo
import androidx.compose.material.icons.filled.Wallpaper
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.models.AgentProvider
import com.openburnbar.data.models.logoRes
import com.openburnbar.ui.components.ProviderLogo
import com.openburnbar.ui.components.SwarmBackground
import com.openburnbar.ui.components.SwarmPace
import com.openburnbar.ui.components.SwarmSimulation
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.wallpaper.BurnBarWallpaperService
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.OutputStream

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

private enum class WallpaperStyle(val displayName: String) {
    DARK("Dark"),
    LIGHT("Light"),
    AMOLED("AMOLED"),
    EMBER("Ember Glow");

    val backgroundColor: Color
        get() = when (this) {
            DARK -> Color(0xFF0E0D0B)
            LIGHT -> Color(0xFFEDF0E6)
            AMOLED -> Color.Black
            EMBER -> Color(0xFF140F0A)
        }

    val isDark: Boolean
        get() = this != LIGHT

    val paletteName: String
        get() = when (this) {
            DARK -> "AuroraTeal"
            LIGHT -> "ForestMoss"
            AMOLED -> "CyberpunkViolet"
            EMBER -> "SolarFlare"
        }
}

@Composable
fun WallpaperGeneratorScreen(
    onBack: () -> Unit
) {
    val context = LocalContext.current
    val haptic = LocalHapticFeedback.current
    val scope = rememberCoroutineScope()
    val view = LocalView.current
    val isDark = isSystemInDarkTheme()
    val config = LocalConfiguration.current
    val density = LocalDensity.current

    var selectedStyle by remember { mutableStateOf(WallpaperStyle.DARK) }
    var showStyleMenu by remember { mutableStateOf(false) }
    var showGlyphCustomizer by remember { mutableStateOf(false) }
    var isSavingStill by remember { mutableStateOf(false) }
    var showTapHint by remember { mutableStateOf(true) }
    var tapHintAlpha by remember { mutableStateOf(1f) }

    val providerGlyphs by rememberProviderGlyphs()

    // Simulation for tap-to-cycle (the SwarmBackground has its own,
    // but we keep a reference to force-cycle on tap)
    val simulation = remember(providerGlyphs) {
        SwarmSimulation(
            particleCount = 320,
            pace = SwarmPace.CINEMATIC,
            context = context.applicationContext,
            enabledProviderGlyphs = providerGlyphs
        )
    }

    LaunchedEffect(selectedStyle) {
        simulation.paletteName = selectedStyle.paletteName
    }

    // Pointer + frame loop state
    var pointer by remember { mutableStateOf<Offset?>(null) }
    var isHolding by remember { mutableStateOf(false) }
    var isRewinding by remember { mutableStateOf(false) }
    var holdStartMs by remember { mutableStateOf(0L) }
    var version by remember { mutableStateOf(0) }

    LaunchedEffect(isHolding, isRewinding) {
        simulation.setPace(if (isHolding) SwarmPace.ENERGETIC else SwarmPace.CINEMATIC)
        simulation.isRewinding = isRewinding
    }

    // Frame loop
    LaunchedEffect(Unit) {
        while (true) {
            kotlinx.coroutines.delay(if (isHolding) 8L else 16L) // faster frame rate when holding
            simulation.advance(System.nanoTime(), pointer)
            version++
        }
    }

    val animatedHintAlpha by animateFloatAsState(
        targetValue = tapHintAlpha,
        animationSpec = tween(400),
        label = "hint-alpha"
    )

    Box(modifier = Modifier.fillMaxSize()) {
        // Full-screen swarm canvas
        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(selectedStyle.backgroundColor)
                .pointerInput(Unit) {
                    awaitPointerEventScope {
                        while (true) {
                            val down = awaitFirstDown(requireUnconsumed = false)
                            val isLeft = down.position.x < size.width / 2
                            pointer = down.position
                            isHolding = true
                            isRewinding = isLeft
                            holdStartMs = System.currentTimeMillis()
                            var isTap = true
                            val tapThreshold = 24.dp.toPx()

                            if (showTapHint) {
                                tapHintAlpha = 0f
                            }

                            while (true) {
                                val event = awaitPointerEvent()
                                val anyActive = event.changes.any { it.pressed }
                                if (!anyActive) {
                                    // Released!
                                    val duration = System.currentTimeMillis() - holdStartMs
                                    if (isTap && duration < 350) {
                                        simulation.forceCycleShape(forward = !isLeft)
                                        haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                                    }
                                    pointer = null
                                    isHolding = false
                                    isRewinding = false
                                    if (showTapHint) showTapHint = false
                                    break
                                }

                                val change = event.changes.firstOrNull { it.pressed }
                                if (change != null) {
                                    pointer = change.position
                                    val dist = (change.position - down.position).getDistance()
                                    if (dist > tapThreshold) {
                                        isTap = false
                                    }
                                    change.consume()
                                }
                            }
                        }
                    }
                }
        ) {
            // Render swarm particles
            androidx.compose.foundation.Canvas(modifier = Modifier.fillMaxSize()) {
                @Suppress("UNUSED_VARIABLE") val tick = version
                simulation.ensureBounds(size)

                simulation.particles.forEach { p ->
                    if (p.isGlyph) return@forEach
                    val color = simulation.colorFor(p, AuroraColors.ember, selectedStyle.isDark)
                    val inShape = simulation.inShapeMode && p.tx != null
                    drawCircle(
                        color = color,
                        radius = (p.size * if (inShape) 1.2 else 0.85).toFloat(),
                        center = Offset(p.x.toFloat(), p.y.toFloat())
                    )
                }

                val nativeCanvas = drawContext.canvas.nativeCanvas
                val paint = simulation.glyphPaint
                simulation.particles.forEach { p ->
                    if (!p.isGlyph) return@forEach
                    val color = simulation.colorFor(p, AuroraColors.ember, selectedStyle.isDark)
                    paint.color = color.toArgb()
                    nativeCanvas.drawText(p.glyph, p.x.toFloat(), p.y.toFloat(), paint)
                }
            }

            // Radial vignette
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(
                        Brush.radialGradient(
                            colors = listOf(
                                Color.Transparent,
                                selectedStyle.backgroundColor.copy(alpha = 0.7f)
                            ),
                            radius = 900f
                        )
                    )
            )
        }

        // Top bar
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(top = 48.dp, start = 16.dp, end = 16.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            IconButton(onClick = onBack) {
                Icon(
                    Icons.AutoMirrored.Filled.ArrowBack,
                    contentDescription = "Back",
                    tint = if (selectedStyle.isDark) Color.White.copy(alpha = 0.7f) else Color.Black.copy(alpha = 0.5f)
                )
            }

            Spacer(modifier = Modifier.weight(1f))

            // Style picker
            Box {
                Surface(
                    onClick = { showStyleMenu = true },
                    shape = RoundedCornerShape(999.dp),
                    color = Color.White.copy(alpha = 0.12f)
                ) {
                    Row(
                        modifier = Modifier.padding(horizontal = 14.dp, vertical = 8.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(6.dp)
                    ) {
                        Icon(
                            Icons.Filled.Palette,
                            contentDescription = null,
                            modifier = Modifier.size(16.dp),
                            tint = if (selectedStyle.isDark) Color.White else Color.Black
                        )
                        Text(
                            selectedStyle.displayName,
                            fontSize = 13.sp,
                            fontWeight = FontWeight.SemiBold,
                            color = if (selectedStyle.isDark) Color.White else Color.Black
                        )
                    }
                }

                DropdownMenu(
                    expanded = showStyleMenu,
                    onDismissRequest = { showStyleMenu = false }
                ) {
                    WallpaperStyle.entries.forEach { style ->
                        DropdownMenuItem(
                            text = { Text(style.displayName) },
                            onClick = {
                                selectedStyle = style
                                showStyleMenu = false
                            },
                            trailingIcon = {
                                if (style == selectedStyle) {
                                    Icon(Icons.Filled.Check, contentDescription = null, modifier = Modifier.size(16.dp))
                                }
                            }
                        )
                    }
                }
            }
        }

        // Bottom controls
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .align(Alignment.BottomCenter)
                .padding(horizontal = 16.dp, vertical = 32.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            // Tap hint
            if (showTapHint) {
                Surface(
                    shape = RoundedCornerShape(999.dp),
                    color = Color.White.copy(alpha = 0.08f),
                    modifier = Modifier.graphicsLayer(alpha = animatedHintAlpha)
                ) {
                    Text(
                        "Tap to explore · Hold to speed up",
                        modifier = Modifier.padding(horizontal = 16.dp, vertical = 10.dp),
                        fontSize = 13.sp,
                        fontWeight = FontWeight.Medium,
                        color = if (selectedStyle.isDark) Color.White.copy(alpha = 0.6f) else Color.Black.copy(alpha = 0.4f)
                    )
                }
            }

            // Provider glyph customizer toggle
            AnimatedVisibility(visible = showGlyphCustomizer) {
                GlyphCustomizerPanel(
                    providerGlyphs = providerGlyphs,
                    isDark = selectedStyle.isDark
                )
            }

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                // Glyph toggle
                Surface(
                    onClick = { showGlyphCustomizer = !showGlyphCustomizer },
                    shape = RoundedCornerShape(999.dp),
                    color = Color.White.copy(alpha = if (showGlyphCustomizer) 0.18f else 0.08f)
                ) {
                    Row(
                        modifier = Modifier.padding(horizontal = 12.dp, vertical = 10.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(6.dp)
                    ) {
                        // Mini provider logo stack
                        Row(horizontalArrangement = Arrangement.spacedBy((-4).dp)) {
                            providerGlyphs.take(3).forEach { provider ->
                                ProviderLogo(provider = provider, size = 16.dp)
                            }
                        }
                        val chevronRotation by animateFloatAsState(
                            targetValue = if (showGlyphCustomizer) 180f else 0f,
                            animationSpec = tween(200),
                            label = "chevron"
                        )
                        Icon(
                            Icons.Filled.KeyboardArrowDown,
                            contentDescription = "Customize glyphs",
                            modifier = Modifier
                                .size(16.dp)
                                .graphicsLayer(rotationZ = chevronRotation),
                            tint = if (selectedStyle.isDark) Color.White.copy(alpha = 0.6f) else Color.Black.copy(alpha = 0.4f)
                        )
                    }
                }

                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    // Save Still
                    Surface(
                        onClick = {
                            if (!isSavingStill) {
                                isSavingStill = true
                                scope.launch {
                                    simulation.instantlySettle()
                                    version++
                                    kotlinx.coroutines.delay(50)
                                    saveStillWallpaper(view, context)
                                    isSavingStill = false
                                }
                            }
                        },
                        shape = RoundedCornerShape(999.dp),
                        color = Color.White.copy(alpha = 0.12f)
                    ) {
                        Row(
                            modifier = Modifier.padding(horizontal = 14.dp, vertical = 10.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(6.dp)
                        ) {
                            if (isSavingStill) {
                                CircularProgressIndicator(
                                    modifier = Modifier.size(14.dp),
                                    strokeWidth = 2.dp,
                                    color = if (selectedStyle.isDark) Color.White else Color.Black
                                )
                            } else {
                                Icon(
                                    Icons.Filled.Photo,
                                    contentDescription = null,
                                    modifier = Modifier.size(14.dp),
                                    tint = if (selectedStyle.isDark) Color.White else Color.Black
                                )
                            }
                            Text(
                                if (isSavingStill) "Saving…" else "Still",
                                fontSize = 12.sp,
                                fontWeight = FontWeight.Bold,
                                color = if (selectedStyle.isDark) Color.White else Color.Black
                            )
                        }
                    }

                    // Set Live Wallpaper
                    Surface(
                        onClick = { setLiveWallpaper(context) },
                        shape = RoundedCornerShape(999.dp),
                        color = AuroraColors.ember
                    ) {
                        Row(
                            modifier = Modifier.padding(horizontal = 14.dp, vertical = 10.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(6.dp)
                        ) {
                            Icon(
                                Icons.Filled.Wallpaper,
                                contentDescription = null,
                                modifier = Modifier.size(14.dp),
                                tint = Color.White
                            )
                            Text(
                                "Set Live",
                                fontSize = 12.sp,
                                fontWeight = FontWeight.Bold,
                                color = Color.White
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
@OptIn(ExperimentalLayoutApi::class)
private fun GlyphCustomizerPanel(
    providerGlyphs: Set<AgentProvider>,
    isDark: Boolean
) {
    Surface(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(20.dp),
        color = Color.White.copy(alpha = if (isDark) 0.08f else 0.5f)
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(14.dp)
                .verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(6.dp)
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                val total = AgentProvider.swarmGlyphProviders.size
                val count = providerGlyphs.size
                Text(
                    when (count) {
                        total -> "All providers"
                        0 -> "Provider logos hidden"
                        else -> "$count/$total providers"
                    },
                    fontSize = 12.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = if (isDark) Color.White.copy(alpha = 0.7f) else Color.Black.copy(alpha = 0.6f)
                )
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Surface(
                        onClick = { GlobalVisualSettings.setProviderGlyphs(AgentProvider.swarmGlyphProviders.toSet()) },
                        shape = RoundedCornerShape(999.dp),
                        color = if (providerGlyphs.size == AgentProvider.swarmGlyphProviders.size)
                            AuroraColors.ember else Color.White.copy(alpha = 0.1f)
                    ) {
                        Text(
                            "All",
                            modifier = Modifier.padding(horizontal = 10.dp, vertical = 5.dp),
                            fontSize = 11.sp,
                            fontWeight = FontWeight.Bold,
                            color = if (providerGlyphs.size == AgentProvider.swarmGlyphProviders.size)
                                Color.White else if (isDark) Color.White.copy(alpha = 0.6f) else Color.Black.copy(alpha = 0.5f)
                        )
                    }
                    Surface(
                        onClick = { GlobalVisualSettings.setProviderGlyphs(emptySet()) },
                        shape = RoundedCornerShape(999.dp),
                        color = if (providerGlyphs.isEmpty()) AuroraColors.ember else Color.White.copy(alpha = 0.1f)
                    ) {
                        Text(
                            "None",
                            modifier = Modifier.padding(horizontal = 10.dp, vertical = 5.dp),
                            fontSize = 11.sp,
                            fontWeight = FontWeight.Bold,
                            color = if (providerGlyphs.isEmpty())
                                Color.White else if (isDark) Color.White.copy(alpha = 0.6f) else Color.Black.copy(alpha = 0.5f)
                        )
                    }
                }
            }

            // Provider chips in a flow layout
            androidx.compose.foundation.layout.FlowRow(
                horizontalArrangement = Arrangement.spacedBy(6.dp),
                verticalArrangement = Arrangement.spacedBy(6.dp)
            ) {
                AgentProvider.swarmGlyphProviders.forEach { provider ->
                    val isSelected = providerGlyphs.contains(provider)
                    Surface(
                        onClick = {
                            val next = if (isSelected) providerGlyphs - provider else providerGlyphs + provider
                            GlobalVisualSettings.setProviderGlyphs(next)
                        },
                        shape = RoundedCornerShape(999.dp),
                        color = if (isSelected)
                            Color.White.copy(alpha = if (isDark) 0.18f else 0.4f)
                        else
                            Color.White.copy(alpha = if (isDark) 0.06f else 0.2f)
                    ) {
                        Row(
                            modifier = Modifier.padding(horizontal = 8.dp, vertical = 6.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(5.dp)
                        ) {
                            ProviderLogo(provider = provider, size = 16.dp)
                            Text(
                                provider.displayName,
                                fontSize = 11.sp,
                                fontWeight = FontWeight.SemiBold,
                                color = if (isDark) Color.White else Color.Black
                            )
                            if (isSelected) {
                                Icon(
                                    Icons.Filled.Check,
                                    contentDescription = null,
                                    modifier = Modifier.size(12.dp),
                                    tint = if (isDark) Color.White.copy(alpha = 0.7f) else Color.Black.copy(alpha = 0.5f)
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}

private suspend fun saveStillWallpaper(view: android.view.View, context: Context) {
    withContext(Dispatchers.IO) {
        try {
            // Capture the current view as a bitmap
            val bitmap = Bitmap.createBitmap(
                view.width, view.height, Bitmap.Config.ARGB_8888
            )
            val canvas = android.graphics.Canvas(bitmap)
            withContext(Dispatchers.Main) {
                view.draw(canvas)
            }

            // Save to gallery via MediaStore
            val filename = "BurnBar_Wallpaper_${System.currentTimeMillis()}.png"
            val outputStream: OutputStream?

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val values = ContentValues().apply {
                    put(MediaStore.Images.Media.DISPLAY_NAME, filename)
                    put(MediaStore.Images.Media.MIME_TYPE, "image/png")
                    put(MediaStore.Images.Media.RELATIVE_PATH, Environment.DIRECTORY_PICTURES + "/BurnBar")
                }
                val uri = context.contentResolver.insert(
                    MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values
                )
                outputStream = uri?.let { context.contentResolver.openOutputStream(it) }
            } else {
                @Suppress("DEPRECATION")
                val dir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES)
                val burnBarDir = java.io.File(dir, "BurnBar")
                burnBarDir.mkdirs()
                val file = java.io.File(burnBarDir, filename)
                outputStream = java.io.FileOutputStream(file)
            }

            outputStream?.use {
                bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)
            }
            bitmap.recycle()

            withContext(Dispatchers.Main) {
                Toast.makeText(context, "Wallpaper saved to Photos", Toast.LENGTH_SHORT).show()
            }
        } catch (e: Exception) {
            withContext(Dispatchers.Main) {
                Toast.makeText(context, "Failed to save: ${e.message}", Toast.LENGTH_SHORT).show()
            }
        }
    }
}

private fun setLiveWallpaper(context: Context) {
    try {
        val intent = Intent(WallpaperManager.ACTION_CHANGE_LIVE_WALLPAPER).apply {
            putExtra(
                WallpaperManager.EXTRA_LIVE_WALLPAPER_COMPONENT,
                ComponentName(context, BurnBarWallpaperService::class.java)
            )
        }
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        context.startActivity(intent)
    } catch (e: Exception) {
        // Fallback to generic live wallpaper picker
        try {
            val intent = Intent(WallpaperManager.ACTION_LIVE_WALLPAPER_CHOOSER)
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            context.startActivity(intent)
        } catch (_: Exception) {
            Toast.makeText(context, "Open Settings → Wallpaper → Live Wallpapers → BurnBar", Toast.LENGTH_LONG).show()
        }
    }
}
