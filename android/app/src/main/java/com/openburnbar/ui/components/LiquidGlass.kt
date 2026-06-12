package com.openburnbar.ui.components

import android.os.Build
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.Stable
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.BlurEffect
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.TileMode
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.translate
import androidx.compose.ui.graphics.layer.GraphicsLayer
import androidx.compose.ui.graphics.layer.drawLayer
import androidx.compose.ui.graphics.rememberGraphicsLayer
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInRoot
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraGradients
import com.openburnbar.ui.theme.AuroraRadius
import com.openburnbar.ui.theme.AuroraShadowSpec
import com.openburnbar.ui.theme.AuroraShadows

// Liquid Glass adapters — Compose mirror of the iOS shape-level vocabulary in
// `OpenBurnBarMobile/Theme/LiquidGlass.swift`. Keep the two files in lockstep
// when the vocabulary grows.
//
// Vocabulary:
//   • `Modifier.liquidGlassSurface(shape)`        — glass plate for passive
//     surfaces: trays, floating bars, cards, sheet inserts.
//   • `Modifier.liquidGlassInteractive(tint, shape)` — glass for tappable
//     controls: buttons, chips, pills. Pass `tint` only to convey meaning
//     (primary action, destructive), never decoration.
//   • `Modifier.liquidGlassCircleButton(diameter)` — the recurring circular
//     overlay control (close ✕, call controls, FAB discs).
//   • `LiquidGlassGroup { }`                       — shared sampling scope.
//     Mark the content the glass floats over with `Modifier.liquidGlassBackdrop()`
//     and, on API 31+, every glass child inside the group draws a genuinely
//     blurred copy of that backdrop under its plate. Below 31 (and outside a
//     group) the adapters fall back to the flat translucent stack.
//
// Why the blur works here when `auroraGlass` dropped it: `RenderEffect` on a
// composable's own layer blurs the composable's CONTENT, not the backdrop —
// that experiment made cards muddy and was removed. The group instead records
// the backdrop into a `GraphicsLayer` and each glass child re-draws that
// recording — offset into its own frame, blurred, clipped to its shape — which
// is true backdrop sampling, the same direction iOS Liquid Glass refracts.
//
// Brand rule (identical to iOS/macOS): glass is the language of the
// utilitarian shell — trays, toolbars, chips, overlay chrome. The
// membership/Pro foil & holo world (`ui/pro`, the store tier cards) stays
// glassless; there, glass appears only on system chrome such as close buttons.

private const val SURFACE_BASE_ALPHA = 0.48f
private const val INTERACTIVE_TINT_ALPHA = 0.22f
private const val DARK_FILL_DAMPING = 0.35f
private const val SAMPLED_FILL_DAMPING = 0.5f
private const val LIGHT_SHEEN_TOP_ALPHA = 0.18f
private const val DARK_SHEEN_TOP_ALPHA = 0.05f
private const val LIGHT_SHEEN_BOTTOM_ALPHA = 0.05f
private const val DARK_SHEEN_BOTTOM_ALPHA = 0.03f
private const val EDGE_STROKE_WIDTH_DP = 0.75f
private val BackdropBlurRadius = 18.dp

/** Default circular control size, mirroring the iOS adapter's 30pt default. */
private val CircleButtonDiameter = 30.dp

// MARK: - Grouping container (backdrop sampling scope)

/**
 * Links a group's recorded backdrop to the glass children that sample it.
 * `frame` is bumped each time the backdrop re-records so children re-draw.
 */
@Stable
internal class LiquidGlassBackdropState {
    var layer: GraphicsLayer? = null
    var sourcePositionInRoot: Offset by mutableStateOf(Offset.Zero)
    var frame: Int by mutableIntStateOf(0)
}

internal val LocalLiquidGlassBackdrop =
    compositionLocalOf<LiquidGlassBackdropState?> { null }

/**
 * Shared sampling scope for grouped glass elements — the Compose analogue of
 * the iOS `GlassEffectContainer` wrapper. On API 31+ the child marked with
 * [liquidGlassBackdrop] is recorded once and every glass adapter inside the
 * group samples that recording; on older systems content renders unchanged
 * and the adapters use their flat translucent fallback.
 */
@Composable
fun LiquidGlassGroup(
    modifier: Modifier = Modifier,
    content: @Composable BoxScope.() -> Unit,
) {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
        val state = remember { LiquidGlassBackdropState() }
        state.layer = rememberGraphicsLayer()
        CompositionLocalProvider(LocalLiquidGlassBackdrop provides state) {
            Box(modifier) { content() }
        }
    } else {
        Box(modifier) { content() }
    }
}

/**
 * Marks the content a [LiquidGlassGroup]'s glass children float over. Apply to
 * the backdrop composable (live canvas, artwork, scroll content) — NOT to the
 * glass elements themselves, or they would sample their own pixels.
 */
@Composable
fun Modifier.liquidGlassBackdrop(): Modifier {
    val state = LocalLiquidGlassBackdrop.current ?: return this
    val layer = state.layer ?: return this
    return this
        .onGloballyPositioned { state.sourcePositionInRoot = it.positionInRoot() }
        .drawWithContent {
            layer.record { this@drawWithContent.drawContent() }
            drawLayer(layer)
            state.frame += 1
        }
}

// MARK: - Shape-level adapters

/**
 * Glass plate for a passive surface (tray, floating bar, card). Inside a
 * [LiquidGlassGroup] on API 31+ the plate sits on a blurred backdrop sample;
 * everywhere else it falls back to the flat translucent Aurora stack.
 *
 * `wash` is the sanctioned escape hatch from the iOS inline-glass pattern: a
 * status or smoke color (alpha included by the caller) riding on the plate for
 * legibility over bright content — e.g. `Color.Black.copy(alpha = 0.3f)` for
 * capsules floating over a live mirror. Never use it for decoration.
 */
