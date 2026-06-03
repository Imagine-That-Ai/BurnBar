@file:Suppress("MagicNumber")
// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.settings

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.NavigateNext
import androidx.compose.material.icons.automirrored.filled.Article
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.Wallpaper
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.hapticfeedback.HapticFeedback
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.R
import com.openburnbar.data.models.AgentProvider
import com.openburnbar.ui.components.AuroraSettingsToggle
import com.openburnbar.ui.components.ProviderLogo
import com.openburnbar.ui.components.WebsiteBackground
import com.openburnbar.ui.theme.AppAppearance
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraRadius
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraType
import com.openburnbar.ui.theme.UIMode

internal object SettingsRootScreenThemeSections

@Composable
internal fun ThemePrefsDivider() {
    Spacer(
        modifier = Modifier
            .fillMaxWidth()
            .height(1.dp)
            .background(MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.4f))
    )
}

internal data class ThemePrefsHaloToggleModel(
    val highlighted: Boolean,
    val icon: ImageVector,
    val label: String,
    val subtitle: String,
    val checked: Boolean,
    val tint: Color,
)

internal data class ThemePrefsHaloToggleCallbacks(
    val onCheckedChange: (Boolean) -> Unit,
    val haptic: HapticFeedback,
)

@Composable
internal fun ThemePrefsHaloToggle(
    model: ThemePrefsHaloToggleModel,
    callbacks: ThemePrefsHaloToggleCallbacks,
) {
    val haloColor by animateColorAsState(
        targetValue = if (model.highlighted) Color(0xFFFFA800).copy(alpha = 0.18f) else Color.Transparent,
        animationSpec = tween(durationMillis = 350),
        label = "theme-prefs-halo"
    )
    Surface(color = haloColor, shape = RoundedCornerShape(AuroraRadius.md.dp)) {
        AuroraSettingsToggle(
            icon = model.icon,
            label = model.label,
            subtitle = model.subtitle,
            checked = model.checked,
            onCheckedChange = {
                callbacks.onCheckedChange(it)
                callbacks.haptic.performHapticFeedback(HapticFeedbackType.LongPress)
            },
            tint = model.tint,
        )
    }
}

@Composable
internal fun ThemePrefsTopBar(onBack: () -> Unit, useWebsiteBackground: Boolean) {
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
        IconButton(onClick = onBack) {
            Icon(
                imageVector = Icons.AutoMirrored.Filled.ArrowBack,
                contentDescription = "Back",
                tint = if (useWebsiteBackground) Color.White else MaterialTheme.colorScheme.onSurface
            )
        }
        Spacer(modifier = Modifier.width(AuroraSpacing.sm.dp))
        Text(
            text = "Theme & SOTA UX",
            style = AuroraType.displayLarge,
            color = if (useWebsiteBackground) Color.White else MaterialTheme.colorScheme.onSurface
        )
    }
}

@Composable
internal fun ThemePrefsToggleSection(
    router: SettingsRouter,
    haptic: HapticFeedback,
    usePremiumSOTAUX: Boolean,
    backgroundStyle: BackgroundStyle,
    enableSwarmSparkles: Boolean,
    excludeBrandShapes: Boolean,
) {
    ThemePrefsPrimaryToggles(router, haptic, usePremiumSOTAUX, backgroundStyle, enableSwarmSparkles)
    ThemePrefsDivider()
    AuroraSettingsToggle(
        icon = Icons.Filled.AutoAwesome,
        label = "Exclude Brand Shapes",
        subtitle = "Skip BurnBar, money, code symbols, rings, and router flow cycles, leaving only AI providers",
        checked = excludeBrandShapes,
        onCheckedChange = {
            GlobalVisualSettings.setExcludeBrandShapesFromSwarm(it)
            haptic.performHapticFeedback(HapticFeedbackType.LongPress)
        },
        tint = Color.White,
    )
}

