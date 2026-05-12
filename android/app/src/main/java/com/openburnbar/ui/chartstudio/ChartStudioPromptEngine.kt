package com.openburnbar.ui.chartstudio

import com.openburnbar.data.derived.TrendDataDigest
import org.json.JSONArray
import org.json.JSONObject

/**
 * Builds the system prompt Hermes sees for every Chart Studio turn, plus the
 * suggested-prompt carousel. Pure-Kotlin port of `ChartStudioPromptEngine.swift`
 * — same intent, idiomatic Kotlin output.
 */
object ChartStudioPromptEngine {

    /**
     * Build the system prompt embedding a compact JSON digest plus a brief
     * specification of the JSON contract Hermes must reply with.
     */
    fun systemPrompt(digest: TrendDataDigest): String {
        val digestJson = digest.toCompactJson()
        return buildString {
            appendLine("You are Hermes, the chart-drawing assistant inside OpenBurnBar.")
            appendLine("Reply with exactly one JSON object describing what to render.")
            appendLine("Do not wrap the JSON in prose or Markdown.")
            appendLine()
            appendLine("Available rendering kinds:")
            appendLine("  • \"native\" — a chart drawn by the Android renderer.")
            appendLine("     Fields: chart (one of line|bar|stacked_bar|area|stacked_area|stream|scatter|heatmap|donut|rule),")
            appendLine("     title, subtitle, xAxis, yAxis, series[name, providerKey?, color?, data[x,y,label?]], rules[].")
            appendLine("  • \"mermaid\" — a Mermaid DSL diagram.")
            appendLine("     Fields: title, subtitle, source (raw DSL).")
            appendLine("  • \"ascii\" — terminal-chrome ASCII art.")
            appendLine("     Fields: title, variant (bar|sparkline|heatmap|banner|scene), body.")
            appendLine("  • \"insight\" — narrative card with optional sparkline.")
            appendLine("     Fields: title, body, tone (positive|neutral|warning), sparkline[]?, followUpPrompt?, followUpLabel?.")
            appendLine("  • \"composed\" — stack of multiple renderings.")
            appendLine("     Fields: items[] (each a valid rendering).")
            appendLine()
            appendLine("Color hints: provider brand colors auto-apply when you supply providerKey.")
            appendLine("Use AgentProvider keys: factory, claude-code, copilot, aider, cursor, openai, codex, zai, ")
            appendLine("minimax, kimi, cline, kilo-code, roo-code, forge-dev, augment, hermes, gemini-cli, goose, openclaw, ollama, windsurf, warp.")
            appendLine()
            appendLine("Here is the user's recent activity digest:")
            appendLine(digestJson)
            appendLine()
            appendLine("Reply with a single JSON object now.")
        }
    }

    /**
     * Suggested prompts for the prompt-carousel chip rail. Curated so each
     * one demonstrates a different rendering kind and produces a visibly
     * different output.
     */
    fun suggestedPrompts(digest: TrendDataDigest): List<String> {
        val anyProvider = digest.providers.firstOrNull()?.provider
        val anyModel = digest.models.firstOrNull()?.model
        val cacheHit = (digest.cache.cacheHitRate * 100).toInt()
        return buildList {
            add("Stack my spend last 7 days by provider")
            add("Where is my burn going this week?")
            add("Show today's hourly spend as a heatmap")
            add("Compare my top models head-to-head")
            if (anyProvider != null) add("Why is $anyProvider so big today?")
            if (anyModel != null) add("Plot $anyModel velocity over time")
            add("Sketch my cache strategy as a Mermaid diagram")
            add("Cache hit rate is $cacheHit% — what should I change?")
            add("ASCII bar chart of my top 5 projects")
            add("Insight: am I trending up or down vs last week?")
        }
    }

    // ── Compact JSON for the digest ─────────────────────────────────────────

    private fun TrendDataDigest.toCompactJson(): String {
        val root = JSONObject()
        root.put("displayMode", displayMode.key)
        root.put("windowDescription", windowDescription)

        val totalsArr = JSONArray()
        for (t in totals) {
            totalsArr.put(JSONObject().apply {
                put("window", t.window)
                put("costUsd", round(t.costUsd, 4))
                put("tokens", t.tokens)
                put("requests", t.requests)
            })
        }
        root.put("totals", totalsArr)

        val providersArr = JSONArray()
        for (p in providers.take(6)) {
            providersArr.put(JSONObject().apply {
                put("provider", p.provider)
                put("providerKey", p.providerKey)
                put("costUsd", round(p.costUsd, 4))
                put("tokens", p.tokens)
                put("requests", p.requests)
                put("sharePct", round(p.sharePct, 1))
            })
        }
        root.put("providers", providersArr)

        val modelsArr = JSONArray()
        for (m in models.take(6)) {
            modelsArr.put(JSONObject().apply {
                put("model", m.model)
                put("provider", m.provider)
                put("providerKey", m.providerKey)
                put("costUsd", round(m.costUsd, 4))
                put("tokens", m.tokens)
                put("requests", m.requests)
                put("sharePct", round(m.sharePct, 1))
            })
        }
        root.put("models", modelsArr)

        val dailyArr = JSONArray()
        for (d in daily.takeLast(14)) {
            dailyArr.put(JSONObject().apply {
                put("date", d.date)
                put("total", round(d.total, 4))
                val perProv = JSONObject()
                for ((k, v) in d.perProvider) perProv.put(k, round(v, 4))
                put("perProvider", perProv)
            })
        }
        root.put("daily", dailyArr)

        val hourlyArr = JSONArray()
        for (h in hourly) {
            hourlyArr.put(JSONObject().apply {
                put("hour", h.hour)
                put("costUsd", round(h.costUsd, 4))
                put("tokens", h.tokens)
            })
        }
        root.put("hourly", hourlyArr)

        val cacheObj = JSONObject().apply {
            put("totalCacheReadTokens", cache.totalCacheReadTokens)
            put("totalCacheCreationTokens", cache.totalCacheCreationTokens)
            put("totalInputTokens", cache.totalInputTokens)
            put("cacheHitRate", round(cache.cacheHitRate, 3))
            put("estSavingsUsd", round(cache.estSavingsUsd, 3))
        }
        root.put("cache", cacheObj)

        return root.toString()
    }

    private fun round(v: Double, places: Int): Double {
        val mult = Math.pow(10.0, places.toDouble())
        return Math.round(v * mult) / mult
    }
}
