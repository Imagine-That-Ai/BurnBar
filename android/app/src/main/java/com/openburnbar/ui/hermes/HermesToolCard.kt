package com.openburnbar.ui.hermes

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Build
import androidx.compose.material.icons.filled.Code
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.OpenInNew
import androidx.compose.material.icons.filled.Public
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.SettingsApplications
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.hermes.MobileTool
import com.openburnbar.data.hermes.MobileToolCategoryGroup
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraGradients
import com.openburnbar.ui.theme.AuroraMotion

// MARK: - HermesToolCard (Compose)
//
// Collapsible card for one Hermes tool invocation. Mirrors the iOS card
// chrome from `OpenBurnBarMobile/Views/Hermes/Square` tool surfaces:
//
//   • Mercury-gradient 1pt stroke (with a slow shimmer when running).
//   • Capability glyph (search / code / file / web / system).
//   • Running state shows a pulsing mercury dot + status text.
//   • Completed state collapses to a single line; tap expands the
//     argument JSON + result snippet (progressive disclosure).
//   • Cards group by `MobileToolCategoryGroup` when rendered as a list
//     ([HermesToolCardRail]).

@Composable
fun HermesToolCard(
    tool: MobileTool,
    state: ToolCardState,
    modifier: Modifier = Modifier,
    argumentsPreview: String? = null,
    resultPreview: String? = null,
    initiallyExpanded: Boolean = false
) {
    var expanded by remember { mutableStateOf(initiallyExpanded) }
    val isRunning = state is ToolCardState.Running

    Column(
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(MaterialTheme.colorScheme.surface)
            .mercuryGradientBorder(animated = isRunning, cornerRadius = 14.dp)
            .clickable { expanded = !expanded }
            .padding(horizontal = 14.dp, vertical = 10.dp)
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp)
        ) {
            Icon(
                imageVector = iconForGroup(tool.categoryGroup),
                contentDescription = null,
                tint = AuroraColors.hermesAureate,
                modifier = Modifier.size(16.dp)
            )
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = tool.name,
                    color = AuroraColors.hermesAureate,
                    fontSize = 13.sp,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 1
                )
                when (state) {
                    is ToolCardState.Running -> {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(6.dp),
                            modifier = Modifier.padding(top = 2.dp)
                        ) {
                            MercuryPulseDot()
                            Text(
                                text = state.statusText ?: "Running…",
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                fontSize = 11.sp,
                                fontFamily = FontFamily.Monospace
                            )
                        }
                    }
                    is ToolCardState.Done -> {
                        Text(
                            text = argumentsPreview ?: tool.categoryGroup.displayLabel,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            fontSize = 11.sp,
                            fontFamily = FontFamily.Monospace,
                            maxLines = 1
                        )
                    }
                    is ToolCardState.Failed -> {
                        Text(
                            text = state.message,
                            color = AuroraColors.error,
                            fontSize = 11.sp,
                            maxLines = 1
                        )
                    }
                }
            }
            Icon(
                imageVector = if (expanded) Icons.Filled.ExpandLess else Icons.Filled.ExpandMore,
                contentDescription = if (expanded) "Collapse tool" else "Expand tool",
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.size(14.dp)
            )
        }
        AnimatedVisibility(visible = expanded) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(top = 8.dp),
                verticalArrangement = Arrangement.spacedBy(6.dp)
            ) {
                Text(
                    text = tool.description,
                    color = MaterialTheme.colorScheme.onSurface,
                    fontSize = 12.sp
                )
                argumentsPreview?.takeIf { it.isNotBlank() }?.let { preview ->
                    ToolCardCodeBlock(label = "Arguments", body = preview)
                }
                resultPreview?.takeIf { it.isNotBlank() }?.let { preview ->
                    ToolCardCodeBlock(label = "Result", body = preview)
                }
            }
        }
    }
}

/**
 * Horizontal rail of tool cards grouped by capability. Mirrors the iOS
 * "Hermes Tool Cards (Hermes mode only)" entry in DESIGN.md — never
 * enumerates all 40+ tools; groups by capability icon.
 */
