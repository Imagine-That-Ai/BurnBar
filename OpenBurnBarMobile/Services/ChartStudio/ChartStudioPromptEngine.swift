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
         response that the iOS app renders natively (no images, no HTML).

        STRICT OUTPUT FORMAT
        Respond with **one and only one** JSON object. No prose, no markdown,\
         no code fences. The object MUST match this schema:

        {
          "kind": "swift_chart" | "mermaid" | "insight" | "composed",
          "title": "Short title shown above the canvas",
          "swift_chart": { … } ,   // only when kind = "swift_chart"
          "mermaid":     { "title": "…", "source": "…" },   // only when kind = "mermaid"
          "insight":     { "title": "…", "body": "…", "sparkline": [Double], "tone": "positive|neutral|warning" }, // only when kind = "insight"
          "components":  [ Envelope, … ]  // only when kind = "composed"
        }

        SUPPORTED swift_chart KINDS
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

        DATA AVAILABLE TO YOU
        Use only fields that appear in the digest below. Never invent dates,\
         providers, projects, or models. If the user asks for something not\
         present, return an "insight" with kind:"insight" explaining the gap.

        EXAMPLES
        // Example 1 — bar chart of cost by provider over 7d
        {"kind":"swift_chart","title":"Cost by provider · 7d","swift_chart":{"kind":"bar","title":"Cost by provider · 7d","xAxis":{"title":"Provider","kind":"category"},"yAxis":{"title":"Cost (USD)","kind":"linear"},"series":[{"name":"USD","points":[{"x":"Claude Code","y":92.10,"group":"Claude Code"},{"x":"Codex","y":24.80,"group":"Codex"}]}],"valueFormat":"currency"}}

        // Example 2 — Mermaid sequence diagram
        {"kind":"mermaid","title":"Agent → tool flow","mermaid":{"title":"Agent → tool flow","source":"sequenceDiagram\\nUser->>Agent: Plan\\nAgent->>Tool: search()\\nTool-->>Agent: results\\nAgent-->>User: response"}}

        // Example 3 — narrative insight
        {"kind":"insight","title":"Cache savings","insight":{"title":"Cache saved you ~$12.40","body":"Claude Code cache reads covered 58% of prompts this week.","sparkline":[1,2,3,4,5,6],"tone":"positive"}}

        RULES
        - Return JSON only. No prose, no fences, no commentary.
        - Always set the top-level "kind" field.
        - Choose the smallest payload that answers the question.
        - Prefer real data from the digest over placeholders.
        - When the user asks for a flowchart / sequence / state diagram, return mermaid.
        - When the user asks for a number-narrative ("why so much?"), return insight.
        - When asked for a composed answer, use kind:"composed" with components.

        DIGEST (read-only — these are the only data points you have):
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
            "Mermaid sequence: Hermes routing my last session",
            "Compare cost-per-million-tokens across my models",
            "Where did my cache savings go this week?",
            "Donut: token share by provider",
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
