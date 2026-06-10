@file:Suppress("MagicNumber")
// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.components

import androidx.compose.animation.core.EaseInOut
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Info
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.ui.settings.BackgroundStyle
import com.openburnbar.ui.settings.rememberAppearance
import com.openburnbar.ui.settings.rememberBackgroundStyle
import com.openburnbar.ui.settings.rememberExcludeBrandShapesFromSwarm
import com.openburnbar.ui.settings.rememberProviderGlyphs
import com.openburnbar.ui.settings.rememberThemePalette
import com.openburnbar.ui.theme.AppAppearance
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraGradients
import com.openburnbar.ui.theme.AuroraMotion
import com.openburnbar.ui.theme.AuroraRadius
import com.openburnbar.ui.theme.AuroraShadowSpec
import com.openburnbar.ui.theme.AuroraShadows
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraTypography
import com.openburnbar.ui.theme.LocalAuroraReduceMotion

// ── Glass Card ──
// 3-layer glass per the parity plan: tier-appropriate blur, brand sheen,
// 0.75dp edge gradient stroke, soft shadow. Optional `interactive` press
// scaling matches the iOS UnifiedGlassCard interaction.
@Composable
fun AuroraGlassCard(
    modifier: Modifier = Modifier,
    cornerRadius: Int = AuroraRadius.lg,
    contentPadding: Dp = AuroraSpacing.md.dp,
    interactive: Boolean = false,
    onClick: (() -> Unit)? = null,
    shadow: AuroraShadowSpec = AuroraShadows.small,
    content: @Composable ColumnScope.() -> Unit,
) {
    val (scale, clickModifier) = rememberAuroraGlassCardInteraction(interactive = interactive, onClick = onClick)
    AuroraGlassCardSurface(
        state =
        AuroraGlassCardSurfaceState(
            modifier = modifier,
            cornerRadius = cornerRadius,
            contentPadding = contentPadding,
            scale = scale,
            clickModifier = clickModifier,
            shadow = shadow,
        ),
        content = content,
    )
}

// ── Aurora Backdrop ──
// Cinematic, parallax-driven backdrop that replaces the simple gradient sweep
// for every primary surface in the Android app.
//
// Layers (bottom to top):
//   1. Base gradient (mode-aware)
//   2. Drifting radial orbs (ember / amber / blaze / whimsy)
//   3. Slow-drifting "aurora ribbon" along the top edge
//   4. Subtle ember particles (drift only when motion allowed)
//   5. Optional vignette
//
// Honors Reduce Motion (no infinite anims) and Reduce Transparency (drops blur).
enum class AuroraDensity { FULL, SUBTLE, MINIMAL }

@Composable
fun AuroraBackdrop(isDark: Boolean = isSystemInDarkTheme(), density: AuroraDensity = AuroraDensity.FULL, modifier: Modifier = Modifier) {
    val reduceMotion = LocalAuroraReduceMotion.current
    val backgroundStyle by rememberBackgroundStyle()

    val appearance by rememberAppearance()
    val editorial = appearance == AppAppearance.EDITORIAL

    Box(modifier = modifier.fillMaxSize()) {
        if (editorial) {
            // Editorial / Paper skin: the light dot-crest — provider logos drifting
            // from coloured dots on paper, like app.burnbar.ai. Light-locked.
            WebsiteBackground(accentColor = AuroraColors.ember, forceLight = true)
        } else {
            when (backgroundStyle) {
                BackgroundStyle.SWARM -> WebsiteBackground(accentColor = AuroraColors.ember)
                BackgroundStyle.DOT_CONSTELLATION -> DotConstellationBackground()
                // The aurora orb/ribbon animations only exist in the AURORA branch, so
                // their infinite transitions live there too — SWARM and DOT_CONSTELLATION
                // never spin an idle aurora clock behind their own renderers.
                BackgroundStyle.AURORA ->
                    AuroraAnimatedBackdrop(
                        isDark = isDark,
                        density = density,
                        reduceMotion = reduceMotion,
                    )
            }
        }
        AuroraBackdropVignette(isDark = isDark && !editorial)
    }
}

