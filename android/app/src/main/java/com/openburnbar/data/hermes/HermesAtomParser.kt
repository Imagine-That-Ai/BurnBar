package com.openburnbar.data.hermes

import java.net.URLDecoder

// MARK: - HermesAtom
//
// Strongly-typed Android port of `OpenBurnBarCore/Hermes/HermesAtom.swift`.
// The atom model is shared across iOS / macOS / Android because Hermes emits
// `[label](burnbar://...)` links the chat surface decodes into atomic chips.
// Mirrors the Swift enum case-for-case; iconName/categoryLabel/description
// stay identical so the iOS detail-sheet copy can be reused verbatim if
// needed.

enum class HermesAtomWindow(val rawValue: String, val displayLabel: String) {
    TODAY("today", "today"),
    YESTERDAY("yesterday", "yesterday"),
    SEVEN_DAYS("7d", "7 days"),
    THIRTY_DAYS("30d", "30 days"),
    NINETY_DAYS("90d", "90 days"),
    ALL("all", "all time");

    companion object {
        fun fromRaw(value: String?): HermesAtomWindow? =
            value?.let { v -> values().firstOrNull { it.rawValue == v } }
    }
}

enum class HermesAtomTokenScope(val rawValue: String, val displayLabel: String) {
    TODAY("today", "today"),
    SESSION("session", "this session"),
    RUN("run", "this run"),
    LIFETIME("lifetime", "lifetime"),
    UNSPECIFIED("unspecified", "");

    companion object {
        fun fromRaw(value: String?): HermesAtomTokenScope? =
            value?.let { v -> values().firstOrNull { it.rawValue == v } }
    }
}

enum class HermesAtomKind(val rawValue: String, val iconName: String, val categoryLabel: String, val description: String) {
    COST("cost", "dollarsign", "Cost", "Open the burn detail for this time window."),
    SESSION("session", "rectangle.stack.fill", "Session", "Open this session's detail view."),
    PROVIDER("provider", "externaldrive", "Provider", "Open this provider's dashboard."),
    MODEL("model", "cpu", "Model", "Open this model's detail or pick it as default."),
    WINDOW("window", "calendar", "Window", "Switch the dashboard to this time window."),
    TOOL("tool", "wrench", "Tool", "See where this tool was invoked in the run."),
    PROJECT("project", "folder.fill", "Project", "Open this project's detail."),
    TOKENS("tokens", "number", "Tokens", "Open the token-usage detail."),
    QUOTA("quota", "gauge", "Quota", "Open quota detail for this provider."),
    RUNTIME("runtime", "antenna", "Runtime", "Open Hermes runtime details for this profile.");
}

/**
 * One conversation atom. Sealed class mirrors the Swift enum cases so
 * navigators can pattern-match against the same shapes the iOS app uses.
 */
sealed class HermesAtom {
    abstract val kind: HermesAtomKind

    data class Cost(val amount: Double, val window: HermesAtomWindow) : HermesAtom() {
        override val kind: HermesAtomKind = HermesAtomKind.COST
    }
    data class Session(val id: String) : HermesAtom() {
        override val kind: HermesAtomKind = HermesAtomKind.SESSION
    }
    data class Provider(val token: String) : HermesAtom() {
        override val kind: HermesAtomKind = HermesAtomKind.PROVIDER
    }
    data class Model(val id: String) : HermesAtom() {
        override val kind: HermesAtomKind = HermesAtomKind.MODEL
    }
    data class Window(val value: HermesAtomWindow) : HermesAtom() {
        override val kind: HermesAtomKind = HermesAtomKind.WINDOW
    }
    data class Tool(val name: String) : HermesAtom() {
        override val kind: HermesAtomKind = HermesAtomKind.TOOL
    }
    data class Project(val id: String) : HermesAtom() {
        override val kind: HermesAtomKind = HermesAtomKind.PROJECT
    }
    data class Tokens(val value: Int, val scope: HermesAtomTokenScope) : HermesAtom() {
        override val kind: HermesAtomKind = HermesAtomKind.TOKENS
    }
    data class Quota(val provider: String, val percent: Int) : HermesAtom() {
        override val kind: HermesAtomKind = HermesAtomKind.QUOTA
    }
    data class Runtime(val profile: String) : HermesAtom() {
        override val kind: HermesAtomKind = HermesAtomKind.RUNTIME
    }

