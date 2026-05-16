package com.openburnbar.ui.components

import androidx.annotation.DrawableRes
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Bolt
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.hermes.AssistantRuntimeID
import com.openburnbar.data.models.AgentProvider
import com.openburnbar.data.models.LLMModelBrand
import com.openburnbar.data.models.logoRes
import com.openburnbar.ui.theme.AuroraColors

/**
 * Universal logo renderer for AI providers / models. Loads the bundled brand
 * PNG when available, falls back to a brand-tinted circle with initials (or a
 * generic glyph for `unknown`). Mirrors iOS `ProviderLogoView`.
 *
 * Two entry points:
 *   • [ProviderLogo] — for [AgentProvider] (the coding agent)
 *   • [ModelLogo]    — for [LLMModelBrand] (the model vendor)
 *
 * Both share the iOS-style continuous corner radius (~22% of size) when
 * `shape` is left as `null`, so the logo reads as a rounded squircle just like
 * SwiftUI's `RoundedRectangle(cornerRadius: size*0.2237, style: .continuous)`.
 */
@Composable
fun ProviderLogo(
    provider: AgentProvider,
    size: Dp = 24.dp,
    modifier: Modifier = Modifier,
    circular: Boolean = false
) {
    BundledLogo(
        resId = provider.logoRes,
        fallbackInitials = provider.displayName.take(2).uppercase(),
        fallbackColors = listOf(Color(provider.brandColor), Color(provider.accentColor)),
        size = size,
        circular = circular,
        modifier = modifier
    )
}

// Runtime-aware overload. Built-in runtimes (Hermes / Pi / Codex / Claude /
// OpenClaw) have a one-to-one drawable mapping owned by the `ProviderLogo`
// object in ProviderLogoView.kt — this composable wraps that drawable in
// the same white squircle every other ProviderLogo call uses, so the runtime
// pill / chat hero render with consistent chrome regardless of whether the
// caller hands us an `AgentProvider` or an `AssistantRuntimeID`.
@Composable
fun ProviderLogo(
    runtime: AssistantRuntimeID,
    size: Dp = 24.dp,
    modifier: Modifier = Modifier,
    circular: Boolean = false
) {
    BundledLogo(
        resId = ProviderLogo.drawableFor(runtime),
        fallbackInitials = runtime.displayName.take(2).uppercase(),
        fallbackColors = listOf(Color.Black, Color.DarkGray),
        size = size,
        circular = circular,
        modifier = modifier
    )
}

@Composable
fun ModelLogo(
    brand: LLMModelBrand,
    size: Dp = 24.dp,
    modifier: Modifier = Modifier,
    circular: Boolean = false
) {
    val accent = Color(brand.emblemColor)
    BundledLogo(
        resId = brand.logoRes,
        fallbackInitials = brand.displayName.take(2).uppercase(),
        fallbackColors = listOf(accent, accent.copy(alpha = 0.6f)),
        size = size,
        circular = circular,
        modifier = modifier
    )
}

@Composable
fun ModelLogo(
    modelKey: String,
    size: Dp = 24.dp,
    modifier: Modifier = Modifier,
    circular: Boolean = false
) = ModelLogo(LLMModelBrand.infer(modelKey), size, modifier, circular)

@Composable
private fun BundledLogo(
    @DrawableRes resId: Int,
    fallbackInitials: String,
    fallbackColors: List<Color>,
    size: Dp,
    circular: Boolean,
    modifier: Modifier
) {
    val shape = if (circular) CircleShape else RoundedCornerShape(size * 0.2237f)
    Box(
        modifier = modifier
            .size(size)
            .clip(shape)
            .background(Color.White)
            .border(0.5.dp, Color.Black.copy(alpha = 0.08f), shape),
        contentAlignment = Alignment.Center
    ) {
        if (resId != 0) {
            Image(
                painter = painterResource(id = resId),
                contentDescription = null,
                modifier = Modifier
                    .size(size)
                    .padding(size * 0.12f),
                contentScale = ContentScale.Fit
            )
        } else if (fallbackInitials.isNotBlank()) {
            Text(
                text = fallbackInitials,
                color = fallbackColors.firstOrNull() ?: Color.Black,
                fontWeight = FontWeight.SemiBold,
                fontSize = (size.value * 0.42f).sp
            )
        } else {
            Icon(
                imageVector = Icons.Outlined.Bolt,
                contentDescription = null,
                tint = fallbackColors.firstOrNull() ?: Color.Black,
                modifier = Modifier.size(size * 0.55f)
            )
        }
    }
}

/**
 * Provider avatar with a soft brand-tinted halo — drop-in replacement for the
 * older `ProviderAuroraAvatar` / `ProviderAvatar` text-circle pattern, now
 * showing the actual brand PNG when one is available.
 */
@Composable
fun ProviderLogoWithHalo(
    provider: AgentProvider,
    size: Dp = 48.dp,
    haloSize: Dp = 8.dp,
    modifier: Modifier = Modifier
) {
    Box(contentAlignment = Alignment.Center, modifier = modifier.size(size + haloSize * 2)) {
        Box(
            modifier = Modifier
                .size(size + haloSize)
                .clip(CircleShape)
                .background(Color.White.copy(alpha = 0.86f))
        )
        ProviderLogo(provider = provider, size = size, circular = true)
    }
}

/** Shorthand for the most common avatar usage — circular logo with subtle halo. */
@Composable
fun ProviderAvatar(
    providerKey: String,
    size: Int = 48,
    modifier: Modifier = Modifier
) {
    val provider = AgentProvider.fromKey(providerKey)
    if (provider != null) {
        ProviderLogoWithHalo(
            provider = provider,
            size = size.dp,
            modifier = modifier
        )
    } else {
        // Unknown provider — render the generic fallback circle.
        Box(
            modifier = modifier
                .size(size.dp)
                .clip(CircleShape)
                .background(
                    Brush.linearGradient(
                        listOf(AuroraColors.whimsy, AuroraColors.whimsy.copy(alpha = 0.6f))
                    )
                ),
            contentAlignment = Alignment.Center
        ) {
            Text(text = "?", color = Color.White, fontWeight = FontWeight.Bold)
        }
    }
}
