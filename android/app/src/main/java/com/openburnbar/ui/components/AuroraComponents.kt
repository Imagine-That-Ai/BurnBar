package com.openburnbar.ui.components

import androidx.compose.animation.core.*
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.*
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Info
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.ui.theme.*
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.ui.graphics.graphicsLayer

// ── Glass Card ──
// 3-layer glass per the parity plan: tier-appropriate blur, brand sheen,
// 0.75dp edge gradient stroke, soft shadow. Optional `interactive` press
// scaling matches the iOS UnifiedGlassCard interaction.
@Composable
fun AuroraGlassCard(
    modifier: Modifier = Modifier,
    cornerRadius: Int = AuroraRadius.lg,
    contentPadding: Dp = AuroraSpacing.lg.dp,
    interactive: Boolean = false,
    onClick: (() -> Unit)? = null,
    shadow: AuroraShadowSpec = AuroraShadows.medium,
    content: @Composable ColumnScope.() -> Unit
) {
    var pressed by remember { mutableStateOf(false) }
    val targetScale = if (pressed && interactive) 0.98f else 1f
    val scale by animateFloatAsState(
        targetValue = targetScale,
        animationSpec = AuroraMotion.cardPressSpec(),
        label = "aurora-glass-card-scale"
    )

    val clickModifier = if (onClick != null) {
        Modifier.pointerInput(onClick) {
            detectTapGestures(
                onPress = {
                    pressed = true
                    val released = tryAwaitRelease()
                    pressed = false
                    if (released) onClick()
                },
                onTap = { /* handled in onPress */ }
            )
        }
    } else Modifier

    Box(
        modifier = modifier
            .graphicsLayer { scaleX = scale; scaleY = scale }
            .then(clickModifier)
            .auroraGlass(cornerRadius = cornerRadius.dp, shadow = shadow)
            .padding(contentPadding)
    ) {
        Column(content = content)
    }
}

// ── Aurora Backdrop ──
@Composable
fun AuroraBackdrop(
    isDark: Boolean = isSystemInDarkTheme(),
    modifier: Modifier = Modifier
) {
    val infiniteTransition = rememberInfiniteTransition()
    val sweepOffset by infiniteTransition.animateFloat(
        initialValue = 0f, targetValue = 1f,
        animationSpec = infiniteRepeatable(
            animation = tween(18000, easing = LinearEasing),
            repeatMode = RepeatMode.Restart
        )
    )

    Box(
        modifier = modifier
            .fillMaxSize()
            .background(
                Brush.linearGradient(
                    colors = AuroraGradients.auroraRibbon(isDark),
                    start = Offset(sweepOffset * 2000f, 0f),
                    end = Offset(sweepOffset * 2000f + 1000f, 1000f)
                )
            )
    )
}

// ── Live Breathing Dot ──
@Composable
fun BreathingDot(
    color: Color = AuroraColors.ember,
    size: Int = 10,
    modifier: Modifier = Modifier
) {
    val infiniteTransition = rememberInfiniteTransition()
    val alpha by infiniteTransition.animateFloat(
        initialValue = 0.3f, targetValue = 1.0f,
        animationSpec = infiniteRepeatable(
            animation = tween(1200, easing = EaseInOut),
            repeatMode = RepeatMode.Reverse
        )
    )

    Box(
        modifier = modifier
            .size(size.dp)
            .clip(CircleShape)
            .background(color.copy(alpha = alpha))
    )
}

// ── Provider Avatar ──
@Composable
fun ProviderAvatar(
    providerKey: String,
    size: Int = 48,
    modifier: Modifier = Modifier
) {
    val provider = com.openburnbar.data.models.AgentProvider.fromKey(providerKey)
    val color = provider?.let { Color(it.brandColor) } ?: AuroraColors.whimsy

    Box(
        modifier = modifier
            .size(size.dp)
            .clip(CircleShape)
            .background(
                Brush.linearGradient(
                    colors = listOf(color, color.copy(alpha = 0.6f))
                )
            ),
        contentAlignment = Alignment.Center
    ) {
        Text(
            text = provider?.displayName?.take(2)?.uppercase() ?: "?",
            color = Color.White,
            fontSize = (size / 3).sp,
            fontWeight = FontWeight.Bold
        )
    }
}