@Composable
internal fun ThemePrefsPrimaryToggles(
    router: SettingsRouter,
    haptic: HapticFeedback,
    usePremiumSOTAUX: Boolean,
    backgroundStyle: BackgroundStyle,
    enableSwarmSparkles: Boolean,
) {
    ThemePrefsHaloToggle(
        model = ThemePrefsHaloToggleModel(
            highlighted = router.highlightedAnchor == SettingsAnchor.USE_PREMIUM_SOTA_UX,
            icon = Icons.Filled.AutoAwesome,
            label = "Premium SOTA UX",
            subtitle = "Cinematic tactile spring physics and high-fidelity haptics",
            checked = usePremiumSOTAUX,
            tint = AuroraColors.blaze,
        ),
        callbacks = ThemePrefsHaloToggleCallbacks(onCheckedChange = { GlobalVisualSettings.setPremiumSOTAUX(it) }, haptic = haptic),
    )
    ThemePrefsDivider()
    ThemePrefsBackgroundStyleSelector(
        highlighted = router.highlightedAnchor == SettingsAnchor.USE_WEBSITE_BACKGROUND,
        useWebsiteBackground = backgroundStyle.usesCustomBackdrop,
        backgroundStyle = backgroundStyle,
        haptic = haptic,
    )
    ThemePrefsDivider()
    ThemePrefsHaloToggle(
        model = ThemePrefsHaloToggleModel(
            highlighted = router.highlightedAnchor == SettingsAnchor.ENABLE_SWARM_SPARKLES,
            icon = Icons.Filled.AutoAwesome,
            label = "Enable Screensaver Sparkles",
            subtitle = "Render an elegant, gentle twinkling shimmer on particles while they hold a reformed shape.",
            checked = enableSwarmSparkles,
            tint = Color.White,
        ),
        callbacks = ThemePrefsHaloToggleCallbacks(onCheckedChange = { GlobalVisualSettings.setSwarmSparkles(it) }, haptic = haptic),
    )
}

/** Per-style metadata for the three-way background picker. */
private data class BackgroundStyleOption(
    val style: BackgroundStyle,
    val subtitle: String,
)

private val backgroundStyleOptions =
    listOf(
        BackgroundStyleOption(BackgroundStyle.AURORA, "Soft drifting gradient orbs and ember ribbons"),
        BackgroundStyleOption(BackgroundStyle.SWARM, "Active, reconverging token-ember swarms from burnbar.ai"),
        BackgroundStyleOption(BackgroundStyle.DOT_CONSTELLATION, "Calm field: one crest or provider logo resolves, shimmers, and dissolves"),
    )

/**
 * Three-way background style picker (Aurora / Swarm / Constellation). Replaces the
 * old single Swarm Background toggle; the legacy `useWebsiteBackground` flag stays
 * derived from the chosen style so every other screen keeps working unchanged.
 */
@Composable
internal fun ThemePrefsBackgroundStyleSelector(
    highlighted: Boolean,
    useWebsiteBackground: Boolean,
    backgroundStyle: BackgroundStyle,
    haptic: HapticFeedback,
) {
    val haloColor by animateColorAsState(
        targetValue = if (highlighted) Color(0xFFFFA800).copy(alpha = 0.18f) else Color.Transparent,
        animationSpec = tween(durationMillis = 350),
        label = "background-style-halo"
    )
    Surface(color = haloColor, shape = RoundedCornerShape(AuroraRadius.md.dp)) {
        Column(modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Icon(Icons.Filled.Wallpaper, contentDescription = null, modifier = Modifier.size(22.dp), tint = AuroraColors.hermesMercury)
                Text(
                    "Background Style",
                    fontWeight = FontWeight.Bold,
                    color = if (useWebsiteBackground) Color.White else MaterialTheme.colorScheme.onSurface,
                )
            }
            backgroundStyleOptions.forEach { option ->
                ThemePrefsBackgroundStyleCard(
                    option = option,
                    selected = backgroundStyle == option.style,
                    useWebsiteBackground = useWebsiteBackground,
                    haptic = haptic,
                )
            }
        }
    }
}

