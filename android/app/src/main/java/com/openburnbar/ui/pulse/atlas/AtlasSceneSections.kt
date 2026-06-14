// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.pulse.atlas

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.NorthEast
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.derived.TrendDataDigest
import com.openburnbar.data.derived.TrendInsight
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

@Composable
fun TrendAtlasCard(
    rollups: UsageRollups,
    recentUsages: List<TokenUsage>,
    displayMode: UsageDisplayMode,
    modifier: Modifier = Modifier,
    onOpenStudio: (() -> Unit)? = null,
) {
    val digest =
        androidx.compose.runtime.remember(rollups, recentUsages, displayMode) {
            TrendDataDigest.build(rollups = rollups, recentUsages = recentUsages, displayMode = displayMode)
        }
    TrendAtlasCard(digest = digest, modifier = modifier, onOpenStudio = onOpenStudio)
}

@Composable
fun TrendAtlasCard(
    digest: TrendDataDigest,
    insights: List<TrendInsight> = com.openburnbar.data.derived.TrendInsightEngine.insights(digest),
    modifier: Modifier = Modifier,
    onOpenStudio: (() -> Unit)? = null,
) {
    var scene by rememberSaveable { mutableStateOf(AtlasScene.SPEND) }
    var paused by remember { mutableStateOf(false) }
    val context = LocalContext.current

    AuroraGlassCard(
        modifier = modifier,
        cornerRadius = AuroraRadius.XL,
        contentPadding = AuroraSpacing.LG.dp,
    ) {
        TrendAtlasCardBody(
            digest = digest,
            insights = insights,
            scene = scene,
            paused = paused,
            onSceneChange = {
                scene = it
                HapticBus.selection(context)
            },
            onOpenStudio = {
                HapticBus.light(context)
                paused = true
                com.openburnbar.ui.chartstudio.ChartStudioPresenter.present(digest)
                onOpenStudio?.invoke()
            },
        )
    }
}

@Composable
internal fun TrendAtlasCardBody(
    digest: TrendDataDigest,
    insights: List<TrendInsight>,
    scene: AtlasScene,
    paused: Boolean,
    onSceneChange: (AtlasScene) -> Unit,
    onOpenStudio: () -> Unit,
) {
    val context = LocalContext.current
    SectionHeaderRow(
        label = "Trend Atlas",
        trailing = { StudioPill(onClick = onOpenStudio) },
    )
    Spacer(Modifier.height(4.dp))
    Text(text = scene.subtitle, style = AuroraType.body, color = MaterialTheme.colorScheme.onSurface)
    Spacer(Modifier.height(AuroraSpacing.MD.dp))
    SceneChipRail(current = scene, onSelect = onSceneChange)
    Spacer(Modifier.height(AuroraSpacing.MD.dp))
    TrendAtlasSceneContent(
        scene = scene,
        digest = digest,
        onSwipe = { drag ->
            if (abs(drag) <= 28f) return@TrendAtlasSceneContent
            val order = AtlasScene.entries
            val current = order.indexOf(scene)
            val next = if (drag < 0) (current + 1) % order.size else (current - 1 + order.size) % order.size
            if (next != current) {
                onSceneChange(order[next])
                HapticBus.selection(context)
            }
        },
    )
    Spacer(Modifier.height(AuroraSpacing.MD.dp))
    InsightAutoRotator(insights = insights, paused = paused)
}

@Composable
private fun TrendAtlasSceneContent(scene: AtlasScene, digest: TrendDataDigest, onSwipe: (Float) -> Unit) {
    AnimatedContent(
        targetState = scene,
        label = "atlas-scene",
        transitionSpec = {
            fadeIn(animationSpec = tween(280)) +
                scaleIn(initialScale = 0.97f, animationSpec = tween(280)) togetherWith
                fadeOut(animationSpec = tween(220))
        },
        modifier =
        Modifier
            .fillMaxWidth()
            .pointerInput(scene) {
                detectHorizontalDragGestures { _, drag -> onSwipe(drag) }
            },
    ) { active ->
        when (active) {
            AtlasScene.SPEND -> SpendStreamScene(digest = digest)
            AtlasScene.MODELS -> ModelLaneScene(digest = digest)
            AtlasScene.CACHE -> CacheConstellationScene(digest = digest)
        }
    }
}

@Composable
internal fun SceneChipRail(current: AtlasScene, onSelect: (AtlasScene) -> Unit) {
    Surface(
        shape = CircleShape,
        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.55f),
        border = BorderStroke(0.5.dp, MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.6f)),
    ) {
        Row(modifier = Modifier.padding(3.dp)) {
            AtlasScene.entries.forEach { scene ->
                AtlasSceneChip(scene = scene, selected = scene == current, onSelect = { onSelect(scene) })
            }
        }
    }
}

@Composable
private fun RowScope.AtlasSceneChip(scene: AtlasScene, selected: Boolean, onSelect: () -> Unit) {
    Surface(
        onClick = onSelect,
        shape = CircleShape,
        color = Color.Transparent,
        modifier = Modifier.weight(1f).clip(CircleShape),
    ) {
        Box(
            modifier =
            if (selected) {
                Modifier.background(Brush.horizontalGradient(colors = listOf(AuroraColors.ember, AuroraColors.amber)))
            } else {
                Modifier
            },
        ) {
            Row(
                modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp).fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.Center,
            ) {
                Icon(
                    imageVector = scene.icon,
                    contentDescription = null,
                    tint = if (selected) Color.White else MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.size(12.dp),
                )
                Spacer(Modifier.width(6.dp))
                Text(
                    text = scene.label,
                    fontSize = AuroraTypography.tiny.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = if (selected) Color.White else MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

@Composable
internal fun StudioPill(onClick: () -> Unit) {
    Surface(
        onClick = onClick,
        shape = CircleShape,
        color = AuroraColors.hermesAureate.copy(alpha = 0.14f),
        border = BorderStroke(0.5.dp, AuroraColors.hermesAureate.copy(alpha = 0.4f)),
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 10.dp, vertical = 5.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(Icons.Filled.AutoAwesome, contentDescription = null, tint = AuroraColors.hermesAureate, modifier = Modifier.size(11.dp))
            Spacer(Modifier.width(4.dp))
            Text("Studio", fontSize = AuroraTypography.tiny.sp, fontWeight = FontWeight.SemiBold, color = AuroraColors.hermesAureate)
            Spacer(Modifier.width(2.dp))
            Icon(Icons.Filled.NorthEast, contentDescription = null, tint = AuroraColors.hermesAureate, modifier = Modifier.size(9.dp))
        }
    }
}