// ── Staggered Entrance ──
// Spring-driven entrance matching iOS AnimatedEntranceModifier:
// `.spring(response: 0.4, dampingFraction: 0.85)` + 12pt Y offset. Respects
// the reduce-motion composition local.
@Composable
fun StaggeredEntrance(
    delay: Int = 0,
    reduceMotion: Boolean = LocalAuroraReduceMotion.current,
    content: @Composable () -> Unit
) {
    var visible by remember { mutableStateOf(false) }

    LaunchedEffect(Unit) {
        if (reduceMotion) visible = true
        else {
            kotlinx.coroutines.delay(delay.toLong())
            visible = true
        }
    }

    val alpha by animateFloatAsState(
        targetValue = if (visible) 1f else 0f,
        animationSpec = AuroraMotion.gentleSpec(),
        label = "stagger-alpha"
    )
    val offsetY by animateDpAsState(
        targetValue = if (visible) 0.dp else 12.dp,
        animationSpec = AuroraMotion.gentleSpec(),
        label = "stagger-offset"
    )

    Box(
        modifier = Modifier
            .graphicsLayer {
                this.alpha = alpha
                translationY = offsetY.value
            }
    ) {
        content()
    }
}

// ── Chart Entrance ──
// Mirrors iOS `.chartEntrance()` modifier: scale 0.92 → 1.0, alpha 0 → 1,
// 16dp Y offset, all via a single spring with response ≈ 0.55.
@Composable
fun Modifier.chartEntrance(
    delay: Int = 0,
    reduceMotion: Boolean = LocalAuroraReduceMotion.current
): Modifier {
    var visible by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) {
        if (reduceMotion) visible = true
        else {
            kotlinx.coroutines.delay(delay.toLong())
            visible = true
        }
    }
    val spec = androidx.compose.animation.core.spring<Float>(
        stiffness = 320f, dampingRatio = 0.75f
    )
    val scale by animateFloatAsState(
        targetValue = if (visible) 1f else 0.92f,
        animationSpec = spec,
        label = "chart-entrance-scale"
    )
    val a by animateFloatAsState(
        targetValue = if (visible) 1f else 0f,
        animationSpec = spec,
        label = "chart-entrance-alpha"
    )
    val ty by animateDpAsState(
        targetValue = if (visible) 0.dp else 16.dp,
        animationSpec = androidx.compose.animation.core.spring(stiffness = 320f, dampingRatio = 0.75f),
        label = "chart-entrance-y"
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
fun Modifier.breathingPulse(
    reduceMotion: Boolean = LocalAuroraReduceMotion.current
): Modifier {
    if (reduceMotion) return this
    val transition = rememberInfiniteTransition(label = "breathing-pulse")
    val scale by transition.animateFloat(
        initialValue = 1f, targetValue = 1.4f,
        animationSpec = infiniteRepeatable(
            animation = tween(1400, easing = EaseInOut),
            repeatMode = RepeatMode.Reverse
        ),
        label = "breathing-scale"
    )
    val a by transition.animateFloat(
        initialValue = 1f, targetValue = 0.55f,
        animationSpec = infiniteRepeatable(
            animation = tween(1400, easing = EaseInOut),
            repeatMode = RepeatMode.Reverse
        ),
        label = "breathing-alpha"
    )
    return this.graphicsLayer {
        scaleX = scale
        scaleY = scale
        alpha = a
    }
}

// ── Chip Selector ──
@Composable
fun <T> ChipSelector(
    items: List<T>,
    selected: T,
    onSelect: (T) -> Unit,
    labelProvider: (T) -> String = { it.toString() },
    modifier: Modifier = Modifier
) {
    Row(
        modifier = modifier,
        horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp)
    ) {
        items.forEach { item ->
            val isSelected = item == selected
            Surface(
                onClick = { onSelect(item) },
                shape = RoundedCornerShape(AuroraRadius.full.dp),
                color = if (isSelected) AuroraColors.ember.copy(alpha = 0.15f)
                        else MaterialTheme.colorScheme.surface,
                border = if (isSelected)
                    androidx.compose.foundation.BorderStroke(1.dp, AuroraColors.ember)
                else null
            ) {
                Text(
                    text = labelProvider(item),
                    modifier = Modifier.padding(horizontal = AuroraSpacing.md.dp, vertical = AuroraSpacing.sm.dp),
                    fontSize = AuroraTypography.caption.sp,
                    fontWeight = if (isSelected) FontWeight.Bold else FontWeight.Normal,
                    color = if (isSelected) AuroraColors.ember
                            else MaterialTheme.colorScheme.onSurface
                )
            }
        }
    }
}

