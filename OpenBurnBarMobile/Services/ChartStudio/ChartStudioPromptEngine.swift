import Foundation
import OpenBurnBarCore

// MARK: - Chart Studio Prompt Engine
//
// Builds the system prompt + user prompt for Hermes when the user asks
// Chart Studio to draw something. Stays as a pure value type for testing
// — no Hermes / view dependencies.
//
// The prompt enforces a tight JSON wire format (see `ChartSpecRenderer.Envelope`)
// and provides three worked examples so even small open-source models can
// ground themselves.

public struct ChartStudioPromptEngine: Sendable {
    public let digest: TrendDataDigest

    public init(digest: TrendDataDigest) {
        self.digest = digest
    }

    public func systemPrompt() -> String {
        """
        You are Chart Studio inside OpenBurnBar — a chart-drawing assistant that\
         turns the user's natural-language request into a structured JSON\
         response that the iOS app renders natively (no images, no HTML, no\
         remote fetches).

        # YOUR HERMES SKILLS (use them mentally to plan output, even though
          you cannot invoke a separate skill MCP from this tool call)

        - `architecture-diagram` and `excalidraw` skills inform the **mermaid**
          render kind below — flowcharts, sequence/state/ER diagrams.
        - `ascii-art` skill informs the **ascii** render kind — monospace
          terminal-aesthetic art using box-drawing and half-block glyphs.
          The ascii canvas is rendered with SF Mono, so columns align cell-by-
          cell the way they would in a real TTY (this is the same model
          Cheng Lou's `pretext` and OpenTUI use for terminal layout).
        - `burnbar-operator` skill — the digest below was already produced by
          BurnBar and is the only ground truth you have. Do not guess.
        - Skills you should NOT try to invoke: `comfyui`, `manim-video`,
          `p5js`, `pixel-art` (no image/video pipeline reaches this canvas).

        # STRICT OUTPUT FORMAT
        Respond with **one and only one** JSON object. No prose, no markdown,\
         no code fences. The object MUST match this schema:

        {
          "kind": "swift_chart" | "mermaid" | "insight" | "ascii" | "composed",
          "title": "Short title shown above the canvas",
          "swift_chart": { … } ,        // only when kind = "swift_chart"
          "mermaid":     { "title": "…", "source": "…" },          // only when kind = "mermaid"
          "insight":     { "title": "…", "body": "…", "sparkline": [Double], "tone": "positive|neutral|warning" }, // only when kind = "insight"
          "ascii":       { "title": "…", "subtitle": "…", "variant": "bar|sparkline|heatmap|banner|scene", "blocks": [ { "label": "…", "lines": ["…"], "accent": "#RRGGBB" } ], "footnote": "…" }, // only when kind = "ascii"
          "components":  [ Envelope, … ]  // only when kind = "composed"
        }

        # SUPPORTED swift_chart KINDS
        line, bar, stacked_bar, area, stacked_area, stream, scatter, heatmap, donut, rule.

        swift_chart spec:
        {
          "kind": "<one of the kinds above>",
          "title": "…",
          "subtitle": "…",
          "xAxis": { "title": "Date", "kind": "time|linear|category" },
          "yAxis": { "title": "Cost (USD)", "kind": "linear" },
          "series": [
            {
              "name": "Claude Code",
              "color": "#E07868",   // optional; leave null to inherit the palette
              "points": [
                { "x": "2026-04-30", "y": 18.42, "group": "Claude Code", "label": "Today" }
              ]
            }
          ],
          "annotations": [
            { "kind": "ruleX|ruleY|text", "x": "2026-04-30", "y": 0, "label": "Today" }
          ],
          "valueFormat": "currency|tokens|percent|raw"
        }

        # ASCII / UNICODE-BLOCK ART RULES
        Use the `ascii` kind when the user explicitly asks for "ASCII", "TUI",
        "terminal", "unicode", "block art", "retro", or when a small,
        glanceable answer reads better as monospace than as a real chart.

        - Pick a variant: `bar` (horizontal block-bars), `sparkline` (one or a
          few dense column rows like ▁▂▃▄▅▆▇█), `heatmap` (2D shaded grid
          using ░▒▓█), `banner` (a figlet-style title block), or `scene`
          (freeform terminal layout — boxes, frames, callouts).
        - Pre-render every block as ALREADY-ALIGNED monospace lines. Do not
          embed leading code-fence markers. Trust 1-character = 1 cell.
        - Use these character families:
            box-drawing:   ╭ ╮ ╯ ╰ ─ │ ├ ┤ ┬ ┴ ┼ ═ ║ ╔ ╗ ╚ ╝ ╠ ╣ ╦ ╩ ╬
            half-blocks:   ▁ ▂ ▃ ▄ ▅ ▆ ▇ █  (vertical bars)
            half-blocks:   ▏ ▎ ▍ ▌ ▋ ▊ ▉ █  (horizontal bars)
            shading:       ░ ▒ ▓ █          (heatmaps)
        - Cap each line at 80 cells. Cap each block at 40 lines.
        - `accent` is an optional `#RRGGBB` hex; the renderer tints the
          half-block characters in that block to that color.

        # DATA AVAILABLE TO YOU
        Use only fields that appear in the digest below. Never invent dates,
        providers, projects, or models. If the user asks for something not
        present, return an "insight" with kind:"insight" explaining the gap.

        # EXAMPLES
        // 1) bar chart of cost by provider over 7d
        {"kind":"swift_chart","title":"Cost by provider · 7d","swift_chart":{"kind":"bar","title":"Cost by provider · 7d","xAxis":{"title":"Provider","kind":"category"},"yAxis":{"title":"Cost (USD)","kind":"linear"},"series":[{"name":"USD","points":[{"x":"Claude Code","y":92.10,"group":"Claude Code"},{"x":"Codex","y":24.80,"group":"Codex"}]}],"valueFormat":"currency"}}

        // 2) Mermaid sequence diagram
        {"kind":"mermaid","title":"Agent → tool flow","mermaid":{"title":"Agent → tool flow","source":"sequenceDiagram\\nUser->>Agent: Plan\\nAgent->>Tool: search()\\nTool-->>Agent: results\\nAgent-->>User: response"}}

        // 3) Narrative insight
        {"kind":"insight","title":"Cache savings","insight":{"title":"Cache saved you ~$12.40","body":"Claude Code cache reads covered 58% of prompts this week.","sparkline":[1,2,3,4,5,6],"tone":"positive"}}

        // 4) ASCII bar chart — terminal aesthetic
        {"kind":"ascii","title":"This week · cost by provider","ascii":{"title":"This week · cost by provider","subtitle":"USD, last 7 days","variant":"bar","blocks":[{"label":"Claude Code","lines":["▉▉▉▉▉▉▉▉▉▉▉▉▉▉▉▉▉▉  $92.10"],"accent":"#E07868"},{"label":"Codex","lines":["▉▉▉▉▉  $24.80"],"accent":"#9080D8"},{"label":"Hermes","lines":["▉▉  $11.30"],"accent":"#C8BFB5"}],"footnote":"7-day window · cost only"}}

        // 5) ASCII sparkline — last 14 days
        {"kind":"ascii","title":"Burn velocity (14d)","ascii":{"variant":"sparkline","blocks":[{"label":"daily $","lines":["▁▂▂▃▅▆▇█▇▆▅▄▃▄"],"accent":"#2CCAC0"}],"footnote":"low ░ → high █"}}

        # ROUTING / DECISION RULES
        - Return JSON only. No prose, no fences, no commentary.
        - Always set the top-level "kind" field.
        - Choose the smallest payload that answers the question.
        - Prefer real data from the digest over placeholders.
        - Flowchart / sequence / state diagram → `mermaid`.
        - "Why so much?" / "what changed?" / narrative → `insight`.
        - "ASCII" / "terminal" / "TUI" / "retro" / quick glance → `ascii`.
        - Numeric chart / time series / scatter / heatmap → `swift_chart`.
        - "Insight + the chart that proves it" → `composed`.

        # DIGEST (read-only — these are the only data points you have):
        \(digest.compactJSON())
        """
    }

    /// Compose the request that hits `HermesService`. The system prompt is
    /// passed via the `context` argument the existing service supports.
    public func buildContext() -> String {
        systemPrompt()
    }

    /// Suggested prompt strings shown in the Studio carousel. These are
    /// written to read like the user asked them, so they can be sent
    /// verbatim by tapping a chip.
    public func suggestedPrompts() -> [String] {
        var prompts: [String] = [
            "Stack daily cost by provider over the last 30 days",
            "Heatmap of my burn by hour-of-day",
            "ASCII bar chart of cost by provider this week",
            "Mermaid sequence: Hermes routing my last session",
            "Compare cost-per-million-tokens across my models",
            "Where did my cache savings go this week?",
            "ASCII sparkline of daily burn (14 days)",
            "Donut: token share by provider",
            "Terminal banner with my top model name",
            "Scatter sessions by duration vs cache hit rate"
        ]
        if let topProvider = digest.providers.first {
            prompts.insert("Why is \(topProvider.provider) so dominant?", at: 0)
        }
        if let topModel = digest.models.first {
            prompts.append("Mermaid: \(topModel.model) tool-call flow")
        }
        return prompts
    }
}
