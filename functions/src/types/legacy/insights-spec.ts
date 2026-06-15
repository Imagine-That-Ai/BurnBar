/* eslint-disable @typescript-eslint/no-empty-object-type -- legacy hand-maintained schema placeholders */
/**
 * @fileoverview Shared TypeScript types for OpenBurnBar Cloud Functions v2.
 *
 * Extracted from src/types/legacy.ts (the strangler "leftovers" bucket) and
 * grouped by domain. Re-exported verbatim from src/types/legacy.ts so every
 * existing `import ... from "../types/legacy"` keeps resolving unchanged.
 */

import type {
  InsightWidgetDataASCIICardDoc,
  InsightWidgetDataDoc,
  InsightWidgetDataNarrativeDoc,
  InsightWidgetDataRecommendationDoc,
} from "./insights-data.js";

// ---------------------------------------------------------------------------
// Firestore: insight_canvases/{id}
// Canonical schema for the Insights tab. The same shape is consumed by
// iOS (Swift Codable) and Android (Kotlin @Serializable). When making
// changes, update the schema version and run the android-firestore-worker
// skill to keep Kotlin data classes aligned.
// ---------------------------------------------------------------------------

export interface InsightCanvasDoc {
  id: string;
  title: string;
  summary?: string;
  symbolName: string;
  theme: InsightTheme;
  widgets: InsightWidgetDoc[];
  layout: InsightLayoutDoc;
  filter: InsightFilterDoc;
  modelTag?: InsightModelTagDoc;
  schemaVersion: number;
  createdAt: string;
  updatedAt: string;
  lastRefreshedAt?: string;
  origin: InsightCanvasOrigin;
  sortIndex: number;
}

export type InsightCanvasOrigin =
  | "userCreated"
  | { template: { id: string } }
  | { composed: { prompt: string } }
  | { imported: { filename: string } };

export type InsightTheme = "aurora" | "ember" | "mercury" | "whimsy" | "mono" | "print";

export type InsightWidgetKind =
  | "kpiTile"
  | "timeSeriesLine"
  | "timeSeriesArea"
  | "streamGraph"
  | "barRanking"
  | "donut"
  | "treemap"
  | "heatmap"
  | "scatter"
  | "sankey"
  | "radar"
  | "cohort"
  | "funnel"
  | "quotaPulse"
  | "forecast"
  | "anomalyTable"
  | "narrative"
  | "recommendation"
  | "useCaseCluster"
  | "agentFocusMatrix"
  | "modelFocusMatrix"
  | "drilldownList"
  | "mermaid"
  | "ascii"
  | "composed"
  | "error";

export type InsightFreshness = "fresh" | "stale" | "computing" | "error" | "locked";

export type InsightEgressTier = "localOnly" | "userKey" | "userRelay" | "hosted";

export interface InsightWidgetDoc {
  id: string;
  kind: InsightWidgetKind;
  title: string;
  subtitle?: string;
  spec: InsightWidgetSpecDoc;
  dataBinding: InsightDataBindingDoc;
  data?: InsightWidgetDataDoc;
  filter?: InsightFilterDoc;
  freshness: InsightFreshness;
  modelTag?: InsightModelTagDoc;
  lockedAt?: string;
  lastComputedAt?: string;
  schemaVersion: number;
  rationale?: string;
}

export type InsightWidgetSpecDoc =
  | { kpiTile: InsightKPITileSpecDoc }
  | { timeSeries: InsightTimeSeriesSpecDoc }
  | { ranking: InsightRankingSpecDoc }
  | { distribution: InsightDistributionSpecDoc }
  | { heatmap: InsightHeatmapSpecDoc }
  | { scatter: InsightScatterSpecDoc }
  | { sankey: InsightSankeySpecDoc }
  | { radar: InsightRadarSpecDoc }
  | { cohort: InsightCohortSpecDoc }
  | { funnel: InsightFunnelSpecDoc }
  | { quotaPulse: InsightQuotaPulseSpecDoc }
  | { forecast: InsightForecastSpecDoc }
  | { anomalyTable: InsightAnomalyTableSpecDoc }
  | { narrative: InsightNarrativeSpecDoc }
  | { recommendation: InsightRecommendationSpecDoc }
  | { useCaseCluster: InsightUseCaseClusterSpecDoc }
  | { agentFocusMatrix: InsightFocusMatrixSpecDoc }
  | { modelFocusMatrix: InsightFocusMatrixSpecDoc }
  | { drilldownList: InsightDrilldownSpecDoc }
  | { mermaid: InsightMermaidSpecDoc }
  | { ascii: InsightASCIISpecDoc }
  | { composed: InsightComposedSpecDoc }
  | { error: InsightErrorSpecDoc };

export interface InsightKPITileSpecDoc {
  metricLabel: string;
  compareWindow: "none" | "previousPeriod" | "weekOverWeek" | "monthOverMonth" | "yearOverYear";
  emphasizeDelta: boolean;
}

export interface InsightTimeSeriesSpecDoc {
  style: "line" | "area" | "stackedArea" | "stream" | "bar" | "stackedBar";
  smoothing: "none" | "monotone" | "rolling7";
  showAnnotations: boolean;
}

export interface InsightRankingSpecDoc {
  orientation: "horizontal" | "vertical";
  showValues: boolean;
}

export interface InsightDistributionSpecDoc {
  style: "donut" | "pie" | "treemap";
  showLegend: boolean;
}