// ── Loading Shimmer ──
@Composable
fun ShimmerCard(
    height: Int = 120,
    modifier: Modifier = Modifier
) {
    val infiniteTransition = rememberInfiniteTransition()
    val shimmerOffset by infiniteTransition.animateFloat(
        initialValue = 0f, targetValue = 1f,
        animationSpec = infiniteRepeatable(
            animation = tween(1500, easing = LinearEasing),
            repeatMode = RepeatMode.Restart
        )
    )

    Box(
        modifier = modifier
            .fillMaxWidth()
            .height(height.dp)
            .clip(RoundedCornerShape(AuroraRadius.lg.dp))
            .background(
                Brush.linearGradient(
                    colors = listOf(
                        MaterialTheme.colorScheme.surface,
                        MaterialTheme.colorScheme.surfaceVariant,
                        MaterialTheme.colorScheme.surface
                    ),
                    start = Offset(shimmerOffset * 2000f - 1000f, 0f),
                    end = Offset(shimmerOffset * 2000f + 1000f, 0f)
                )
            )
    )
}

// ── Empty State ──
@Composable
fun EmptyStateView(
    icon: ImageVector = Icons.Default.Info,
    title: String,
    message: String,
    onRetry: (() -> Unit)? = null,
    retryLabel: String = "Retry"
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(AuroraSpacing.xxxl.dp),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            modifier = Modifier.size(48.dp),
            tint = AuroraColors.whimsy.copy(alpha = 0.5f)
        )
        Spacer(modifier = Modifier.height(AuroraSpacing.md.dp))
        Text(
            text = title,
            fontSize = AuroraTypography.title.sp,
            fontWeight = FontWeight.Bold,
            color = MaterialTheme.colorScheme.onSurface
        )
        Spacer(modifier = Modifier.height(AuroraSpacing.sm.dp))
        Text(
            text = message,
            fontSize = AuroraTypography.body.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center
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
fun ErrorStateView(
    icon: ImageVector = Icons.Default.Info,
    title: String,
    message: String,
    onRetry: () -> Unit,
    retryLabel: String = "Retry"
) {
    EmptyStateView(icon = icon, title = title, message = message, onRetry = onRetry, retryLabel = retryLabel)
}

// ── Section Header ──
@Composable
fun SectionHeader(
    title: String,
    modifier: Modifier = Modifier,
    action: (@Composable () -> Unit)? = null
) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = AuroraSpacing.lg.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically
    ) {
        Text(
            text = title,
            fontSize = AuroraTypography.headline.sp,
            fontWeight = FontWeight.Bold,
            color = MaterialTheme.colorScheme.onSurface
        )
        action?.invoke()
    }
}

// ── Mercury Shimmer Overlay (Hermes) ──
@Composable
fun MercuryShimmerOverlay(
    modifier: Modifier = Modifier,
    cornerRadius: Int = AuroraRadius.lg
) {
    val infiniteTransition = rememberInfiniteTransition()
    val shimmer by infiniteTransition.animateFloat(
        initialValue = 0f, targetValue = 1f,
        animationSpec = infiniteRepeatable(
            animation = tween(AuroraMotion.mercuryShimmerDuration.toInt(), easing = LinearEasing),
            repeatMode = RepeatMode.Restart
        )
    )

    Box(
        modifier = modifier
            .clip(RoundedCornerShape(cornerRadius.dp))
            .border(
                1.dp,
                Brush.linearGradient(
                    colors = AuroraGradients.mercuryFoil.map {
                        it.copy(alpha = (0.3f + (shimmer * 0.3f)).coerceIn(0f, 1f))
                    },
                    start = Offset(shimmer * 500f, 0f),
                    end = Offset(shimmer * 500f + 500f, 500f)
                ),
                RoundedCornerShape(cornerRadius.dp)
            )
    )
}