/**
 * The AURORA-style backdrop: gradient base + drifting orbs/ribbon driven by an
 * infinite transition. Extracted so the `rememberInfiniteTransition` phase clocks
 * are created (and animating) ONLY while AURORA is the active background — they do
 * not run behind the SWARM or DOT_CONSTELLATION renderers.
 *
 * Phases flow down as `() -> Float` lambdas read in layout/draw scopes, so the
 * 18s/12s loops never recompose this subtree; Reduce Motion renders the same
 * static 0f frame without creating an infinite transition at all.
 */
@Composable
private fun AuroraAnimatedBackdrop(isDark: Boolean, density: AuroraDensity, reduceMotion: Boolean) {
    AuroraBackdropGradientLayer(isDark = isDark)
    if (reduceMotion) {
        AuroraBackdropAnimatedLayers(
            isDark = isDark,
            density = density,
            reduceMotion = true,
            phase = { 0f },
            ribbonPhase = { 0f },
        )
        return
    }
    val infiniteTransition = rememberInfiniteTransition(label = "aurora")
    val phase = infiniteTransition.animateFloat(
        initialValue = 0f,
        targetValue = 1f,
        animationSpec =
        infiniteRepeatable(
            animation = tween(18000, easing = LinearEasing),
            repeatMode = RepeatMode.Restart,
        ),
        label = "aurora-phase",
    )
    val ribbonPhase = infiniteTransition.animateFloat(
        initialValue = 0f,
        targetValue = (2 * Math.PI).toFloat(),
        animationSpec =
        infiniteRepeatable(
            animation = tween(12000, easing = LinearEasing),
            repeatMode = RepeatMode.Restart,
        ),
        label = "ribbon-phase",
    )
    AuroraBackdropAnimatedLayers(
        isDark = isDark,
        density = density,
        reduceMotion = false,
        phase = { phase.value },
        ribbonPhase = { ribbonPhase.value },
    )
}

/**
 * The custom dark backdrop selected by the user. Dispatches on the active
 * [BackgroundStyle]: DOT_CONSTELLATION renders the calm, one-logo-at-a-time
 * constellation field; every other custom style renders the active, reconverging
 * token-ember swarm from burnbar.ai (which murmurates and periodically reconverges
 * into "$", "</>", provider logos, concentric quota rings, and a router-failover
 * S-curve). Screens call this only when a custom backdrop is active, so this stays
 * the single dispatch point keeping all surfaces coherent.
 */
@Composable
fun WebsiteBackground(
    accentColor: Color = AuroraColors.ember,
    modifier: Modifier = Modifier,
    forceLight: Boolean = false,
) {
    val backgroundStyle by rememberBackgroundStyle()
    // Editorial forces the light dot-crest, so it bypasses the constellation
    // style and always renders the swarm in light mode.
    if (!forceLight && backgroundStyle == BackgroundStyle.DOT_CONSTELLATION) {
        DotConstellationBackground(modifier = modifier)
        return
    }

    val themePalette by rememberThemePalette()
    val providerGlyphs by rememberProviderGlyphs()
    val excludeBrandShapes by rememberExcludeBrandShapesFromSwarm()

    SwarmBackground(
        accentColor = accentColor,
        modifier = modifier,
        pace = if (forceLight) SwarmPace.CINEMATIC else SwarmPace.ENERGETIC,
        enabledProviderGlyphs = providerGlyphs,
        paletteName = themePalette,
        excludeBrandShapes = excludeBrandShapes,
        forceLight = forceLight,
    )
}

