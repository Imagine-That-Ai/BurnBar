package com.openburnbar.ui.components

import android.graphics.RenderEffect
import android.graphics.RuntimeShader
import android.graphics.Shader
import android.os.Build
import androidx.annotation.RequiresApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.asComposeRenderEffect
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraGradients
import com.openburnbar.ui.theme.AuroraRadius
import com.openburnbar.ui.theme.AuroraShadowSpec
import com.openburnbar.ui.theme.AuroraShadows

/**
 * Three-tier glass surface dispatch mirroring iOS `.ultraThinMaterial` + brand
 * sheen + edge gradient. Picked from the user-approved plan:
 *   • API 33+ — backdrop blur + AGSL highlight shader (refractive shine)
 *   • API 31-32 — `RenderEffect.createBlurEffect` only
 *   • API ≤30 — translucent fill + gradient sheen + edge stroke + shadow
 *
 * The modifier composes onto any container; pair it with a clip to round the
 * corners before content draws.
 */

/** Tier of glass rendering actually applied for the current device. Exposed for telemetry/tests. */
enum class AuroraGlassTier { SHADER, BLUR, SURFACE }

fun deviceGlassTier(): AuroraGlassTier = when {
    Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU -> AuroraGlassTier.SHADER
    Build.VERSION.SDK_INT >= Build.VERSION_CODES.S -> AuroraGlassTier.BLUR
    else -> AuroraGlassTier.SURFACE
}

/**
 * Apply the Aurora glass treatment to a modifier chain. The caller is expected
 * to wrap content inside this modifier — the shadow and stroke draw outside of
 * its bounds while the blur applies to anything drawn inside.
 *
 * @param cornerRadius corner radius for the surface; defaults to AuroraRadius.lg
 * @param blurRadiusDp blur radius applied on API 31+. Ignored on older devices.
 * @param tintAlpha base fill alpha on top of the blurred backdrop.
 * @param interactive when true, scales 0.98 on press; wire via Modifier.scale externally.
 * @param shadow elevation/spot spec for the dropped shadow.
 * @param isDark optional override; defaults to `isSystemInDarkTheme`.
 */
@Composable
fun Modifier.auroraGlass(
    cornerRadius: Dp = AuroraRadius.lg.dp,
    blurRadiusDp: Float = 12f,
    tintAlpha: Float = 0.72f,
    shadow: AuroraShadowSpec = AuroraShadows.medium,
    isDark: Boolean = isSystemInDarkTheme()
): Modifier {
    val shape = RoundedCornerShape(cornerRadius)

    val baseFill = if (isDark) {
        AuroraColors.darkSurface.copy(alpha = tintAlpha)
    } else {
        AuroraColors.lightSurface.copy(alpha = tintAlpha)
    }

    val sheen = Brush.linearGradient(colors = AuroraGradients.glassSheen)
    val stroke = Brush.linearGradient(colors = AuroraGradients.glassStroke)

    // Shadow lives outside the blurred surface so it can spill into the area
    // around the glass — applying it before the clip preserves that bloom.
    val withShadow = if (shadow.elevation > 0.dp) {
        this.shadow(
            elevation = shadow.elevation,
            shape = shape,
            spotColor = Color.Black.copy(alpha = shadow.spotAlpha),
            ambientColor = Color.Black.copy(alpha = shadow.spotAlpha)
        )
    } else this

    return withShadow
        .clip(shape)
        .glassRenderEffect(blurRadiusDp)
        .background(baseFill, shape)
        .background(sheen, shape)
        .border(0.75.dp, stroke, shape)
}

/**
 * Internal modifier that installs the tier-appropriate `RenderEffect`. Anything
 * older than Android 12 stays a no-op and we lean on the surface fill below for
 * the look.
 */
