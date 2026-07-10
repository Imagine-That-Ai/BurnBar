/**
 * Faithful port of functions/src/community/classifier.ts for the member console.
 * Keep in sync with golden fixtures in tests/fixtures/classifier-goldens.json.
 */

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

export interface ClassifierSignals {
  fileExtensions?: readonly string[];
  model?: string;
  appSurface?: string;
  hasCodeExecution?: boolean;
  hasErrorOutput?: boolean;
  hasSearchResults?: boolean;
  hasMultiStepPlanning?: boolean;
  keywords?: readonly string[];
}

export interface PurposeCorrection {
  fingerprint: string;
  correctedTo: ModelPurposeCategory;
}

export interface ClassificationResult {
  category: ModelPurposeCategory;
  confidence: number;
  contributingSignals: readonly string[];
}

const FILE_EXTENSION_MAP: Record<string, ModelPurposeCategory> = {
  swift: "ui",
  xaml: "ui",
  css: "ui",
  scss: "ui",
  html: "ui",
  vue: "ui",
  svelte: "ui",
  go: "backend",
  rs: "backend",
  py: "backend",
  java: "backend",
  kt: "backend",
  sql: "backend",
  proto: "backend",
  grpc: "backend",
  ts: "logic",
  tsx: "logic",
  js: "logic",
  mjs: "logic",
  cjs: "logic",
  dart: "logic",
  md: "writing",
  txt: "writing",
  rst: "writing",
  docx: "writing",
  pdf: "writing",
  json: "research",
  yaml: "research",
  yml: "research",
  csv: "research",
  toml: "research",
};

const KEYWORD_MAP: Record<string, ModelPurposeCategory> = {
  ui: "ui",
  design: "ui",
  frontend: "ui",
  layout: "ui",
  view: "ui",
  button: "ui",
  animation: "ui",
  theme: "ui",
  color: "ui",
  responsive: "ui",
  accessibility: "ui",
  api: "backend",
  server: "backend",
  database: "backend",
  migration: "backend",
  endpoint: "backend",
  auth: "backend",
  deploy: "backend",
  docker: "backend",
  kubernetes: "backend",
  grpc: "backend",
  refactor: "logic",
  algorithm: "logic",
  function: "logic",
  type: "logic",
  interface: "logic",
  state: "logic",
  model: "logic",
  parse: "logic",
  docs: "writing",
  documentation: "writing",
  readme: "writing",
  blog: "writing",
  article: "writing",
  essay: "writing",
  summary: "writing",
  research: "research",
  search: "research",
  analyze: "research",
  data: "research",
  benchmark: "research",
  evaluate: "research",
  bug: "debugging",
  error: "debugging",
  fix: "debugging",
  crash: "debugging",
  stacktrace: "debugging",
  debug: "debugging",
  test: "debugging",
  fail: "debugging",
  plan: "orchestration",
  workflow: "orchestration",
  pipeline: "orchestration",
  agent: "orchestration",
  automate: "orchestration",
  schedule: "orchestration",
  mission: "orchestration",
};

/** Ordered — first substring match wins (see model-bias-tie-order golden). */
const MODEL_BIAS: ReadonlyArray<readonly [string, Partial<Record<ModelPurposeCategory, number>>]> = [
  ["o1", { research: 0.3, logic: 0.2 }],
  ["o3", { research: 0.3, logic: 0.2 }],
  ["deepseek", { logic: 0.3, backend: 0.2 }],
  ["claude-3.5-sonnet", { writing: 0.15, logic: 0.15 }],
  ["gpt-4o", { ui: 0.1, writing: 0.1 }],
  ["llama", { backend: 0.15 }],
];

const SURFACE_BIAS: Record<string, Partial<Record<ModelPurposeCategory, number>>> = {
  chat: {},
  dashboard: { orchestration: 0.1 },
  editor: { logic: 0.1 },
  terminal: { debugging: 0.15, backend: 0.1 },
};

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

export function signalFingerprint(signals: ClassifierSignals): string {
  const parts: string[] = [];
  if (signals.fileExtensions) {
    parts.push(`ext:${signals.fileExtensions.map((extension) => extension.toLowerCase()).sort().join(",")}`);
  }
  if (signals.appSurface) parts.push(`surf:${signals.appSurface}`);
  if (signals.hasCodeExecution) parts.push("exec");
  if (signals.hasErrorOutput) parts.push("err");
  if (signals.hasSearchResults) parts.push("search");
  if (signals.hasMultiStepPlanning) parts.push("plan");
  return parts.join("|") || "default";
}

export function classifyPurpose(
  signals: ClassifierSignals,
  corrections: readonly PurposeCorrection[] = [],
): ClassificationResult {
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

  if (signals.fileExtensions) {
    for (const ext of signals.fileExtensions) {
      const cat = FILE_EXTENSION_MAP[ext.toLowerCase()];
      if (cat) {
        scores[cat] += 1.0;
        contributingSignals.push(`file:${ext}`);
      }
    }
  }

  if (signals.keywords) {
    for (const kw of signals.keywords) {
      const cat = KEYWORD_MAP[kw.toLowerCase()];
      if (cat) {
        scores[cat] += 0.5;
        contributingSignals.push(`keyword:${kw}`);
      }
    }
  }

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

  if (signals.appSurface) {
    const surfaceBias = SURFACE_BIAS[signals.appSurface.toLowerCase()];
    if (surfaceBias) {
      for (const [cat, weight] of Object.entries(surfaceBias)) {
        scores[cat as ModelPurposeCategory] += weight;
      }
      contributingSignals.push(`surface:${signals.appSurface}`);
    }
  }

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

  const confidence = totalScore > 0 ? maxScore / totalScore : 0;

  if (totalScore === 0) {
    return { category: "other", confidence: 0, contributingSignals: [] };
  }

  return {
    category: winner,
    confidence: Math.round(confidence * 100) / 100,
    contributingSignals,
  };
}