    /** Default label used when the source link text is empty / whitespace. */
    val fallbackLabel: String
        get() = when (this) {
            is Cost -> {
                val rounded = "%.2f".format(amount)
                "\$$rounded ${window.displayLabel}"
            }
            is Session -> "session ${id.take(8)}"
            is Provider -> token.replaceFirstChar { it.titlecase() }
            is Model -> id
            is Window -> value.displayLabel
            is Tool -> name
            is Project -> id
            is Tokens -> if (scope == HermesAtomTokenScope.UNSPECIFIED) {
                "${formatTokenCount(value)} tokens"
            } else {
                "${formatTokenCount(value)} ${scope.displayLabel}"
            }
            is Quota -> "$percent% ${provider.replaceFirstChar { it.titlecase() }}"
            is Runtime -> profile.replaceFirstChar { it.titlecase() }
        }

    companion object {
        fun formatTokenCount(value: Int): String {
            if (value < 1_000) return value.toString()
            if (value < 1_000_000) {
                val k = value / 1_000.0
                return "%.1fk".format(k)
            }
            if (value >= 1_000_000_000) {
                val b = value / 1_000_000_000.0
                return "%.2fB".format(b)
            }
            val m = value / 1_000_000.0
            return "%.1fM".format(m)
        }
    }
}

// MARK: - URL Codec

const val HERMES_ATOM_URL_SCHEME = "burnbar"

object HermesAtomURL {

    /** Encode an atom back to its canonical burnbar:// URL string. */
    fun encode(atom: HermesAtom): String {
        return when (atom) {
            is HermesAtom.Cost -> buildURL("burn", listOf(
                "window" to atom.window.rawValue,
                "amount" to atom.amount.toString()
            ))
            is HermesAtom.Session -> buildURL("session", listOf("id" to atom.id))
            is HermesAtom.Provider -> buildURL("provider", listOf("token" to atom.token))
            is HermesAtom.Model -> buildURL("model", listOf("id" to atom.id))
            is HermesAtom.Window -> buildURL("window", listOf("value" to atom.value.rawValue))
            is HermesAtom.Tool -> buildURL("tool", listOf("name" to atom.name))
            is HermesAtom.Project -> buildURL("project", listOf("id" to atom.id))
            is HermesAtom.Tokens -> buildURL("tokens", listOf(
                "value" to atom.value.toString(),
                "scope" to atom.scope.rawValue
            ))
            is HermesAtom.Quota -> buildURL("quota", listOf(
                "provider" to atom.provider,
                "percent" to atom.percent.toString()
            ))
            is HermesAtom.Runtime -> buildURL("runtime", listOf("profile" to atom.profile))
        }
    }

    /** Decode a burnbar:// URL string to an atom; returns null on any failure. */
    fun decode(urlString: String): HermesAtom? {
        val trimmed = urlString.trim()
        if (trimmed.isEmpty()) return null
        val schemeIndex = trimmed.indexOf("://")
        if (schemeIndex <= 0) return null
        val scheme = trimmed.substring(0, schemeIndex).lowercase()
        if (scheme != HERMES_ATOM_URL_SCHEME) return null
        val afterScheme = trimmed.substring(schemeIndex + 3)
        val questionMark = afterScheme.indexOf('?')
        val host = (if (questionMark >= 0) afterScheme.substring(0, questionMark) else afterScheme)
            .lowercase()
        val query = if (questionMark >= 0) afterScheme.substring(questionMark + 1) else ""
        val params = parseQuery(query)
        return decode(host, params)
    }

