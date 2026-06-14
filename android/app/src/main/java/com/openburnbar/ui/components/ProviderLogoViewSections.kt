// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.components

import androidx.annotation.DrawableRes
import com.openburnbar.R

internal fun builtInRuntimeModelDrawable(key: String): Int? = when {
    "openclaw" in key || "open_claw" in key || "open-claw" in key -> R.drawable.logo_openclaw
    "droid" in key || "factory-droid" in key || "factorydroid" in key -> R.drawable.factory_logo
    "forge" in key || "forge-dev" in key || "forgedev" in key -> R.drawable.logo_forge
    "antigravity" in key || "agy" == key || "google-antigravity" in key -> R.drawable.logo_antigravity
    else -> null
}

internal fun piHermesRuntimeDrawable(key: String): Int? = when {
    key == "pi" || key.startsWith("pi-") || key.endsWith("/pi") -> R.drawable.pi_runtime_glyph
    key == "hermes" || key.endsWith("/hermes") -> R.drawable.logo_hermes
    else -> null
}

internal fun anthropicOpenAiModelDrawable(key: String): Int? = when {
    "claude" in key || "anthropic" in key -> R.drawable.logo_anthropic
    "gpt" in key || "chatgpt" in key || "openai" in key -> R.drawable.logo_open_ai
    "codex" in key -> R.drawable.logo_codex
    else -> null
}

internal fun googleModelDrawable(key: String): Int? = when {
    "gemini" in key || "google" in key -> R.drawable.google_logo
    else -> null
}

internal fun asianProviderModelDrawable(key: String): Int? = when {
    "deepseek" in key -> R.drawable.logo_deep_seek
    "kimi" in key || "moonshot" in key -> R.drawable.kimi_logo
    "minimax" in key || "abab" in key -> R.drawable.logo_mini_max
    "qwen" in key || "qwq" in key -> R.drawable.logo_qwen
    "z.ai" in key || "zai" in key || "glm" in key -> R.drawable.logo_zai
    "alibaba" in key || "tongyi" in key -> R.drawable.logo_alibaba
    else -> null
}

internal fun westernProviderModelDrawable(key: String): Int? = when {
    "llama" in key || "meta" in key -> R.drawable.logo_meta
    "mistral" in key || "mixtral" in key -> R.drawable.logo_mistral
    "grok" in key || "xai" in key -> R.drawable.logo_grok
    "cohere" in key || "command" in key -> R.drawable.logo_cohere
    "perplexity" in key || "sonar" in key -> R.drawable.logo_perplexity
    else -> null
}

internal fun cloudAndLocalModelDrawable(key: String): Int? = when {
    "mlx" in key || "apple" in key -> R.drawable.logo_apple
    "nova" in key || "amazon" in key || "bedrock" in key -> R.drawable.logo_amazon
    "ollama" in key -> R.drawable.logo_ollama
    else -> null
}

@DrawableRes
internal fun drawableForModelTokenKey(key: String): Int = builtInRuntimeModelDrawable(key)
    ?: piHermesRuntimeDrawable(key)
    ?: anthropicOpenAiModelDrawable(key)
    ?: googleModelDrawable(key)
    ?: asianProviderModelDrawable(key)
    ?: westernProviderModelDrawable(key)
    ?: cloudAndLocalModelDrawable(key)
    ?: R.drawable.logo_hermes
