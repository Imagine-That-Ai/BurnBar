package com.openburnbar.data.models

import androidx.compose.ui.graphics.Color

enum class AgentProvider(val key: String, val displayName: String, val brandColor: Long, val accentColor: Long) {
    FACTORY("factory", "Factory", 0xFF8B5CF6, 0xFFF45B69),
    CLAUDE_CODE("claude-code", "Claude Code", 0xFFCC785C, 0xFFD4A574),
    COPILOT("copilot", "Copilot", 0xFF23EA3B, 0xFF0969DA),
    AIDER("aider", "Aider", 0xFFFF6B35, 0xFFE86100),
    CURSOR("cursor", "Cursor", 0xFFAC8C57, 0xFF007AFF),
    OPEN_AI("openai", "OpenAI", 0xFF00A67E, 0xFF00C48C),
    CODEX("codex", "Codex", 0xFF00A67E, 0xFF00C48C),
    ZAI("zai", "Zai", 0xFF8B5CF6, 0xFFA78BFA),
    MINIMAX("minimax", "MiniMax", 0xFFF59E0B, 0xFFFCD34D),
    KIMI("kimi", "Kimi", 0xFF6366F1, 0xFF818CF8),
    CLINE("cline", "Cline", 0xFFD4A373, 0xFFE8C4A0),
    KILO_CODE("kilo-code", "KiloCode", 0xFF10B981, 0xFF34D399),
    ROO_CODE("roo-code", "RooCode", 0xFFEC4899, 0xFFF472B6),
    FORGE_DEV("forge-dev", "Forge Dev", 0xFFF97316, 0xFFFB923C),
    AUGMENT("augment", "Augment", 0xFF3B82F6, 0xFF60A5FA),
    HERMES("hermes", "Hermes", 0xFFA855F7, 0xFFC084FC),
    GEMINI_CLI("gemini-cli", "Gemini CLI", 0xFF4285F4, 0xFF8AB4F8),
    GOOSE("goose", "Goose", 0xFF0D9488, 0xFF2DD4BF),
    OPEN_CLAW("openclaw", "OpenClaw", 0xFFFF6B6B, 0xFFF472B6),
    OLLAMA("ollama", "Ollama", 0xFF6B7280, 0xFF9CA3AF),
    WINDSURF("windsurf", "Windsurf", 0xFF06B6D4, 0xFF22D3EE),
    WARP("warp", "Warp", 0xFFDDE4EA, 0xFF111111);

    companion object {
        fun fromKey(key: String): AgentProvider? = entries.find { it.key == key }

        fun chartPalette(provider: AgentProvider): List<Color> {
            val p = Color(provider.brandColor)
            val a = Color(provider.accentColor)
            return listOf(p, a, p.copy(alpha = 0.6f), a.copy(alpha = 0.5f))
        }
    }
}
