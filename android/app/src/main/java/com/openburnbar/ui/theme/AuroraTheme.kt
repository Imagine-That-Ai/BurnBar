package com.openburnbar.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.graphics.Color

// ── Aurora Color Tokens ──
// Light: warm botanical cream. Dark: cool slate blue (GitHub/Xcode dark lineage).
object AuroraColors {
    // Brand accents
    val ember    = Color(0xFFF45B69)
    val amber    = Color(0xFFF28C38)
    val blaze    = Color(0xFFE86100)
    val whimsy   = Color(0xFF6A5ACD)

    // Light mode surfaces
    val lightBackground       = Color(0xFFF3E8E6)
    val lightSurface          = Color(0xFFFAF5F2)
    val lightSurfaceElevated  = Color(0xFFFDF8F5)
    val lightBorder           = Color(0xFFE8BFB5)
    val lightBorderSubtle     = Color(0xFFF2E0DA)
    val lightTextPrimary      = Color(0xFF2A1816)
    val lightTextSecondary    = Color(0xFF6E4E48)
    val lightTextMuted        = Color(0xFF9A756D)

    // Dark mode surfaces
    val darkBackground        = Color(0xFF0D1117)
    val darkSurface           = Color(0xFF161B22)
    val darkSurfaceElevated   = Color(0xFF1F2630)
    val darkBorder            = Color(0xFF30363D)
    val darkBorderSubtle      = Color(0xFF21262D)
    val darkTextPrimary       = Color(0xFFE6EDF3)
    val darkTextSecondary     = Color(0xFF8B949E)
    val darkTextMuted         = Color(0xFF6E7681)

    // Semantic
    val success = Color(0xFF3A7835)
    val warning = Color(0xFFC47800)
    val error   = Color(0xFFD43030)

    val successDark = Color(0xFF38D898)
    val warningDark = Color(0xFFFFA800)
    val errorDark   = Color(0xFFFA5053)

    // Burn-specific colors (aliases for ember/blaze)
    val burnOrange = ember
    val burnCoral  = Color(0xFFE86100)  // blaze alias

    // Hermes mercury
    val hermesMercury = Color(0xFFAEA69C)
    val hermesAureate = Color(0xFFB8942E)
    val hermesMercuryDark = Color(0xFFC8BFB5)
    val hermesAureateDark = Color(0xFFD4AA3C)

    // Chat bubbles
    val chatUserStroke      = Color(0xFF6A5ACD)
    val chatAssistantStroke = Color(0xFFF45B69)
}

// ── Aurora Typography ──
object AuroraTypography {
    // SwiftUI-compatible sizes
    val displayHero   = 44
    val display       = 28
    val title         = 20
    val headline      = 16
    val heading       = 16  // alias for consistency
    val body          = 14
    val caption       = 12
    val tiny          = 11
}

// ── Aurora Spacing ──
object AuroraSpacing {
    const val xxs = 2
    const val xs  = 4
    const val sm  = 8
    const val md  = 12
    const val lg  = 16
    const val xl  = 24
    const val xxl = 32
    const val xxxl = 48
}

// ── Aurora Radius ──
object AuroraRadius {
    const val sm   = 6
    const val md   = 10
    const val lg   = 16
    const val xl   = 22
    const val full = 9999
}

// ── Aurora Gradients ──
object AuroraGradients {
    fun auroraRibbon(isDark: Boolean): List<Color> = listOf(
        AuroraColors.ember.copy(alpha = 0.55f),
        AuroraColors.amber.copy(alpha = 0.35f),
        (if (isDark) AuroraColors.hermesMercuryDark else AuroraColors.hermesMercury).copy(alpha = 0.25f),
        AuroraColors.whimsy.copy(alpha = 0.18f)
    )

    val heroCard = listOf(
        AuroraColors.ember.copy(alpha = 0.18f),
        AuroraColors.amber.copy(alpha = 0.08f),
        AuroraColors.blaze.copy(alpha = 0.04f)
    )

    val mercuryFoil = listOf(
        AuroraColors.hermesMercury.copy(alpha = 0.85f),
        AuroraColors.hermesAureate.copy(alpha = 0.7f),
        AuroraColors.hermesMercury.copy(alpha = 0.85f)
    )

    val primaryGradient = listOf(AuroraColors.ember, AuroraColors.amber)

    val accentGradient = listOf(AuroraColors.whimsy, AuroraColors.ember)

    val cardGradient = listOf(
        AuroraColors.ember.copy(alpha = 0.06f),
        AuroraColors.amber.copy(alpha = 0.04f),
        AuroraColors.blaze.copy(alpha = 0.03f)
    )

    val whimsyGradient = listOf(AuroraColors.whimsy, AuroraColors.whimsy.copy(alpha = 0.6f))