@Composable
fun HermesToolCardRail(
    tools: List<MobileTool>,
    states: Map<String, ToolCardState>,
    modifier: Modifier = Modifier
) {
    val grouped = remember(tools) { tools.groupBy { it.categoryGroup } }
    Column(
        modifier = modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(10.dp)
    ) {
        grouped.forEach { (group, entries) ->
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(
                    text = group.displayLabel.uppercase(),
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    fontSize = 10.sp,
                    fontWeight = FontWeight.SemiBold,
                    fontFamily = FontFamily.Monospace
                )
                entries.forEach { tool ->
                    val state = states[tool.id] ?: ToolCardState.Done
                    HermesToolCard(tool = tool, state = state)
                }
            }
        }
    }
}

/** Tool card state. Mirrors iOS tool-card chrome states. */
sealed class ToolCardState {
    /** Tool is still running. */
    data class Running(val statusText: String? = null) : ToolCardState()

    /** Tool completed successfully. */
    object Done : ToolCardState()

    /** Tool failed with a short reason. */
    data class Failed(val message: String) : ToolCardState()
}

@Composable
private fun ToolCardCodeBlock(label: String, body: String) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(8.dp))
            .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.65f))
            .padding(horizontal = 10.dp, vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp)
    ) {
        Text(
            text = label.uppercase(),
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            fontSize = 9.sp,
            fontWeight = FontWeight.SemiBold,
            fontFamily = FontFamily.Monospace
        )
        Text(
            text = body,
            color = MaterialTheme.colorScheme.onSurface,
            fontSize = 11.sp,
            fontFamily = FontFamily.Monospace
        )
    }
}

/**
 * Slow pulsing mercury dot rendered next to a running tool card.
 * Matches `mercuryPulse` motion token in `DESIGN.md`.
 */
@Composable
private fun MercuryPulseDot(modifier: Modifier = Modifier) {
    val transition = rememberInfiniteTransition(label = "mercuryPulse")
    val scale by transition.animateFloat(
        initialValue = 0.7f,
        targetValue = 1.1f,
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = 1500, easing = LinearEasing),
            repeatMode = RepeatMode.Reverse
        ),
        label = "mercuryPulseScale"
    )
    val alpha by transition.animateFloat(
        initialValue = 0.55f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = 1500, easing = LinearEasing),
            repeatMode = RepeatMode.Reverse
        ),
        label = "mercuryPulseAlpha"
    )
    Box(
        modifier = modifier
            .size((6 * scale).dp)
            .clip(RoundedCornerShape(percent = 50))
            .background(
                Brush.linearGradient(colors = AuroraGradients.mercuryGradient)
                    .let { it } // gradient brush; alpha applied via overlay
            )
    ) {
        Box(
            modifier = Modifier
                .size((6 * scale).dp)
                .clip(RoundedCornerShape(percent = 50))
                .background(Color.White.copy(alpha = 1f - alpha))
        )
    }
}

/**
 * Mercury-gradient border modifier. When `animated` is true, the
 * gradient sweeps in a 3s `mercuryShimmer` cycle.
 */
@Composable
private fun Modifier.mercuryGradientBorder(
    animated: Boolean,
    cornerRadius: androidx.compose.ui.unit.Dp
): Modifier {
    val transition = rememberInfiniteTransition(label = "mercuryShimmer")
    val phase by transition.animateFloat(
        initialValue = 0f,
        targetValue = if (animated) 1f else 0f,
        animationSpec = infiniteRepeatable(
            animation = tween(
                durationMillis = AuroraMotion.mercuryShimmerDuration.toInt(),
                easing = LinearEasing
            ),
            repeatMode = RepeatMode.Restart
        ),
        label = "mercuryShimmerPhase"
    )
    val brush = Brush.linearGradient(
        colors = AuroraGradients.mercuryGradient,
        start = Offset(phase * 400f, 0f),
        end = Offset(phase * 400f + 400f, 400f)
    )
    return this.border(1.dp, brush, RoundedCornerShape(cornerRadius))
}

private fun iconForGroup(group: MobileToolCategoryGroup): ImageVector = when (group) {
    MobileToolCategoryGroup.SEARCH -> Icons.Filled.Search
    MobileToolCategoryGroup.CODE -> Icons.Filled.Code
    MobileToolCategoryGroup.FILE -> Icons.Filled.Description
    MobileToolCategoryGroup.WEB -> Icons.Filled.Public
    MobileToolCategoryGroup.SYSTEM -> Icons.Filled.SettingsApplications
}
