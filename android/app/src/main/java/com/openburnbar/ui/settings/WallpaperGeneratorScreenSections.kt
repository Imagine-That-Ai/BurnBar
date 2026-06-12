@file:OptIn(
    androidx.compose.foundation.layout.ExperimentalLayoutApi::class,
    androidx.compose.material3.ExperimentalMaterial3Api::class,
)

@file:Suppress("MagicNumber")
// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

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
import android.view.View
import android.widget.Toast
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
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
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.hapticfeedback.HapticFeedback
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.models.AgentProvider
import com.openburnbar.ui.components.AuroraBottomSheet
import com.openburnbar.ui.components.LiquidGlassGroup
import com.openburnbar.ui.components.ProviderLogo
import com.openburnbar.ui.components.SwarmPace
import com.openburnbar.ui.components.SwarmSimulation
import com.openburnbar.ui.components.liquidGlassBackdrop
import com.openburnbar.ui.components.liquidGlassInteractive
import com.openburnbar.ui.components.liquidGlassSurface
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.wallpaper.BurnBarWallpaperService
import java.io.OutputStream
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

internal enum class WallpaperStyle(val displayName: String) {
    DARK("Dark"),
    LIGHT("Light"),
    AMOLED("AMOLED"),
    EMBER("Ember Glow"),
    ;

    val backgroundColor: Color
        get() =
            when (this) {
                DARK -> Color(0xFF0E0D0B)
                LIGHT -> Color(0xFFEDF0E6)
                AMOLED -> Color.Black
                EMBER -> Color(0xFF140F0A)
            }

    val isDark: Boolean
        get() = this != LIGHT

    val paletteName: String
        get() =
            when (this) {
                DARK -> "AuroraTeal"
                LIGHT -> "ForestMoss"
                AMOLED -> "CyberpunkViolet"
                EMBER -> "SolarFlare"
            }
}

internal data class WallpaperGeneratorState(
    val context: Context,
    val haptic: HapticFeedback,
    val scope: CoroutineScope,
    val view: View,
    val selectedStyle: WallpaperStyle,
    val onSelectedStyleChange: (WallpaperStyle) -> Unit,
    val showGlyphCustomizer: Boolean,
    val onShowGlyphCustomizerChange: (Boolean) -> Unit,
    val isSavingStill: Boolean,
    val onIsSavingStillChange: (Boolean) -> Unit,
    val showTapHint: Boolean,
    val onShowTapHintChange: (Boolean) -> Unit,
    val tapHintAlpha: Float,
    val onTapHintAlphaChange: (Float) -> Unit,
    val providerGlyphs: Set<AgentProvider>,
    val simulation: SwarmSimulation,
    val animatedHintAlpha: Float,
)

@Composable
internal fun rememberWallpaperGeneratorState(): WallpaperGeneratorState {
    val context = LocalContext.current
    val haptic = LocalHapticFeedback.current
    val scope = rememberCoroutineScope()
    val view = LocalView.current

    var selectedStyle by remember { mutableStateOf(WallpaperStyle.DARK) }
    var showGlyphCustomizer by remember { mutableStateOf(false) }
    var isSavingStill by remember { mutableStateOf(false) }
    var showTapHint by remember { mutableStateOf(true) }
    var tapHintAlpha by remember { mutableStateOf(1f) }

    val providerGlyphs by rememberProviderGlyphs()
    val simulation =
        remember(providerGlyphs) {
            SwarmSimulation(
                particleCount = 320,
                pace = SwarmPace.CINEMATIC,
                context = context.applicationContext,
                enabledProviderGlyphs = providerGlyphs,
            )
        }

    // Pre-warm every shape's point table OFF the main thread so the preview's
    // first provider-logo reconvergence (and tap-to-cycle) never decodes the
    // logo bitmaps synchronously on the UI thread; the SYNCHRONIZED lazies
    // stay the cache-miss path, so a race just blocks as it did before.
    LaunchedEffect(simulation) {
        withContext(Dispatchers.Default) { simulation.prewarmShapePointTables() }
    }

    LaunchedEffect(selectedStyle) {
        simulation.paletteName = selectedStyle.paletteName
    }

    val animatedHintAlpha by animateFloatAsState(
        targetValue = tapHintAlpha,
        animationSpec = tween(400),
        label = "hint-alpha",
    )

    return WallpaperGeneratorState(
        context = context,
        haptic = haptic,
        scope = scope,
        view = view,
        selectedStyle = selectedStyle,
        onSelectedStyleChange = { selectedStyle = it },
        showGlyphCustomizer = showGlyphCustomizer,
        onShowGlyphCustomizerChange = { showGlyphCustomizer = it },
        isSavingStill = isSavingStill,
        onIsSavingStillChange = { isSavingStill = it },
        showTapHint = showTapHint,
        onShowTapHintChange = { showTapHint = it },
        tapHintAlpha = tapHintAlpha,
        onTapHintAlphaChange = { tapHintAlpha = it },
        providerGlyphs = providerGlyphs,
        simulation = simulation,
        animatedHintAlpha = animatedHintAlpha,
    )
}

