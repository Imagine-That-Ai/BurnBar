// ---------------------------------------------------------------------------
// Insight Analysis schema — canonical contract
//
// This is the cross-platform contract for the LLM-backed analysis layer that
// sits ABOVE the existing canvas/widget visual contract. Swift
// (`OpenBurnBarCore/.../InsightAnalysis.swift`) is the source-of-truth shape;
// this file mirrors it for the Functions backend, and the Kotlin port at
// `android/.../data/insights/analysis/InsightAnalysis.kt` mirrors both.
//
// Privacy contract (must hold across every platform):
//   - The analysis layer NEVER ships secrets, credentials, raw source files,
//     or full transcripts unless `InsightAnalysisRequest.allowDeepTranscriptAnalysis`
//     is true. Even then, the engine emits a budget warning the UI must
//     surface before sending.
//   - Every analysis run writes one `InsightAnalysisAuditEntry`.
// ---------------------------------------------------------------------------

import type {
  InsightCanvasDoc,
  InsightCitationDoc,
  InsightDigestDoc,
  InsightEgressTier,
  InsightModelTagDoc,
  InsightTimeWindowDoc,
  InsightTokenUsageDoc,
  InsightWidgetDoc,
} from "./types.js";

// ---------------------------------------------------------------------------
// Schema versioning
// ---------------------------------------------------------------------------

export const INSIGHT_ANALYSIS_SCHEMA_VERSION = 1 as const;

/** Wire-format platform identifier; matches `InsightAnalysisPlatform` in Swift/Kotlin. */
export type InsightAnalysisPlatform = "macOS" | "iOS" | "iPadOS" | "android";

export type InsightConfidence = "low" | "medium" | "high";

export type InsightSeverity = "info" | "low" | "medium" | "high" | "critical";

export type InsightAnalysisInstruction =
  | "defaultBrief"
  | "answerFollowUp"
  | "generateReport"
  | "updateCanvas";

export type InsightAnalysisStatus =
  | "started"
  | "succeeded"
  | "partial"
  | "modelUnavailable"
  | "schemaViolation"
  | "cancelled"
  | "failed";

// ---------------------------------------------------------------------------
// Context budget report
// ---------------------------------------------------------------------------

/**
 * Audit-grade summary of what the engine actually shipped to the model.
 *
 * `includedDataSources` and `truncatedDataSources` are stable identifier
 * strings (e.g. "rollups.last7d", "quotaSnapshots", "sessions.transcripts")
 * so the audit view can group runs and so privacy reviews can be diffed
 * across platforms.
 */
export interface InsightContextBudgetReport {
  maxEncodedBytes: number;
  encodedBytes: number;
  estimatedPromptTokens: number;
  includedDataSources: string[];
  truncatedDataSources: string[];
  truncationSummary: string;
}

// ---------------------------------------------------------------------------
// Evidence + context
// ---------------------------------------------------------------------------

export interface InsightEvidence {
  id: string;
  citation: InsightCitationDoc;
  source: string;
  summary: string;
  numericValue?: number;
}

export interface InsightEvidencePack {
  id: string;
  sourcePlatform: InsightAnalysisPlatform;
  generatedAt: string;
  timeWindow: InsightTimeWindowDoc;
  includedDataSources: string[];
  budgetReport: InsightContextBudgetReport;
  evidence: InsightEvidence[];
  summary: string;
  contentHash: string;
  deepTranscriptIncluded: boolean;
}

export interface InsightPlatformCapabilityReport {
  platform: InsightAnalysisPlatform;
  providerFamilies: InsightProviderFamily[];
  includedDataSources: string[];
  supportsDeepLocalLogs: boolean;
  supportsSyncedEvidencePacks: boolean;
  supportsModelSelection: boolean;
  supportsConversation: boolean;
  supportsGeneratedWidgetPinning: boolean;
  supportsAuditAndCache: boolean;
  gaps: string[];
}

export interface InsightAnalysisContext {
  digest: InsightDigestDoc;
  evidenceIndex: InsightEvidence[];
  budgetReport: InsightContextBudgetReport;
  /** Compact summaries of prior runs the engine should not duplicate. */
  priorRunSummaries: string[];
  evidencePacks: InsightEvidencePack[];
}

// ---------------------------------------------------------------------------
// Request
// ---------------------------------------------------------------------------

export interface InsightAnalysisRequest {
  id: string;
  prompt: string;
  context: InsightAnalysisContext;
  /** When refining an existing canvas, the host passes it through here. */
  currentCanvas?: InsightCanvasDoc;
  selectedModel: InsightModelTagDoc;
  instruction: InsightAnalysisInstruction;
  /**
   * Opt-in for transcript-level analysis. When false (the default), the
   * engine will not include raw or summarized message bodies in the context.
   */
  allowDeepTranscriptAnalysis: boolean;
  maxGeneratedWidgets: number;
}

// ---------------------------------------------------------------------------
// Result + leaf types
// ---------------------------------------------------------------------------

