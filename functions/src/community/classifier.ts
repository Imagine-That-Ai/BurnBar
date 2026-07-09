/**
 * @fileoverview Canonical model-purpose classifier — shared spec for all
 * BurnBar Community platforms.
 *
 * Categories: ui, backend, logic, writing, research, debugging, orchestration, other.
 * Inferred from session context, model metadata, app surface, and file signals.
 *
 * This is the CANONICAL implementation. Swift/Kotlin/C# ports must produce
 * identical results for the same input signals. Golden fixtures in
 * tests/fixtures/classifier-goldens.json verify cross-platform parity.
 *
 * Design principles:
 *   - Deterministic: same inputs → same output, no randomness.
 *   - Signal-weighted: each signal contributes a score to one or more categories;
 *     the highest-scoring category wins.
 *   - Correction-biasable: user corrections persist locally and override the
 *     inferred label when the same signal pattern recurs.
 *   - Privacy-preserving: only metadata signals, never prompt content.
 */

/** The eight canonical purpose categories. */
export type ModelPurposeCategory =
  | "ui"
  | "backend"
  | "logic"
  | "writing"
  | "research"
  | "debugging"
  | "orchestration"
  | "other";

export const PURPOSE_CATEGORIES: readonly ModelPurposeCategory[] = [
  "ui",
  "backend",
  "logic",
  "writing",
  "research",
  "debugging",
  "orchestration",
  "other",
];

/** Input signals for classification — all metadata, no content. */
export interface ClassifierSignals {
  /** File extensions mentioned in the session context (e.g. ["swift", "kt", "md"]). */
  fileExtensions?: readonly string[];
  /** Model being used (e.g. "claude-3.5-sonnet", "gpt-4o"). */
  model?: string;
  /** App surface where the session originated (e.g. "chat", "dashboard", "editor"). */
  appSurface?: string;
  /** Whether the session involves code execution / terminal output. */
  hasCodeExecution?: boolean;
  /** Whether error messages or stack traces are present. */
  hasErrorOutput?: boolean;
  /** Whether web search results are referenced. */
  hasSearchResults?: boolean;
  /** Whether the session involves multi-step planning or agent orchestration. */
  hasMultiStepPlanning?: boolean;
  /** Session title or summary keywords (lowercased, already sanitized). */
  keywords?: readonly string[];
}

/** A correction entry biases future inference when the same pattern recurs. */
export interface PurposeCorrection {
  /** The signal fingerprint that triggered the correction. */
  fingerprint: string;
  /** The user-corrected category. */
  correctedTo: ModelPurposeCategory;
}

/** Classification result with confidence. */
export interface ClassificationResult {
  category: ModelPurposeCategory;
  /** Confidence score (0..1) — the winning category's share of total signal weight. */
  confidence: number;
  /** Signals that contributed to this classification. */
  contributingSignals: readonly string[];
}

// ---------------------------------------------------------------------------
// Signal weights
// ---------------------------------------------------------------------------

/**
 * File extension → category mapping. Extensions strongly suggest a purpose
 * category. These are the canonical weights; ports must use identical values.
 */
const FILE_EXTENSION_MAP: Record<string, ModelPurposeCategory> = {
  // UI
  swift: "ui", // SwiftUI views are dominant on Apple platforms
  xaml: "ui",
  css: "ui",
  scss: "ui",
  html: "ui",
  vue: "ui",
  svelte: "ui",
  // Backend
  go: "backend",
  rs: "backend",
  py: "backend",
  java: "backend",
  kt: "backend",
  sql: "backend",
  proto: "backend",
  grpc: "backend",
  // Logic
  ts: "logic",
  tsx: "logic",
  js: "logic",
  mjs: "logic",
  cjs: "logic",
  dart: "logic",
  // Writing
  md: "writing",
  txt: "writing",
  rst: "writing",
  docx: "writing",
  pdf: "writing",
  // Research
  json: "research",
  yaml: "research",
  yml: "research",
  csv: "research",
  toml: "research",
};

