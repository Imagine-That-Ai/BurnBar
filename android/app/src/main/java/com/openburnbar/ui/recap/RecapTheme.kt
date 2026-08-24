package com.openburnbar.ui.recap

import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.recap.RecapCard
import com.openburnbar.data.recap.RecapInsightKind
import com.openburnbar.data.recap.RecapTone
import com.openburnbar.data.recap.RecapVisualData
import com.openburnbar.ui.theme.AuroraColors

object RecapTheme {

    object Typography {
        val heroNumeral = TextStyle(
            fontFamily = FontFamily.SansSerif,
            fontWeight = FontWeight.Bold,
            fontSize = 72.sp,
            lineHeight = 76.sp,
            letterSpacing = (-1.0).sp,
        )
        val largeNumeral = TextStyle(
            fontFamily = FontFamily.SansSerif,
            fontWeight = FontWeight.Bold,
            fontSize = 48.sp,
            lineHeight = 52.sp,
            letterSpacing = (-0.5).sp,
        )
        val tileNumeral = TextStyle(
            fontFamily = FontFamily.SansSerif,
            fontWeight = FontWeight.Bold,
            fontSize = 34.sp,
            lineHeight = 38.sp,
        )
        val heroHeadline = TextStyle(
            fontFamily = FontFamily.SansSerif,
            fontWeight = FontWeight.Bold,
            fontSize = 28.sp,
            lineHeight = 34.sp,
        )
        val cardHeadline = TextStyle(
            fontFamily = FontFamily.SansSerif,
            fontWeight = FontWeight.SemiBold,
            fontSize = 19.sp,
            lineHeight = 24.sp,
        )
        val cardBody = TextStyle(
            fontFamily = FontFamily.SansSerif,
            fontWeight = FontWeight.Normal,
            fontSize = 15.sp,
            lineHeight = 21.sp,
        )
        val eyebrow = TextStyle(
            fontFamily = FontFamily.SansSerif,
            fontWeight = FontWeight.Bold,
            fontSize = 11.sp,
            lineHeight = 14.sp,
            letterSpacing = 1.2.sp,
        )
        val caption = TextStyle(
            fontFamily = FontFamily.SansSerif,
            fontWeight = FontWeight.Medium,
            fontSize = 13.sp,
            lineHeight = 18.sp,
        )
    }

    object Layout {
        val cardCornerRadius = 20.dp
        val heroCornerRadius = 26.dp
        val cardPadding = 20.dp
        val heroPadding = 24.dp
        val gutter = 16.dp
    }

    fun accentFor(card: RecapCard): Color {
        val visualData = card.visualData
        if (visualData is RecapVisualData.Ranked) {
            val first = visualData.entries.firstOrNull()
            if (first?.colorSeed != null) {
                return colorForModelSeed(first.colorSeed)
            }
        }
        val family = card.candidate.family
        if (family.startsWith("model:")) {
            return colorForModelSeed(family.removePrefix("model:"))
        }
        return accentFor(card.tone, card.kind)
    }

    fun accentFor(tone: RecapTone, kind: RecapInsightKind): Color {
        return when (kind) {
            RecapInsightKind.RECORD, RecapInsightKind.MILESTONE -> AuroraColors.amber
            RecapInsightKind.ANOMALY -> AuroraColors.blaze
            RecapInsightKind.FUN_FACT -> AuroraColors.whimsy
            RecapInsightKind.TREND, RecapInsightKind.COMPARISON -> AuroraColors.ember
            RecapInsightKind.PERSONALITY -> if (tone == RecapTone.PLAYFUL) AuroraColors.whimsy else AuroraColors.ember
        }
    }

    fun colorForModelSeed(seed: String): Color {
        val s = seed.lowercase()
        return when {
            s.contains("claude") || s.contains("anthropic") -> Color(0xFFD97706)
            s.contains("gpt") || s.contains("openai") -> Color(0xFF10B981)
            s.contains("gemini") || s.contains("google") -> Color(0xFF3B82F6)
            s.contains("grok") || s.contains("xai") -> Color(0xFF8B5CF6)
            s.contains("deepseek") -> Color(0xFF06B6D4)
            s.contains("llama") || s.contains("meta") -> Color(0xFFEC4899)
            else -> AuroraColors.ember
        }
    }

    fun wash(accent: Color): Brush {
        return Brush.linearGradient(
            colors = listOf(accent.copy(alpha = 0.14f), accent.copy(alpha = 0.04f)),
        )
    }

    fun numeralFill(accent: Color): Brush {
        return Brush.verticalGradient(
            colors = listOf(accent, accent.copy(alpha = 0.72f)),
        )
    }
}