export interface InsightFinding {
  id: string;
  title: string;
  whyItMatters: string;
  evidence: InsightCitationDoc[];
  confidence: InsightConfidence;
  severity: InsightSeverity;
  recommendedAction: string;
  /** When set, references a generated widget the user can pin alongside this finding. */
  generatedWidgetID?: string;
}

export interface InsightAnomaly {
  id: string;
  title: string;
  occurredAt?: string;
  detail: string;
  score: number;
  evidence: InsightCitationDoc[];
  confidence: InsightConfidence;
}

export interface InsightRecommendation {
  id: string;
  title: string;
  rationale: string;
  recommendedAction: string;
  estimatedImpact?: string;
  evidence: InsightCitationDoc[];
  confidence: InsightConfidence;
  severity: InsightSeverity;
}

/**
 * A widget the engine wants the UI to materialize. The widget itself reuses
 * the existing `InsightWidgetDoc` so it slots straight into the canvas grid.
 */
export interface InsightGeneratedWidget {
  id: string;
  widget: InsightWidgetDoc;
  reason: string;
  citations: InsightCitationDoc[];
}

export interface InsightFollowUpQuestion {
  id: string;
  question: string;
  rationale?: string;
}

export interface InsightAnalysisResult {
  id: string;
  requestID: string;
  schemaVersion: typeof INSIGHT_ANALYSIS_SCHEMA_VERSION;
  generatedAt: string;
  platform: InsightAnalysisPlatform;
  timeWindow: InsightTimeWindowDoc;
  executiveSummary: string;
  modelTag: InsightModelTagDoc;
  contextBudget: InsightContextBudgetReport;
  findings: InsightFinding[];
  anomalies: InsightAnomaly[];
  recommendations: InsightRecommendation[];
  generatedWidgets: InsightGeneratedWidget[];
  followUpQuestions: InsightFollowUpQuestion[];
  citations: InsightCitationDoc[];
  tokenUsage?: InsightTokenUsageDoc;
  estimatedCostUSD?: number;
  /** Reference to the audit entry the engine wrote. */
  auditID?: string;
  /** Stable SHA-256 digest of the canonical result body. */
  resultHash: string;
}

// ---------------------------------------------------------------------------
// Audit entry
// ---------------------------------------------------------------------------

export interface InsightAnalysisAuditEntry {
  id: string;
  requestID: string;
  platform: InsightAnalysisPlatform;
  selectedModel: InsightModelTagDoc;
  egressTier: InsightEgressTier;
  timeWindow: InsightTimeWindowDoc;
  contextBudget: InsightContextBudgetReport;
  includedDataSources: string[];
  truncationSummary: string;
  promptHash: string;
  resultHash: string;
  status: InsightAnalysisStatus;
  startedAt: string;
  completedAt?: string;
  errorDescription?: string;
  tokenUsage?: InsightTokenUsageDoc;
  estimatedCostUSD?: number;
  ranAt: string;
}

// ---------------------------------------------------------------------------
// Model preference
// ---------------------------------------------------------------------------

export type InsightModelPreferenceMode = "automatic" | "explicit";

export interface InsightModelPreference {
  mode: InsightModelPreferenceMode;
  /** Required when mode === "explicit". */
  explicitModel?: InsightModelTagDoc;
  /**
   * If true, the picker only surfaces models with `egressTier === "localOnly"`.
   * The engine refuses to dispatch to non-local models when this is set.
   */
  restrictToLocalOnly: boolean;
  /** Hard ceiling for routing — the engine will not exceed this tier. */
  maxEgressTier?: InsightEgressTier;
  /**
   * Whether the user has accepted the deep-transcript opt-in for this
   * preference. The composer shows the larger-budget warning when true.
   */
  deepTranscriptOptIn: boolean;
}

export const DEFAULT_INSIGHT_MODEL_PREFERENCE: InsightModelPreference = {
  mode: "automatic",
  restrictToLocalOnly: false,
  deepTranscriptOptIn: false,
};

// ---------------------------------------------------------------------------
// Provider family (catalog normalization)
// ---------------------------------------------------------------------------

/**
 * Normalized family the picker groups models by. Each platform's catalog
 * adapter maps its raw provider entries into one of these values so the UI
 * can show a single grouped list (Codex, Claude, MiniMax, Z.ai, Kimi,
 * Ollama, Hermes-advertised).
 */
export type InsightProviderFamily =
  | "codex"
  | "claude"
  | "minimax"
  | "zai"
  | "kimi"
  | "ollama"
  | "hermes"
  | "openai"
  | "pi"
  | "openrouter"
  | "local-rules"
  | "other";

export interface InsightProviderFamilyEntry {
  family: InsightProviderFamily;
  providerKey: string;
  modelID: string;
  displayName: string;
  egressTier: InsightEgressTier;
  /** USD per million input/output tokens, for cost estimate badges. */
  inputCostPerMtoken?: number;
  outputCostPerMtoken?: number;
  /** SF Symbol or family logo asset name. */
  symbolName?: string;
  /** True when the model is the host's default for `automatic` resolution. */
  isAutomaticDefault?: boolean;
}

