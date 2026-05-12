package com.openburnbar.ui.theme

import android.provider.Settings
import androidx.compose.animation.core.AnimationSpec
import androidx.compose.animation.core.EaseOut
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.remember
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

// ── Aurora Color Tokens ──
// Light: warm botanical cream. Dark: cool slate blue (GitHub/Xcode dark lineage).
object AuroraColors {
    // Brand accents (light-mode primary values)
    val ember    = Color(0xFFF45B69)
    val amber    = Color(0xFFF28C38)
    val blaze    = Color(0xFFE86100)
    val whimsy   = Color(0xFF6A5ACD)

    // Dark-mode brand accents (mirrors iOS Theme/DesignSystem.swift adaptive colors)
    val emberDark   = Color(0xFFFA5053)
    val amberDark   = Color(0xFFFFA800)
    val whimsyDark  = Color(0xFF8B7FE8)

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

    // Returns the appropriate brand accent for the current theme. The light-mode
    // hex is the public token most code references; this helper is for places
    // that need to mirror iOS's automatic adaptive Color.
    fun ember(isDark: Boolean) = if (isDark) emberDark else ember
    fun amber(isDark: Boolean) = if (isDark) amberDark else amber
    fun whimsy(isDark: Boolean) = if (isDark) whimsyDark else whimsy
}

// ── Aurora Typography (legacy size tokens) ──
// Kept for the many call sites that reference `AuroraTypography.body.sp` directly.
// Prefer `AuroraType.*` TextStyle constants for new code so weight + family are
// captured alongside size.
object AuroraTypography {
    val displayHero   = 44
    val display       = 28
    val displayLarge  = 36   // iOS DesignSystem.swift Typography.displayLarge
    val title         = 20
    val headline      = 16
    val heading       = 16
    val body          = 14
    val caption       = 12
    val tiny          = 11
}

// ── Aurora Type (full TextStyle constants) ──
// Mirrors iOS DesignSystem.Typography. SansSerif here stands in for SwiftUI
// `.rounded` — the closest stock Android equivalent without bundling a custom
// rounded font. Mono variants use FontFamily.Monospace.
object AuroraType {
    val displayLarge = TextStyle(
        fontFamily = FontFamily.SansSerif,
        fontWeight = FontWeight.Bold,
        fontSize = 36.sp,
        lineHeight = 44.sp,
        letterSpacing = (-0.3).sp
    )
    val display = TextStyle(
        fontFamily = FontFamily.SansSerif,
        fontWeight = FontWeight.Bold,
        fontSize = 28.sp,
        lineHeight = 34.sp,
        letterSpacing = (-0.2).sp
    )
    val title = TextStyle(
        fontFamily = FontFamily.SansSerif,
        fontWeight = FontWeight.SemiBold,
        fontSize = 20.sp,
        lineHeight = 26.sp
    )
    val headline = TextStyle(
        fontFamily = FontFamily.SansSerif,
        fontWeight = FontWeight.SemiBold,
        fontSize = 16.sp,
        lineHeight = 22.sp
    )
    val body = TextStyle(
        fontFamily = FontFamily.SansSerif,
        fontWeight = FontWeight.Normal,
        fontSize = 14.sp,
        lineHeight = 20.sp
    )
    val caption = TextStyle(
        fontFamily = FontFamily.SansSerif,
        fontWeight = FontWeight.Medium,
        fontSize = 12.sp,
        lineHeight = 16.sp
    )
    val tiny = TextStyle(
        fontFamily = FontFamily.SansSerif,
        fontWeight = FontWeight.Medium,
        fontSize = 11.sp,
        lineHeight = 14.sp
    )

    val monoLarge = TextStyle(
        fontFamily = FontFamily.Monospace,
        fontWeight = FontWeight.Bold,
        fontSize = 28.sp,
        lineHeight = 34.sp
    )
    val mono = TextStyle(
        fontFamily = FontFamily.Monospace,
        fontWeight = FontWeight.Medium,
        fontSize = 14.sp,
        lineHeight = 20.sp
    )
    val monoSmall = TextStyle(
        fontFamily = FontFamily.Monospace,
        fontWeight = FontWeight.Medium,
        fontSize = 12.sp,
        lineHeight = 16.sp
    )
    val monoTiny = TextStyle(
        fontFamily = FontFamily.Monospace,
        fontWeight = FontWeight.Medium,
        fontSize = 11.sp,
        lineHeight = 14.sp
    )
}

// ── Material3 Typography wiring ──
// Maps the closest M3 slots to AuroraType so `MaterialTheme.typography.bodyMedium`
// etc. picks up our weights/families. App code should prefer AuroraType directly
// where the M3 mapping is fuzzy.
private val AuroraMaterialTypography = Typography(
    displayLarge = AuroraType.displayLarge,
    displayMedium = AuroraType.display,
    displaySmall = AuroraType.title,
    headlineSmall = AuroraType.headline,
    titleLarge = AuroraType.title,
    titleMedium = AuroraType.headline,
    bodyLarge = AuroraType.body.copy(fontSize = 16.sp, lineHeight = 22.sp),
    bodyMedium = AuroraType.body,
    bodySmall = AuroraType.caption,
    labelLarge = AuroraType.headline.copy(fontWeight = FontWeight.SemiBold),
    labelMedium = AuroraType.caption,
    labelSmall = AuroraType.tiny
)

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

// ── Aurora Shadows ──
// Centralized elevation specs that mirror iOS ad-hoc shadow usage. Each spec
// captures the elevation Compose needs plus the shadow color/alpha so glass
// surfaces and cards stay consistent.
data class AuroraShadowSpec(val elevation: Dp, val spotAlpha: Float)

