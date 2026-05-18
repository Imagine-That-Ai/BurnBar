import Foundation

/// JSON Schema (draft 2020-12) the LLM verdict author is constrained to.
///
/// Embedded as a Swift string literal so the prompt builder can inline it
/// verbatim. The post-processor (`InsightVoicePostProcessor`) re-validates
/// every shipped output against this contract.
///
/// **Important:** this schema describes the LLM's *narrative* slots only.
/// It is intentionally a strict subset of `InsightVerdict` — fields like
/// `rings` and `keyNumbers` are computed by the local executor and are
/// *not* authored by the model. Keeping the LLM surface narrow is how we
/// prevent free-form narration from leaking into chart-eligible state.
public enum InsightVoiceSchemaV2 {

    /// The canonical JSON Schema document.
    public static let jsonSchema: String = #"""
    {
      "$schema": "https://json-schema.org/draft/2020-12/schema",
      "$id": "https://burnbar.ai/insights/voice-v2.schema.json",
      "title": "InsightVerdict.voice",
      "type": "object",
      "required": ["headline", "bullets", "provenance", "confidence"],
      "additionalProperties": false,
      "properties": {
        "headline": {
          "type": "string",
          "minLength": 8,
          "maxLength": 80,
          "description": "Declarative one-sentence verdict. No greeting, no hedging."
        },
        "subhead": {
          "type": ["string", "null"],
          "maxLength": 120,
          "description": "Optional one-sentence amplification."
        },
        "bullets": {
          "type": "array",
          "minItems": 1,
          "maxItems": 4,
          "items": {
            "type": "object",
            "required": ["claim", "type", "citations"],
            "additionalProperties": false,
            "properties": {
              "claim": {
                "type": "string",
                "minLength": 8,
                "maxLength": 200,
                "description": "Specific quantitative claim. Must contain ≥1 numeric token."
              },
              "type": {
                "type": "string",
                "enum": [
                  "reflective_fact",
                  "comparison",
                  "pattern",
                  "anomaly",
                  "recommendation",
                  "discovery",
                  "forecast",
                  "achievement",
                  "risk",
                  "story"
                ]
              },
              "citations": {
                "type": "array",
                "minItems": 1,
                "items": {
                  "type": "string",
                  "pattern": "^[A-Za-z0-9_\\-]+$",
                  "description": "Session ID (or other digest-known identifier)."
                }
              },
              "delta": {
                "type": ["object", "null"],
                "additionalProperties": false,
                "required": ["value", "unit", "baseline"],
                "properties": {
                  "value": { "type": "number" },
                  "unit": {
                    "type": "string",
                    "enum": ["usd", "tokens", "sessions", "pct", "days", "ms", "ratio", "count"]
                  },
                  "baseline": { "type": "string", "maxLength": 60 }
                }
              },
              "acceptAction": {
                "type": ["object", "null"],
                "additionalProperties": false,
                "required": ["label", "intent"],
                "properties": {
                  "label": { "type": "string", "maxLength": 28 },
                  "intent": {
                    "type": "string",
                    "enum": [
                      "switchRouterRule",
                      "pinCanvas",
                      "openSession",
                      "openSettings",
                      "openExternal",
                      "createMission",
                      "investigate",
                      "snooze"
                    ]
                  },
                  "payload": {
                    "type": ["object", "null"],
                    "additionalProperties": { "type": "string" }
                  }
                }
              }
            }
          }
        },
        "anomaly": {
          "type": ["object", "null"],
          "additionalProperties": false,
          "required": ["label", "detail", "zScore", "citations"],
          "properties": {
            "label": { "type": "string", "maxLength": 80 },
            "detail": { "type": "string", "maxLength": 200 },
            "occurredAt": { "type": "string", "format": "date-time" },
            "zScore": { "type": "number", "minimum": 2.0 },
            "affectedSessionIDs": {
              "type": "array",
              "items": { "type": "string" }
            },
            "citations": {
              "type": "array",
              "minItems": 1,
              "items": { "type": "string" }
            }
          }
        },
        "recommendation": {
          "type": ["object", "null"],
          "additionalProperties": false,
          "required": ["headline", "rationale", "expectedImpact", "acceptAction", "citations"],
          "properties": {
            "headline": { "type": "string", "maxLength": 80 },
            "rationale": { "type": "string", "maxLength": 200 },
            "expectedImpact": { "type": "string", "maxLength": 60 },
            "acceptAction": { "$ref": "#/properties/bullets/items/properties/acceptAction" },
            "citations": {
              "type": "array",
              "minItems": 1,
              "items": { "type": "string" }
            }
          }
        },
        "provenance": {
          "type": "object",
          "additionalProperties": false,
          "required": ["modelID", "providerKey", "egressTier"],
          "properties": {
            "modelID": { "type": "string", "minLength": 1 },
            "providerKey": { "type": "string", "minLength": 1 },
            "egressTier": {
              "type": "string",
              "enum": ["localOnly", "userKey", "userRelay", "hosted"]
            }
          }
        },
        "confidence": { "type": "string", "enum": ["low", "medium", "high"] },
        "followUps": {
          "type": "array",
          "minItems": 0,
          "maxItems": 3,
          "items": { "type": "string", "maxLength": 100 }
        }
      }
    }
    """#

    /// Banned phrase fragments (lowercased). The post-processor drops any
    /// bullet containing one of these. Order is irrelevant; the matcher
    /// is a case-insensitive substring scan.
    public static let bannedPhrases: [String] = [
        "based on the data",
        "it seems that",
        "it appears that",
        "leveraging",
        "leverage",
        "significant",
        "substantial",
        "notable",
        "considerable",
        "robust",
        "harness the power",
        "in conclusion",
        "moving forward",
        "going forward",
        "welcome back",
        "as we can see",
        "it is worth noting",
        "delve into",
        "navigating",
        "unleash",
        "unlock the potential"
    ]

    /// The accept-action intent registry. The post-processor demotes any
    /// bullet whose `acceptAction.intent` isn't in this set to a no-action
    /// bullet rather than dropping it entirely.
    public static let allowedActionIntents: Set<String> = Set(
        VerdictAcceptAction.Intent.allCases.map(\.rawValue)
    )
}
