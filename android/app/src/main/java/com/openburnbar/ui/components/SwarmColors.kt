package com.openburnbar.ui.components

import androidx.compose.ui.graphics.Color
import com.openburnbar.data.models.AgentProvider

/** Swarm particle coloring: palettes, brand roles, blending. */
internal fun providerLogoColor(provider: AgentProvider, role: String, opacity: Float, isDark: Boolean): Color {
    val brand =
        if (provider == AgentProvider.XAI && isDark) {
            Color(0xFFECEFF4)
        } else {
            Color(provider.brandColor)
        }
    val accent = Color(provider.accentColor)
    val hot = blend(brand, Color.White, if (role == "logo-flame-inner") 0.28f else 0.16f)
    val shadow = blend(brand, if (isDark) Color.Black else Color.DarkGray, if (role == "logo-flame-outer") 0.34f else 0.18f)
    val spark = blend(accent, Color.White, 0.34f)
    val color =
        when (role) {
            "logo-flame-outer" -> blend(shadow, brand, 0.34f)
            "logo-flame-spark" -> spark
            else -> blend(brand, hot, 0.52f)
        }
    val alphaMultiplier =
        when (role) {
            "logo-flame-outer" -> 1.44f
            "logo-flame-spark" -> 1.72f
            else -> 1.62f
        }
    return color.copy(alpha = (opacity * alphaMultiplier).coerceAtMost(1f))
}

internal fun contrastAdjustedSourceLogoColor(color: Color): Color {
    val luminance = 0.2126f * color.red + 0.7152f * color.green + 0.0722f * color.blue
    return when {
        luminance < 0.08f -> Color(0xFFD6DBE5)
        luminance < 0.22f -> blend(color, Color.White, 0.46f)
        else -> color
    }
}

internal fun parseRoleAndProvider(role: String?): Pair<String, AgentProvider>? {
    if (role == null) return null
    val separator = role.lastIndexOf(':')
    if (separator <= 0 || separator >= role.lastIndex) return null
    val cleanRole = role.substring(0, separator)
    val provider = AgentProvider.fromKey(role.substring(separator + 1)) ?: return null
    return cleanRole to provider
}

internal fun blend(lhs: Color, rhs: Color, amount: Float): Color {
    val t = amount.coerceIn(0f, 1f)
    return Color(
        red = lhs.red * (1f - t) + rhs.red * t,
        green = lhs.green * (1f - t) + rhs.green * t,
        blue = lhs.blue * (1f - t) + rhs.blue * t,
        alpha = 1f,
    )
}

internal fun relativeLuminance(color: Color): Float = relativeLuminance(color.red, color.green, color.blue)

internal fun relativeLuminance(red: Float, green: Float, blue: Float): Float = 0.2126f * red + 0.7152f * green + 0.0722f * blue

internal val COOKING_SWARM_COLORS =
    listOf(
        // Dragonfruit Pink
        Color(0xFFFF2A6D),
        // Tangerine Orange
        Color(0xFFFF5E3A),
        // Honey Mango Yellow
        Color(0xFFFFD700),
        // Mint Basil Green
        Color(0xFF2ECC71),
        // Electric Blueberry Blue
        Color(0xFF00F5FF),
        // Fig Plum Purple
        Color(0xFF9B59B6),
        // Strawberry Pink
        Color(0xFFFF1493),
        // Lime Kiwi Green
        Color(0xFF7FFF00),
    )

internal fun cookingSwarmColor(colorIndex: Double, opacity: Float): Color {
    val idx = (colorIndex * COOKING_SWARM_COLORS.size).toInt().coerceIn(0, COOKING_SWARM_COLORS.size - 1)
    return COOKING_SWARM_COLORS[idx].copy(alpha = (opacity * 1.5f).coerceAtMost(1f))
}

internal data class SwarmPalette(
    val whimsy: Color,
    val ember: Color,
    val amber: Color,
    val blaze: Color,
)

private enum class SwarmPaletteFamily(val dark: SwarmPalette, val light: SwarmPalette) {
    AURORA(
        dark =
        SwarmPalette(
            whimsy = Color(0xFF8B2DF2),
            ember = Color(0xFF008080),
            amber = Color(0xFF00F5FF),
            blaze = Color(0xFF00FF80),
        ),
        light =
        SwarmPalette(
            whimsy = Color(0xFF7012C9),
            ember = Color(0xFF006666),
            amber = Color(0xFF00C2CC),
            blaze = Color(0xFF00CC66),
        ),
    ),
    CRIMSON(
        dark =
        SwarmPalette(
            whimsy = Color(0xFF4A0082),
            ember = Color(0xFFFF1493),
            amber = Color(0xFFFF4500),
            blaze = Color(0xFFB22222),
        ),
        light =
        SwarmPalette(
            whimsy = Color(0xFF380069),
            ember = Color(0xFFCC0A75),
            amber = Color(0xFFCC2E00),
            blaze = Color(0xFF8E1414),
        ),
    ),
    EMBER(
        dark =
        SwarmPalette(
            whimsy = Color(0xFF8080FF),
            ember = Color(0xFFFA6B06),
            amber = Color(0xFFFFA800),
            blaze = Color(0xFFEE1803),
        ),
        light =
        SwarmPalette(
            whimsy = Color(0xFF514DDB),
            ember = Color(0xFFCC4D00),
            amber = Color(0xFFC78500),
            blaze = Color(0xFFBD1200),
        ),
    ),
}

internal fun swarmPaletteFor(paletteName: String, isDark: Boolean): SwarmPalette {
    val family =
        when (paletteName) {
            "AuroraTeal", "Aurora" -> SwarmPaletteFamily.AURORA
            "Crimson", "SunsetCrimson" -> SwarmPaletteFamily.CRIMSON
            else -> SwarmPaletteFamily.EMBER
        }
    return if (isDark) family.dark else family.light
}

internal fun routerFlowColor(role: String, palette: SwarmPalette, accent: Color, opacity: Float): Color {
    return when (role) {
        "gateway" -> palette.whimsy.copy(alpha = (opacity * 1.6f).coerceAtMost(1f))
        "path-1", "target-1" -> palette.blaze.copy(alpha = (opacity * 1.5f).coerceAtMost(1f))
        "path-2", "target-2" -> palette.amber.copy(alpha = (opacity * 1.5f).coerceAtMost(1f))
        "path-3", "target-3" -> palette.ember.copy(alpha = (opacity * 1.5f).coerceAtMost(1f))
        else -> accent.copy(alpha = (opacity * 0.35f).coerceAtMost(1f))
    }
}

internal fun emberIndexColor(colorIndex: Double, palette: SwarmPalette, opacity: Float): Color {
    return when {
        colorIndex < 0.08 -> palette.whimsy.copy(alpha = opacity)
        colorIndex < 0.35 -> palette.ember.copy(alpha = opacity)
        colorIndex < 0.62 -> palette.amber.copy(alpha = opacity)
        else -> palette.blaze.copy(alpha = opacity)
    }
}