@Composable
private fun ThemePrefsBackgroundStyleCard(
    option: BackgroundStyleOption,
    selected: Boolean,
    useWebsiteBackground: Boolean,
    haptic: HapticFeedback,
) {
    val primaryColor = MaterialTheme.colorScheme.primary
    Surface(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(AuroraRadius.md.dp),
        color = if (selected) primaryColor.copy(alpha = 0.12f) else MaterialTheme.colorScheme.surface.copy(alpha = 0.4f),
        border =
            if (selected) {
                androidx.compose.foundation.BorderStroke(2.dp, primaryColor)
            } else {
                androidx.compose.foundation.BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.3f))
            },
        onClick = {
            GlobalVisualSettings.setBackgroundStyle(option.style)
            haptic.performHapticFeedback(HapticFeedbackType.LongPress)
        }
    ) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    option.style.displayName,
                    fontWeight = FontWeight.Bold,
                    fontSize = 15.sp,
                    color = if (useWebsiteBackground) Color.White else MaterialTheme.colorScheme.onSurface,
                )
                Spacer(modifier = Modifier.height(2.dp))
                Text(
                    option.subtitle,
                    fontSize = 12.sp,
                    lineHeight = 15.sp,
                    color = if (useWebsiteBackground) Color.White.copy(alpha = 0.7f) else MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            if (selected) {
                Surface(modifier = Modifier.size(10.dp), shape = CircleShape, color = primaryColor) {}
            }
        }
    }
}

@Composable
internal fun ThemePrefsWallpaperRow(router: SettingsRouter, useWebsiteBackground: Boolean) {
    ThemePrefsDivider()
    Surface(
        onClick = { router.page = SettingsPageRoute.WALLPAPER_GENERATOR },
        shape = RoundedCornerShape(AuroraRadius.md.dp),
        color = Color.Transparent
    ) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            Surface(shape = RoundedCornerShape(12.dp), color = AuroraColors.ember.copy(alpha = 0.15f)) {
                Box(modifier = Modifier.size(42.dp), contentAlignment = Alignment.Center) {
                    Icon(Icons.Filled.Wallpaper, contentDescription = null, modifier = Modifier.size(24.dp), tint = AuroraColors.ember)
                }
            }
            Column(modifier = Modifier.weight(1f)) {
                Text("Generate Wallpaper", fontWeight = FontWeight.Bold, color = if (useWebsiteBackground) Color.White else MaterialTheme.colorScheme.onSurface)
                Text(
                    "Create a swarm wallpaper colored by your AI usage",
                    fontSize = 13.sp,
                    color = if (useWebsiteBackground) Color.White.copy(alpha = 0.7f) else MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
            Icon(
                Icons.AutoMirrored.Filled.NavigateNext,
                contentDescription = "Open",
                tint = if (useWebsiteBackground) Color.White.copy(alpha = 0.5f) else MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.5f)
            )
        }
    }
}

@Composable
internal fun ThemePrefsUIModeSelector(useWebsiteBackground: Boolean, haptic: HapticFeedback) {
    ThemePrefsDivider()
    val activeUiMode by rememberUIMode()
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Text(
            text = "UI Mode",
            fontWeight = FontWeight.Bold,
            color = if (useWebsiteBackground) Color.White else MaterialTheme.colorScheme.onSurface
        )
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp), modifier = Modifier.fillMaxWidth()) {
            UIMode.entries.forEach { mode ->
                ThemePrefsUIModeCard(mode, activeUiMode, useWebsiteBackground, haptic)
            }
        }
    }
}

