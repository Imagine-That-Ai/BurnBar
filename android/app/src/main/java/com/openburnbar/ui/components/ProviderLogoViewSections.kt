@file:Suppress("MagicNumber")
// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.components

import androidx.annotation.DrawableRes
import com.openburnbar.R

internal fun builtInRuntimeModelDrawable(key: String): Int? =
    when {
        "openclaw" in key || "open_claw" in key || "open-claw" in key -> R.drawable.open_claw_logo
        "droid" in key || "factory-droid" in key || "factorydroid" in key -> R.drawable.factory_logo
        "forge" in key || "forge-dev" in key || "forgedev" in key -> R.drawable.forge_logo
        "antigravity" in key || "agy" == key || "google-antigravity" in key -> R.drawable.antigravity_logo
        else -> null
    }

internal fun piHermesRuntimeDrawable(key: String): Int? =
    when {
        key == "pi" || key.startsWith("pi-") || key.endsWith("/pi") -> R.drawable.pi_runtime_glyph
        key == "hermes" || key.endsWith("/hermes") -> R.drawable.hermes_logo
        else -> null
    }

internal fun anthropicOpenAiModelDrawable(key: String): Int? =
    when {
        "claude" in key || "anthropic" in key -> R.drawable.anthropic_logo
        "gpt" in key || "chatgpt" in key || "openai" in key -> R.drawable.open_ai_logo
        "codex" in key -> R.drawable.codex_logo
        else -> null
    }

internal fun googleModelDrawable(key: String): Int? =
    when {
        "gemini" in key || "google" in key -> R.drawable.google_logo
        else -> null
    }

internal fun asianProviderModelDrawable(key: String): Int? =
    when {
        "deepseek" in key -> R.drawable.deep_seek_logo
        "kimi" in key || "moonshot" in key -> R.drawable.kimi_logo
        "minimax" in key || "abab" in key -> R.drawable.mini_max_logo
        "qwen" in key || "qwq" in key -> R.drawable.qwen_logo
        "z.ai" in key || "zai" in key || "glm" in key -> R.drawable.zai_logo
        "alibaba" in key || "tongyi" in key -> R.drawable.alibaba_logo
        else -> null
    }

internal fun westernProviderModelDrawable(key: String): Int? =
    when {
        "llama" in key || "meta" in key -> R.drawable.meta_logo
        "mistral" in key || "mixtral" in key -> R.drawable.mistral_logo
        "grok" in key || "xai" in key -> R.drawable.grok_logo
        "cohere" in key || "command" in key -> R.drawable.cohere_logo
        "perplexity" in key || "sonar" in key -> R.drawable.perplexity_logo
        else -> null
    }

internal fun cloudAndLocalModelDrawable(key: String): Int? =
    when {
        "mlx" in key || "apple" in key -> R.drawable.apple_logo
        "nova" in key || "amazon" in key || "bedrock" in key -> R.drawable.amazon_logo
        "ollama" in key -> R.drawable.ollama_logo
        else -> null
    }

@DrawableRes
internal fun drawableForModelTokenKey(key: String): Int =
    builtInRuntimeModelDrawable(key)
        ?: piHermesRuntimeDrawable(key)
        ?: anthropicOpenAiModelDrawable(key)
        ?: googleModelDrawable(key)
        ?: asianProviderModelDrawable(key)
        ?: westernProviderModelDrawable(key)
        ?: cloudAndLocalModelDrawable(key)
        ?: R.drawable.hermes_logo