    private fun parseQuery(raw: String): Map<String, String> {
        if (raw.isEmpty()) return emptyMap()
        val out = mutableMapOf<String, String>()
        for (pair in raw.split('&')) {
            val eq = pair.indexOf('=')
            if (eq <= 0) continue
            val key = decodeComponent(pair.substring(0, eq)).lowercase()
            val value = decodeComponent(pair.substring(eq + 1))
            if (key.isNotEmpty() && value.isNotEmpty()) {
                out[key] = value
            }
        }
        return out
    }

    private fun decodeComponent(raw: String): String =
        runCatching { URLDecoder.decode(raw, "UTF-8") }.getOrDefault(raw)

    private fun decode(host: String, params: Map<String, String>): HermesAtom? {
        return when (host) {
            "burn" -> {
                val window = HermesAtomWindow.fromRaw(params["window"]) ?: HermesAtomWindow.TODAY
                val amount = params["amount"]?.toDoubleOrNull() ?: 0.0
                HermesAtom.Cost(amount = amount, window = window)
            }
            "session" -> params["id"]?.takeIf { it.isNotEmpty() }?.let { HermesAtom.Session(it) }
            "provider" -> params["token"]?.takeIf { it.isNotEmpty() }?.let { HermesAtom.Provider(it) }
            "model" -> params["id"]?.takeIf { it.isNotEmpty() }?.let { HermesAtom.Model(it) }
            "window" -> HermesAtomWindow.fromRaw(params["value"])?.let { HermesAtom.Window(it) }
            "tool" -> params["name"]?.takeIf { it.isNotEmpty() }?.let { HermesAtom.Tool(it) }
            "project" -> params["id"]?.takeIf { it.isNotEmpty() }?.let { HermesAtom.Project(it) }
            "tokens" -> {
                val value = params["value"]?.toIntOrNull() ?: return null
                val scope = HermesAtomTokenScope.fromRaw(params["scope"]) ?: HermesAtomTokenScope.UNSPECIFIED
                HermesAtom.Tokens(value = value, scope = scope)
            }
            "quota" -> {
                val provider = params["provider"]?.takeIf { it.isNotEmpty() } ?: return null
                val percent = params["percent"]?.toIntOrNull() ?: return null
                HermesAtom.Quota(provider = provider, percent = percent)
            }
            "runtime" -> params["profile"]?.takeIf { it.isNotEmpty() }?.let { HermesAtom.Runtime(it) }
            else -> null
        }
    }

    private fun buildURL(host: String, params: List<Pair<String, String>>): String {
        val joined = params.joinToString("&") { (k, v) ->
            "$k=${java.net.URLEncoder.encode(v, "UTF-8")}"
        }
        return "$HERMES_ATOM_URL_SCHEME://$host?$joined"
    }
}

// MARK: - HermesAtomRun (parsed run stream)
//
// One typed segment of a parsed Hermes message. Output of `HermesAtomParser`
// — concatenating `text` for each run reproduces the input (link labels are
// preserved as the chip label).

sealed class HermesAtomRun {
    abstract val text: String

    /** Plain prose body. */
    data class Text(override val text: String) : HermesAtomRun()

    /** Atomic burnbar:// chip. */
    data class Atom(val atom: HermesAtom, val label: String) : HermesAtomRun() {
        override val text: String get() = label
    }

    /** `@handle` mention, atomic. */
    data class Mention(val handle: String) : HermesAtomRun() {
        override val text: String get() = handle
    }

    /** `` `inline code` `` span. */
    data class Code(val code: String) : HermesAtomRun() {
        override val text: String get() = code
    }

    val isAtomic: Boolean
        get() = this is Atom || this is Mention
}

// MARK: - HermesAtomParser
//
// Two-pass parser that mirrors the Swift `HermesAtomParser`. Phase 1 lifts
// canonical `[label](burnbar://...)` markdown links. Phase 2 walks the
// remaining body for `@mentions`, `` `code` ``, `$cost`, and known model IDs.