/** Keyword → category mapping for session title/summary keywords. */
const KEYWORD_MAP: Record<string, ModelPurposeCategory> = {
  // UI
  ui: "ui", design: "ui", frontend: "ui", layout: "ui", view: "ui", button: "ui",
  animation: "ui", theme: "ui", color: "ui", responsive: "ui", accessibility: "ui",
  // Backend
  api: "backend", server: "backend", database: "backend", migration: "backend",
  endpoint: "backend", auth: "backend", deploy: "backend", docker: "backend",
  kubernetes: "backend", grpc: "backend",
  // Logic
  refactor: "logic", algorithm: "logic", function: "logic", type: "logic",
  interface: "logic", state: "logic", model: "logic", parse: "logic",
  // Writing
  docs: "writing", documentation: "writing", readme: "writing", blog: "writing",
  article: "writing", essay: "writing", summary: "writing",
  // Research
  research: "research", search: "research", analyze: "research", data: "research",
  benchmark: "research", evaluate: "research",
  // Debugging
  bug: "debugging", error: "debugging", fix: "debugging", crash: "debugging",
  stacktrace: "debugging", debug: "debugging", test: "debugging", fail: "debugging",
  // Orchestration
  plan: "orchestration", workflow: "orchestration", pipeline: "orchestration",
  agent: "orchestration", automate: "orchestration", schedule: "orchestration",
  mission: "orchestration",
};

/**
 * Model bias — some models are used more for certain purposes.
 *
 * ORDERED ARRAY (not a Record): iteration order is significant because we
 * break at the first substring match. Swift Dictionary / Kotlin HashMap /
 * C# Dictionary have undefined iteration order, so an object map would produce
 * divergent results across ports when a model string matches two keys. Ports
 * MUST iterate this list in the exact order below and break at first match.
 */
const MODEL_BIAS: ReadonlyArray<readonly [string, Partial<Record<ModelPurposeCategory, number>>]> = [
  ["o1", { research: 0.3, logic: 0.2 }],
  ["o3", { research: 0.3, logic: 0.2 }],
  ["deepseek", { logic: 0.3, backend: 0.2 }],
  ["claude-3.5-sonnet", { writing: 0.15, logic: 0.15 }],
  ["gpt-4o", { ui: 0.1, writing: 0.1 }],
  ["llama", { backend: 0.15 }],
];

/** App surface bias. */
const SURFACE_BIAS: Record<string, Partial<Record<ModelPurposeCategory, number>>> = {
  chat: {},
  dashboard: { orchestration: 0.1 },
  editor: { logic: 0.1 },
  terminal: { debugging: 0.15, backend: 0.1 },
};

// ---------------------------------------------------------------------------
// Fingerprint (for correction matching)
// ---------------------------------------------------------------------------

/**
 * Build a deterministic fingerprint from signals for correction matching.
 * Two sessions with the same signal shape produce the same fingerprint,
 * so a user correction on one biases the other.
 */
export function signalFingerprint(signals: ClassifierSignals): string {
  const parts: string[] = [];
  if (signals.fileExtensions) parts.push(`ext:${[...signals.fileExtensions].sort().join(",")}`);
  if (signals.appSurface) parts.push(`surf:${signals.appSurface}`);
  if (signals.hasCodeExecution) parts.push("exec");
  if (signals.hasErrorOutput) parts.push("err");
  if (signals.hasSearchResults) parts.push("search");
  if (signals.hasMultiStepPlanning) parts.push("plan");
  return parts.join("|") || "default";
}

// ---------------------------------------------------------------------------
// Classification
// ---------------------------------------------------------------------------

const CATEGORY_WEIGHT: Record<ModelPurposeCategory, number> = {
  ui: 0,
  backend: 0,
  logic: 0,
  writing: 0,
  research: 0,
  debugging: 0,
  orchestration: 0,
  other: 0,
};

