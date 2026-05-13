import Foundation

/// JSON Schema for the canvas-shaped response we ask LLMs to produce.
///
/// Used in tier-1 strict-schema mode (Anthropic, OpenAI). For tier-2
/// (`json_object`) we still embed this in the system prompt so the model
/// has a concrete shape to follow.
public enum InsightJSONSchema {

    public static let canvasSchemaV1: String = """
    {
      "$schema": "https://json-schema.org/draft/2020-12/schema",
      "type": "object",
      "additionalProperties": false,
      "required": ["title", "widgets"],
      "properties": {
        "title": { "type": "string", "minLength": 1, "maxLength": 80 },
        "summary": { "type": "string", "maxLength": 240 },
        "symbolName": { "type": "string", "default": "sparkles.tv" },
        "theme": { "type": "string", "enum": ["aurora", "ember", "mercury", "whimsy", "mono", "print"] },
        "filterWindow": {
          "type": "string",
          "enum": ["today", "last24h", "last7d", "last30d", "last90d", "last365d", "allTime"]
        },
        "widgets": {
          "type": "array",
          "minItems": 1,
          "maxItems": 12,
          "items": { "$ref": "#/$defs/widget" }
        }
      },
      "$defs": {
        "widget": {
          "type": "object",
          "required": ["kind", "title", "spec", "dataBinding"],
          "additionalProperties": false,
          "properties": {
            "kind": {
              "type": "string",
              "enum": [
                "kpiTile", "timeSeriesLine", "timeSeriesArea", "streamGraph",
                "barRanking", "donut", "treemap", "heatmap", "scatter", "sankey",
                "radar", "cohort", "funnel", "quotaPulse", "forecast",
                "anomalyTable", "narrative", "recommendation", "useCaseCluster",
                "agentFocusMatrix", "modelFocusMatrix", "drilldownList",
                "mermaid", "ascii", "composed"
              ]
            },
            "title": { "type": "string", "minLength": 1, "maxLength": 80 },
            "subtitle": { "type": "string", "maxLength": 160 },
            "rationale": { "type": "string", "maxLength": 400 },
            "spec":        { "type": "object" },
            "dataBinding": { "type": "object" },
            "filter":      { "type": "object" }
          }
        }
      }
    }
    """
}
