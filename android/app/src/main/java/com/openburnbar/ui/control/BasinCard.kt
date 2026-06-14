// Compose Canvas literals (dp/alpha/geometry); token-per-line extraction obscures the drawing.

package com.openburnbar.ui.control

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.openburnbar.data.domains.EncryptionTier
import com.openburnbar.data.domains.PensieveControlTokens
import com.openburnbar.ui.components.AuroraGlassCard
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraType
import com.openburnbar.ui.theme.LocalAuroraReduceMotion
import kotlin.math.cos
import kotlin.math.sin

/**
 * The Basin — a Compose Canvas hero that pools each domain's footprint as a
 * mercury-silver droplet whose radius tracks its byte/count weight and whose
 * color is its encryption tier. A slow surface-tension shimmer reads as living
 * mercury; obeys Reduce Motion. This is the emotional anchor of the surface:
 * "here is everything of yours, and how it's sealed."
 */
@Composable
internal fun BasinCard(snapshot: ControlCenterSnapshot, modifier: Modifier = Modifier) {
    val reduceMotion = LocalAuroraReduceMotion.current
    val transition = rememberInfiniteTransition(label = "basin")
    val phase by transition.animateFloat(
        initialValue = 0f,
        targetValue = (2f * Math.PI).toFloat(),
        animationSpec =
        infiniteRepeatable(
            animation = tween(if (reduceMotion) 1 else 18000, easing = LinearEasing),
            repeatMode = RepeatMode.Restart,
        ),
        label = "basin-phase",
    )

    val droplets = remember(snapshot) { layoutDroplets(snapshot.rows) }

    AuroraGlassCard(modifier = modifier) {
        Column(verticalArrangement = Arrangement.spacedBy(AuroraSpacing.MD.dp)) {
            Text(
                "The Basin",
                style = AuroraType.title.copy(fontWeight = FontWeight.Bold),
                color = PensieveControlTokens.mercuryBright,
            )
            Text(
                "Everything BurnBar holds for you, pooled by how it's sealed.",
                style = AuroraType.caption,
                color = PensieveControlTokens.textMute,
            )
            Box(
                modifier =
                Modifier
                    .fillMaxWidth()
                    .height(200.dp),
                contentAlignment = Alignment.Center,
            ) {
                Canvas(modifier = Modifier.fillMaxWidth().height(200.dp)) {
                    drawBasinFloor()
                    droplets.forEach { drawDroplet(it, phase) }
                }
            }
            BasinLegend()
        }
    }
}

private fun DrawScope.drawBasinFloor() {
    drawRect(
        brush =
        Brush.verticalGradient(
            colors =
            listOf(
                PensieveControlTokens.inkElevated.copy(alpha = 0f),
                PensieveControlTokens.mercuryWash,
            ),
        ),
        size = size,
    )
}

private fun DrawScope.drawDroplet(d: BasinDroplet, phase: Float) {
    val cx = d.fx * size.width
    val cy = d.fy * size.height
    // Surface-tension wobble: small radial breathing, phase-offset per droplet.
    val wobble = 1f + 0.04f * sin(phase + d.seed)
    val r = d.radius * minOf(size.width, size.height) * wobble
    // Mercury body: radial gradient from bright crown to tier-tinted rim.
    drawCircle(
        brush =
        Brush.radialGradient(
            colors =
            listOf(
                PensieveControlTokens.mercuryBright.copy(alpha = 0.9f),
                d.tierColor.copy(alpha = 0.55f),
                d.tierColor.copy(alpha = 0.12f),
            ),
            center = Offset(cx - r * 0.25f, cy - r * 0.25f),
            radius = r * 1.3f,
        ),
        radius = r,
        center = Offset(cx, cy),
    )
    // Tier rim.
    drawCircle(
        color = d.tierColor.copy(alpha = 0.7f),
        radius = r,
        center = Offset(cx, cy),
        style = androidx.compose.ui.graphics.drawscope.Stroke(width = 1.25f),
    )
    // Specular crown highlight (the "mercury" cue).
    drawCircle(
        color = Color.White.copy(alpha = 0.45f),
        radius = r * 0.22f,
        center = Offset(cx - r * 0.32f + 2f * cos(phase + d.seed), cy - r * 0.32f),
    )
}

@Composable
private fun BasinLegend() {
    Row(horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.MD.dp)) {
        LegendDot(EncryptionTier.END_TO_END, "Sealed")
        LegendDot(EncryptionTier.ZERO_ACCESS, "Zero-access")
        LegendDot(EncryptionTier.SERVER_READABLE, "Readable")
    }
}

@Composable
private fun LegendDot(tier: EncryptionTier, label: String) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Box(
            modifier =
            Modifier
                .size(10.dp)
                .padding(0.dp),
        ) {
            Canvas(modifier = Modifier.size(10.dp)) {
                drawCircle(color = PensieveControlTokens.tierColor(tier))
            }
        }
        Spacer(modifier = Modifier.width(AuroraSpacing.XS.dp))
        Text(label, style = AuroraType.tiny, color = PensieveControlTokens.textMute)
    }
}

internal data class BasinDroplet(
    val id: String,
    val fx: Float,
    val fy: Float,
    val radius: Float,
    val tierColor: Color,
    val seed: Float,
)

/**
 * Lays domain footprints into the basin. Radius is a sqrt of the domain's
 * weight (so area ≈ weight), normalized against the heaviest domain; weight
 * blends count and bytes. Positions are deterministic (golden-angle spiral) so
 * the layout is stable across recompositions and never overlaps the legend.
 */
private fun layoutDroplets(rows: List<DomainRow>): List<BasinDroplet> {
    val weighted = rows.map { it to weightOf(it) }.filter { it.second > 0.0 }
    if (weighted.isEmpty()) return emptyList()
    val maxWeight = weighted.maxOf { it.second }
    val golden = 2.399963f // golden angle in radians
    return weighted.mapIndexed { index, (row, weight) ->
        val norm = (weight / maxWeight).toFloat().coerceIn(0f, 1f)
        // Radius fraction 0.045..0.16 of min-dimension.
        val radius = 0.045f + 0.115f * kotlin.math.sqrt(norm)
        val angle = index * golden
        val spiral = 0.16f + 0.30f * (index.toFloat() / weighted.size.coerceAtLeast(1))
        val fx = (0.5f + spiral * cos(angle)).coerceIn(0.12f, 0.88f)
        val fy = (0.46f + spiral * sin(angle) * 0.7f).coerceIn(0.16f, 0.80f)
        BasinDroplet(
            id = row.domain.id,
            fx = fx,
            fy = fy,
            radius = radius,
            tierColor = PensieveControlTokens.tierColor(row.domain.encryptionTier),
            seed = index * 1.7f,
        )
    }
}

private fun weightOf(row: DomainRow): Double {
    val countWeight = row.count.toDouble()
    // Bytes are heavier signal when present (storage-backed domains); scale to a
    // comparable magnitude (1 droplet-unit ≈ 64 KB or 1 record).
    val byteWeight = row.bytes.toDouble() / (64.0 * 1024.0)
    return maxOf(countWeight, byteWeight)
}