function zeroScores(): Record<ModelPurposeCategory, number> {
  return { ...CATEGORY_WEIGHT };
}

/**
 * Classify a session's purpose from metadata signals.
 *
 * Returns the highest-scoring category with a confidence score and the list
 * of contributing signal names. If a correction fingerprint matches, the
 * corrected category wins with confidence 1.0.
 */
export function classifyPurpose(
  signals: ClassifierSignals,
  corrections: readonly PurposeCorrection[] = [],
): ClassificationResult {
  // Check for a matching correction first — corrections override inference.
  const fp = signalFingerprint(signals);
  const matchedCorrection = corrections.find((c) => c.fingerprint === fp);
  if (matchedCorrection) {
    return {
      category: matchedCorrection.correctedTo,
      confidence: 1.0,
      contributingSignals: ["user_correction"],
    };
  }

  const scores = zeroScores();
  const contributingSignals: string[] = [];

  // File extension signals (weight: 1.0 each).
  if (signals.fileExtensions) {
    for (const ext of signals.fileExtensions) {
      const cat = FILE_EXTENSION_MAP[ext.toLowerCase()];
      if (cat) {
        scores[cat] += 1.0;
        contributingSignals.push(`file:${ext}`);
      }
    }
  }

  // Keyword signals (weight: 0.5 each).
  if (signals.keywords) {
    for (const kw of signals.keywords) {
      const cat = KEYWORD_MAP[kw.toLowerCase()];
      if (cat) {
        scores[cat] += 0.5;
        contributingSignals.push(`keyword:${kw}`);
      }
    }
  }

  // Boolean signals.
  if (signals.hasErrorOutput) {
    scores.debugging += 1.5;
    contributingSignals.push("error_output");
  }
  if (signals.hasCodeExecution) {
    scores.backend += 0.5;
    scores.logic += 0.5;
    contributingSignals.push("code_execution");
  }
  if (signals.hasSearchResults) {
    scores.research += 1.0;
    contributingSignals.push("search_results");
  }
  if (signals.hasMultiStepPlanning) {
    scores.orchestration += 1.0;
    contributingSignals.push("multi_step_planning");
  }

  // Model bias — iterate the ORDERED array and break at first match.
  // (Swift/Kotlin/C# ports MUST iterate in the same fixed order.)
  if (signals.model) {
    const modelLower = signals.model.toLowerCase();
    for (const [key, bias] of MODEL_BIAS) {
      if (modelLower.includes(key)) {
        for (const [cat, weight] of Object.entries(bias)) {
          scores[cat as ModelPurposeCategory] += weight;
        }
        contributingSignals.push(`model:${key}`);
        break;
      }
    }
  }

  // App surface bias.
  if (signals.appSurface) {
    const surfaceBias = SURFACE_BIAS[signals.appSurface.toLowerCase()];
    if (surfaceBias) {
      for (const [cat, weight] of Object.entries(surfaceBias)) {
        scores[cat as ModelPurposeCategory] += weight;
      }
      contributingSignals.push(`surface:${signals.appSurface}`);
    }
  }

  // Find the winner.
  let winner: ModelPurposeCategory = "other";
  let maxScore = 0;
  let totalScore = 0;

  for (const cat of PURPOSE_CATEGORIES) {
    totalScore += scores[cat];
    if (scores[cat] > maxScore) {
      maxScore = scores[cat];
      winner = cat;
    }
  }

  // Confidence = winner's share of total signal weight.
  const confidence = totalScore > 0 ? maxScore / totalScore : 0;

  // If no signals matched at all, return "other" with low confidence.
  if (totalScore === 0) {
    return {
      category: "other",
      confidence: 0,
      contributingSignals: [],
    };
  }

  return {
    category: winner,
    confidence: Math.round(confidence * 100) / 100,
    contributingSignals,
  };
}
