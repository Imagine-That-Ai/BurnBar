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
import com.openburnbar.data.models.AgentProvider
import com.openburnbar.data.square.AgentIdentity

// ── Provider / Agent / Model Logos (Android) ──
//
// Parity with iOS `ProviderLogoView` / `ProviderAvatar`. 40 logos ported
// from `Assets.xcassets/*Logo.imageset/*.png` into `res/drawable/*_logo.png`.
// This file owns the mapping from a domain identifier (an `AgentProvider`
// enum, an `AssistantRuntimeID`, or a raw model/runtime token) to its
// drawable resource, and renders the logo at a consistent size + chrome.

object ProviderLogo {

    /// Asset for the well-known agent providers we render across the app.
    @DrawableRes
    fun drawableFor(provider: AgentProvider): Int = when (provider) {
        AgentProvider.FACTORY      -> R.drawable.factory_logo
        AgentProvider.CLAUDE_CODE  -> R.drawable.claude_code_logo
        AgentProvider.COPILOT      -> R.drawable.copilot_logo
        AgentProvider.AIDER        -> R.drawable.aider_logo
        AgentProvider.CURSOR       -> R.drawable.cursor_logo
        AgentProvider.OPEN_AI      -> R.drawable.open_ai_logo
        AgentProvider.CODEX        -> R.drawable.codex_logo
        AgentProvider.OPENCODE     -> R.drawable.open_code_logo
        AgentProvider.ZAI          -> R.drawable.zai_logo
        AgentProvider.MINIMAX      -> R.drawable.mini_max_logo
        AgentProvider.KIMI         -> R.drawable.kimi_logo
        AgentProvider.CLINE        -> R.drawable.cline_logo
        AgentProvider.KILO_CODE    -> R.drawable.kilo_code_logo
        AgentProvider.ROO_CODE     -> R.drawable.roo_code_logo
        AgentProvider.FORGE_DEV    -> R.drawable.forge_logo
        AgentProvider.AUGMENT      -> R.drawable.augment_logo
        AgentProvider.HERMES       -> R.drawable.hermes_logo
        AgentProvider.GEMINI_CLI   -> R.drawable.gemini_cli_logo
        AgentProvider.GOOSE        -> R.drawable.goose_logo
        AgentProvider.OPEN_CLAW    -> R.drawable.open_claw_logo
        AgentProvider.OLLAMA       -> R.drawable.ollama_logo
        AgentProvider.WINDSURF     -> R.drawable.windsurf_logo
        AgentProvider.WARP         -> R.drawable.warp_logo
    }

    /// Asset for an `AssistantRuntimeID`. Maps the 5 runtimes to their
    /// closest brand logo so the runtime tile reads as the agent, not a
    /// generic glyph.
    @DrawableRes
    fun drawableFor(runtime: AssistantRuntimeID): Int = when (runtime) {
        AssistantRuntimeID.HERMES     -> R.drawable.hermes_logo
        AssistantRuntimeID.PI         -> R.drawable.pi_runtime_glyph
        AssistantRuntimeID.CODEX      -> R.drawable.codex_logo
        AssistantRuntimeID.CLAUDE     -> R.drawable.claude_code_logo
        AssistantRuntimeID.OPEN_CLAW  -> R.drawable.open_claw_logo
    }