@Composable
internal fun RowScope.ThemePrefsUIModeCard(
    mode: UIMode,
    activeUiMode: UIMode,
    useWebsiteBackground: Boolean,
    haptic: HapticFeedback,
) {
    val isSelected = activeUiMode == mode
    val primaryColor = MaterialTheme.colorScheme.primary
    Surface(
        modifier = Modifier.weight(1f).height(115.dp),
        shape = RoundedCornerShape(AuroraRadius.md.dp),
        color = if (isSelected) primaryColor.copy(alpha = 0.12f) else MaterialTheme.colorScheme.surface.copy(alpha = 0.4f),
        border =
            if (isSelected) {
                androidx.compose.foundation.BorderStroke(2.dp, primaryColor)
            } else {
                androidx.compose.foundation.BorderStroke(
                    1.dp,
                    MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.3f),
                )
            },
        onClick = {
            GlobalVisualSettingsUIMode.setUIMode(mode)
            haptic.performHapticFeedback(HapticFeedbackType.LongPress)
        }
    ) {
        Column(modifier = Modifier.fillMaxSize().padding(12.dp), verticalArrangement = Arrangement.SpaceBetween) {
            Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
                if (mode == UIMode.COOKING) {
                    Icon(painter = painterResource(id = R.drawable.ic_cooking_skillet), contentDescription = null, modifier = Modifier.size(24.dp), tint = Color.Unspecified)
                } else {
                    Icon(Icons.Filled.AutoAwesome, contentDescription = null, modifier = Modifier.size(20.dp), tint = if (isSelected) primaryColor else MaterialTheme.colorScheme.onSurfaceVariant)
                }
                if (isSelected) {
                    Surface(modifier = Modifier.size(8.dp), shape = CircleShape, color = primaryColor) {}
                }
            }
            Column {
                Text(text = mode.displayName, fontWeight = FontWeight.Bold, fontSize = 14.sp, color = if (useWebsiteBackground) Color.White else MaterialTheme.colorScheme.onSurface)
                Spacer(modifier = Modifier.height(2.dp))
                Text(text = mode.description, fontSize = 11.sp, lineHeight = 13.sp, color = if (useWebsiteBackground) Color.White.copy(alpha = 0.7f) else MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}

@Composable
internal fun ThemePrefsAppearanceSelector(useWebsiteBackground: Boolean, haptic: HapticFeedback) {
    ThemePrefsDivider()
    val activeAppearance by rememberAppearance()
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Text(
            text = "App Skin",
            fontWeight = FontWeight.Bold,
            color = if (useWebsiteBackground) Color.White else MaterialTheme.colorScheme.onSurface
        )
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp), modifier = Modifier.fillMaxWidth()) {
            AppAppearance.entries.forEach { appearance ->
                ThemePrefsAppearanceCard(appearance, activeAppearance, useWebsiteBackground, haptic)
            }
        }
    }
}

@Composable
internal fun RowScope.ThemePrefsAppearanceCard(
    appearance: AppAppearance,
    activeAppearance: AppAppearance,
    useWebsiteBackground: Boolean,
    haptic: HapticFeedback,
) {
    val isSelected = activeAppearance == appearance
    val primaryColor = MaterialTheme.colorScheme.primary
    Surface(
        modifier = Modifier.weight(1f).height(115.dp),
        shape = RoundedCornerShape(AuroraRadius.md.dp),
        color = if (isSelected) primaryColor.copy(alpha = 0.12f) else MaterialTheme.colorScheme.surface.copy(alpha = 0.4f),
        border =
            if (isSelected) {
                androidx.compose.foundation.BorderStroke(2.dp, primaryColor)
            } else {
                androidx.compose.foundation.BorderStroke(
                    1.dp,
                    MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.3f),
                )
            },
        onClick = {
            GlobalVisualSettingsAppearance.setAppearance(appearance)
            haptic.performHapticFeedback(HapticFeedbackType.LongPress)
        }
    ) {
        Column(modifier = Modifier.fillMaxSize().padding(12.dp), verticalArrangement = Arrangement.SpaceBetween) {
            Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    imageVector = if (appearance == AppAppearance.EDITORIAL) Icons.AutoMirrored.Filled.Article else Icons.Filled.AutoAwesome,
                    contentDescription = null,
                    modifier = Modifier.size(20.dp),
                    tint = if (isSelected) primaryColor else MaterialTheme.colorScheme.onSurfaceVariant,
                )
                if (isSelected) {
                    Surface(modifier = Modifier.size(8.dp), shape = CircleShape, color = primaryColor) {}
                }
            }
            Column {
                Text(text = appearance.displayName, fontWeight = FontWeight.Bold, fontSize = 14.sp, color = if (useWebsiteBackground) Color.White else MaterialTheme.colorScheme.onSurface)
                Spacer(modifier = Modifier.height(2.dp))
                Text(text = appearance.description, fontSize = 11.sp, lineHeight = 13.sp, color = if (useWebsiteBackground) Color.White.copy(alpha = 0.7f) else MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}

@Composable
internal fun ThemePrefsColorPaletteSection(useWebsiteBackground: Boolean) {
    ThemePrefsDivider()
    val themePalette by rememberThemePalette()
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text("Color Palette", fontWeight = FontWeight.Bold, color = if (useWebsiteBackground) Color.White else MaterialTheme.colorScheme.onSurface)
        androidx.compose.foundation.lazy.LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            itemsIndexed(AppThemePalette.entries) { _, palette ->
                val isSelected = themePalette == palette.name
                Surface(
                    color = if (isSelected) AuroraColors.amber.copy(alpha = 0.3f) else Color.Transparent,
                    shape = RoundedCornerShape(16.dp),
                    onClick = { GlobalVisualSettingsPalette.setThemePalette(palette.name) }
                ) {
                    Text(
                        text = palette.displayName,
                        modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp),
                        color = if (useWebsiteBackground) Color.White else MaterialTheme.colorScheme.onSurface
                    )
                }
            }
        }
    }
}

