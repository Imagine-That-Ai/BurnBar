package com.openburnbar.ui.pulse.atlas

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.TrendingFlat
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.NorthEast
import androidx.compose.material.icons.filled.Speed
import androidx.compose.material.icons.filled.StackedLineChart
import androidx.compose.material.icons.filled.Storage
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.derived.TrendDataDigest
import com.openburnbar.data.derived.TrendInsight
import com.openburnbar.data.derived.TrendInsightEngine
import com.openburnbar.data.models.TokenUsage
import com.openburnbar.data.models.UsageDisplayMode
import com.openburnbar.data.models.UsageRollups
import com.openburnbar.ui.components.AuroraGlassCard
import com.openburnbar.ui.components.HapticBus
import com.openburnbar.ui.pulse.SectionHeaderRow
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraRadius
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraType
import com.openburnbar.ui.theme.AuroraTypography
import kotlin.math.abs

/** The three rendered scenes in the Trend Atlas card. */
enum class AtlasScene(val label: String, val subtitle: String, val icon: ImageVector) {
    SPEND("Spend", "Daily spend · stacked by provider", Icons.Filled.StackedLineChart),
    MODELS("Models", "Top models · share, velocity, rank", Icons.Filled.Speed),
    CACHE("Cache", "Sessions · duration vs cache hit rate", Icons.Filled.Storage)
}

/**
 * Android port of iOS `TrendAtlasCard` — the analytical card that lives at
 * the bottom of the Pulse screen. Hosts a 3-scene chip selector, the
 * scene-specific content (Spend stream, Model lanes, Cache constellation),
 * and an auto-rotating insight strip beneath. Tapping the card or the
 * trailing "Studio ↗" affordance dispatches `onOpenStudio` which the host
 * can route to a Chart Studio screen when one ships; for now we use it to
 * surface a haptic + a callback the host can hook later.
 */
@Composable
fun TrendAtlasCard(
    rollups: UsageRollups,
    recentUsages: List<TokenUsage>,
    displayMode: UsageDisplayMode,
    modifier: Modifier = Modifier,
    onOpenStudio: (() -> Unit)? = null
) {
    val digest = remember(rollups, recentUsages, displayMode) {
        TrendDataDigest.build(
            rollups = rollups,
            recentUsages = recentUsages,
            displayMode = displayMode
        )
    }
    val insights = remember(digest) { TrendInsightEngine.insights(digest) }
    val context = LocalContext.current

    var scene by rememberSaveable { mutableStateOf(AtlasScene.SPEND) }
    var paused by remember { mutableStateOf(false) }

    AuroraGlassCard(
        modifier = modifier,
        cornerRadius = AuroraRadius.xl,
        contentPadding = AuroraSpacing.lg.dp
    ) {
        SectionHeaderRow(
            label = "Trend Atlas",
            trailing = {
                StudioPill(onClick = {
                    HapticBus.light(context)
                    paused = true
                    // Present Chart Studio fullscreen with the live digest.
                    com.openburnbar.ui.chartstudio.ChartStudioPresenter.present(digest)
                    onOpenStudio?.invoke()
                })
            }
        )

        Spacer(Modifier.height(4.dp))

        Text(
            text = scene.subtitle,
            style = AuroraType.body,
            color = MaterialTheme.colorScheme.onSurface
        )

        Spacer(Modifier.height(AuroraSpacing.md.dp))

        SceneChipRail(
            current = scene,
            onSelect = {
                scene = it
                HapticBus.selection(context)
            }
        )

        Spacer(Modifier.height(AuroraSpacing.md.dp))

        // Scene content with iOS-style cross-fade + slight scale-in.
        val sceneModifier = Modifier
            .fillMaxWidth()
            .pointerInput(scene) {
                detectHorizontalDragGestures { _, drag ->
                    if (abs(drag) > 28f) {
                        val order = AtlasScene.entries
                        val current = order.indexOf(scene)
                        val next = if (drag < 0) (current + 1) % order.size
                                   else (current - 1 + order.size) % order.size
                        if (next != current) {
                            scene = order[next]
                            HapticBus.selection(context)
                        }
                    }
                }
            }

        AnimatedContent(
            targetState = scene,
            label = "atlas-scene",
            transitionSpec = {
                (fadeIn(animationSpec = tween(280)) +
                    scaleIn(initialScale = 0.97f, animationSpec = tween(280))) togetherWith
                fadeOut(animationSpec = tween(220))
            },
            modifier = sceneModifier
        ) { active ->
            when (active) {
                AtlasScene.SPEND  -> SpendStreamScene(digest = digest)
                AtlasScene.MODELS -> ModelLaneScene(digest = digest)
                AtlasScene.CACHE  -> CacheConstellationScene(digest = digest)
            }
        }

        Spacer(Modifier.height(AuroraSpacing.md.dp))

        InsightAutoRotator(insights = insights, paused = paused)
    }
}

