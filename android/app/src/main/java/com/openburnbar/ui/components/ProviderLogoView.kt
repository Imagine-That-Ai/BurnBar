// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.components

import androidx.annotation.DrawableRes
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.openburnbar.R
import com.openburnbar.data.hermes.AssistantRuntimeID
import com.openburnbar.data.hermes.HermesSubProvider
import com.openburnbar.data.models.AgentProvider
import com.openburnbar.data.square.AgentIdentity

// ── Provider / Agent / Model Logos (Android) ──
//
// Parity with iOS `ProviderLogoView` / `ProviderAvatar`. 40 logos ported
// from `Assets.xcassets/*Logo.imageset/*.png` into `res/drawable-nodpi/`
// (density-neutral, so BitmapFactory never density-upscales the bitmaps).
// This file owns the mapping from a domain identifier (an `AgentProvider`
// enum, an `AssistantRuntimeID`, or a raw model/runtime token) to its
// drawable resource, and renders the logo at a consistent size + chrome.

object ProviderLogo {
    // / Asset for the well-known agent providers we render across the app.
    @DrawableRes
    fun drawableFor(provider: AgentProvider): Int = when (provider) {
        AgentProvider.FACTORY -> R.drawable.factory_logo
        AgentProvider.CLAUDE_CODE -> R.drawable.logo_claude_code
        AgentProvider.COPILOT -> R.drawable.logo_copilot
        AgentProvider.AIDER -> R.drawable.aider_logo
        AgentProvider.CURSOR -> R.drawable.logo_cursor
        AgentProvider.OPEN_AI -> R.drawable.logo_open_ai
        AgentProvider.DEEP_SEEK -> R.drawable.logo_deep_seek
        AgentProvider.CODEX -> R.drawable.logo_codex
        AgentProvider.OPENCODE -> R.drawable.open_code_logo
        AgentProvider.ZAI -> R.drawable.logo_zai
        AgentProvider.MINIMAX -> R.drawable.logo_mini_max
        AgentProvider.KIMI -> R.drawable.kimi_logo
        AgentProvider.CLINE -> R.drawable.logo_cline
        AgentProvider.KILO_CODE -> R.drawable.kilo_code_logo
        AgentProvider.ROO_CODE -> R.drawable.roo_code_logo
        AgentProvider.FORGE_DEV -> R.drawable.logo_forge
        AgentProvider.AUGMENT -> R.drawable.augment_logo
        AgentProvider.HERMES -> R.drawable.logo_hermes
        AgentProvider.PI_AGENT -> R.drawable.pi_agent_logo
        AgentProvider.GEMINI_CLI -> R.drawable.logo_gemini_cli
        AgentProvider.GOOSE -> R.drawable.goose_logo
        AgentProvider.OPEN_CLAW -> R.drawable.logo_openclaw
        AgentProvider.OLLAMA -> R.drawable.logo_ollama
        AgentProvider.WINDSURF -> R.drawable.logo_windsurf
        AgentProvider.WARP -> R.drawable.logo_warp
        AgentProvider.XAI -> R.drawable.logo_grok
        AgentProvider.ANTIGRAVITY -> R.drawable.logo_antigravity
        AgentProvider.MIMO -> R.drawable.mimo_logo
    }

    // / Asset for an `AssistantRuntimeID`. Maps the 5 runtimes to their
    // / closest brand logo so the runtime tile reads as the agent, not a
    // / generic glyph.
    @DrawableRes
    fun drawableFor(runtime: AssistantRuntimeID): Int = when (runtime) {
        AssistantRuntimeID.HERMES -> R.drawable.logo_hermes
        AssistantRuntimeID.PI -> R.drawable.pi_runtime_glyph
        AssistantRuntimeID.CODEX -> R.drawable.logo_codex
        AssistantRuntimeID.CLAUDE -> R.drawable.logo_claude_code
        AssistantRuntimeID.OPEN_CLAW -> R.drawable.logo_openclaw
        AssistantRuntimeID.DROID -> R.drawable.factory_logo
        AssistantRuntimeID.FORGE -> R.drawable.logo_forge
        AssistantRuntimeID.ANTIGRAVITY -> R.drawable.logo_antigravity
        AssistantRuntimeID.GROK -> R.drawable.logo_grok
        AssistantRuntimeID.CURSOR_AGENT -> R.drawable.logo_cursor
    }

