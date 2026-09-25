/**
 * @fileoverview Shared TypeScript types for OpenBurnBar Cloud Functions v2.
 *
 * Extracted from src/types/legacy.ts (the strangler "leftovers" bucket) and
 * grouped by domain. Re-exported verbatim from src/types/legacy.ts so every
 * existing `import ... from "../types/legacy"` keeps resolving unchanged.
 */

import type {
  InsightAnomalyRowDoc,
  InsightCanvasDoc,
  InsightCitationDoc,
  InsightDrilldownRowDoc,
  InsightEgressTier,
  InsightFilterDoc,
  InsightModelTagDoc,
  InsightTaxonomyDoc,
  InsightTimeWindowDoc,
  InsightWidgetDataQuotaStateDoc,
  InsightWidgetDataRankingDoc,
  InsightWidgetDataTimeSeriesDoc,
  InsightWidgetDoc,
} from "./insights-spec.js";

export interface InsightDigestDoc {
  contentHash: string;
  generatedAt: string;
  windowStart: string;
  windowEnd: string;
  rowCount: number;
  totals: InsightDigestTotalsDoc;
  providers: InsightDigestProviderSnapshotDoc[];
  models: InsightDigestModelSnapshotDoc[];
  projects: InsightDigestProjectSnapshotDoc[];
  devices: InsightDigestDeviceSnapshotDoc[];
  daily: InsightDigestDailyPointDoc[];
  hourly: number[];
  useCaseHistogram: InsightDigestUseCaseBinDoc[];
  agentFocusSignals: InsightDigestAgentFocusSignalDoc[];
  modelFocusSignals: InsightDigestModelFocusSignalDoc[];
  quotaSnapshots: InsightDigestQuotaSnapshotDoc[];
  operatingActions: InsightDigestActionDoc[];
  summaryRunsLog: InsightDigestSummaryRunDoc[];
  modelBenchmarks: InsightDigestModelBenchmarkDoc[];
  anomalies: InsightDigestAnomalyDoc[];
  glossary: InsightTaxonomyDoc;
}

export interface InsightDigestTotalsDoc {
  costUSD: number;
  totalTokens: number;
  inputTokens: number;
  outputTokens: number;
  reasoningTokens: number;
  cacheReadTokens: number;
  cacheCreationTokens: number;
  sessionCount: number;
}

export interface InsightDigestProviderSnapshotDoc {
  id: string;
  displayName: string;
  costUSD: number;
  totalTokens: number;
  sessionCount: number;
  topModels: string[];
  topInferredTaskTitles: string[];
  topKeyTools: string[];
}

export interface InsightDigestModelSnapshotDoc {
  id: string;
  providerID: string;
  costUSD: number;
  totalTokens: number;
  sessionCount: number;
  avgCostPerSession: number;
  cacheHitRate: number;
  topInferredTaskTitles: string[];
  topProjects: string[];
}

export interface InsightDigestProjectSnapshotDoc {
  id: string;
  displayName: string;
  costUSD: number;
  totalTokens: number;
  sessionCount: number;
}

export interface InsightDigestDeviceSnapshotDoc {
  id: string;
  displayName: string;
  costUSD: number;
  sessionCount: number;
}

export interface InsightDigestDailyPointDoc {
  day: string;
  costUSD: number;
  totalTokens: number;
  sessionCount: number;
  perProvider: Record<string, number>;
}

export interface InsightDigestUseCaseBinDoc {
  id: string;
  count: number;
  costUSD: number;
}

export interface InsightDigestAgentFocusSignalDoc {
  agentID: string;
  focus: string;
  weight: number;
}

export interface InsightDigestModelFocusSignalDoc {
  modelID: string;
  focus: string;
  weight: number;
}

export interface InsightDigestQuotaSnapshotDoc {
  id: string;
  providerID: string;
  bucketName: string;
  used: number;
  limit?: number;
  resetsAt?: string;
}

export interface InsightDigestActionDoc {
  id: string;
  kind: string;
  projectID?: string;
  occurredAt: string;
  summary: string;
}

export interface InsightDigestSummaryRunDoc {
  id: string;
  providerID: string;
  modelID: string;
  costUSD: number;
  ranAt: string;
}

export interface InsightDigestModelBenchmarkDoc {
  id: string;
  source: string;
  sourceURL?: string;
  attribution?: string;
  fetchedAt: string;
  modelID: string;
  providerID?: string;
  taskCategory: string;
  score?: number;
  rank?: number;
  costSignal?: number;
  latencySignal?: number;
  contextWindowTokens?: number;
  reliabilitySignal?: number;
  confidence?: number;
  freshness: string;
  inputCostPerMtoken?: number;
  outputCostPerMtoken?: number;
  blendedCostPerMtoken?: number;
}