@Composable
private fun rememberSaveStillHandler(
    state: WallpaperGeneratorState,
    onVersionBump: () -> Unit,
): () -> Unit {
    val scope = state.scope
    return {
        if (!state.isSavingStill) {
            state.onIsSavingStillChange(true)
            scope.launch {
                state.simulation.instantlySettle()
                onVersionBump()
                delay(50)
                saveStillWallpaper(state.view, state.context)
                state.onIsSavingStillChange(false)
            }
        }
    }
}

@Composable
internal fun WallpaperGeneratorScreenContent(
    onBack: () -> Unit,
    state: WallpaperGeneratorState,
) {
    var pointer by remember { mutableStateOf<Offset?>(null) }
    var isHolding by remember { mutableStateOf(false) }
    var isRewinding by remember { mutableStateOf(false) }
    var version by remember { mutableIntStateOf(0) }
    val onSaveStill = rememberSaveStillHandler(state) { version++ }

    LaunchedEffect(isHolding, isRewinding) {
        state.simulation.setPace(if (isHolding) SwarmPace.ENERGETIC else SwarmPace.CINEMATIC)
        state.simulation.isRewinding = isRewinding
    }

    LaunchedEffect(Unit) {
        while (true) {
            delay(if (isHolding) 8L else 16L)
            state.simulation.advance(System.nanoTime(), pointer)
            version++
        }
    }

    LiquidGlassGroup(modifier = Modifier.fillMaxSize()) {
        WallpaperSwarmCanvasSection(
            selectedStyle = state.selectedStyle,
            simulation = state.simulation,
            version = version,
            pointerArgs =
            WallpaperSwarmPointerArgs(
                showTapHint = state.showTapHint,
                onTapHintAlphaChange = state.onTapHintAlphaChange,
                onShowTapHintChange = state.onShowTapHintChange,
                haptic = state.haptic,
                simulation = state.simulation,
                onPointerChange = { pointer = it },
                onIsHoldingChange = { isHolding = it },
                onIsRewindingChange = { isRewinding = it },
            ),
        )
        WallpaperGeneratorTopBar(
            selectedStyle = state.selectedStyle,
            onBack = onBack,
            onOpenCustomizer = { state.onShowGlyphCustomizerChange(true) },
        )
        WallpaperGeneratorBottomControls(
            state = state,
            onSaveStill = onSaveStill,
            onSetLive = { setLiveWallpaper(state.context) },
            modifier = Modifier.align(Alignment.BottomCenter),
        )
        if (state.showGlyphCustomizer) {
            WallpaperSettingsSheet(
                selectedStyle = state.selectedStyle,
                onStyleSelected = state.onSelectedStyleChange,
                providerGlyphs = state.providerGlyphs,
                onDismiss = { state.onShowGlyphCustomizerChange(false) },
            )
        }
    }
}

internal data class WallpaperSwarmPointerArgs(
    val showTapHint: Boolean,
    val onTapHintAlphaChange: (Float) -> Unit,
    val onShowTapHintChange: (Boolean) -> Unit,
    val haptic: HapticFeedback,
    val simulation: SwarmSimulation,
    val onPointerChange: (Offset?) -> Unit,
    val onIsHoldingChange: (Boolean) -> Unit,
    val onIsRewindingChange: (Boolean) -> Unit,
)