/**
 * Convenience for a list of pre-computed insights — useful when a host
 * wants to override the digest-derived ranking (e.g., merge in
 * server-pushed insights).
 */
@Composable
fun TrendAtlasCard(
    digest: TrendDataDigest,
    insights: List<TrendInsight> = TrendInsightEngine.insights(digest),
    modifier: Modifier = Modifier,
    onOpenStudio: (() -> Unit)? = null
) {
    val context = LocalContext.current
    var scene by rememberSaveable { mutableStateOf(AtlasScene.SPEND) }
    var paused by remember { mutableStateOf(false) }

    AuroraGlassCard(
        modifier = modifier,
        cornerRadius = AuroraRadius.xl,
        contentPadding = AuroraSpacing.lg.dp
    ) {
        SectionHeaderRow(
            label = "Trend Atlas",
            trailing = {
                StudioPill(onClick = {
                    HapticBus.light(context)
                    paused = true
                    // Present Chart Studio fullscreen with the live digest.
                    com.openburnbar.ui.chartstudio.ChartStudioPresenter.present(digest)
                    onOpenStudio?.invoke()
                })
            }
        )

        Spacer(Modifier.height(4.dp))

        Text(
            text = scene.subtitle,
            style = AuroraType.body,
            color = MaterialTheme.colorScheme.onSurface
        )

        Spacer(Modifier.height(AuroraSpacing.md.dp))

        SceneChipRail(
            current = scene,
            onSelect = {
                scene = it
                HapticBus.selection(context)
            }
        )

        Spacer(Modifier.height(AuroraSpacing.md.dp))

        AnimatedContent(
            targetState = scene,
            label = "atlas-scene-explicit",
            transitionSpec = {
                (fadeIn(animationSpec = tween(280)) +
                    scaleIn(initialScale = 0.97f, animationSpec = tween(280))) togetherWith
                fadeOut(animationSpec = tween(220))
            },
            modifier = Modifier.fillMaxWidth()
        ) { active ->
            when (active) {
                AtlasScene.SPEND  -> SpendStreamScene(digest = digest)
                AtlasScene.MODELS -> ModelLaneScene(digest = digest)
                AtlasScene.CACHE  -> CacheConstellationScene(digest = digest)
            }
        }

        Spacer(Modifier.height(AuroraSpacing.md.dp))

        InsightAutoRotator(insights = insights, paused = paused)
    }
}

@Composable
private fun SceneChipRail(
    current: AtlasScene,
    onSelect: (AtlasScene) -> Unit
) {
    Surface(
        shape = CircleShape,
        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.55f),
        border = BorderStroke(0.5.dp, MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.6f))
    ) {
        Row(modifier = Modifier.padding(3.dp)) {
            AtlasScene.entries.forEach { s ->
                val selected = s == current
                Surface(
                    onClick = { onSelect(s) },
                    shape = CircleShape,
                    color = if (selected) Color.Transparent else Color.Transparent,
                    modifier = Modifier
                        .weight(1f)
                        .clip(CircleShape)
                ) {
                    Box(
                        modifier = if (selected) {
                            Modifier.background(
                                Brush.horizontalGradient(
                                    colors = listOf(AuroraColors.ember, AuroraColors.amber)
                                )
                            )
                        } else Modifier
                    ) {
                        Row(
                            modifier = Modifier
                                .padding(horizontal = 12.dp, vertical = 6.dp)
                                .fillMaxWidth(),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.Center
                        ) {
                            Icon(
                                imageVector = s.icon,
                                contentDescription = null,
                                tint = if (selected) Color.White
                                       else MaterialTheme.colorScheme.onSurfaceVariant,
                                modifier = Modifier.size(12.dp)
                            )
                            Spacer(Modifier.width(6.dp))
                            Text(
                                text = s.label,
                                fontSize = AuroraTypography.tiny.sp,
                                fontWeight = FontWeight.SemiBold,
                                color = if (selected) Color.White
                                        else MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun StudioPill(onClick: () -> Unit) {
    Surface(
        onClick = onClick,
        shape = CircleShape,
        color = AuroraColors.hermesAureate.copy(alpha = 0.14f),
        border = BorderStroke(0.5.dp, AuroraColors.hermesAureate.copy(alpha = 0.4f))
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 10.dp, vertical = 5.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Icon(
                imageVector = Icons.Filled.AutoAwesome,
                contentDescription = null,
                tint = AuroraColors.hermesAureate,
                modifier = Modifier.size(11.dp)
            )
            Spacer(Modifier.width(4.dp))
            Text(
                text = "Studio",
                fontSize = AuroraTypography.tiny.sp,
                fontWeight = FontWeight.SemiBold,
                color = AuroraColors.hermesAureate
            )
            Spacer(Modifier.width(2.dp))
            Icon(
                imageVector = Icons.Filled.NorthEast,
                contentDescription = null,
                tint = AuroraColors.hermesAureate,
                modifier = Modifier.size(9.dp)
            )
        }
    }
}
