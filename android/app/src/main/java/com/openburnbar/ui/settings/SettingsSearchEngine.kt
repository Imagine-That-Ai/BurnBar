package com.openburnbar.ui.settings

import java.text.Normalizer
import java.util.Locale

/**
 * Settings search ranking engine — Android port of the macOS/iOS version.
 *
 * Same semantics:
 * - Weighted hits: title=3, keywords=2, subtitle=2, helpText=1.
 * - AND token semantics: every token must hit somewhere on the row.
 * - Diacritic-folded, case-insensitive substring match.
 * - Tie-break by lowercase title ascending. Capped at [DEFAULT_RESULT_LIMIT].
 */
object SettingsSearchEngine {

    const val WEIGHT_TITLE = 3
    const val WEIGHT_KEYWORD = 2
    const val WEIGHT_SUBTITLE = 2
    const val WEIGHT_HELP_TEXT = 1

    const val DEFAULT_RESULT_LIMIT = 25

    /** Returns the items ranked against [query]. Empty/whitespace yields []. */
    fun search(
        query: String,
        items: List<SettingsItem>,
        limit: Int = DEFAULT_RESULT_LIMIT,
    ): List<SettingsItem> {
        val tokens = tokenize(query)
        if (tokens.isEmpty()) return emptyList()

        val scored = items.mapNotNull { item ->
            score(item, tokens)?.let { item to it }
        }

        return scored
            .sortedWith(compareByDescending<Pair<SettingsItem, Int>> { it.second }
                .thenBy { foldedTitle(it.first) })
            .take(limit)
            .map { it.first }
    }

    internal fun score(item: SettingsItem, tokens: List<String>): Int? {
        val title = foldedTitle(item)
        val keywords = item.keywords.map { fold(it) }
        val subtitle = item.subtitle?.let { fold(it) }.orEmpty()
        val helpText = item.helpText?.let { fold(it) }.orEmpty()

        var total = 0
        for (token in tokens) {
            var tokenScore = 0
            if (title.contains(token)) tokenScore += WEIGHT_TITLE
            if (keywords.any { it.contains(token) }) tokenScore += WEIGHT_KEYWORD
            if (subtitle.isNotEmpty() && subtitle.contains(token)) tokenScore += WEIGHT_SUBTITLE
            if (helpText.isNotEmpty() && helpText.contains(token)) tokenScore += WEIGHT_HELP_TEXT
            if (tokenScore == 0) return null
            total += tokenScore
        }
        return total
    }

    /** Lowercase + remove combining diacritics for case-insensitive match. */
    internal fun fold(input: String): String {
        val normalized = Normalizer.normalize(input, Normalizer.Form.NFD)
        // Strip combining marks (e.g. accents) so "café" matches "cafe".
        val stripped = normalized.replace(Regex("\\p{InCombiningDiacriticalMarks}+"), "")
        return stripped.lowercase(Locale.ROOT)
    }

    internal fun tokenize(query: String): List<String> =
        fold(query)
            .split(Regex("\\s+"))
            .filter { it.isNotEmpty() }

    private fun foldedTitle(item: SettingsItem): String = fold(item.title)
}