@Composable
private fun Modifier.glassRenderEffect(blurRadiusDp: Float): Modifier {
    return when (Build.VERSION.SDK_INT) {
        in Build.VERSION_CODES.TIRAMISU..Int.MAX_VALUE -> {
            // API 33+ — chain blur with the AGSL refraction shader so the glass
            // picks up a subtle warm highlight that mimics iOS Liquid Glass.
            val effect = remember(blurRadiusDp) { buildShaderGlassEffect(blurRadiusDp) }
            this.graphicsLayer {
                compositingStrategy = CompositingStrategy.Offscreen
                renderEffect = effect.asComposeRenderEffect()
            }
        }
        in Build.VERSION_CODES.S..Build.VERSION_CODES.S_V2 -> {
            // API 31-32 — backdrop blur only.
            val effect = remember(blurRadiusDp) { buildBlurEffect(blurRadiusDp) }
            this.graphicsLayer {
                compositingStrategy = CompositingStrategy.Offscreen
                renderEffect = effect.asComposeRenderEffect()
            }
        }
        else -> this // surface fallback handled by background fill/border below
    }
}

@RequiresApi(Build.VERSION_CODES.S)
private fun buildBlurEffect(blurRadiusDp: Float): RenderEffect =
    RenderEffect.createBlurEffect(blurRadiusDp, blurRadiusDp, Shader.TileMode.CLAMP)

@RequiresApi(Build.VERSION_CODES.TIRAMISU)
private fun buildShaderGlassEffect(blurRadiusDp: Float): RenderEffect {
    // AGSL fragment shader: samples the upstream image, adds a warm radial
    // highlight in the top-left quadrant, and lifts overall luminance very
    // slightly so the glass reads as a refractive surface rather than a flat
    // translucent layer. The blur happens first via chainEffect so the
    // highlight is added on top of the blurred content.
    val agsl = """
        uniform shader content;
        uniform float2 iSize;
        half4 main(float2 coord) {
            half4 src = content.eval(coord);
            float2 uv = coord / max(iSize.x, 0.0001);
            float2 hl = float2(0.18, 0.18) - uv;
            float r = length(hl) * 1.6;
            float intensity = smoothstep(0.55, 0.0, r);
            half3 tint = half3(1.0, 0.78, 0.66);
            half3 outRgb = src.rgb + intensity * 0.08 * tint;
            return half4(outRgb, src.a);
        }
    """.trimIndent()

    return try {
        val shader = RuntimeShader(agsl)
        val blur = buildBlurEffect(blurRadiusDp)
        val shaderEffect = RenderEffect.createRuntimeShaderEffect(shader, "content")
        RenderEffect.createChainEffect(shaderEffect, blur)
    } catch (t: Throwable) {
        // If the shader fails to compile on any specific device or AGSL changes
        // we degrade to the API 31 blur path rather than blowing up the UI.
        buildBlurEffect(blurRadiusDp)
    }
}

/**
 * Lightweight container that applies the glass treatment and reserves no extra
 * padding. Use when you want the glass look on a free-form composable rather
 * than via [AuroraGlassCard], which forces a Column with default padding.
 */
@Composable
fun AuroraGlassBox(
    modifier: Modifier = Modifier,
    cornerRadius: Dp = AuroraRadius.lg.dp,
    blurRadiusDp: Float = 12f,
    shadow: AuroraShadowSpec = AuroraShadows.medium,
    isDark: Boolean = isSystemInDarkTheme(),
    content: @Composable () -> Unit
) {
    Box(
        modifier = modifier.auroraGlass(
            cornerRadius = cornerRadius,
            blurRadiusDp = blurRadiusDp,
            shadow = shadow,
            isDark = isDark
        )
    ) { content() }
}

/**
 * Subtle highlight-only sheen for elements that should not get the full glass
 * surface but still benefit from the brand-tinted gradient. Used by buttons in
 * regular (non-prominent) state.
 */
val auroraSheenBrush: Brush
    get() = Brush.linearGradient(
        colors = AuroraGradients.glassSheen,
        start = Offset(0f, 0f),
        end = Offset(800f, 800f)
    )
