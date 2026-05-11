package com.openburnbar.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraRadius
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraType

/** Visual severity for an [AuroraBadge]. */
enum class AuroraBadgeTone { Neutral, Success, Warning, Error, Info, Accent }

/**
 * Small pill badge with semantic background tint + optional border. Mirrors
 * `CacheHitRateBadge` and the various small status pills used across the iOS
 * dashboard.
 */
@Composable
fun AuroraBadge(
    text: String,
    modifier: Modifier = Modifier,
    tone: AuroraBadgeTone = AuroraBadgeTone.Neutral,
    bordered: Boolean = true,
    cornerRadius: Dp = AuroraRadius.full.dp,
    padding: PaddingValues = PaddingValues(horizontal = AuroraSpacing.sm.dp, vertical = 2.dp)
) {
    val (fg, bg) = toneColors(tone)

    Box(
        modifier = modifier
            .background(bg, RoundedCornerShape(cornerRadius))
            .let { if (bordered) it.border(0.75.dp, fg.copy(alpha = 0.45f), RoundedCornerShape(cornerRadius)) else it }
            .padding(padding)
    ) {
        Text(text = text, style = AuroraType.tiny, color = fg)
    }
}

private fun toneColors(tone: AuroraBadgeTone): Pair<Color, Color> = when (tone) {
    AuroraBadgeTone.Success -> AuroraColors.success to AuroraColors.success.copy(alpha = 0.14f)
    AuroraBadgeTone.Warning -> AuroraColors.warning to AuroraColors.warning.copy(alpha = 0.14f)
    AuroraBadgeTone.Error   -> AuroraColors.error to AuroraColors.error.copy(alpha = 0.14f)
    AuroraBadgeTone.Info    -> AuroraColors.whimsy to AuroraColors.whimsy.copy(alpha = 0.14f)
    AuroraBadgeTone.Accent  -> AuroraColors.ember to AuroraColors.ember.copy(alpha = 0.14f)
    AuroraBadgeTone.Neutral -> AuroraColors.hermesMercury to AuroraColors.hermesMercury.copy(alpha = 0.14f)
}