@Composable
internal fun OrbLayer(isDark: Boolean, phase: () -> Float, opacity: Float, modifier: Modifier = Modifier) {
    Box(modifier = modifier) {
        // Ember orb
        Orb(
            color = if (isDark) AuroraColors.emberDark else AuroraColors.ember,
            baseAlpha = if (isDark) 0.55f else 0.20f,
            size = 460.dp,
            motion = OrbMotion(Offset(-100f, -200f), Offset(-60f, -176f), phase, opacity),
        )
        // Amber orb
        Orb(
            color = if (isDark) AuroraColors.amberDark else AuroraColors.amber,
            baseAlpha = if (isDark) 0.45f else 0.16f,
            size = 420.dp,
            motion = OrbMotion(Offset(120f, 240f), Offset(92f, 210f), phase, opacity),
        )
        // Blaze orb
        Orb(
            color = if (isDark) AuroraColors.blaze else AuroraColors.blaze,
            baseAlpha = if (isDark) 0.30f else 0.12f,
            size = 380.dp,
            motion = OrbMotion(Offset(-60f, 140f), Offset(-42f, 118f), phase, opacity),
        )
    }
}

private data class OrbMotion(
    val offsetA: Offset,
    val offsetB: Offset,
    val phase: () -> Float,
    val opacity: Float,
)

/**
 * Pure drift interpolation for one aurora orb: phase 0 rests at [offsetA],
 * phase 1 at [offsetB], linear in between (the website's 18s ease-in-out
 * drift feeds the eased phase in). Extracted from the placement lambda so the
 * math is unit-testable without a composition.
 */
internal fun auroraOrbDriftOffset(offsetA: Offset, offsetB: Offset, phase: Float): androidx.compose.ui.unit.IntOffset =
    androidx.compose.ui.unit.IntOffset(
        (offsetA.x + (offsetB.x - offsetA.x) * phase).toInt(),
        (offsetA.y + (offsetB.y - offsetA.y) * phase).toInt(),
    )

@Composable
private fun Orb(color: Color, baseAlpha: Float, size: androidx.compose.ui.unit.Dp, motion: OrbMotion) {
    val opacity = motion.opacity
    val displaySize = size * 1.4f // larger for softness

    Box(
        modifier =
        Modifier
            .size(displaySize)
            .offset {
                // Phase is snapshot-read (and interpolated) inside the placement
                // lambda so the 18s drift never recomposes the orb.
                auroraOrbDriftOffset(motion.offsetA, motion.offsetB, motion.phase())
            }
            .background(
                Brush.radialGradient(
                    colors =
                    listOf(
                        color.copy(alpha = baseAlpha * opacity),
                        color.copy(alpha = baseAlpha * 0.5f * opacity),
                        Color.Transparent,
                    ),
                    center = Offset(0.5f, 0.5f),
                    radius = 0.5f,
                ),
                shape = CircleShape,
            ),
    )
}

@Composable
internal fun RibbonLayer(isDark: Boolean, ribbonPhase: () -> Float, opacity: Float, modifier: Modifier = Modifier) {
    val ember = if (isDark) AuroraColors.emberDark else AuroraColors.ember
    val amber = if (isDark) AuroraColors.amberDark else AuroraColors.amber
    val mercury = if (isDark) AuroraColors.hermesMercuryDark else AuroraColors.hermesMercury

    Canvas(modifier = modifier) {
        // Snapshot-read here so the 12s drift invalidates draw only, never composition.
        val phase = ribbonPhase()
        val amplitude = 24f
        val frequency = 2 * Math.PI.toFloat()
        val segments = 36
        val path = androidx.compose.ui.graphics.Path()

        for (i in 0..segments) {
            val x = i.toFloat() / segments * size.width
            val progress = i.toFloat() / segments
            val y =
                size.height * 0.35f + kotlin.math.sin(
                    progress * frequency + phase,
                ) * amplitude
            if (i == 0) path.moveTo(x, y) else path.lineTo(x, y)
        }
        for (i in segments downTo 0) {
            val x = i.toFloat() / segments * size.width
            val progress = i.toFloat() / segments
            val y =
                size.height * 0.35f + kotlin.math.sin(
                    progress * frequency + phase,
                ) * amplitude + 38f
            path.lineTo(x, y)
        }
        path.close()

        drawPath(
            path = path,
            brush =
            Brush.linearGradient(
                colors =
                listOf(
                    ember.copy(alpha = if (isDark) 0.45f else 0.20f * opacity),
                    amber.copy(alpha = if (isDark) 0.30f else 0.14f * opacity),
                    mercury.copy(alpha = if (isDark) 0.18f else 0.08f * opacity),
                ),
                start = Offset(0f, 0f),
                end = Offset(size.width, size.height),
            ),
        )
    }
}

