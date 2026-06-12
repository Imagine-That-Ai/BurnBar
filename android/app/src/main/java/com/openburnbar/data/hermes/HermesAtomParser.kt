package com.openburnbar.data.hermes

import java.net.URLDecoder

/** Token counts at or above this format with the "M" suffix instead of "k". */
private const val MILLION_TOKEN_FORMAT_THRESHOLD = 1_000_000

/** Divisor converting a raw token count into millions for "%.1fM" display. */
private const val TOKENS_PER_MILLION = 1_000_000.0

/** Token counts at or above this format with the "B" suffix instead of "M". */
private const val BILLION_TOKEN_FORMAT_THRESHOLD = 1_000_000_000

/** Divisor converting a raw token count into billions for "%.2fB" display. */
private const val TOKENS_PER_BILLION = 1_000_000_000.0

/** Length of the `://` separator between a URL scheme and the rest of the URL. */
private const val URL_SCHEME_SEPARATOR_LENGTH = 3

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
    ALL("all", "all time"),
    ;

    companion object {
        fun fromRaw(value: String?): HermesAtomWindow? = value?.let { v -> values().firstOrNull { it.rawValue == v } }
    }
}

enum class HermesAtomTokenScope(val rawValue: String, val displayLabel: String) {
    TODAY("today", "today"),
    SESSION("session", "this session"),
    RUN("run", "this run"),
    LIFETIME("lifetime", "lifetime"),
    UNSPECIFIED("unspecified", ""),
    ;

    companion object {
        fun fromRaw(value: String?): HermesAtomTokenScope? = value?.let { v -> values().firstOrNull { it.rawValue == v } }
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
    RUNTIME("runtime", "antenna", "Runtime", "Open Hermes runtime details for this profile."),
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
        get() =
            when (this) {
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
                is Tokens ->
                    if (scope == HermesAtomTokenScope.UNSPECIFIED) {
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
            if (value < MILLION_TOKEN_FORMAT_THRESHOLD) {
                val k = value / 1_000.0
                return "%.1fk".format(k)
            }
            if (value >= BILLION_TOKEN_FORMAT_THRESHOLD) {
                val b = value / TOKENS_PER_BILLION
                return "%.2fB".format(b)
            }
            val m = value / TOKENS_PER_MILLION
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
            is HermesAtom.Cost ->
                buildURL(
                    "burn",
                    listOf(
                        "window" to atom.window.rawValue,
                        "amount" to atom.amount.toString(),
                    ),
                )
            is HermesAtom.Session -> buildURL("session", listOf("id" to atom.id))
            is HermesAtom.Provider -> buildURL("provider", listOf("token" to atom.token))
            is HermesAtom.Model -> buildURL("model", listOf("id" to atom.id))
            is HermesAtom.Window -> buildURL("window", listOf("value" to atom.value.rawValue))
            is HermesAtom.Tool -> buildURL("tool", listOf("name" to atom.name))
            is HermesAtom.Project -> buildURL("project", listOf("id" to atom.id))
            is HermesAtom.Tokens ->
                buildURL(
                    "tokens",
                    listOf(
                        "value" to atom.value.toString(),
                        "scope" to atom.scope.rawValue,
                    ),
                )
            is HermesAtom.Quota ->
                buildURL(
                    "quota",
                    listOf(
                        "provider" to atom.provider,
                        "percent" to atom.percent.toString(),
                    ),
                )
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
        val afterScheme = trimmed.substring(schemeIndex + URL_SCHEME_SEPARATOR_LENGTH)
        val questionMark = afterScheme.indexOf('?')
        val host =
            (if (questionMark >= 0) afterScheme.substring(0, questionMark) else afterScheme)
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

    private fun decodeComponent(raw: String): String = runCatching { URLDecoder.decode(raw, "UTF-8") }.getOrDefault(raw)

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
        val joined =
            params.joinToString("&") { (k, v) ->
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
        val withLinks = HermesAtomMarkdownParser.extractMarkdownLinks(text)
        val output = mutableListOf<HermesAtomRun>()
        for (chunk in withLinks) {
            when (chunk) {
                is HermesAtomMarkdownParser.LinkChunk.Link -> output.add(HermesAtomRun.Atom(chunk.atom, chunk.label))
                is HermesAtomMarkdownParser.LinkChunk.Body -> output.addAll(HermesAtomEntityParser.parseEntities(chunk.text))
            }
        }
        return output
    }
}