@Composable
private fun WallpaperSwarmCanvasSection(
    selectedStyle: WallpaperStyle,
    simulation: SwarmSimulation,
    version: Int,
    pointerArgs: WallpaperSwarmPointerArgs,
) {
    Box(
        modifier =
        Modifier
            .fillMaxSize()
            .liquidGlassBackdrop()
            .background(selectedStyle.backgroundColor)
            .wallpaperSwarmPointerInput(pointerArgs),
    ) {
        WallpaperSwarmParticleCanvas(
            simulation = simulation,
            selectedStyle = selectedStyle,
            version = version,
        )
        WallpaperSwarmVignette(backgroundColor = selectedStyle.backgroundColor)
    }
}

private fun Modifier.wallpaperSwarmPointerInput(args: WallpaperSwarmPointerArgs): Modifier =
    pointerInput(Unit) {
        awaitPointerEventScope {
            while (true) {
                wallpaperSwarmHandlePointerDown(args)
            }
        }
    }

private suspend fun androidx.compose.ui.input.pointer.AwaitPointerEventScope.wallpaperSwarmHandlePointerDown(
    args: WallpaperSwarmPointerArgs,
) {
    val down = awaitFirstDown(requireUnconsumed = false)
    val isLeft = down.position.x < size.width / 2
    args.onPointerChange(down.position)
    args.onIsHoldingChange(true)
    args.onIsRewindingChange(isLeft)
    val holdStartMs = System.currentTimeMillis()
    val tapThreshold = 24.dp.toPx()

    if (args.showTapHint) {
        args.onTapHintAlphaChange(0f)
    }

    try {
        wallpaperSwarmTrackPointerEvents(
            context =
            WallpaperSwarmTrackContext(
                args = args,
                down = down,
                isLeft = isLeft,
                holdStartMs = holdStartMs,
                tapThreshold = tapThreshold,
                isTap = true,
            ),
        )
    } finally {
        args.onPointerChange(null)
        args.onIsHoldingChange(false)
        args.onIsRewindingChange(false)
        if (args.showTapHint) {
            args.onShowTapHintChange(false)
        }
    }
}

internal data class WallpaperSwarmTrackContext(
    val args: WallpaperSwarmPointerArgs,
    val down: androidx.compose.ui.input.pointer.PointerInputChange,
    val isLeft: Boolean,
    val holdStartMs: Long,
    val tapThreshold: Float,
    var isTap: Boolean,
)

private suspend fun androidx.compose.ui.input.pointer.AwaitPointerEventScope.wallpaperSwarmTrackPointerEvents(
    context: WallpaperSwarmTrackContext,
) {
    while (true) {
        val event = awaitPointerEvent()
        val anyActive = event.changes.any { it.pressed }
        if (!anyActive) {
            val duration = System.currentTimeMillis() - context.holdStartMs
            if (context.isTap && duration < 350) {
                context.args.simulation.forceCycleShape(forward = !context.isLeft)
                context.args.haptic.performHapticFeedback(HapticFeedbackType.LongPress)
            }
            break
        }

        val change = event.changes.firstOrNull { it.pressed }
        if (change != null) {
            context.args.onPointerChange(change.position)
            val dist = (change.position - context.down.position).getDistance()
            if (dist > context.tapThreshold) {
                context.isTap = false
            }
            change.consume()
        }
    }
}