@Composable
internal fun ParticleLayer(modifier: Modifier = Modifier) {
    Box(modifier = modifier) {
        for (index in 0 until 8) {
            AuroraParticle(index = index)
        }
    }
}

@Composable
private fun AuroraParticle(index: Int) {
    val infiniteTransition = rememberInfiniteTransition(label = "particle-$index")
    val rise = infiniteTransition.animateFloat(
        initialValue = 0f,
        targetValue = 28f + index * 6f,
        animationSpec =
        infiniteRepeatable(
            animation =
            tween(
                durationMillis = 5000 + index * 700,
                easing = EaseInOut,
            ),
            repeatMode = RepeatMode.Reverse,
        ),
        label = "particle-rise-$index",
    )

    val palette = listOf(AuroraColors.ember, AuroraColors.amber, AuroraColors.blaze, Color.White)
    val particleColor = palette[index % palette.size]
    val size = (3f + index % 4 * 1.4f).dp
    val startX = (-130 + index * 38).dp
    val startY = (220 + index % 3 * 36).dp
    val alpha = 0.5f

    Box(
        modifier =
        Modifier
            .size(size)
            .offset {
                // Lambda overload: `rise` is snapshot-read at placement so the bob
                // never recomposes the particle. roundToPx matches the Dp overload.
                androidx.compose.ui.unit.IntOffset(
                    startX.roundToPx(),
                    (startY - rise.value.dp).roundToPx(),
                )
            }
            .background(
                particleColor.copy(alpha = alpha * (0.4f + index % 3 * 0.18f)),
                shape = CircleShape,
            ),
    )
}

// ── Live Breathing Dot ──
@Composable
fun BreathingDot(color: Color = AuroraColors.ember, size: Int = 10, modifier: Modifier = Modifier) {
    val infiniteTransition = rememberInfiniteTransition()
    val alpha by infiniteTransition.animateFloat(
        initialValue = 0.3f,
        targetValue = 1.0f,
        animationSpec =
        infiniteRepeatable(
            animation = tween(1200, easing = EaseInOut),
            repeatMode = RepeatMode.Reverse,
        ),
    )

    Box(
        modifier =
        modifier
            .size(size.dp)
            .clip(CircleShape)
            .background(color.copy(alpha = alpha)),
    )
}

// ── Provider Avatar ──
// (Moved to ProviderLogo.kt — that file now provides the logo-backed
// ProviderAvatar / ProviderLogo / ModelLogo composables.)

// ── Staggered Entrance ──
// Spring-driven entrance matching iOS AnimatedEntranceModifier:
// `.spring(response: 0.4, dampingFraction: 0.85)` + 12pt Y offset. Respects
// the reduce-motion composition local.
@Composable
fun StaggeredEntrance(delay: Int = 0, reduceMotion: Boolean = LocalAuroraReduceMotion.current, content: @Composable () -> Unit) {
    var visible by remember { mutableStateOf(false) }

    LaunchedEffect(Unit) {
        if (reduceMotion) {
            visible = true
        } else {
            kotlinx.coroutines.delay(delay.toLong())
            visible = true
        }
    }

    val alpha by animateFloatAsState(
        targetValue = if (visible) 1f else 0f,
        animationSpec = AuroraMotion.gentleSpec(),
        label = "stagger-alpha",
    )
    val offsetY by animateDpAsState(
        targetValue = if (visible) 0.dp else 12.dp,
        animationSpec = AuroraMotion.gentleSpec(),
        label = "stagger-offset",
    )

    Box(
        modifier =
        Modifier
            .graphicsLayer {
                this.alpha = alpha
                translationY = offsetY.value
            },
    ) {
        content()
    }
}

