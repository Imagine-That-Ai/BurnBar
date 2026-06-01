package com.openburnbar.ui.hermes

/**
 * Display mode for chat messages shared across platforms.
 * Mirrors [com.openburnbar.core.ChatViewMode] in OpenBurnBarCore iOS/macOS.
 */
enum class ChatViewMode(val key: String, val displayLabel: String) {
    AGENT("agent", "Agent"),
    CLI("cli", "CLI"),
    ;

    companion object {
        fun fromKey(key: String?): ChatViewMode = entries.firstOrNull { it.key == key } ?: AGENT
    }
}
