package com.openburnbar.data.text

enum class TextExpansionMode(val wireName: String) {
    STATIC("static"),
    LLM_REWRITE("llm_rewrite");

    companion object {
        fun fromWireName(value: String): TextExpansionMode =
            entries.firstOrNull { it.wireName == value } ?: STATIC
    }
}

enum class TextExpansionSurface {
    IN_APP_THREAD,
    MAC_GLOBAL,
    IOS_KEYBOARD,
    ANDROID_IME,
}

data class TextExpansionScope(
    val surfaces: Set<TextExpansionSurface> = TextExpansionSurface.entries.toSet(),
    val bundleIdentifiers: Set<String> = emptySet(),
    val threadIds: Set<String> = emptySet(),
) {
    fun allows(
        surface: TextExpansionSurface,
        bundleIdentifier: String? = null,
        threadId: String? = null,
    ): Boolean {
        if (!surfaces.contains(surface)) return false
        if (bundleIdentifiers.isNotEmpty()) {
            val bundle = bundleIdentifier ?: return false
            if (bundleIdentifiers.none { it.equals(bundle, ignoreCase = true) }) return false
        }
        if (threadIds.isNotEmpty()) {
            val thread = threadId ?: return false
            if (!threadIds.contains(thread)) return false
        }
        return true
    }
}

data class TextExpansionSnippet(
    val id: String,
    val title: String,
    val trigger: String,
    val body: String,
    val mode: TextExpansionMode = TextExpansionMode.STATIC,
    val isEnabled: Boolean = true,
    val scope: TextExpansionScope = TextExpansionScope(),
    val deletedAtMillis: Long? = null,
) {
    val canonicalTrigger: String = TextExpansionTrigger.canonicalName(trigger)
    val activationToken: String = TextExpansionTrigger.PREFIX + canonicalTrigger
    val isActive: Boolean = isEnabled && deletedAtMillis == null && canonicalTrigger.isNotBlank()
}

object TextExpansionTrigger {
    const val PREFIX = "&&"
    private const val MIN_LENGTH = 2
    private const val MAX_LENGTH = 64

    fun canonicalName(raw: String): String {
        var value = raw.trim()
        while (value.startsWith(PREFIX)) {
            value = value.removePrefix(PREFIX)
        }
        return value.lowercase()
    }

    fun validationError(raw: String): String? {
        val name = canonicalName(raw)
        if (name.length < MIN_LENGTH) return "Trigger must be at least $MIN_LENGTH characters."
        if (name.length > MAX_LENGTH) return "Trigger must be $MAX_LENGTH characters or shorter."
        val valid = name.all { it in 'a'..'z' || it in '0'..'9' || it == '_' || it == '-' }
        return if (valid) null else "Use lowercase letters, numbers, hyphen, or underscore."
    }
}

data class TextExpansionMatch(
    val snippet: TextExpansionSnippet,
    val token: String,
    val start: Int,
    val end: Int,
    val boundary: Char?,
    val requiresPreview: Boolean,
)

data class TextExpansionResult(
    val text: String,
    val match: TextExpansionMatch,
)

object TextExpansionMatcher {
    fun isBoundary(char: Char): Boolean =
        char.isWhitespace() || (isPunctuation(char) && char != '&' && char != '_' && char != '-')

    fun match(
        text: String,
        snippets: List<TextExpansionSnippet>,
        surface: TextExpansionSurface,
        bundleIdentifier: String? = null,
        threadId: String? = null,
        cursor: Int = text.length,
        expandWhenUnambiguous: Boolean = true,
    ): TextExpansionMatch? {
        if (cursor <= 0 || cursor > text.length) return null
        val active = snippets.filter {
            it.isActive && it.scope.allows(surface, bundleIdentifier, threadId)
        }
        if (active.isEmpty()) return null

        val last = text[cursor - 1]
        val hasBoundary = isBoundary(last)
        val tokenEnd = if (hasBoundary) cursor - 1 else cursor
        if (tokenEnd <= 0) return null

        var tokenStart = tokenEnd
        while (tokenStart > 0 && !isBoundary(text[tokenStart - 1])) {
            tokenStart -= 1
        }
        val token = text.substring(tokenStart, tokenEnd)
        if (!token.startsWith(TextExpansionTrigger.PREFIX)) return null
        val canonical = TextExpansionTrigger.canonicalName(token)
        if (canonical.isBlank()) return null

        val snippet = active.firstOrNull { it.canonicalTrigger == canonical } ?: return null
        if (!hasBoundary && !expandWhenUnambiguous) return null
        if (!hasBoundary && active.any { it.canonicalTrigger != canonical && it.canonicalTrigger.startsWith(canonical) }) {
            return null
        }
        return TextExpansionMatch(
            snippet = snippet,
            token = token,
            start = tokenStart,
            end = tokenEnd,
            boundary = if (hasBoundary) last else null,
            requiresPreview = snippet.mode == TextExpansionMode.LLM_REWRITE,
        )
    }

    fun replace(text: String, match: TextExpansionMatch, replacement: String = match.snippet.body): String =
        text.replaceRange(match.start, match.end, replacement)

    fun expandStaticIfAvailable(
        text: String,
        snippets: List<TextExpansionSnippet>,
        surface: TextExpansionSurface,
        bundleIdentifier: String? = null,
        threadId: String? = null,
        cursor: Int = text.length,
        expandWhenUnambiguous: Boolean = true,
    ): TextExpansionResult? {
        val match = match(text, snippets, surface, bundleIdentifier, threadId, cursor, expandWhenUnambiguous)
            ?: return null
        if (match.requiresPreview) return null
        return TextExpansionResult(replace(text, match), match)
    }

    private fun isPunctuation(char: Char): Boolean {
        val type = Character.getType(char)
        return type == Character.CONNECTOR_PUNCTUATION.toInt() ||
            type == Character.DASH_PUNCTUATION.toInt() ||
            type == Character.START_PUNCTUATION.toInt() ||
            type == Character.END_PUNCTUATION.toInt() ||
            type == Character.INITIAL_QUOTE_PUNCTUATION.toInt() ||
            type == Character.FINAL_QUOTE_PUNCTUATION.toInt() ||
            type == Character.OTHER_PUNCTUATION.toInt()
    }
}