    /// Map a raw model/runtime token (e.g. "claude-3-5-sonnet", "gpt-4o",
    /// "gemini-2.0-flash") to the most specific brand logo we can match.
    /// Mirrors `LLMModelBrand` on iOS.
    @DrawableRes
    fun drawableForModelToken(token: String): Int {
        val k = token.lowercase()
        return when {
            // Built-in runtimes first — these are the most precise identifiers
            // we have and they should always win over substring matching.
            "openclaw"   in k || "open_claw" in k || "open-claw" in k -> R.drawable.open_claw_logo
            // Pi as a runtime token shows up as exact "pi" / "pi-agent".
            // Restrict it to whole-token matches so "openai" / "perplexity"
            // don't fall into this bucket.
            k == "pi" || k.startsWith("pi-") || k.endsWith("/pi")     -> R.drawable.pi_runtime_glyph
            k == "hermes" || k.endsWith("/hermes")                    -> R.drawable.hermes_logo
            "claude"     in k || "anthropic" in k             -> R.drawable.anthropic_logo
            "gpt"        in k || "chatgpt"   in k             -> R.drawable.open_ai_logo
            "openai"     in k                                  -> R.drawable.open_ai_logo
            "codex"      in k                                  -> R.drawable.codex_logo
            "gemini"     in k                                  -> R.drawable.google_logo
            "google"     in k                                  -> R.drawable.google_logo
            "deepseek"   in k                                  -> R.drawable.deep_seek_logo
            "kimi"       in k || "moonshot" in k              -> R.drawable.kimi_logo
            "minimax"    in k || "abab"     in k              -> R.drawable.mini_max_logo
            "llama"      in k || "meta"     in k              -> R.drawable.meta_logo
            "mistral"    in k || "mixtral"  in k              -> R.drawable.mistral_logo
            "qwen"       in k || "qwq"      in k              -> R.drawable.qwen_logo
            "grok"       in k || "xai"      in k              -> R.drawable.grok_logo
            "cohere"     in k || "command"  in k              -> R.drawable.cohere_logo
            "perplexity" in k || "sonar"    in k              -> R.drawable.perplexity_logo
            "mlx"        in k || "apple"    in k              -> R.drawable.apple_logo
            "nova"       in k || "amazon"   in k || "bedrock" in k -> R.drawable.amazon_logo
            "alibaba"    in k || "tongyi"   in k              -> R.drawable.alibaba_logo
            "ollama"     in k                                  -> R.drawable.ollama_logo
            "z.ai"       in k || "zai"      in k || "glm" in k -> R.drawable.zai_logo
            else                                               -> R.drawable.hermes_logo
        }
    }

    /// Strongest lookup — uses the full `AgentIdentity` so we never lose
    /// the `runtimeID` (set for every built-in) to URI-string roundtripping.
    @DrawableRes
    fun drawableForIdentity(identity: AgentIdentity): Int {
        // 1. Built-in runtime — single source of truth.
        identity.runtimeID?.let { return drawableFor(it) }
        // 2. ID may be a provider URI / key.
        AgentProvider.fromKey(identity.id)?.let { return drawableFor(it) }
        // 3. Display name as a coarse fallback ("Claude Code", "OpenAI").
        AgentProvider.fromKey(identity.displayName)?.let { return drawableFor(it) }
        // 4. Model-token substring matching against id + display name.
        return drawableForAnyIdentifier(identity.id.ifBlank { identity.displayName })
    }

    /// Best-effort logo for any free-form identifier (key, display name,
    /// model token). Resolves built-in agent URIs (`agent://burnbar/{token}`)
    /// directly against the runtime table first, then falls through to
    /// provider keys, then to model-token substring matching, then to the
    /// Hermes mark.
    @DrawableRes
    fun drawableForAnyIdentifier(identifier: String?): Int {
        if (identifier.isNullOrBlank()) return R.drawable.hermes_logo

        // 1. Built-in agent URI: peel off the `agent://burnbar/` prefix and
        //    look up the runtime directly. This is what `AgentIdentity.id`
        //    looks like for HERMES / PI / CODEX / CLAUDE / OPEN_CLAW.
        val builtInPrefix = "agent://burnbar/"
        if (identifier.startsWith(builtInPrefix)) {
            val token = identifier.removePrefix(builtInPrefix)
            val runtime = AssistantRuntimeID.entries.firstOrNull { it.token == token }
            if (runtime != null) return drawableFor(runtime)
        }

        // 2. Bare runtime token (e.g. "pi", "openclaw") — catch the cases
        //    where the caller passes a token without the URI prefix.
        AssistantRuntimeID.entries.firstOrNull { it.token == identifier.lowercase() }
            ?.let { return drawableFor(it) }

        // 3. Provider key / display name match.
        AgentProvider.fromKey(identifier)?.let { return drawableFor(it) }

        // 4. Model-token substring matching.
        return drawableForModelToken(identifier)
    }
}

// MARK: - Rendering