@Composable
private fun WallpaperSwarmParticleCanvas(
    simulation: SwarmSimulation,
    selectedStyle: WallpaperStyle,
    version: Int,
) {
    key(version) {
        Canvas(modifier = Modifier.fillMaxSize()) {
            simulation.ensureBounds(size)

            simulation.particles.forEach { p ->
                if (p.isGlyph) return@forEach
                val color = simulation.colorFor(p, AuroraColors.ember, selectedStyle.isDark)
                val inShape = simulation.inShapeMode && p.tx != null
                drawCircle(
                    color = color,
                    radius = (p.size * if (inShape) 1.2 else 0.85).toFloat(),
                    center = Offset(p.x.toFloat(), p.y.toFloat()),
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
    }
}

@Composable
private fun WallpaperSwarmVignette(backgroundColor: Color) {
    Box(
        modifier =
        Modifier
            .fillMaxSize()
            .background(
                Brush.radialGradient(
                    colors =
                    listOf(
                        Color.Transparent,
                        backgroundColor.copy(alpha = 0.7f),
                    ),
                    radius = 900f,
                ),
            ),
    )
}

@Composable
private fun WallpaperGeneratorTopBar(
    selectedStyle: WallpaperStyle,
    onBack: () -> Unit,
    onOpenCustomizer: () -> Unit,
) {
    Row(
        modifier =
        Modifier
            .fillMaxWidth()
            .padding(top = 48.dp, start = 16.dp, end = 16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        IconButton(onClick = onBack) {
            Icon(
                Icons.AutoMirrored.Filled.ArrowBack,
                contentDescription = "Back",
                tint = if (selectedStyle.isDark) Color.White.copy(alpha = 0.7f) else Color.Black.copy(alpha = 0.5f),
            )
        }

        Spacer(modifier = Modifier.weight(1f))

        Surface(
            onClick = onOpenCustomizer,
            shape = RoundedCornerShape(999.dp),
            color = Color.Transparent,
            modifier = Modifier.liquidGlassInteractive(shape = RoundedCornerShape(999.dp)),
        ) {
            Row(
                modifier = Modifier.padding(horizontal = 14.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                Icon(
                    Icons.Filled.Palette,
                    contentDescription = null,
                    modifier = Modifier.size(16.dp),
                    tint = if (selectedStyle.isDark) Color.White else Color.Black,
                )
                Text(
                    selectedStyle.displayName,
                    fontSize = 13.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = if (selectedStyle.isDark) Color.White else Color.Black,
                )
            }
        }
    }
}

@Composable
private fun WallpaperGeneratorBottomControls(
    state: WallpaperGeneratorState,
    onSaveStill: () -> Unit,
    onSetLive: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier =
        modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 32.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        if (state.showTapHint) {
            WallpaperTapHintChip(
                selectedStyle = state.selectedStyle,
                animatedHintAlpha = state.animatedHintAlpha,
            )
        }

        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            WallpaperGlyphCustomizerToggle(
                selectedStyle = state.selectedStyle,
                showGlyphCustomizer = state.showGlyphCustomizer,
                providerGlyphs = state.providerGlyphs,
                onToggle = {
                    state.onShowGlyphCustomizerChange(!state.showGlyphCustomizer)
                },
            )

            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                WallpaperSaveStillButton(
                    selectedStyle = state.selectedStyle,
                    isSavingStill = state.isSavingStill,
                    onClick = onSaveStill,
                )
                WallpaperSetLiveButton(onClick = onSetLive)
            }
        }
    }
}

@Composable
private fun WallpaperTapHintChip(
    selectedStyle: WallpaperStyle,
    animatedHintAlpha: Float,
) {
    Surface(
        shape = RoundedCornerShape(999.dp),
        color = Color.Transparent,
        modifier =
        Modifier
            .graphicsLayer(alpha = animatedHintAlpha)
            .liquidGlassSurface(shape = RoundedCornerShape(999.dp)),
    ) {
        Text(
            "Tap to explore · Hold to speed up",
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 10.dp),
            fontSize = 13.sp,
            fontWeight = FontWeight.Medium,
            color = if (selectedStyle.isDark) Color.White.copy(alpha = 0.6f) else Color.Black.copy(alpha = 0.4f),
        )
    }
}

@Composable
private fun WallpaperGlyphCustomizerToggle(
    selectedStyle: WallpaperStyle,
    showGlyphCustomizer: Boolean,
    providerGlyphs: Set<AgentProvider>,
    onToggle: () -> Unit,
) {
    val chevronRotation by animateFloatAsState(
        targetValue = if (showGlyphCustomizer) 180f else 0f,
        animationSpec = tween(200),
        label = "chevron",
    )
    Surface(
        onClick = onToggle,
        shape = RoundedCornerShape(999.dp),
        color = Color.Transparent,
        modifier =
        Modifier.liquidGlassInteractive(
            tint = if (showGlyphCustomizer) Color.White else null,
            shape = RoundedCornerShape(999.dp),
        ),
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Row(horizontalArrangement = Arrangement.spacedBy((-4).dp)) {
                providerGlyphs.take(3).forEach { provider ->
                    ProviderLogo(provider = provider, size = 16.dp)
                }
            }
            Icon(
                Icons.Filled.KeyboardArrowDown,
                contentDescription = "Customize glyphs",
                modifier =
                Modifier
                    .size(16.dp)
                    .graphicsLayer(rotationZ = chevronRotation),
                tint = if (selectedStyle.isDark) Color.White.copy(alpha = 0.6f) else Color.Black.copy(alpha = 0.4f),
            )
        }
    }
}