@Composable
internal fun ThemePrefsProviderGlyphsSection(
    useWebsiteBackground: Boolean,
    customizeProviderGlyphs: Boolean,
    onCustomizeProviderGlyphsChange: (Boolean) -> Unit,
    providerGlyphs: Set<AgentProvider>,
) {
    ThemePrefsDivider()
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        ThemePrefsProviderGlyphsExpandHeader(
            useWebsiteBackground = useWebsiteBackground,
            customizeProviderGlyphs = customizeProviderGlyphs,
            onCustomizeProviderGlyphsChange = onCustomizeProviderGlyphsChange,
            providerGlyphs = providerGlyphs,
        )
        if (customizeProviderGlyphs) {
            ThemePrefsProviderGlyphCustomizer(useWebsiteBackground, providerGlyphs)
        }
    }
}

@Composable
private fun ThemePrefsProviderGlyphsExpandHeader(
    useWebsiteBackground: Boolean,
    customizeProviderGlyphs: Boolean,
    onCustomizeProviderGlyphsChange: (Boolean) -> Unit,
    providerGlyphs: Set<AgentProvider>,
) {
    Surface(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(AuroraRadius.lg.dp),
        color = MaterialTheme.colorScheme.surface.copy(alpha = if (useWebsiteBackground) 0.42f else 0.76f),
        onClick = { onCustomizeProviderGlyphsChange(!customizeProviderGlyphs) }
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp)
        ) {
            SettingsProviderLogoStack(
                providers = providerGlyphsPreview(providerGlyphs),
                maxVisible = 4
            )
            ThemePrefsProviderGlyphsHeaderText(useWebsiteBackground, providerGlyphs)
            ThemePrefsProviderGlyphsExpandChevron(customizeProviderGlyphs, useWebsiteBackground)
        }
    }
}

@Composable
private fun RowScope.ThemePrefsProviderGlyphsHeaderText(
    useWebsiteBackground: Boolean,
    providerGlyphs: Set<AgentProvider>,
) {
    Column(modifier = Modifier.weight(1f)) {
        Text(
            "Provider glyphs",
            fontWeight = FontWeight.SemiBold,
            color = if (useWebsiteBackground) Color.White else MaterialTheme.colorScheme.onSurface
        )
        Text(
            providerGlyphSummary(providerGlyphs),
            fontSize = 12.sp,
            color = if (useWebsiteBackground) Color.White.copy(alpha = 0.68f) else MaterialTheme.colorScheme.onSurfaceVariant
        )
    }
}

@Composable
private fun ThemePrefsProviderGlyphsExpandChevron(
    customizeProviderGlyphs: Boolean,
    useWebsiteBackground: Boolean,
) {
    val rotation by animateFloatAsState(
        targetValue = if (customizeProviderGlyphs) 180f else 0f,
        animationSpec = tween(durationMillis = 200),
        label = "provider-glyph-chevron"
    )
    Icon(
        imageVector = Icons.Filled.KeyboardArrowDown,
        contentDescription = if (customizeProviderGlyphs) "Collapse" else "Expand",
        modifier = Modifier.size(22.dp).graphicsLayer(rotationZ = rotation),
        tint = if (useWebsiteBackground) Color.White.copy(alpha = 0.74f) else MaterialTheme.colorScheme.onSurfaceVariant
    )
}

@Composable
internal fun ThemePrefsProviderGlyphCustomizer(useWebsiteBackground: Boolean, providerGlyphs: Set<AgentProvider>) {
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        ProviderGlyphQuickAction(
            title = "All",
            active = providerGlyphs.size == AgentProvider.swarmGlyphProviders.size,
            onClick = { GlobalVisualSettings.setProviderGlyphs(AgentProvider.swarmGlyphProviders.toSet()) }
        )
        ProviderGlyphQuickAction(
            title = "None",
            active = providerGlyphs.isEmpty(),
            onClick = { GlobalVisualSettings.setProviderGlyphs(emptySet()) }
        )
    }
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        AgentProvider.swarmGlyphProviders.forEach { provider ->
            val isSelected = providerGlyphs.contains(provider)
            ProviderGlyphSelectionRow(
                provider = provider,
                selected = isSelected,
                highContrastText = useWebsiteBackground,
            ) {
                val next = if (isSelected) providerGlyphs - provider else providerGlyphs + provider
                GlobalVisualSettings.setProviderGlyphs(next)
            }
        }
    }
}