enum class ProviderLogoStyle {
    Flat,        // raw logo, no chrome
    Disc,        // logo on a tinted circle
    Tile         // logo on a rounded-square brand tile (pinned-grid style)
}

@Composable
fun ProviderLogoView(
    @DrawableRes drawableRes: Int,
    size: Dp = 36.dp,
    style: ProviderLogoStyle = ProviderLogoStyle.Flat,
    tintBackground: Color? = null,
    modifier: Modifier = Modifier
) {
    val padding = when (style) {
        ProviderLogoStyle.Flat -> 0.dp
        ProviderLogoStyle.Disc, ProviderLogoStyle.Tile -> size * 0.18f
    }

    Box(
        modifier = modifier
            .size(size)
            .then(
                when (style) {
                    ProviderLogoStyle.Flat -> Modifier
                    ProviderLogoStyle.Disc -> Modifier
                        .clip(CircleShape)
                        .background(tintBackground ?: Color.White.copy(alpha = 0.10f))
                        .border(0.6.dp, Color.White.copy(alpha = 0.18f), CircleShape)
                    ProviderLogoStyle.Tile -> Modifier
                        .clip(RoundedCornerShape(size * 0.24f))
                        .background(tintBackground ?: Color.White.copy(alpha = 0.08f))
                        .border(0.6.dp, Color.White.copy(alpha = 0.18f), RoundedCornerShape(size * 0.24f))
                }
            ),
        contentAlignment = Alignment.Center
    ) {
        Image(
            painter = painterResource(id = drawableRes),
            contentDescription = null,
            contentScale = ContentScale.Fit,
            modifier = Modifier
                .size(size - padding * 2)
        )
    }
}

@Composable
fun ProviderLogoView(
    provider: AgentProvider,
    size: Dp = 36.dp,
    style: ProviderLogoStyle = ProviderLogoStyle.Disc,
    modifier: Modifier = Modifier
) = ProviderLogoView(
    drawableRes = ProviderLogo.drawableFor(provider),
    size = size,
    style = style,
    tintBackground = Color(provider.brandColor).copy(alpha = 0.12f),
    modifier = modifier
)

@Composable
fun ProviderLogoView(
    runtime: AssistantRuntimeID,
    size: Dp = 36.dp,
    style: ProviderLogoStyle = ProviderLogoStyle.Disc,
    modifier: Modifier = Modifier
) = ProviderLogoView(
    drawableRes = ProviderLogo.drawableFor(runtime),
    size = size,
    style = style,
    modifier = modifier
)

// ── BurnBar Agent Avatar ──
//
// The single component every Hermes Square surface should call to render
// an agent's brand mark. Takes the full `AgentIdentity` so we never lose
// `runtimeID` to string parsing. Renders a flat PNG on a brand-tinted
// circular disc with a thin brand-colored ring — same treatment iOS uses,
// no double-chrome.

@Composable
fun BurnBarAgentAvatar(
    identity: AgentIdentity,
    size: Dp = 40.dp,
    showRing: Boolean = true,
    modifier: Modifier = Modifier
) {
    val brandColor = remember(identity.paletteHex) {
        runCatching {
            val cleaned = identity.paletteHex.trim().removePrefix("#")
            val rgb = cleaned.toLong(radix = 16)
            Color(0xFF000000L or rgb)
        }.getOrElse { Color.White }
    }
    val drawableRes = remember(identity.id, identity.runtimeID, identity.displayName) {
        ProviderLogo.drawableForIdentity(identity)
    }

    Box(
        modifier = modifier.size(size),
        contentAlignment = Alignment.Center
    ) {
        Box(
            modifier = Modifier
                .size(size)
                .clip(CircleShape)
                .background(brandColor.copy(alpha = 0.14f))
                .then(
                    if (showRing) Modifier.border(
                        width = 0.8.dp,
                        color = brandColor.copy(alpha = 0.55f),
                        shape = CircleShape
                    ) else Modifier
                )
        )
        Image(
            painter = painterResource(id = drawableRes),
            contentDescription = "${identity.displayName} logo",
            contentScale = ContentScale.Fit,
            modifier = Modifier.size(size * 0.74f)
        )
    }
}