@Composable
private fun WallpaperSaveStillButton(
    selectedStyle: WallpaperStyle,
    isSavingStill: Boolean,
    onClick: () -> Unit,
) {
    Surface(
        onClick = onClick,
        shape = RoundedCornerShape(999.dp),
        color = Color.Transparent,
        modifier = Modifier.liquidGlassInteractive(shape = RoundedCornerShape(999.dp)),
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 14.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            if (isSavingStill) {
                CircularProgressIndicator(
                    modifier = Modifier.size(14.dp),
                    strokeWidth = 2.dp,
                    color = if (selectedStyle.isDark) Color.White else Color.Black,
                )
            } else {
                Icon(
                    Icons.Filled.Photo,
                    contentDescription = null,
                    modifier = Modifier.size(14.dp),
                    tint = if (selectedStyle.isDark) Color.White else Color.Black,
                )
            }
            Text(
                if (isSavingStill) "Saving…" else "Still",
                fontSize = 12.sp,
                fontWeight = FontWeight.Bold,
                color = if (selectedStyle.isDark) Color.White else Color.Black,
            )
        }
    }
}

@Composable
private fun WallpaperSetLiveButton(onClick: () -> Unit) {
    Surface(
        onClick = onClick,
        shape = RoundedCornerShape(999.dp),
        color = AuroraColors.ember,
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 14.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Icon(
                Icons.Filled.Wallpaper,
                contentDescription = null,
                modifier = Modifier.size(14.dp),
                tint = Color.White,
            )
            Text(
                "Set Live",
                fontSize = 12.sp,
                fontWeight = FontWeight.Bold,
                color = Color.White,
            )
        }
    }
}

@Composable
internal fun WallpaperSettingsSheet(
    selectedStyle: WallpaperStyle,
    onStyleSelected: (WallpaperStyle) -> Unit,
    providerGlyphs: Set<AgentProvider>,
    onDismiss: () -> Unit,
) {
    AuroraBottomSheet(onDismissRequest = onDismiss) {
        WallpaperSettingsSheetBody(
            selectedStyle = selectedStyle,
            onStyleSelected = onStyleSelected,
            providerGlyphs = providerGlyphs,
            onDismiss = onDismiss,
        )
    }
}

@Composable
private fun WallpaperSettingsSheetBody(
    selectedStyle: WallpaperStyle,
    onStyleSelected: (WallpaperStyle) -> Unit,
    providerGlyphs: Set<AgentProvider>,
    onDismiss: () -> Unit,
) {
    val isDark = selectedStyle.isDark
    Column(
        modifier =
        Modifier
            .fillMaxWidth()
            .padding(bottom = 16.dp)
            .verticalScroll(rememberScrollState()),
        verticalArrangement = Arrangement.spacedBy(20.dp),
    ) {
        WallpaperSettingsSheetHeader(isDark = isDark, onDismiss = onDismiss)
        WallpaperStylePickerSection(
            selectedStyle = selectedStyle,
            isDark = isDark,
            onStyleSelected = onStyleSelected,
        )
        WallpaperSettingsDivider(isDark = isDark)
        WallpaperProviderGlyphsSection(
            isDark = isDark,
            providerGlyphs = providerGlyphs,
        )
    }
}

@Composable
private fun WallpaperSettingsSheetHeader(isDark: Boolean, onDismiss: () -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = "Wallpaper Options",
            fontSize = 18.sp,
            fontWeight = FontWeight.Bold,
            color = if (isDark) Color.White else Color.Black,
        )
        IconButton(onClick = onDismiss) {
            Icon(
                imageVector = Icons.Filled.Check,
                contentDescription = "Done",
                tint = if (isDark) Color.White else Color.Black,
            )
        }
    }
}

@Composable
private fun WallpaperStylePickerSection(
    selectedStyle: WallpaperStyle,
    isDark: Boolean,
    onStyleSelected: (WallpaperStyle) -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(
            text = "Background Style",
            fontSize = 12.sp,
            fontWeight = FontWeight.Bold,
            color = (if (isDark) Color.White else Color.Black).copy(alpha = 0.5f),
        )
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            WallpaperStyle.entries.forEach { style ->
                WallpaperStyleChip(
                    style = style,
                    isSelected = style == selectedStyle,
                    isDark = isDark,
                    onClick = { onStyleSelected(style) },
                    modifier = Modifier.weight(1f),
                )
            }
        }
    }
}