@Composable
internal fun ThemePrefsTabLayoutNote(useWebsiteBackground: Boolean) {
    ThemePrefsDivider()
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text("Tab Layout", fontWeight = FontWeight.Bold, color = if (useWebsiteBackground) Color.White else MaterialTheme.colorScheme.onSurface)
        Text(
            "Android Tab arrangement customized via DataStore.",
            fontSize = 12.sp,
            color = if (useWebsiteBackground) Color.White.copy(alpha = 0.7f) else MaterialTheme.colorScheme.onSurfaceVariant
        )
    }
}

@Composable
internal fun ThemePrefsHighlightEffect(router: SettingsRouter) {
    val pending = router.pendingAnchor
    LaunchedEffect(pending) {
        val isSwarmSettingsAnchor =
            pending == SettingsAnchor.USE_PREMIUM_SOTA_UX ||
                pending == SettingsAnchor.USE_WEBSITE_BACKGROUND ||
                pending == SettingsAnchor.ENABLE_SWARM_SPARKLES
        if (pending != null && isSwarmSettingsAnchor) {
            router.consumePendingAnchor(pending)
            kotlinx.coroutines.delay(1_400)
            router.clearHighlight(pending)
        }
    }
}

internal data class ThemePrefsScreenState(
    val isDark: Boolean,
    val useWebsiteBackground: Boolean,
    val backgroundStyle: BackgroundStyle,
    val haptic: HapticFeedback,
    val usePremiumSOTAUX: Boolean,
    val enableSwarmSparkles: Boolean,
    val excludeBrandShapes: Boolean,
    val customizeProviderGlyphs: Boolean,
    val onCustomizeProviderGlyphsChange: (Boolean) -> Unit,
    val providerGlyphs: Set<AgentProvider>,
)

@Composable
internal fun ThemePrefsScreenBody(
    router: SettingsRouter,
    onBack: () -> Unit,
    state: ThemePrefsScreenState,
) {
    val useWebsiteBackground = state.useWebsiteBackground
    val isDark = state.isDark
    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .background(
                if (useWebsiteBackground) Color.Transparent
                else if (isDark) AuroraColors.darkBackground
                else AuroraColors.lightBackground
            )
            .padding(horizontal = AuroraSpacing.lg.dp),
        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.md.dp)
    ) {
        Spacer(modifier = Modifier.height(AuroraSpacing.lg.dp))
        ThemePrefsTopBar(onBack = onBack, useWebsiteBackground = useWebsiteBackground)
        Spacer(modifier = Modifier.height(AuroraSpacing.sm.dp))
        Surface(
            modifier = Modifier.fillMaxWidth(),
            shape = RoundedCornerShape(AuroraRadius.lg.dp),
            color = MaterialTheme.colorScheme.surface.copy(alpha = if (useWebsiteBackground) 0.35f else 0.6f)
        ) {
            Column(modifier = Modifier.fillMaxWidth().padding(AuroraSpacing.md.dp), verticalArrangement = Arrangement.spacedBy(AuroraSpacing.md.dp)) {
                ThemePrefsToggleSection(
                    router,
                    state.haptic,
                    state.usePremiumSOTAUX,
                    state.backgroundStyle,
                    state.enableSwarmSparkles,
                    state.excludeBrandShapes,
                )
                ThemePrefsWallpaperRow(router, useWebsiteBackground)
                ThemePrefsAppearanceSelector(useWebsiteBackground, state.haptic)
                ThemePrefsUIModeSelector(useWebsiteBackground, state.haptic)
                ThemePrefsColorPaletteSection(useWebsiteBackground)
                ThemePrefsProviderGlyphsSection(
                    useWebsiteBackground,
                    state.customizeProviderGlyphs,
                    state.onCustomizeProviderGlyphsChange,
                    state.providerGlyphs,
                )
                ThemePrefsTabLayoutNote(useWebsiteBackground)
            }
        }
        Spacer(modifier = Modifier.height(48.dp))
    }
}