export interface InsightDigestAnomalyDoc {
  id: string;
  occurredAt: string;
  label: string;
  score: number;
  detail?: string;
}

export type InsightAnalysisPlatformDoc = "macOS" | "iOS" | "iPadOS" | "android";

export type InsightAnalysisInstructionDoc = "defaultBrief" | "answerFollowUp" | "generateReport" | "updateCanvas";

export interface InsightAnalysisRequestDoc {
  id: string;
  prompt: string;
  context: InsightAnalysisContextDoc;
  currentCanvas?: InsightCanvasDoc;
  selectedModel: InsightModelTagDoc;
  instruction: InsightAnalysisInstructionDoc;
  allowDeepTranscriptAnalysis: boolean;
  maxGeneratedWidgets: number;
  schemaVersion: 1;
}

export interface InsightAnalysisContextDoc {
  digest: InsightDigestDoc;
  evidenceIndex: InsightEvidenceDoc[];
  budgetReport: InsightContextBudgetReportDoc;
  priorRunSummaries: string[];
  evidencePacks: InsightEvidencePackDoc[];
}

export interface InsightEvidenceDoc {
  id: string;
  citation: InsightCitationDoc;
  source: string;
  summary: string;
  numericValue?: number;
}

export interface InsightEvidencePackDoc {
  id: string;
  sourcePlatform: InsightAnalysisPlatformDoc;
  generatedAt: string;
  timeWindow: InsightTimeWindowDoc;
  includedDataSources: string[];
  budgetReport: InsightContextBudgetReportDoc;
  evidence: InsightEvidenceDoc[];
  summary: string;
  contentHash: string;
  deepTranscriptIncluded: boolean;
}

export interface InsightPlatformCapabilityReportDoc {
  platform: InsightAnalysisPlatformDoc;
  providerFamilies: InsightProviderFamilyDoc[];
  includedDataSources: string[];
  supportsDeepLocalLogs: boolean;
  supportsSyncedEvidencePacks: boolean;
  supportsModelSelection: boolean;
  supportsConversation: boolean;
  supportsGeneratedWidgetPinning: boolean;
  supportsAuditAndCache: boolean;
  gaps: string[];
}

export type InsightProviderFamilyDoc =
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

export interface InsightContextBudgetReportDoc {
  maxEncodedBytes: number;
  encodedBytes: number;
  estimatedPromptTokens: number;
  includedDataSources: string[];
  truncatedDataSources: string[];
  truncationSummary: string;
}

export interface InsightAnalysisResultDoc {
  id: string;
  requestID: string;
  schemaVersion: 1;
  generatedAt: string;
  platform: InsightAnalysisPlatformDoc;
  timeWindow: InsightTimeWindowDoc;
  executiveSummary: string;
  modelTag: InsightModelTagDoc;
  contextBudget: InsightContextBudgetReportDoc;
  findings: InsightFindingDoc[];
  anomalies: InsightAnomalyDoc[];
  recommendations: InsightRecommendationDoc[];
  missionCandidates: InsightMissionCandidateDoc[];
  generatedWidgets: InsightGeneratedWidgetDoc[];
  followUpQuestions: InsightFollowUpQuestionDoc[];
  citations: InsightCitationDoc[];
  tokenUsage?: InsightTokenUsageDoc;
  estimatedCostUSD?: number;
  auditID?: string;
  resultHash: string;
}

export type InsightConfidenceDoc = "low" | "medium" | "high";

export type InsightSeverityDoc = "info" | "low" | "medium" | "high" | "critical";

export interface InsightFindingDoc {
  id: string;
  title: string;
  whyItMatters: string;
  evidence: InsightCitationDoc[];
  confidence: InsightConfidenceDoc;
  severity: InsightSeverityDoc;
  recommendedAction: string;
  generatedWidgetID?: string;
}

export interface InsightAnomalyDoc {
  id: string;
  title: string;
  occurredAt?: string;
  detail: string;
  score: number;
  evidence: InsightCitationDoc[];
  confidence: InsightConfidenceDoc;
}

export interface InsightRecommendationDoc {
  id: string;
  title: string;
  rationale: string;
  recommendedAction: string;
  estimatedImpact?: string;
  evidence: InsightCitationDoc[];
  confidence: InsightConfidenceDoc;
  severity: InsightSeverityDoc;
}

export type InsightMissionLensDoc = "accretion" | "diligence" | "techDebt" | "routing" | "quota" | "focus";