// ---------------------------------------------------------------------------
// Generated audit collection (Firestore document path):
//   users/{uid}/insight_analyses/{auditID}
// ---------------------------------------------------------------------------
export const INSIGHT_ANALYSIS_AUDIT_COLLECTION = "insight_analyses" as const;

// ---------------------------------------------------------------------------
// JSON Schema (Draft 2020-12) for the structured analysis result.
//
// Mirrors `InsightJSONSchema.analysisResultSchemaV1` in Swift and Kotlin.
// Engines must validate the LLM payload against this schema before
// constructing `InsightAnalysisResult`.
// ---------------------------------------------------------------------------

export const InsightJSONSchema = {
  analysisResultSchemaV1: {
    $schema: "https://json-schema.org/draft/2020-12/schema",
    type: "object",
    additionalProperties: false,
    required: [
      "executiveSummary",
      "findings",
      "anomalies",
      "recommendations",
      "citations",
      "generatedWidgets",
      "followUpQuestions",
    ],
    properties: {
      executiveSummary: { type: "string", minLength: 1, maxLength: 800 },
      findings: { type: "array", maxItems: 8, items: { $ref: "#/$defs/finding" } },
      anomalies: { type: "array", maxItems: 8, items: { $ref: "#/$defs/anomaly" } },
      recommendations: {
        type: "array",
        maxItems: 8,
        items: { $ref: "#/$defs/recommendation" },
      },
      generatedWidgets: {
        type: "array",
        maxItems: 8,
        items: { $ref: "#/$defs/generatedWidget" },
      },
      followUpQuestions: {
        type: "array",
        maxItems: 8,
        items: { $ref: "#/$defs/followUpQuestion" },
      },
      citations: { type: "array", items: { $ref: "#/$defs/citationRef" } },
    },
    $defs: {
      confidence: { type: "string", enum: ["low", "medium", "high"] },
      severity: { type: "string", enum: ["info", "low", "medium", "high", "critical"] },
      citationRef: {
        type: "object",
        additionalProperties: false,
        required: ["id", "label"],
        properties: {
          id: { type: "string", minLength: 1, maxLength: 120 },
          label: { type: "string", minLength: 1, maxLength: 120 },
        },
      },
      finding: {
        type: "object",
        additionalProperties: false,
        required: [
          "title",
          "whyItMatters",
          "evidence",
          "confidence",
          "severity",
          "recommendedAction",
        ],
        properties: {
          title: { type: "string", minLength: 1, maxLength: 120 },
          whyItMatters: { type: "string", minLength: 1, maxLength: 600 },
          evidence: { type: "array", items: { $ref: "#/$defs/citationRef" } },
          confidence: { $ref: "#/$defs/confidence" },
          severity: { $ref: "#/$defs/severity" },
          recommendedAction: { type: "string", minLength: 1, maxLength: 500 },
        },
      },
      anomaly: {
        type: "object",
        additionalProperties: false,
        required: ["title", "detail", "score", "evidence", "confidence"],
        properties: {
          title: { type: "string", minLength: 1, maxLength: 120 },
          detail: { type: "string", minLength: 1, maxLength: 600 },
          score: { type: "number" },
          evidence: { type: "array", items: { $ref: "#/$defs/citationRef" } },
          confidence: { $ref: "#/$defs/confidence" },
        },
      },
      recommendation: {
        type: "object",
        additionalProperties: false,
        required: [
          "title",
          "rationale",
          "recommendedAction",
          "evidence",
          "confidence",
          "severity",
        ],
        properties: {
          title: { type: "string", minLength: 1, maxLength: 120 },
          rationale: { type: "string", minLength: 1, maxLength: 600 },
          recommendedAction: { type: "string", minLength: 1, maxLength: 500 },
          estimatedImpact: { type: "string", maxLength: 240 },
          evidence: { type: "array", items: { $ref: "#/$defs/citationRef" } },
          confidence: { $ref: "#/$defs/confidence" },
          severity: { $ref: "#/$defs/severity" },
        },
      },
      generatedWidget: {
        type: "object",
        additionalProperties: false,
        required: ["kind", "title", "reason", "citations"],
        properties: {
          kind: { type: "string" },
          title: { type: "string", minLength: 1, maxLength: 80 },
          reason: { type: "string", minLength: 1, maxLength: 300 },
          citations: { type: "array", items: { $ref: "#/$defs/citationRef" } },
        },
      },
      followUpQuestion: {
        type: "object",
        additionalProperties: false,
        required: ["question"],
        properties: {
          question: { type: "string", minLength: 1, maxLength: 160 },
          rationale: { type: "string", maxLength: 240 },
        },
      },
    },
  },
} as const;

export type InsightAnalysisResultSchemaV1 =
  (typeof InsightJSONSchema)["analysisResultSchemaV1"];