    // / Asset for a `HermesSubProvider`. Maps the sub-providers to their
    // / brand logos.
    @DrawableRes
    fun drawableFor(subProvider: HermesSubProvider): Int = when (subProvider) {
        HermesSubProvider.CODEX -> R.drawable.logo_codex
        HermesSubProvider.CLAUDE -> R.drawable.logo_claude_code
        HermesSubProvider.ZAI -> R.drawable.logo_zai
        HermesSubProvider.KIMI -> R.drawable.kimi_logo
        HermesSubProvider.MINIMAX -> R.drawable.logo_mini_max
        HermesSubProvider.OLLAMA -> R.drawable.logo_ollama
    }

    // / Map a raw model/runtime token (e.g. "claude-3-5-sonnet", "gpt-4o",
    // / "gemini-2.0-flash") to the most specific brand logo we can match.
    // / Mirrors `LLMModelBrand` on iOS.
    @DrawableRes
    fun drawableForModelToken(token: String): Int = drawableForModelTokenKey(token.lowercase())

    // / Strongest lookup — uses the full `AgentIdentity` so we never lose
    // / the `runtimeID` (set for every built-in) to URI-string roundtripping.
    @DrawableRes
    fun drawableForIdentity(identity: AgentIdentity): Int {
        val providerFromId = AgentProvider.fromKey(identity.id)
        val providerFromName = AgentProvider.fromKey(identity.displayName)
        return when {
            identity.id.startsWith(AgentIdentity.PAIRED_MAC_URI_PREFIX) -> R.drawable.paired_mac_logo
            identity.runtimeID != null -> drawableFor(identity.runtimeID)
            providerFromId != null -> drawableFor(providerFromId)
            providerFromName != null -> drawableFor(providerFromName)
            else -> drawableForAnyIdentifier(identity.id.ifBlank { identity.displayName })
        }
    }

    // / Best-effort logo for any free-form identifier (key, display name,
    // / model token). Resolves built-in agent URIs (`agent://burnbar/{token}`)
    // / directly against the runtime table first, then falls through to
    // / provider keys, then to model-token substring matching, then to the
    // / Hermes mark.
    @DrawableRes
    fun drawableForAnyIdentifier(identifier: String?): Int {
        if (identifier.isNullOrBlank()) return R.drawable.logo_hermes
        if (identifier.startsWith(AgentIdentity.PAIRED_MAC_URI_PREFIX)) return R.drawable.paired_mac_logo

        val builtInPrefix = "agent://burnbar/"
        val builtInRuntime =
            if (identifier.startsWith(builtInPrefix)) {
                val token = identifier.removePrefix(builtInPrefix)
                AssistantRuntimeID.entries.firstOrNull { it.token == token }
            } else {
                null
            }
        val bareRuntime = AssistantRuntimeID.entries.firstOrNull { it.token == identifier.lowercase() }
        val provider = AgentProvider.fromKey(identifier)
        return when {
            builtInRuntime != null -> drawableFor(builtInRuntime)
            bareRuntime != null -> drawableFor(bareRuntime)
            provider != null -> drawableFor(provider)
            else -> drawableForModelToken(identifier)
        }
    }
}

// MARK: - Rendering

enum class ProviderLogoStyle {
    Flat, // raw logo, no chrome
    Disc, // logo on a tinted circle
    Tile, // logo on a rounded-square brand tile (pinned-grid style)
}