object HermesAtomParser {

    /** Parse `text` into a stream of `HermesAtomRun`s. */
    fun parse(text: String): List<HermesAtomRun> {
        val withLinks = extractMarkdownLinks(text)
        val output = mutableListOf<HermesAtomRun>()
        for (chunk in withLinks) {
            when (chunk) {
                is LinkChunk.Link -> output.add(HermesAtomRun.Atom(chunk.atom, chunk.label))
                is LinkChunk.Body -> output.addAll(parseEntities(chunk.text))
            }
        }
        return output
    }

    // ── Phase 1: markdown link extraction ──

    private sealed class LinkChunk {
        data class Body(val text: String) : LinkChunk()
        data class Link(val atom: HermesAtom, val label: String) : LinkChunk()
    }

    private fun extractMarkdownLinks(source: String): List<LinkChunk> {
        val output = mutableListOf<LinkChunk>()
        var bodyStart = 0
        var i = 0
        while (i < source.length) {
            if (source[i] == '[') {
                val escaped = i > 0 && source[i - 1] == '\\'
                if (!escaped) {
                    val match = matchMarkdownLink(source, i)
                    if (match != null) {
                        if (bodyStart < i) {
                            output.add(LinkChunk.Body(source.substring(bodyStart, i)))
                        }
                        output.add(LinkChunk.Link(match.atom, match.label))
                        i = match.endIndex
                        bodyStart = i
                        continue
                    }
                }
            }
            i += 1
        }
        if (bodyStart < source.length) {
            output.add(LinkChunk.Body(source.substring(bodyStart)))
        }
        return output
    }

    private data class MarkdownLinkMatch(val atom: HermesAtom, val label: String, val endIndex: Int)

    private fun matchMarkdownLink(source: String, start: Int): MarkdownLinkMatch? {
        var idx = start + 1
        val labelBuf = StringBuilder()
        var depth = 1
        while (idx < source.length) {
            val c = source[idx]
            if (c == '\n') return null
            if (c == '[') depth += 1
            if (c == ']') {
                depth -= 1
                if (depth == 0) break
            }
            labelBuf.append(c)
            idx += 1
        }
        if (idx >= source.length || source[idx] != ']') return null
        val afterClose = idx + 1
        if (afterClose >= source.length || source[afterClose] != '(') return null
        var urlIdx = afterClose + 1
        val urlBuf = StringBuilder()
        while (urlIdx < source.length) {
            val c = source[urlIdx]
            if (c == ')') break
            if (c == '\n') return null
            urlBuf.append(c)
            urlIdx += 1
        }
        if (urlIdx >= source.length || source[urlIdx] != ')') return null
        val endIndex = urlIdx + 1
        val atom = HermesAtomURL.decode(urlBuf.toString()) ?: return null
        val cleaned = labelBuf.toString().trim()
        val resolved = if (cleaned.isEmpty()) atom.fallbackLabel else cleaned
        return MarkdownLinkMatch(atom = atom, label = resolved, endIndex = endIndex)
    }

    // ── Phase 2: entity sub-parser ──

    private fun parseEntities(source: String): List<HermesAtomRun> {
        val output = mutableListOf<HermesAtomRun>()
        val buffer = StringBuilder()
        var i = 0
        while (i < source.length) {
            val ch = source[i]
            if (ch == '`') {
                if (buffer.isNotEmpty()) {
                    output.addAll(scanRegexAtoms(buffer.toString()))
                    buffer.clear()
                }
                val match = matchInlineCode(source, i)
                if (match != null) {
                    output.add(HermesAtomRun.Code(match.body))
                    i = match.endIndex
                    continue
                } else {
                    buffer.append('`')
                    i += 1
                    continue
                }
            }
            if (ch == '@') {
                val prev: Char = if (i == 0) ' ' else source[i - 1]
                if (prev.isWhitespace() || prev == '(' || prev == '[' || prev == '{') {
                    val match = matchMention(source, i)
                    if (match != null) {
                        if (buffer.isNotEmpty()) {
                            output.addAll(scanRegexAtoms(buffer.toString()))
                            buffer.clear()
                        }
                        output.add(HermesAtomRun.Mention(match.handle))
                        i = match.endIndex
                        continue
                    }
                }
            }
            buffer.append(ch)
            i += 1
        }
        if (buffer.isNotEmpty()) {
            output.addAll(scanRegexAtoms(buffer.toString()))
        }
        return output
    }