// ── Chart Entrance ──
// Mirrors iOS `.chartEntrance()` modifier: scale 0.92 → 1.0, alpha 0 → 1,
// 16dp Y offset, all via a single spring with response ≈ 0.55.
@Composable
fun Modifier.chartEntrance(delay: Int = 0, reduceMotion: Boolean = LocalAuroraReduceMotion.current): Modifier {
    var visible by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) {
        if (reduceMotion) {
            visible = true
        } else {
            kotlinx.coroutines.delay(delay.toLong())
            visible = true
        }
    }
    val spec =
        androidx.compose.animation.core.spring<Float>(
            stiffness = 320f,
            dampingRatio = 0.75f,
        )
    val scale by animateFloatAsState(
        targetValue = if (visible) 1f else 0.92f,
        animationSpec = spec,
        label = "chart-entrance-scale",
    )
    val a by animateFloatAsState(
        targetValue = if (visible) 1f else 0f,
        animationSpec = spec,
        label = "chart-entrance-alpha",
    )
    val ty by animateDpAsState(
        targetValue = if (visible) 0.dp else 16.dp,
        animationSpec = androidx.compose.animation.core.spring(stiffness = 320f, dampingRatio = 0.75f),
        label = "chart-entrance-y",
    )
    return this.graphicsLayer {
        scaleX = scale
        scaleY = scale
        alpha = a
        translationY = ty.value
    }
}

// ── Breathing Pulse Modifier ──
// Scale 1.0 ↔ 1.4, alpha 1.0 ↔ 0.55, 1.4s easeInOut, reversing forever.
// Matches iOS BreathingPulseModifier.
@Composable
fun Modifier.breathingPulse(reduceMotion: Boolean = LocalAuroraReduceMotion.current): Modifier {
    if (reduceMotion) return this
    val transition = rememberInfiniteTransition(label = "breathing-pulse")
    val scale by transition.animateFloat(
        initialValue = 1f,
        targetValue = 1.4f,
        animationSpec =
        infiniteRepeatable(
            animation = tween(1400, easing = EaseInOut),
            repeatMode = RepeatMode.Reverse,
        ),
        label = "breathing-scale",
    )
    val a by transition.animateFloat(
        initialValue = 1f,
        targetValue = 0.55f,
        animationSpec =
        infiniteRepeatable(
            animation = tween(1400, easing = EaseInOut),
            repeatMode = RepeatMode.Reverse,
        ),
        label = "breathing-alpha",
    )
    return this.graphicsLayer {
        scaleX = scale
        scaleY = scale
        alpha = a
    }
}

// ── Chip Selector ──
@Composable
fun <T> ChipSelector(items: List<T>, selected: T, onSelect: (T) -> Unit, labelProvider: (T) -> String = { it.toString() }, modifier: Modifier = Modifier) {
    Row(
        modifier = modifier,
        horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp),
    ) {
        items.forEach { item ->
            val isSelected = item == selected
            Surface(
                onClick = { onSelect(item) },
                shape = RoundedCornerShape(AuroraRadius.full.dp),
                color =
                if (isSelected) {
                    AuroraColors.ember.copy(alpha = 0.15f)
                } else {
                    MaterialTheme.colorScheme.surface
                },
                border =
                if (isSelected) {
                    androidx.compose.foundation.BorderStroke(1.dp, AuroraColors.ember)
                } else {
                    null
                },
            ) {
                Text(
                    text = labelProvider(item),
                    modifier = Modifier.padding(horizontal = AuroraSpacing.md.dp, vertical = AuroraSpacing.sm.dp),
                    fontSize = AuroraTypography.caption.sp,
                    fontWeight = if (isSelected) FontWeight.Bold else FontWeight.Normal,
                    color =
                    if (isSelected) {
                        AuroraColors.ember
                    } else {
                        MaterialTheme.colorScheme.onSurface
                    },
                )
            }
        }
    }
}