@Composable
fun ProviderLogoView(
    @DrawableRes drawableRes: Int,
    size: Dp = 36.dp,
    style: ProviderLogoStyle = ProviderLogoStyle.Flat,
    tintBackground: Color? = null,
    modifier: Modifier = Modifier,
) {
    val padding =
        when (style) {
            ProviderLogoStyle.Flat -> 0.dp
            ProviderLogoStyle.Disc, ProviderLogoStyle.Tile -> size * 0.18f
        }

    Box(
        modifier =
        modifier
            .size(size)
            .then(
                when (style) {
                    ProviderLogoStyle.Flat -> Modifier
                    ProviderLogoStyle.Disc ->
                        Modifier
                            .clip(CircleShape)
                            .background(tintBackground ?: Color.White.copy(alpha = 0.10f))
                            .border(0.6.dp, Color.White.copy(alpha = 0.18f), CircleShape)
                    ProviderLogoStyle.Tile ->
                        Modifier
                            .clip(RoundedCornerShape(size * 0.24f))
                            .background(tintBackground ?: Color.White.copy(alpha = 0.08f))
                            .border(0.6.dp, Color.White.copy(alpha = 0.18f), RoundedCornerShape(size * 0.24f))
                },
            ),
        contentAlignment = Alignment.Center,
    ) {
        Image(
            painter = painterResource(id = drawableRes),
            contentDescription = null,
            contentScale = ContentScale.Fit,
            modifier =
            Modifier
                .size(size - padding * 2),
        )
    }
}

@Composable
fun ProviderLogoView(provider: AgentProvider, size: Dp = 36.dp, style: ProviderLogoStyle = ProviderLogoStyle.Disc, modifier: Modifier = Modifier) =
    ProviderLogoView(
        drawableRes = ProviderLogo.drawableFor(provider),
        size = size,
        style = style,
        tintBackground = Color(provider.brandColor).copy(alpha = 0.12f),
        modifier = modifier,
    )

@Composable
fun ProviderLogoView(runtime: AssistantRuntimeID, size: Dp = 36.dp, style: ProviderLogoStyle = ProviderLogoStyle.Disc, modifier: Modifier = Modifier) =
    ProviderLogoView(
        drawableRes = ProviderLogo.drawableFor(runtime),
        size = size,
        style = style,
        modifier = modifier,
    )

// ── BurnBar Agent Avatar ──
//
// The single component every Hermes Square surface should call to render
// an agent's brand mark. Takes the full `AgentIdentity` so we never lose
// `runtimeID` to string parsing. Renders a flat PNG on a brand-tinted
// circular disc with a thin brand-colored ring — same treatment iOS uses,
// no double-chrome.

@Composable
fun BurnBarAgentAvatar(identity: AgentIdentity, size: Dp = 40.dp, showRing: Boolean = true, modifier: Modifier = Modifier) {
    val brandColor =
        remember(identity.paletteHex) {
            runCatching {
                val cleaned = identity.paletteHex.trim().removePrefix("#")
                val rgb = cleaned.toLong(radix = 16)
                Color(0xFF000000L or rgb)
            }.getOrElse { Color.White }
        }
    val drawableRes =
        remember(identity.id, identity.runtimeID, identity.displayName) {
            ProviderLogo.drawableForIdentity(identity)
        }

    Box(
        modifier = modifier.size(size),
        contentAlignment = Alignment.Center,
    ) {
        Box(
            modifier =
            Modifier
                .size(size)
                .clip(CircleShape)
                .background(brandColor.copy(alpha = 0.14f))
                .then(
                    if (showRing) {
                        Modifier.border(
                            width = 0.8.dp,
                            color = brandColor.copy(alpha = 0.55f),
                            shape = CircleShape,
                        )
                    } else {
                        Modifier
                    },
                ),
        )
        Image(
            painter = painterResource(id = drawableRes),
            contentDescription = "${identity.displayName} logo",
            contentScale = ContentScale.Fit,
            modifier = Modifier.size(size * 0.74f),
        )
    }
}