object AuroraShadows {
    val none      = AuroraShadowSpec(0.dp, 0f)
    val subtle    = AuroraShadowSpec(2.dp, 0.05f)
    val small     = AuroraShadowSpec(4.dp, 0.10f)
    val medium    = AuroraShadowSpec(8.dp, 0.12f)
    val cardHover = AuroraShadowSpec(12.dp, 0.18f)
    val large     = AuroraShadowSpec(16.dp, 0.20f)
    val fab       = AuroraShadowSpec(12.dp, 0.25f)
}

// ── Aurora Gradients ──
object AuroraGradients {
    fun auroraRibbon(isDark: Boolean): List<Color> = listOf(
        AuroraColors.ember(isDark).copy(alpha = 0.55f),
        AuroraColors.amber(isDark).copy(alpha = 0.35f),
        (if (isDark) AuroraColors.hermesMercuryDark else AuroraColors.hermesMercury).copy(alpha = 0.25f),
        AuroraColors.whimsy(isDark).copy(alpha = 0.18f)
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

    val mercuryGradient = listOf(
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

    // Plan 2 Pi runtime accent gradient. Composed entirely from the existing
    // `whimsy` brand color so no new tokens leak into the palette. Mirrors
    // `UnifiedDesignSystem.piGradient` (iOS) and `DesignSystem.Colors.piGradient`
    // (macOS) so the Pi runtime pill and bubble strokes match 1:1.
    val piGradient = listOf(AuroraColors.whimsy, AuroraColors.whimsy.copy(alpha = 0.65f))

    // Edge gradient used for the 0.75dp glass-card stroke. Matches the iOS
    // UnifiedGlassCard border treatment.
    val glassStroke = listOf(
        AuroraColors.ember.copy(alpha = 0.22f),
        AuroraColors.lightBorder.copy(alpha = 0.55f),
        AuroraColors.blaze.copy(alpha = 0.18f)
    )

    // Brand-tinted sheen overlay laid on top of the glass surface for warmth.
    val glassSheen = listOf(
        AuroraColors.ember.copy(alpha = 0.08f),
        Color.Transparent,
        AuroraColors.blaze.copy(alpha = 0.06f)
    )

    fun providerRing(provider: com.openburnbar.data.models.AgentProvider): List<Color> = listOf(
        Color(provider.brandColor).copy(alpha = 0.95f),
        Color(provider.accentColor).copy(alpha = 0.65f),
        Color(provider.brandColor).copy(alpha = 0f),
        Color(provider.accentColor).copy(alpha = 0.45f),
        Color(provider.brandColor).copy(alpha = 0.95f)
    )
}

// ── Aurora Animation Specs ──
// Re-derived from iOS DesignSystem.Animation responses:
//   stiffness ≈ (2π / response)²
//   auroraSpring  response=0.35 damping=0.75 → stiffness ≈ 322
//   cardHover     response=0.25 damping=0.80 → stiffness ≈ 632
//   cardPress     response=0.22 damping=0.70 → stiffness ≈ 815
//   auroraSnap is `easeOut 150ms` on iOS — kept as tween, not spring.
object AuroraMotion {

    // Legacy data class retained for callers that read durationMs / dampingRatio
    // as raw fields. Prefer the spec factories below for new Compose code.
    data class SpringSpec(val durationMs: Int, val dampingRatio: Float)

    val auroraSpring  = SpringSpec(350, 0.75f)
    val auroraSnap    = SpringSpec(150, 1.0f)  // easeOut on iOS — kept for legacy reads
    val cardHover     = SpringSpec(250, 0.80f)
    val cardPress     = SpringSpec(220, 0.70f)
    const val mercuryShimmerDuration = 3000L

    // Compose AnimationSpec<Float> factories — use these in animate*AsState
    // calls. Stiffness numbers are derived from iOS response constants.
    fun <T> auroraSpringSpec(): AnimationSpec<T> =
        spring(stiffness = 322f, dampingRatio = 0.75f)

    fun <T> auroraSnapSpec(): AnimationSpec<T> =
        tween(durationMillis = 150, easing = EaseOut)

    fun <T> cardHoverSpec(): AnimationSpec<T> =
        spring(stiffness = 632f, dampingRatio = 0.80f)

    fun <T> cardPressSpec(): AnimationSpec<T> =
        spring(stiffness = 815f, dampingRatio = 0.70f)

    fun <T> gentleSpec(): AnimationSpec<T> =
        spring(stiffness = Spring.StiffnessLow, dampingRatio = 0.85f)
}

// ── Reduce-motion CompositionLocal ──
// Mirrors iOS `@Environment(\.accessibilityReduceMotion)`. Reads the system
// animator-duration-scale once at theme entry; composables that drive infinite
// or large transitions should respect this.
val LocalAuroraReduceMotion = compositionLocalOf { false }

// ── Composable Theme ──
private val DarkColorScheme = darkColorScheme(
    primary = AuroraColors.emberDark,
    secondary = AuroraColors.amberDark,
    tertiary = AuroraColors.whimsyDark,
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
    val context = LocalContext.current
    val reduceMotion = remember(context) {
        runCatching {
            Settings.Global.getFloat(
                context.contentResolver,
                Settings.Global.ANIMATOR_DURATION_SCALE,
                1f
            ) == 0f
        }.getOrDefault(false)
    }

    CompositionLocalProvider(LocalAuroraReduceMotion provides reduceMotion) {
        MaterialTheme(
            colorScheme = colorScheme,
            typography = AuroraMaterialTypography,
            content = content
        )
    }
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