export type InsightMissionPriorityDoc = "low" | "medium" | "high" | "critical";
export type InsightMissionEffortDoc = "small" | "medium" | "large";

export interface InsightMissionCandidateDoc {
  id: string;
  title: string;
  summary: string;
  projectID?: string;
  projectDisplayName?: string;
  lens: InsightMissionLensDoc;
  priority: InsightMissionPriorityDoc;
  confidence: InsightConfidenceDoc;
  expectedImpact: string;
  effort: InsightMissionEffortDoc;
  acceptanceCriteria: string[];
  sourceInsightIDs: string[];
  evidence: InsightCitationDoc[];
  dispatchMetadata: Record<string, string>;
}

export interface InsightGeneratedWidgetDoc {
  id: string;
  widget: InsightWidgetDoc;
  reason: string;
  citations: InsightCitationDoc[];
}

export interface InsightFollowUpQuestionDoc {
  id: string;
  question: string;
  rationale?: string;
}

export interface InsightAnalysisAuditEntryDoc {
  id: string;
  requestID: string;
  platform: InsightAnalysisPlatformDoc;
  selectedModel: InsightModelTagDoc;
  egressTier: InsightEgressTier;
  timeWindow: InsightTimeWindowDoc;
  contextBudget: InsightContextBudgetReportDoc;
  includedDataSources: string[];
  truncationSummary: string;
  promptHash: string;
  resultHash: string;
  status: "started" | "succeeded" | "partial" | "modelUnavailable" | "schemaViolation" | "cancelled" | "failed";
  startedAt: string;
  completedAt?: string;
  errorDescription?: string;
  tokenUsage?: InsightTokenUsageDoc;
  estimatedCostUSD?: number;
  ranAt: string;
}

export interface InsightModelPreferenceDoc {
  mode: "automatic" | "explicit";
  explicitModel?: InsightModelTagDoc;
  restrictToLocalOnly: boolean;
  maxEgressTier?: InsightEgressTier;
  deepTranscriptOptIn: boolean;
}

export interface InsightTokenUsageDoc {
  providerKey: string;
  modelID: string;
  inputTokens: number;
  outputTokens: number;
  reasoningTokens: number;
  cacheCreationTokens: number;
  cacheReadTokens: number;
  estimatedCostUSD: number;
  startedAt: string;
  completedAt: string;
}

export interface InsightInvestigateRequestDoc {
  prompt: string;
  digest: InsightDigestDoc;
  canvas?: InsightCanvasDoc;
  widget?: InsightWidgetDoc;
  modelTag: InsightModelTagDoc;
  capabilityTier: "tier1" | "tier2" | "tier3";
  maxNewWidgets: number;
  allowToolCalls: boolean;
  instruction: "composeCanvas" | "refineCanvas" | "refreshNarratives" | "refineWidget" | "explainBriefly";
}

export type InsightInvestigateEventDoc =
  | { thinkingDelta: string }
  | { partialCanvas: InsightCanvasDoc }
  | { widgetReady: InsightWidgetDoc }
  | { toolCall: InsightToolCallDoc }
  | { toolResult: InsightToolResultDoc }
  | { usage: InsightTokenUsageDoc }
  | { finalCanvas: InsightCanvasDoc };

export interface InsightToolCallDoc {
  id: string;
  name: string;
  arguments: InsightToolArgumentsDoc;
}

export interface InsightToolResultDoc {
  id: string;
  toolName: string;
  isError: boolean;
  summary: string;
  payload: InsightToolResultPayloadDoc;
}

export type InsightToolArgumentsDoc =
  | { drilldownSearch: { query: string; filter?: InsightFilterDoc } }
  | { drilldownSession: { sessionID: string } }
  | { agentUsage: { agent: string; window: InsightTimeWindowDoc } }
  | { modelUsage: { modelID: string; window: InsightTimeWindowDoc } }
  | { operatingActions: { window: InsightTimeWindowDoc } }
  | { quotaSnapshot: { providerKey?: string } }
  | { anomalyDetail: { anomalyID: string } }
  | "listFocuses"
  | "listUseCases";

export type InsightToolResultPayloadDoc =
  | { sessions: InsightDrilldownRowDoc[] }
  | { timeSeries: InsightWidgetDataTimeSeriesDoc }
  | { ranking: InsightWidgetDataRankingDoc }
  | { actions: InsightDigestActionDoc[] }
  | { quota: InsightWidgetDataQuotaStateDoc }
  | { anomaly: InsightAnomalyRowDoc }
  | { vocabulary: string[] }
  | { error: string };

export interface InsightCapabilityTierDoc {
  tier: number;
  structuredOutput: boolean;
  maxTokens: number;
}