@Composable
fun Modifier.liquidGlassSurface(
    shape: Shape = RoundedCornerShape(AuroraRadius.lg.dp),
    wash: Color? = null,
    washBrush: Brush? = null,
    shadow: AuroraShadowSpec = AuroraShadows.none,
    isDark: Boolean = isSystemInDarkTheme(),
): Modifier =
    liquidGlassPlate(
        shape = shape,
        wash = wash,
        washBrush = washBrush,
        shadow = shadow,
        isDark = isDark,
    )

/**
 * Glass for a tappable control. Pass `tint` only to convey meaning (primary
 * action, destructive) — glass chrome stays monochrome by default. Press
 * feedback (scale/alpha) stays caller-side, matching the house pattern.
 */
@Composable
fun Modifier.liquidGlassInteractive(
    tint: Color? = null,
    shape: Shape = RoundedCornerShape(AuroraRadius.lg.dp),
    shadow: AuroraShadowSpec = AuroraShadows.none,
    isDark: Boolean = isSystemInDarkTheme(),
): Modifier =
    liquidGlassPlate(
        shape = shape,
        wash = tint?.copy(alpha = INTERACTIVE_TINT_ALPHA),
        washBrush = null,
        shadow = shadow,
        isDark = isDark,
    )

/**
 * The recurring circular glass control used in toolbars and as floating
 * overlay buttons (close ✕, call controls, FAB discs).
 */
@Composable
fun Modifier.liquidGlassCircleButton(
    diameter: Dp = CircleButtonDiameter,
    tint: Color? = null,
): Modifier = size(diameter).liquidGlassInteractive(tint = tint, shape = CircleShape)

// MARK: - Shared plate implementation

@Composable
private fun Modifier.liquidGlassPlate(
    shape: Shape,
    wash: Color?,
    washBrush: Brush? = null,
    shadow: AuroraShadowSpec,
    isDark: Boolean,
): Modifier {
    val backdrop = LocalLiquidGlassBackdrop.current
    val withShadow =
        if (shadow.elevation > 0.dp) {
            this.shadow(
                elevation = shadow.elevation,
                shape = shape,
                spotColor = Color.Black.copy(alpha = shadow.spotAlpha),
                ambientColor = Color.Black.copy(alpha = shadow.spotAlpha),
            )
        } else {
            this
        }
    return withShadow
        .clip(shape)
        .liquidGlassBackdropSample(backdrop)
        .background(baseFill(isDark = isDark, sampled = backdrop?.layer != null), shape)
        .background(sheenBrush(isDark = isDark), shape)
        .liquidGlassWash(wash = wash, washBrush = washBrush, shape = shape)
        .border(EDGE_STROKE_WIDTH_DP.dp, Brush.linearGradient(AuroraGradients.glassStroke), shape)
}

private fun Modifier.liquidGlassWash(wash: Color?, washBrush: Brush?, shape: Shape): Modifier {
    val withColor = if (wash != null) background(wash, shape) else this
    return if (washBrush != null) withColor.background(washBrush, shape) else withColor
}

/**
 * Base translucent wash. When a backdrop sample is being drawn underneath, the
 * wash thins out so the blur shows through; without one it carries the surface
 * on its own (the pre-31 / out-of-group fallback).
 */
private fun baseFill(isDark: Boolean, sampled: Boolean): Color {
    val requested = if (sampled) SURFACE_BASE_ALPHA * SAMPLED_FILL_DAMPING else SURFACE_BASE_ALPHA
    return if (isDark) {
        AuroraColors.darkSurface.copy(alpha = (requested * DARK_FILL_DAMPING).coerceIn(0f, 1f))
    } else {
        AuroraColors.lightSurface.copy(alpha = requested)
    }
}

private fun sheenBrush(isDark: Boolean): Brush =
    Brush.verticalGradient(
        colors =
        listOf(
            Color.White.copy(alpha = if (isDark) DARK_SHEEN_TOP_ALPHA else LIGHT_SHEEN_TOP_ALPHA),
            Color.Transparent,
            AuroraColors.blaze.copy(
                alpha = if (isDark) DARK_SHEEN_BOTTOM_ALPHA else LIGHT_SHEEN_BOTTOM_ALPHA,
            ),
        ),
    )

// MARK: - Backdrop sampling (API 31+)

@Composable
private fun Modifier.liquidGlassBackdropSample(state: LiquidGlassBackdropState?): Modifier {
    if (state == null || Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return this
    val blurLayer = rememberGraphicsLayer()
    var positionInRoot by remember { mutableStateOf(Offset.Zero) }
    return this
        .onGloballyPositioned { positionInRoot = it.positionInRoot() }
        .drawBehind { drawBlurredBackdrop(state, blurLayer, positionInRoot) }
}

private fun DrawScope.drawBlurredBackdrop(
    state: LiquidGlassBackdropState,
    blurLayer: GraphicsLayer,
    positionInRoot: Offset,
) {
    val source = state.layer ?: return
    // Draw-phase read: re-draws this plate whenever the backdrop re-records.
    if (state.frame < 0) return
    val offset = state.sourcePositionInRoot - positionInRoot
    blurLayer.renderEffect =
        BlurEffect(
            radiusX = BackdropBlurRadius.toPx(),
            radiusY = BackdropBlurRadius.toPx(),
            edgeTreatment = TileMode.Clamp,
        )
    blurLayer.record {
        translate(left = offset.x, top = offset.y) {
            drawLayer(source)
        }
    }
    drawLayer(blurLayer)
}