@Composable
private fun WallpaperStyleChip(
    style: WallpaperStyle,
    isSelected: Boolean,
    isDark: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Surface(
        onClick = onClick,
        shape = RoundedCornerShape(12.dp),
        color =
        if (isSelected) {
            if (isDark) Color.White.copy(alpha = 0.15f) else Color.Black.copy(alpha = 0.08f)
        } else {
            Color.Transparent
        },
        border =
        BorderStroke(
            1.dp,
            if (isSelected) {
                AuroraColors.ember
            } else if (isDark) {
                Color.White.copy(alpha = 0.1f)
            } else {
                Color.Black.copy(alpha = 0.1f)
            },
        ),
        modifier = modifier,
    ) {
        Column(
            modifier =
            Modifier
                .fillMaxWidth()
                .padding(vertical = 8.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            WallpaperStylePreviewDot(style = style)
            Text(
                text = style.displayName,
                fontSize = 10.sp,
                fontWeight = FontWeight.SemiBold,
                color = if (isDark) Color.White else Color.Black,
            )
        }
    }
}

@Composable
private fun WallpaperStylePreviewDot(style: WallpaperStyle) {
    Box(
        modifier =
        Modifier
            .size(10.dp)
            .background(
                color =
                when (style) {
                    WallpaperStyle.DARK -> Color(0xFF22201C)
                    WallpaperStyle.LIGHT -> Color(0xFFEDF0E6)
                    WallpaperStyle.AMOLED -> Color.Black
                    WallpaperStyle.EMBER -> AuroraColors.ember
                },
                shape = RoundedCornerShape(999.dp),
            )
            .border(
                1.dp,
                if (style == WallpaperStyle.LIGHT) Color.Black.copy(alpha = 0.2f) else Color.White.copy(alpha = 0.2f),
                shape = RoundedCornerShape(999.dp),
            ),
    )
}

@Composable
private fun WallpaperSettingsDivider(isDark: Boolean) {
    Spacer(
        modifier =
        Modifier
            .fillMaxWidth()
            .height(1.dp)
            .background(if (isDark) Color.White.copy(alpha = 0.1f) else Color.Black.copy(alpha = 0.1f)),
    )
}

@Composable
private fun WallpaperProviderGlyphsSection(
    isDark: Boolean,
    providerGlyphs: Set<AgentProvider>,
) {
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        WallpaperProviderGlyphsHeader(isDark = isDark, providerGlyphs = providerGlyphs)
        WallpaperProviderGlyphsFlow(isDark = isDark, providerGlyphs = providerGlyphs)
    }
}

@Composable
private fun WallpaperProviderGlyphsHeader(
    isDark: Boolean,
    providerGlyphs: Set<AgentProvider>,
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column {
            Text(
                text = "Provider Glyphs",
                fontSize = 12.sp,
                fontWeight = FontWeight.Bold,
                color = (if (isDark) Color.White else Color.Black).copy(alpha = 0.5f),
            )
            val total = AgentProvider.swarmGlyphProviders.size
            val count = providerGlyphs.size
            Text(
                text =
                when (count) {
                    total -> "All active"
                    0 -> "All hidden"
                    else -> "$count/$total active"
                },
                fontSize = 11.sp,
                color = (if (isDark) Color.White else Color.Black).copy(alpha = 0.4f),
            )
        }

        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            WallpaperProviderGlyphsBulkButton(
                label = "All",
                isActive = providerGlyphs.size == AgentProvider.swarmGlyphProviders.size,
                isDark = isDark,
                onClick = { GlobalVisualSettings.setProviderGlyphs(AgentProvider.swarmGlyphProviders.toSet()) },
            )
            WallpaperProviderGlyphsBulkButton(
                label = "None",
                isActive = providerGlyphs.isEmpty(),
                isDark = isDark,
                onClick = { GlobalVisualSettings.setProviderGlyphs(emptySet()) },
            )
        }
    }
}

@Composable
private fun WallpaperProviderGlyphsBulkButton(
    label: String,
    isActive: Boolean,
    isDark: Boolean,
    onClick: () -> Unit,
) {
    Surface(
        onClick = onClick,
        shape = RoundedCornerShape(999.dp),
        color =
        if (isActive) {
            AuroraColors.ember
        } else if (isDark) {
            Color.White.copy(alpha = 0.1f)
        } else {
            Color.Black.copy(alpha = 0.05f)
        },
    ) {
        Text(
            text = label,
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp),
            fontSize = 11.sp,
            fontWeight = FontWeight.Bold,
            color =
            if (isActive) {
                Color.White
            } else if (isDark) {
                Color.White.copy(alpha = 0.6f)
            } else {
                Color.Black.copy(alpha = 0.6f)
            },
        )
    }
}

