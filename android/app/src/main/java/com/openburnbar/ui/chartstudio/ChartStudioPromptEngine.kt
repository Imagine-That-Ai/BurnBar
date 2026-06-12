// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.chartstudio

import com.openburnbar.data.derived.TrendDataDigest

/**
 * Builds the system prompt Hermes sees for every Chart Studio turn, plus the
 * suggested-prompt carousel. Pure-Kotlin port of `ChartStudioPromptEngine.swift`
 * — same intent, idiomatic Kotlin output.
 */
object ChartStudioPromptEngine {
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
            appendLine(
                "minimax, kimi, cline, kilo-code, roo-code, forge-dev, augment, hermes, gemini-cli, antigravity, goose, openclaw, ollama, windsurf, warp.",
            )
            appendLine()
            appendLine("Here is the user's recent activity digest:")
            appendLine(digestJson)
            appendLine()
            appendLine("Reply with a single JSON object now.")
        }
    }

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
}
