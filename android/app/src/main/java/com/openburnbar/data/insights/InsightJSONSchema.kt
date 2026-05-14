package com.openburnbar.data.insights

/**
 * JSON Schema (Draft 2020-12) for the structured `InsightAnalysisResult`.
 *
 * Mirrors `InsightJSONSchema.analysisResultSchemaV1` in
 * `OpenBurnBarCore/.../InsightJSONSchema.swift` and
 * `functions/src/insightAnalysis.ts`.
 *
 * Tier-1 model gateways receive this as `response_format`; tier-2
 * (`json_object`) callers embed it in the system prompt. Tier-3 (narrative-
 * only) callers fall back to a single executive summary + zero generated
 * widgets.
 */
object InsightJSONSchema {
    const val analysisResultSchemaV1: String = """
    {
      "${"$"}schema": "https://json-schema.org/draft/2020-12/schema",
      "type": "object",
      "additionalProperties": false,
      "required": [
        "executiveSummary", "findings", "anomalies", "recommendations",
        "generatedWidgets", "followUpQuestions", "citations"
      ],
      "properties": {
        "executiveSummary": { "type": "string", "minLength": 1, "maxLength": 800 },
        "findings": { "type": "array", "minItems": 0, "maxItems": 8, "items": { "${"$"}ref": "#/${"$"}defs/finding" } },
        "anomalies": { "type": "array", "minItems": 0, "maxItems": 8, "items": { "${"$"}ref": "#/${"$"}defs/anomaly" } },
        "recommendations": { "type": "array", "minItems": 0, "maxItems": 8, "items": { "${"$"}ref": "#/${"$"}defs/recommendation" } },
        "missionCandidates": { "type": "array", "minItems": 0, "maxItems": 8, "items": { "${"$"}ref": "#/${"$"}defs/missionCandidate" } },
        "generatedWidgets": { "type": "array", "minItems": 0, "maxItems": 8, "items": { "${"$"}ref": "#/${"$"}defs/generatedWidget" } },
        "followUpQuestions": { "type": "array", "minItems": 0, "maxItems": 8, "items": { "${"$"}ref": "#/${"$"}defs/followUpQuestion" } },
        "citations": { "type": "array", "items": { "${"$"}ref": "#/${"$"}defs/citationRef" } }
      },
      "${"$"}defs": {
        "confidence": { "type": "string", "enum": ["low", "medium", "high"] },
        "severity": { "type": "string", "enum": ["info", "low", "medium", "high", "critical"] },
        "citationRef": {
          "type": "object",
          "additionalProperties": false,
          "required": ["id", "label"],
          "properties": {
            "id": { "type": "string", "minLength": 1, "maxLength": 120 },
            "label": { "type": "string", "minLength": 1, "maxLength": 120 }
          }
        },
        "finding": {
          "type": "object",
          "additionalProperties": false,
          "required": ["title", "whyItMatters", "evidence", "confidence", "severity", "recommendedAction"],
          "properties": {
            "title": { "type": "string", "minLength": 1, "maxLength": 120 },
            "whyItMatters": { "type": "string", "minLength": 1, "maxLength": 600 },
            "evidence": { "type": "array", "items": { "${"$"}ref": "#/${"$"}defs/citationRef" } },
            "confidence": { "${"$"}ref": "#/${"$"}defs/confidence" },
            "severity": { "${"$"}ref": "#/${"$"}defs/severity" },
            "recommendedAction": { "type": "string", "minLength": 1, "maxLength": 500 }
          }
        },
        "anomaly": {
          "type": "object",
          "additionalProperties": false,
          "required": ["title", "detail", "score", "evidence", "confidence"],
          "properties": {
            "title": { "type": "string", "minLength": 1, "maxLength": 120 },
            "detail": { "type": "string", "minLength": 1, "maxLength": 600 },
            "score": { "type": "number" },
            "evidence": { "type": "array", "items": { "${"$"}ref": "#/${"$"}defs/citationRef" } },
            "confidence": { "${"$"}ref": "#/${"$"}defs/confidence" }
          }
        },
        "recommendation": {
          "type": "object",
          "additionalProperties": false,
          "required": ["title", "rationale", "recommendedAction", "evidence", "confidence", "severity"],
          "properties": {
            "title": { "type": "string", "minLength": 1, "maxLength": 120 },
            "rationale": { "type": "string", "minLength": 1, "maxLength": 600 },
            "recommendedAction": { "type": "string", "minLength": 1, "maxLength": 500 },
            "estimatedImpact": { "type": "string", "maxLength": 240 },
            "evidence": { "type": "array", "items": { "${"$"}ref": "#/${"$"}defs/citationRef" } },
            "confidence": { "${"$"}ref": "#/${"$"}defs/confidence" },
            "severity": { "${"$"}ref": "#/${"$"}defs/severity" }
          }
        },
        "missionCandidate": {
          "type": "object",
          "additionalProperties": false,
          "required": ["title", "summary", "lens", "priority", "confidence", "expectedImpact", "effort", "acceptanceCriteria", "evidence"],
          "properties": {
            "title": { "type": "string", "minLength": 1, "maxLength": 140 },
            "summary": { "type": "string", "minLength": 1, "maxLength": 700 },
            "projectID": { "type": "string", "maxLength": 160 },
            "projectDisplayName": { "type": "string", "maxLength": 160 },
            "lens": { "type": "string", "enum": ["accretion", "diligence", "techDebt", "routing", "quota", "focus"] },
            "priority": { "type": "string", "enum": ["low", "medium", "high", "critical"] },
            "confidence": { "${"$"}ref": "#/${"$"}defs/confidence" },
            "expectedImpact": { "type": "string", "minLength": 1, "maxLength": 400 },
            "effort": { "type": "string", "enum": ["small", "medium", "large"] },
            "acceptanceCriteria": { "type": "array", "minItems": 1, "maxItems": 6, "items": { "type": "string", "minLength": 1, "maxLength": 180 } },
            "sourceInsightIDs": { "type": "array", "items": { "type": "string", "minLength": 1, "maxLength": 120 } },
            "evidence": { "type": "array", "items": { "${"$"}ref": "#/${"$"}defs/citationRef" } },
            "dispatchMetadata": { "type": "object", "additionalProperties": { "type": "string", "maxLength": 160 } }
          }
        },
        "generatedWidget": {
          "type": "object",
          "additionalProperties": false,
          "required": ["kind", "title", "reason", "citations"],
          "properties": {
            "kind": { "type": "string" },
            "title": { "type": "string", "minLength": 1, "maxLength": 80 },
            "reason": { "type": "string", "minLength": 1, "maxLength": 300 },
            "citations": { "type": "array", "items": { "${"$"}ref": "#/${"$"}defs/citationRef" } }
          }
        },
        "followUpQuestion": {
          "type": "object",
          "additionalProperties": false,
          "required": ["question"],
          "properties": {
            "question": { "type": "string", "minLength": 1, "maxLength": 160 },
            "rationale": { "type": "string", "maxLength": 240 }
          }
        }
      }
    }
    """
}
