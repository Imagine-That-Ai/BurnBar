/**
 * @fileoverview Shared TypeScript types for OpenBurnBar Cloud Functions v2.
 *
 * Extracted from src/types/legacy.ts (the strangler "leftovers" bucket) and
 * grouped by domain. Re-exported verbatim from src/types/legacy.ts so every
 * existing `import ... from "../types/legacy"` keeps resolving unchanged.
 */

import type { InsightCitationDoc, InsightValueFormat } from "./insights-spec.js";

// InsightWidgetDataDoc — the full union of widget data shapes.
// Each variant matches InsightWidgetKind one-to-one.
export type InsightWidgetDataDoc =
  | { kpi: InsightWidgetDataKPIDoc }
  | { timeSeries: InsightWidgetDataTimeSeriesDoc }
  | { ranking: InsightWidgetDataRankingDoc }
  | { distribution: InsightWidgetDataDistributionDoc }
  | { heatmap: InsightWidgetDataHeatmapDoc }
  | { scatter: InsightWidgetDataScatterDoc }
  | { sankey: InsightWidgetDataSankeyDoc }
  | { radar: InsightWidgetDataRadarDoc }
  | { cohort: InsightWidgetDataCohortDoc }
  | { funnel: InsightWidgetDataFunnelDoc }
  | { quota: InsightWidgetDataQuotaStateDoc }
  | { forecast: InsightWidgetDataForecastDoc }
  | { anomaly: InsightWidgetDataAnomalyTableDoc }
  | { narrative: InsightWidgetDataNarrativeDoc }
  | { recommendation: InsightWidgetDataRecommendationDoc }
  | { useCaseCluster: InsightWidgetDataUseCaseClusterDoc }
  | { focusMatrix: InsightWidgetDataFocusMatrixDoc }
  | { drilldown: InsightWidgetDataDrilldownDoc }
  | { mermaid: string }
  | { ascii: InsightWidgetDataASCIICardDoc }
  | { composed: InsightWidgetDataDoc[] }
  | { empty: { reason: string } }
  | { error: { message: string } };

export interface InsightWidgetDataKPIDoc {
  metricLabel: string;
  value: number;
  valueFormat: InsightValueFormat;
  delta?: number;
  deltaIsPercent: boolean;
  sparkline: number[];
  contextLabel?: string;
}

export interface InsightWidgetDataTimeSeriesDoc {
  series: InsightTimeSeriesSeriesDoc[];
  xAxisLabel: string;
  yAxisLabel: string;
  yFormat: InsightValueFormat;
  annotations: InsightTimeSeriesAnnotationDoc[];
}

export interface InsightTimeSeriesSeriesDoc {
  id: string;
  name: string;
  colorHex?: string;
  points: InsightTimeSeriesPointDoc[];
}

export interface InsightTimeSeriesPointDoc {
  date: string;
  value: number;
}

export interface InsightTimeSeriesAnnotationDoc {
  date: string;
  label: string;
  tone: "positive" | "neutral" | "warning" | "negative";
}

export interface InsightWidgetDataRankingDoc {
  rows: InsightRankingRowDoc[];
  valueFormat: InsightValueFormat;
  dimensionLabel: string;
}

export interface InsightRankingRowDoc {
  id: string;
  label: string;
  value: number;
  secondaryLabel?: string;
  colorHex?: string;
}

export interface InsightWidgetDataDistributionDoc {
  slices: InsightDistributionSliceDoc[];
  valueFormat: InsightValueFormat;
  total: number;
}

export interface InsightDistributionSliceDoc {
  id: string;
  label: string;
  value: number;
  colorHex?: string;
}

export interface InsightWidgetDataHeatmapDoc {
  rowLabels: string[];
  columnLabels: string[];
  cells: number[][];
  valueFormat: InsightValueFormat;
}

export interface InsightWidgetDataScatterDoc {
  points: InsightScatterPointDoc[];
  xAxisLabel: string;
  yAxisLabel: string;
  xFormat: InsightValueFormat;
  yFormat: InsightValueFormat;
}

export interface InsightScatterPointDoc {
  id: string;
  label: string;
  x: number;
  y: number;
  size: number;
  colorHex?: string;
}

export interface InsightWidgetDataSankeyDoc {
  nodes: InsightSankeyNodeDoc[];
  links: InsightSankeyLinkDoc[];
}

export interface InsightSankeyNodeDoc {
  id: string;
  label: string;
  colorHex?: string;
}

export interface InsightSankeyLinkDoc {
  source: string;
  target: string;
  value: number;
}

export interface InsightWidgetDataRadarDoc {
  axes: string[];
  series: InsightRadarSeriesDoc[];
}

export interface InsightRadarSeriesDoc {
  id: string;
  name: string;
  values: number[];
  colorHex?: string;
}

export interface InsightWidgetDataCohortDoc {
  cohortLabels: string[];
  periodLabels: string[];
  cells: (number | null)[][];
}

export interface InsightWidgetDataFunnelDoc {
  steps: InsightFunnelStepDoc[];
}

export interface InsightFunnelStepDoc {
  id: string;
  label: string;
  count: number;
}

export interface InsightWidgetDataQuotaStateDoc {
  buckets: InsightQuotaBucketDoc[];
}

export interface InsightQuotaBucketDoc {
  id: string;
  providerLabel: string;
  bucketName: string;
  used: number;
  limit?: number;
  resetsAt?: string;
  symbolName: string;
  colorHex?: string;
}

export interface InsightWidgetDataForecastDoc {
  actual: InsightTimeSeriesPointDoc[];
  forecast: InsightTimeSeriesPointDoc[];
  lowerBound: InsightTimeSeriesPointDoc[];
  upperBound: InsightTimeSeriesPointDoc[];
  xAxisLabel: string;
  yAxisLabel: string;
  yFormat: InsightValueFormat;
  summary?: string;
}

export interface InsightWidgetDataAnomalyTableDoc {
  rows: InsightAnomalyRowDoc[];
}

export interface InsightAnomalyRowDoc {
  id: string;
  occurredAt: string;
  label: string;
  detail?: string;
  score: number;
  citations: InsightCitationDoc[];
}

export interface InsightWidgetDataNarrativeDoc {
  headline: string;
  body: string;
  bullets: string[];
  tone: "positive" | "neutral" | "warning" | "negative";
  citations: InsightCitationDoc[];
  sparkline: number[];
}

export interface InsightWidgetDataRecommendationDoc {
  headline: string;
  rationale: string;
  action: string;
  estimatedImpact?: string;
  confidence: "low" | "medium" | "high";
  citations: InsightCitationDoc[];
}

export interface InsightWidgetDataUseCaseClusterDoc {
  clusters: InsightUseCaseClusterDoc[];
}

export interface InsightUseCaseClusterDoc {
  id: string;
  label: string;
  size: number;
  exampleSessionIDs: string[];
  colorHex?: string;
}

export interface InsightWidgetDataFocusMatrixDoc {
  rowLabels: string[];
  columnLabels: string[];
  cells: number[][];
}

export interface InsightWidgetDataDrilldownDoc {
  rows: InsightDrilldownRowDoc[];
}

export interface InsightDrilldownRowDoc {
  id: string;
  title: string;
  subtitle?: string;
  occurredAt: string;
  costUSD?: number;
  tokens?: number;
  citation: InsightCitationDoc;
}

export interface InsightWidgetDataASCIICardDoc {
  headline: string;
  monoBody: string;
  caption?: string;
}