// ── Loading Shimmer ──
@Composable
fun ShimmerCard(height: Int = 120, modifier: Modifier = Modifier) {
    val infiniteTransition = rememberInfiniteTransition()
    val shimmerOffset by infiniteTransition.animateFloat(
        initialValue = 0f,
        targetValue = 1f,
        animationSpec =
        infiniteRepeatable(
            animation = tween(1500, easing = LinearEasing),
            repeatMode = RepeatMode.Restart,
        ),
    )

    Box(
        modifier =
        modifier
            .fillMaxWidth()
            .height(height.dp)
            .clip(RoundedCornerShape(AuroraRadius.lg.dp))
            .background(
                Brush.linearGradient(
                    colors =
                    listOf(
                        MaterialTheme.colorScheme.surface,
                        MaterialTheme.colorScheme.surfaceVariant,
                        MaterialTheme.colorScheme.surface,
                    ),
                    start = Offset(shimmerOffset * 2000f - 1000f, 0f),
                    end = Offset(shimmerOffset * 2000f + 1000f, 0f),
                ),
            ),
    )
}

// ── Empty State ──
@Composable
fun EmptyStateView(icon: ImageVector = Icons.Default.Info, title: String, message: String, onRetry: (() -> Unit)? = null, retryLabel: String = "Retry") {
    Column(
        modifier =
        Modifier
            .fillMaxWidth()
            .padding(AuroraSpacing.xxxl.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            modifier = Modifier.size(48.dp),
            tint = AuroraColors.whimsy.copy(alpha = 0.5f),
        )
        Spacer(modifier = Modifier.height(AuroraSpacing.md.dp))
        Text(
            text = title,
            fontSize = AuroraTypography.title.sp,
            fontWeight = FontWeight.Bold,
            color = MaterialTheme.colorScheme.onSurface,
        )
        Spacer(modifier = Modifier.height(AuroraSpacing.sm.dp))
        Text(
            text = message,
            fontSize = AuroraTypography.body.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
        )
        if (onRetry != null) {
            Spacer(modifier = Modifier.height(AuroraSpacing.lg.dp))
            Button(onClick = onRetry) {
                Text(retryLabel)
            }
        }
    }
}

// ── Error State ──
@Composable
fun ErrorStateView(icon: ImageVector = Icons.Default.Info, title: String, message: String, onRetry: () -> Unit, retryLabel: String = "Retry") {
    EmptyStateView(icon = icon, title = title, message = message, onRetry = onRetry, retryLabel = retryLabel)
}

// ── Section Header ──
@Composable
fun SectionHeader(title: String, modifier: Modifier = Modifier, action: (@Composable () -> Unit)? = null) {
    Row(
        modifier =
        modifier
            .fillMaxWidth()
            .padding(horizontal = AuroraSpacing.lg.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = title,
            fontSize = AuroraTypography.headline.sp,
            fontWeight = FontWeight.Bold,
            color = MaterialTheme.colorScheme.onSurface,
        )
        action?.invoke()
    }
}

// ── Mercury Shimmer Overlay (Hermes) ──
@Composable
fun MercuryShimmerOverlay(modifier: Modifier = Modifier, cornerRadius: Int = AuroraRadius.lg) {
    val infiniteTransition = rememberInfiniteTransition()
    val shimmer by infiniteTransition.animateFloat(
        initialValue = 0f,
        targetValue = 1f,
        animationSpec =
        infiniteRepeatable(
            animation = tween(AuroraMotion.mercuryShimmerDuration.toInt(), easing = LinearEasing),
            repeatMode = RepeatMode.Restart,
        ),
    )

    Box(
        modifier =
        modifier
            .clip(RoundedCornerShape(cornerRadius.dp))
            .border(
                1.dp,
                Brush.linearGradient(
                    colors =
                    AuroraGradients.mercuryFoil.map {
                        it.copy(alpha = (0.3f + shimmer * 0.3f).coerceIn(0f, 1f))
                    },
                    start = Offset(shimmer * 500f, 0f),
                    end = Offset(shimmer * 500f + 500f, 500f),
                ),
                RoundedCornerShape(cornerRadius.dp),
            ),
    )
}