@Composable
private fun WallpaperProviderGlyphsFlow(
    isDark: Boolean,
    providerGlyphs: Set<AgentProvider>,
) {
    FlowRow(
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        AgentProvider.swarmGlyphProviders.forEach { provider ->
            WallpaperProviderGlyphChip(
                provider = provider,
                isSelected = providerGlyphs.contains(provider),
                isDark = isDark,
                onClick = {
                    val next = if (providerGlyphs.contains(provider)) {
                        providerGlyphs - provider
                    } else {
                        providerGlyphs + provider
                    }
                    GlobalVisualSettings.setProviderGlyphs(next)
                },
            )
        }
    }
}

@Composable
private fun WallpaperProviderGlyphChip(
    provider: AgentProvider,
    isSelected: Boolean,
    isDark: Boolean,
    onClick: () -> Unit,
) {
    Surface(
        onClick = onClick,
        shape = RoundedCornerShape(999.dp),
        color =
        if (isSelected) {
            if (isDark) Color.White.copy(alpha = 0.18f) else Color.Black.copy(alpha = 0.08f)
        } else if (isDark) {
            Color.White.copy(alpha = 0.06f)
        } else {
            Color.Black.copy(alpha = 0.03f)
        },
        border =
        BorderStroke(
            0.75.dp,
            if (isSelected) AuroraColors.ember else Color.Transparent,
        ),
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 10.dp, vertical = 7.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            ProviderLogo(provider = provider, size = 16.dp)
            Text(
                text = provider.displayName,
                fontSize = 11.sp,
                fontWeight = FontWeight.SemiBold,
                color = if (isDark) Color.White else Color.Black,
            )
            if (isSelected) {
                Icon(
                    imageVector = Icons.Filled.Check,
                    contentDescription = null,
                    modifier = Modifier.size(11.dp),
                    tint = if (isDark) Color.White.copy(alpha = 0.7f) else Color.Black.copy(alpha = 0.5f),
                )
            }
        }
    }
}

internal suspend fun saveStillWallpaper(view: View, context: Context) {
    withContext(Dispatchers.IO) {
        try {
            val bitmap =
                Bitmap.createBitmap(
                    view.width,
                    view.height,
                    Bitmap.Config.ARGB_8888,
                )
            val canvas = android.graphics.Canvas(bitmap)
            withContext(Dispatchers.Main) {
                view.draw(canvas)
            }

            val filename = "BurnBar_Wallpaper_${System.currentTimeMillis()}.png"
            val outputStream: OutputStream?

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val values =
                    ContentValues().apply {
                        put(MediaStore.Images.Media.DISPLAY_NAME, filename)
                        put(MediaStore.Images.Media.MIME_TYPE, "image/png")
                        put(MediaStore.Images.Media.RELATIVE_PATH, Environment.DIRECTORY_PICTURES + "/BurnBar")
                    }
                val uri =
                    context.contentResolver.insert(
                        MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                        values,
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
        } catch (e: IllegalStateException) {
            withContext(Dispatchers.Main) {
                Toast.makeText(context, "Failed to save: ${e.message}", Toast.LENGTH_SHORT).show()
            }
        }
    }
}

internal fun setLiveWallpaper(context: Context) {
    try {
        val intent =
            Intent(WallpaperManager.ACTION_CHANGE_LIVE_WALLPAPER).apply {
                putExtra(
                    WallpaperManager.EXTRA_LIVE_WALLPAPER_COMPONENT,
                    ComponentName(context, BurnBarWallpaperService::class.java),
                )
            }
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        context.startActivity(intent)
    } catch (_: IllegalStateException) {
        try {
            val intent = Intent(WallpaperManager.ACTION_LIVE_WALLPAPER_CHOOSER)
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            context.startActivity(intent)
        } catch (_: Exception) {
            Toast.makeText(context, "Open Settings → Wallpaper → Live Wallpapers → BurnBar", Toast.LENGTH_LONG).show()
        }
    }
}
