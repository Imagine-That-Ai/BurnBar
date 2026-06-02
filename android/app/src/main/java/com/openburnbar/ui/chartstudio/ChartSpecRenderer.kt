package com.openburnbar.ui.chartstudio

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonPrimitive

/**
 * Decodes a Hermes response into a [ChartStudioRendering]. Tolerates prose-
 * wrapped JSON (extracts the first balanced `{ ... }`), strips Markdown code
 * fences, and dispatches the inner `kind` field to the right schema. Any
 * decode failure surfaces as [ChartStudioRendering.Error] so the UI always
 * has something renderable.
 */
object ChartSpecRenderer {
    internal const val SAFE_MERMAID_FALLBACK = "flowchart TD\n  blocked[Unsupported Mermaid content removed]"

    private const val MAX_MERMAID_SOURCE_CHARS = 12_000

    private val dangerousMermaidPatterns =
        listOf(
            Regex("""<\s*/?\s*(script|iframe|object|embed|foreignObject|link|meta)\b""", RegexOption.IGNORE_CASE),
            Regex("""\bon[a-z]+\s*=""", RegexOption.IGNORE_CASE),
            Regex("""\b(javascript|data|vbscript)\s*:""", RegexOption.IGNORE_CASE),
            Regex("""\bhttps?://""", RegexOption.IGNORE_CASE),
            Regex("""(^|[;\n])\s*(click|href)\b""", setOf(RegexOption.IGNORE_CASE, RegexOption.MULTILINE)),
            Regex("""^\s*%%\{""", setOf(RegexOption.IGNORE_CASE, RegexOption.MULTILINE)),
            Regex("""\burl\s*\(""", RegexOption.IGNORE_CASE),
        )

    private val json =
        Json {
            ignoreUnknownKeys = true
            isLenient = true
            coerceInputValues = true
        }

    fun decode(raw: String): ChartStudioRendering {
        val cleaned =
            extractFirstJsonObject(raw)
                ?: return ChartStudioRendering.Error("Couldn't find a JSON payload in Hermes' response.")
        return runCatching { decodeNode(json.parseToJsonElement(cleaned)) }
            .getOrElse { ChartStudioRendering.Error("Couldn't decode the spec: ${it.message ?: "unknown error"}") }
    }

    private fun decodeNode(node: JsonElement): ChartStudioRendering {
        if (node !is JsonObject) {
            return ChartStudioRendering.Error("Top-level spec must be a JSON object.")
        }
        val kind = node["kind"]?.jsonPrimitive?.contentOrNullSafe()?.lowercase()
        return when (kind) {
            "native", "swift_chart", "chart" -> decodeNative(node)
            "mermaid" -> decodeMermaid(node)
            "ascii" -> decodeAscii(node)
            "insight" -> decodeInsight(node)
            "composed" -> decodeComposed(node)
            "error" ->
                ChartStudioRendering.Error(
                    node["message"]?.jsonPrimitive?.contentOrNullSafe() ?: "Unknown error",
                )
            else -> ChartStudioRendering.Error("Unknown rendering kind: $kind")
        }
    }

    private fun decodeNative(obj: JsonObject): ChartStudioRendering.Native {
        // Rewrite to a canonical shape so kotlinx-serialization handles the heavy lifting.
        val patched = JsonObject(obj.toMutableMap().apply { put("kind", JsonPrimitive("native")) })
        return ChartStudioRendering.Native(json.decodeFromJsonElement(ChartSpec.serializer(), patched))
    }

    private fun decodeMermaid(obj: JsonObject): ChartStudioRendering.Mermaid {
        val spec = json.decodeFromJsonElement(MermaidSpec.serializer(), obj)
        return ChartStudioRendering.Mermaid(spec.copy(source = sanitizeMermaid(spec.source)))
    }

    private fun decodeAscii(obj: JsonObject): ChartStudioRendering.Ascii = ChartStudioRendering.Ascii(json.decodeFromJsonElement(AsciiSpec.serializer(), obj))

    private fun decodeInsight(obj: JsonObject): ChartStudioRendering.Insight = ChartStudioRendering.Insight(
        json.decodeFromJsonElement(InsightSpec.serializer(), obj),
    )

    private fun decodeComposed(obj: JsonObject): ChartStudioRendering {
        val arr = obj["items"]?.jsonArray ?: return ChartStudioRendering.Error("Composed spec needs an items array.")
        val items = arr.map { decodeNode(it) }
        return ChartStudioRendering.Composed(items)
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    /**
     * Scan for the first balanced `{ ... }` block in [raw], ignoring braces
     * inside string literals. Handles prose preludes ("Sure, here's a chart:")
     * and Markdown code fences ("```json ... ```").
     */
    internal fun extractFirstJsonObject(raw: String): String? {
        val text =
            raw.trim().removeSurrounding("```json\n", "\n```")
                .removeSurrounding("```\n", "\n```")
                .trim()
        val start = text.indexOf('{')
        if (start < 0) return null
        var depth = 0
        var inString = false
        var escape = false
        for (i in start until text.length) {
            val c = text[i]
            when {
                escape -> escape = false
                c == '\\' && inString -> escape = true
                c == '"' -> inString = !inString
                inString -> Unit
                c == '{' -> depth++
                c == '}' -> {
                    depth--
                    if (depth == 0) return text.substring(start, i + 1)
                }
            }
        }
        return null
    }

    /**
     * Defensive sanitation for Mermaid DSL. This blocks active content and
     * external resource references before the source reaches the WebView;
     * the WebView shell still enforces CSP/network blocks as defense in depth.
     */
    internal fun sanitizeMermaid(source: String): String {
        var s = source.trim()
        if (s.startsWith("```")) {
            s = s.substringAfter('\n', s).trim()
        }
        if (s.endsWith("```")) {
            s = s.substringBeforeLast("```").trim()
        }
        if (s.isBlank() || s.length > MAX_MERMAID_SOURCE_CHARS) {
            return SAFE_MERMAID_FALLBACK
        }
        if (s.any { it == '\u0000' || (it.isISOControl() && it != '\n' && it != '\r' && it != '\t') }) {
            return SAFE_MERMAID_FALLBACK
        }
        if (dangerousMermaidPatterns.any { it.containsMatchIn(s) }) {
            return SAFE_MERMAID_FALLBACK
        }
        return s
    }
}

private fun JsonPrimitive.contentOrNullSafe(): String? = runCatching { content }.getOrNull()