@Composable
fun ThemePrefsScreen(
    router: SettingsRouter,
    onBack: () -> Unit
) {
    val isDark = isSystemInDarkTheme()
    val haptic = LocalHapticFeedback.current
    val useWebsiteBackground by rememberWebsiteBackground()
    val backgroundStyle by rememberBackgroundStyle()
    val usePremiumSOTAUX by rememberPremiumSOTAUX()
    val enableSwarmSparkles by rememberSwarmSparkles()
    val excludeBrandShapes by rememberExcludeBrandShapesFromSwarm()
    var customizeProviderGlyphs by rememberSaveable { mutableStateOf(false) }
    val providerGlyphs by rememberProviderGlyphs()

    ThemePrefsHighlightEffect(router)

    Box(modifier = Modifier.fillMaxSize()) {
        if (useWebsiteBackground) WebsiteBackground(accentColor = AuroraColors.hermesMercury)
        ThemePrefsScreenBody(
            router = router,
            onBack = onBack,
            state =
            ThemePrefsScreenState(
                isDark = isDark,
                useWebsiteBackground = useWebsiteBackground,
                backgroundStyle = backgroundStyle,
                haptic = haptic,
                usePremiumSOTAUX = usePremiumSOTAUX,
                enableSwarmSparkles = enableSwarmSparkles,
                excludeBrandShapes = excludeBrandShapes,
                customizeProviderGlyphs = customizeProviderGlyphs,
                onCustomizeProviderGlyphsChange = { customizeProviderGlyphs = it },
                providerGlyphs = providerGlyphs,
            ),
        )
    }
}

internal fun providerGlyphSummary(providers: Set<AgentProvider>): String {
    val total = AgentProvider.swarmGlyphProviders.size
    val count = providers.size
    return when (count) {
        total -> "All providers selected"
        0 -> "Provider logos hidden"
        else -> "$count/$total providers selected"
    }
}

internal fun providerGlyphsPreview(providerGlyphs: Set<AgentProvider>): List<AgentProvider> =
    AgentProvider.swarmGlyphProviders.filter { providerGlyphs.contains(it) }.ifEmpty {
        AgentProvider.swarmGlyphProviders.take(4)
    }

@Composable
internal fun ProviderGlyphQuickAction(
    title: String,
    active: Boolean,
    onClick: () -> Unit,
) {
    Surface(
        shape = RoundedCornerShape(999.dp),
        color = if (active) AuroraColors.ember else MaterialTheme.colorScheme.surface.copy(alpha = 0.72f),
        onClick = onClick,
    ) {
        Text(
            text = title,
            modifier = Modifier.padding(horizontal = 14.dp, vertical = 8.dp),
            fontSize = 12.sp,
            fontWeight = FontWeight.Bold,
            color = if (active) Color.White else MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
internal fun ProviderGlyphSelectionRow(
    provider: AgentProvider,
    selected: Boolean,
    highContrastText: Boolean,
    onClick: () -> Unit,
) {
    val providerColor = Color(provider.brandColor)
    Surface(
        modifier = Modifier.fillMaxWidth(),
        color = if (selected) providerColor.copy(alpha = 0.16f) else MaterialTheme.colorScheme.surface.copy(alpha = 0.58f),
        shape = RoundedCornerShape(16.dp),
        onClick = onClick,
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 10.dp, vertical = 9.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Surface(
                shape = RoundedCornerShape(12.dp),
                color = MaterialTheme.colorScheme.surface,
            ) {
                Box(
                    modifier = Modifier
                        .size(42.dp)
                        .padding(6.dp),
                    contentAlignment = Alignment.Center,
                ) {
                    ProviderLogo(provider = provider, size = 30.dp)
                }
            }
            Text(
                text = provider.displayName,
                color = if (highContrastText) Color.White else MaterialTheme.colorScheme.onSurface,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.weight(1f),
            )
            Surface(
                shape = RoundedCornerShape(999.dp),
                color = if (selected) providerColor else MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.35f),
            ) {
                Text(
                    text = if (selected) "On" else "Off",
                    modifier = Modifier.padding(horizontal = 10.dp, vertical = 5.dp),
                    fontSize = 11.sp,
                    fontWeight = FontWeight.Bold,
                    color = if (selected) Color.White else MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}