    fun providerRing(provider: com.openburnbar.data.models.AgentProvider): List<Color> = listOf(
        Color(provider.brandColor).copy(alpha = 0.95f),
        Color(provider.accentColor).copy(alpha = 0.65f),
        Color(provider.brandColor).copy(alpha = 0f),
        Color(provider.accentColor).copy(alpha = 0.45f),
        Color(provider.brandColor).copy(alpha = 0.95f)
    )
}

// ── Aurora Animation Specs ──
object AuroraMotion {
    // Spring specs (durationMs, dampingRatio)
    data class SpringSpec(val durationMs: Int, val dampingRatio: Float)

    val auroraSpring  = SpringSpec(420, 0.82f)
    val auroraSnap    = SpringSpec(280, 0.78f)
    val cardHover     = SpringSpec(250, 0.82f)
    val cardPress     = SpringSpec(220, 0.70f)
    val mercuryShimmerDuration = 3000L
}

// ── Composable Theme ──
private val DarkColorScheme = darkColorScheme(
    primary = AuroraColors.ember,
    secondary = AuroraColors.amber,
    tertiary = AuroraColors.whimsy,
    background = AuroraColors.darkBackground,
    surface = AuroraColors.darkSurface,
    surfaceVariant = AuroraColors.darkSurfaceElevated,
    onPrimary = Color.White,
    onSecondary = Color.White,
    onTertiary = Color.White,
    onBackground = AuroraColors.darkTextPrimary,
    onSurface = AuroraColors.darkTextPrimary,
    onSurfaceVariant = AuroraColors.darkTextSecondary,
    outline = AuroraColors.darkBorder,
    outlineVariant = AuroraColors.darkBorderSubtle,
    error = AuroraColors.errorDark
)

private val LightColorScheme = lightColorScheme(
    primary = AuroraColors.ember,
    secondary = AuroraColors.amber,
    tertiary = AuroraColors.whimsy,
    background = AuroraColors.lightBackground,
    surface = AuroraColors.lightSurface,
    surfaceVariant = AuroraColors.lightSurfaceElevated,
    onPrimary = Color.White,
    onSecondary = Color.White,
    onTertiary = Color.White,
    onBackground = AuroraColors.lightTextPrimary,
    onSurface = AuroraColors.lightTextPrimary,
    onSurfaceVariant = AuroraColors.lightTextSecondary,
    outline = AuroraColors.lightBorder,
    outlineVariant = AuroraColors.lightBorderSubtle,
    error = AuroraColors.error
)

@Composable
fun AuroraTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    content: @Composable () -> Unit
) {
    val colorScheme = if (darkTheme) DarkColorScheme else LightColorScheme

    MaterialTheme(
        colorScheme = colorScheme,
        content = content
    )
}

// ── Model color helpers ──
fun colorForModel(modelName: String): Color {
    val key = modelName.lowercase()
    if (key.contains("claude") || key.contains("anthropic")) return Color(0xFFCC785C)
    if (key.contains("gpt") || key.contains("openai") || key.contains("chatgpt")) return Color(0xFF00A67E)
    if (key.contains("gemini") || key.contains("google")) return Color(0xFF4285F4)
    if (key.contains("deepseek")) return Color(0xFF6366F1)
    if (key.contains("kimi") || key.contains("moonshot")) return Color(0xFF6366F1)
    if (key.contains("minimax") || key.contains("abab")) return Color(0xFFF59E0B)
    if (key.contains("llama") || key.contains("meta")) return Color(0xFF0668E1)
    if (key.contains("mistral") || key.contains("mixtral")) return Color(0xFFFF7000)
    if (key.contains("qwen") || key.contains("qwq")) return Color(0xFF615EFF)
    if (key.contains("grok") || key.contains("xai")) return Color(0xFF1A1A1A)
    if (key.contains("cohere") || key.contains("command")) return Color(0xFF39594D)
    if (key.contains("perplexity") || key.contains("sonar")) return Color(0xFF20808D)
    if (key.contains("mlx") || key.contains("apple")) return Color(0xFFA2AAAD)
    if (key.contains("nova") || key.contains("amazon") || key.contains("bedrock")) return Color(0xFFFF9900)
    if (key.contains("alibaba") || key.contains("tongyi")) return Color(0xFFFF6A00)
    if (key.contains("ollama")) return Color(0xFF8B8589)

    val palette = listOf(
        0xFFD4A373, 0xFF10B981, 0xFFEC4899, 0xFFF97316,
        0xFF3B82F6, 0xFFA855F7, 0xFFEF4444, 0xFF14B8A6,
        0xFFF59E0B, 0xFF8B5CF6, 0xFF06B6D4, 0xFF84CC16
    )
    var hash = 5381L
    key.forEach { byte -> hash = ((hash shl 5) + hash) + byte.code.toLong() }
    return Color(palette[(hash % palette.size).toInt()])
}
