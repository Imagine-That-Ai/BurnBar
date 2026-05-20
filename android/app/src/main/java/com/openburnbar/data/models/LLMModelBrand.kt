package com.openburnbar.data.models

import com.openburnbar.R

/**
 * LLM vendor behind a model id — the entity that *trained* the model, distinct
 * from [AgentProvider], which is the *coding agent* that calls it. Mirrors the
 * iOS `LLMModelBrand` enum at `AgentLens/Theme/LLMModelBrand.swift`.
 */
enum class LLMModelBrand(val emblemColor: Long) {
    ANTHROPIC(0xFFCC785C),
    OPEN_AI(0xFF00A67E),
    GOOGLE(0xFF4285F4),
    DEEP_SEEK(0xFF6366F1),
    KIMI(0xFF6366F1),
    MINI_MAX(0xFFF59E0B),
    META(0xFF0668E1),
    MISTRAL(0xFFFF7000),
    QWEN(0xFF615EFF),
    X_AI(0xFF1A1A1A),
    COHERE(0xFF39594D),
    PERPLEXITY(0xFF20808D),
    APPLE(0xFFA2AAAD),
    AMAZON(0xFFFF9900),
    ALIBABA(0xFFFF6A00),
    OLLAMA(0xFF8B8589),
    UNKNOWN(0xFF8B8589);

    /** Drawable resource ID for the bundled logo, or 0 if no logo is bundled. */
    val logoRes: Int
        get() = when (this) {
            ANTHROPIC  -> R.drawable.logo_anthropic
            OPEN_AI    -> R.drawable.logo_open_ai
            GOOGLE     -> R.drawable.logo_google
            DEEP_SEEK  -> R.drawable.logo_deep_seek
            KIMI       -> R.drawable.logo_kimi
            MINI_MAX   -> R.drawable.logo_mini_max
            META       -> R.drawable.logo_meta
            MISTRAL    -> R.drawable.logo_mistral
            QWEN       -> R.drawable.logo_qwen
            X_AI       -> R.drawable.logo_grok
            COHERE     -> R.drawable.logo_cohere
            PERPLEXITY -> R.drawable.logo_perplexity
            APPLE      -> R.drawable.logo_apple
            AMAZON     -> R.drawable.logo_amazon
            ALIBABA    -> R.drawable.logo_alibaba
            OLLAMA     -> R.drawable.logo_ollama
            UNKNOWN    -> 0
        }

    val displayName: String
        get() = when (this) {
            ANTHROPIC  -> "Anthropic"
            OPEN_AI    -> "OpenAI"
            GOOGLE     -> "Google"
            DEEP_SEEK  -> "DeepSeek"
            KIMI       -> "Kimi"
            MINI_MAX   -> "MiniMax"
            META       -> "Meta"
            MISTRAL    -> "Mistral"
            QWEN       -> "Qwen"
            X_AI       -> "xAI"
            COHERE     -> "Cohere"
            PERPLEXITY -> "Perplexity"
            APPLE      -> "Apple"
            AMAZON     -> "Amazon"
            ALIBABA    -> "Alibaba"
            OLLAMA     -> "Ollama"
            UNKNOWN    -> "Unknown"
        }

    companion object {
        /** Best-effort vendor detection from model id strings. Mirrors iOS infer logic. */
        fun infer(modelKey: String): LLMModelBrand {
            val k = modelKey.lowercase()
            return when {
                k.contains("claude") || k.contains("anthropic") -> ANTHROPIC
                k.contains("gpt") || k.contains("openai") ||
                    k.contains("chatgpt") || k.contains("codex") -> OPEN_AI
                k.contains("gemini") || k.contains("google") -> GOOGLE
                k.contains("deepseek") -> DEEP_SEEK
                k.contains("kimi") || k.contains("moonshot") -> KIMI
                k.contains("minimax") || k.contains("abab") -> MINI_MAX
                k.contains("llama") || k.contains("meta") -> META
                k.contains("mistral") || k.contains("mixtral") -> MISTRAL
                k.contains("qwen") || k.contains("qwq") -> QWEN
                k.contains("grok") || k.contains("xai") -> X_AI
                k.contains("cohere") || k.contains("command") -> COHERE
                k.contains("perplexity") || k.contains("sonar") -> PERPLEXITY
                k.contains("mlx") || k.contains("apple") -> APPLE
                k.contains("nova") || k.contains("amazon") || k.contains("bedrock") -> AMAZON
                k.contains("alibaba") || k.contains("tongyi") -> ALIBABA
                k.contains("ollama") -> OLLAMA
                else -> UNKNOWN
            }
        }
    }
}

/**
 * Drawable resource ID for an [AgentProvider]'s coding-agent logo, or 0 if no
 * bundled logo exists. Mirrors `AgentLens/Views/Components/ProviderLogoView.swift`.
 */
val AgentProvider.logoRes: Int
    get() = when (this) {
        AgentProvider.FACTORY     -> R.drawable.logo_factory
        AgentProvider.CLAUDE_CODE -> R.drawable.logo_claude_code
        AgentProvider.COPILOT     -> R.drawable.logo_copilot
        AgentProvider.AIDER       -> R.drawable.logo_aider
        AgentProvider.CURSOR      -> R.drawable.logo_cursor
        AgentProvider.OPEN_AI     -> R.drawable.logo_open_ai
        AgentProvider.CODEX       -> R.drawable.logo_codex
        AgentProvider.ZAI         -> R.drawable.logo_zai
        AgentProvider.MINIMAX     -> R.drawable.logo_mini_max
        AgentProvider.KIMI        -> R.drawable.logo_kimi
        AgentProvider.CLINE       -> R.drawable.logo_cline
        AgentProvider.KILO_CODE   -> R.drawable.logo_kilo_code
        AgentProvider.ROO_CODE    -> R.drawable.logo_roo_code
        AgentProvider.FORGE_DEV   -> R.drawable.logo_forge
        AgentProvider.AUGMENT     -> R.drawable.logo_augment
        AgentProvider.HERMES      -> R.drawable.logo_hermes
        AgentProvider.GEMINI_CLI  -> R.drawable.logo_gemini_cli
        AgentProvider.GOOSE       -> R.drawable.logo_goose
        AgentProvider.OPEN_CLAW   -> R.drawable.logo_openclaw
        AgentProvider.OPENCODE    -> R.drawable.logo_open_code
        AgentProvider.OLLAMA      -> R.drawable.logo_ollama
        AgentProvider.WINDSURF    -> R.drawable.logo_windsurf
        AgentProvider.WARP        -> R.drawable.logo_warp
        AgentProvider.ANTIGRAVITY -> R.drawable.logo_gemini_cli
    }