export interface InsightHeatmapSpecDoc {
  palette: "ember" | "mercury" | "whimsy" | "mono";
}

export interface InsightScatterSpecDoc {
  logX: boolean;
  logY: boolean;
  bubble: boolean;
}

export interface InsightSankeySpecDoc {}
export interface InsightRadarSpecDoc {
  fill: boolean;
}

export interface InsightCohortSpecDoc {}
export interface InsightFunnelSpecDoc {}

export interface InsightQuotaPulseSpecDoc {
  compact: boolean;
}

export interface InsightForecastSpecDoc {
  showBands: boolean;
}

export interface InsightAnomalyTableSpecDoc {
  minScore: number;
}

export interface InsightNarrativeSpecDoc {
  emphasize: "headlineOnly" | "balanced" | "deepDive";
}

export interface InsightRecommendationSpecDoc {
  category: "efficiency" | "quality" | "cost" | "quota" | "risk" | "learning";
}

export interface InsightUseCaseClusterSpecDoc {
  maxClusters: number;
}

export interface InsightFocusMatrixSpecDoc {
  palette: "ember" | "mercury" | "whimsy" | "mono";
}

export interface InsightDrilldownSpecDoc {
  groupBy?: InsightDataBindingDimension;
}

export interface InsightMermaidSpecDoc {}
export interface InsightASCIISpecDoc {}

export interface InsightComposedSpecDoc {
  children: InsightWidgetSpecDoc[];
}

export interface InsightErrorSpecDoc {
  message: string;
}

export type InsightDataBindingDoc =
  | { kpi: { metric: string; window: InsightTimeWindowDoc } }
  | { timeSeries: { metric: string; dimension?: InsightDataBindingDimension; window: InsightTimeWindowDoc } }
  | { ranking: { metric: string; dimension: InsightDataBindingDimension; limit: number; window: InsightTimeWindowDoc } }
  | { distribution: { metric: string; dimension: InsightDataBindingDimension; window: InsightTimeWindowDoc } }
  | { heatmap: { metric: string; window: InsightTimeWindowDoc } }
  | {
      scatter: {
        xMetric: string;
        yMetric: string;
        dimension: InsightDataBindingDimension;
        window: InsightTimeWindowDoc;
      };
    }
  | {
      sankey: {
        source: InsightDataBindingDimension;
        mid?: InsightDataBindingDimension;
        target: InsightDataBindingDimension;
        window: InsightTimeWindowDoc;
      };
    }
  | { radar: { target: InsightRadarTargetDoc; window: InsightTimeWindowDoc } }
  | { cohort: { window: InsightTimeWindowDoc } }
  | { funnel: { stages: string[]; window: InsightTimeWindowDoc } }
  | { quota: { providerKey?: string } }
  | { forecast: { metric: string; horizonDays: number } }
  | { anomaly: { window: InsightTimeWindowDoc } }
  | { useCaseClusters: { window: InsightTimeWindowDoc } }
  | { agentFocusMatrix: { window: InsightTimeWindowDoc } }
  | { modelFocusMatrix: { window: InsightTimeWindowDoc } }
  | { drilldown: { limit: number } }
  | { narrative: InsightWidgetDataNarrativeDoc }
  | { recommendation: InsightWidgetDataRecommendationDoc }
  | { mermaid: { source: string } }
  | { ascii: InsightWidgetDataASCIICardDoc }
  | { composed: InsightDataBindingDoc[] };

export type InsightDataBindingDimension =
  | "provider"
  | "model"
  | "project"
  | "device"
  | "session"
  | "file"
  | "day"
  | "hourOfDay"
  | "dayOfWeek"
  | "focus"
  | "useCase";

export type InsightRadarTargetDoc = { agent: string } | { model: string } | "allAgents" | "allModels";

export type InsightTimeWindowDoc =
  | "today"
  | "last24h"
  | "last7d"
  | "last30d"
  | "last90d"
  | "last365d"
  | "allTime"
  | { custom: { start: string; end: string } };

export interface InsightLayoutDoc {
  columnCount: number;
  rowHeight: number;
  gap: number;
  placements: Record<string, InsightCellPlacementDoc>;
  revision: number;
}

export interface InsightCellPlacementDoc {
  column: number;
  row: number;
  colSpan: number;
  rowSpan: number;
}

export interface InsightFilterDoc {
  window: InsightTimeWindowDoc;
  providers: string[];
  models: string[];
  projects: string[];
  focuses: string[];
  useCases: string[];
  minCostUSD?: number;
  maxCostUSD?: number;
}

export interface InsightModelTagDoc {
  providerKey: string;
  modelID: string;
  displayName: string;
  egressTier: InsightEgressTier;
  stampedAt: string;
}

export interface InsightCitationDoc {
  id: string;
  kind: InsightCitationKindDoc;
  label: string;
}

export type InsightCitationKindDoc =
  | { session: { id: string; provider?: string } }
  | { model: { id: string } }
  | { agent: { provider: string } }
  | { project: { name: string } }
  | { day: { date: string } }
  | { anomaly: { id: string } }
  | { query: { text: string } }
  | { quota: { provider: string; bucket: string } }
  | { benchmark: { source: string; modelID: string; taskCategory: string } };

export interface InsightTaxonomyDoc {
  focuses: string[];
  useCases: string[];
}

export type InsightValueFormat = "currency" | "tokens" | "percent" | "duration" | "count" | "raw";