    private data class InlineCodeMatch(val body: String, val endIndex: Int)

    private fun matchInlineCode(source: String, start: Int): InlineCodeMatch? {
        var idx = start + 1
        val body = StringBuilder()
        while (idx < source.length) {
            val c = source[idx]
            if (c == '`') {
                if (body.isEmpty()) return null
                return InlineCodeMatch(body.toString(), idx + 1)
            }
            if (c == '\n') return null
            body.append(c)
            idx += 1
        }
        return null
    }

    private data class MentionMatch(val handle: String, val endIndex: Int)

    private fun matchMention(source: String, start: Int): MentionMatch? {
        var idx = start + 1
        val handle = StringBuilder("@")
        while (idx < source.length) {
            val c = source[idx]
            if (c.isLetter() || c.isDigit() || c == '_' || c == '-' || c == '.') {
                handle.append(c)
                idx += 1
            } else {
                break
            }
        }
        if (handle.length <= 1) return null
        return MentionMatch(handle.toString(), idx)
    }

    private fun scanRegexAtoms(source: String): List<HermesAtomRun> {
        if (source.isEmpty()) return emptyList()
        val modelAlt = knownModelIDs.joinToString("|") { Regex.escape(it) }
        val pattern = Regex("(\\$\\d{1,3}(?:,\\d{3})*(?:\\.\\d+)?)|($modelAlt)")
        val matches = pattern.findAll(source).toList()
        if (matches.isEmpty()) return listOf(HermesAtomRun.Text(source))

        val output = mutableListOf<HermesAtomRun>()
        var cursor = 0
        for (match in matches) {
            val range = match.range
            if (range.first > cursor) {
                output.add(HermesAtomRun.Text(source.substring(cursor, range.first)))
            }
            val matched = source.substring(range.first, range.last + 1)
            val cost = parseCost(matched)
            when {
                cost != null -> output.add(
                    HermesAtomRun.Atom(HermesAtom.Cost(cost, HermesAtomWindow.TODAY), matched)
                )
                knownModelIDs.contains(matched) -> output.add(
                    HermesAtomRun.Atom(HermesAtom.Model(matched), matched)
                )
                else -> output.add(HermesAtomRun.Text(matched))
            }
            cursor = range.last + 1
        }
        if (cursor < source.length) {
            output.add(HermesAtomRun.Text(source.substring(cursor)))
        }
        return output
    }

    private fun parseCost(matched: String): Double? {
        if (!matched.startsWith("$")) return null
        val trimmed = matched.drop(1).replace(",", "")
        return trimmed.toDoubleOrNull()
    }

    /** Allowlist of canonical model identifiers (mirrors the Swift list). */
    private val knownModelIDs: List<String> = listOf(
        "claude-sonnet-4.7",
        "claude-sonnet-4.6",
        "claude-sonnet-4.5",
        "claude-opus-4.7",
        "claude-opus-4.6",
        "claude-haiku-4.7",
        "gpt-5.5",
        "gpt-5",
        "gpt-4.6",
        "gpt-4o",
        "gpt-4o-mini",
        "o1-preview",
        "o1-mini",
        "minimax-m2.7",
        "minimax-m2",
        "kimi-k1.7",
        "kimi-k1.5",
        "glm-5",
        "glm-4.6",
        "deepseek-v3.5",
        "gemini-3-pro",
        "gemini-3-flash"
    )
}
