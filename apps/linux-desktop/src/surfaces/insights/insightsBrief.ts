import type { UsageInsights } from '../../tauriBridge.js';
import { weekOverWeekTokenDeltaPct } from './insightsChartMath.js';

export type InsightsBrief = {
  headline: string;
  summary: string;
  observations: string[];
  followUps: { label: string; href: string; reason: string }[];
};

function topLabel(entries: { label: string; pct: number }[], fallback: string): string {
  return [...entries].sort((left, right) => right.pct - left.pct)[0]?.label ?? fallback;
}

function signedPercent(value: number | null): string {
  if (value === null || !Number.isFinite(value)) return 'No week-over-week comparison yet';
  const rounded = Math.round(value * 10) / 10;
  return `${rounded > 0 ? '+' : ''}${rounded}% week over week`;
}

/**
 * Builds an editorial-style brief strictly from normalized usage aggregates.
 * It deliberately does not infer provider quality, project intent, or savings.
 */
export function buildInsightsBrief(data: UsageInsights): InsightsBrief {
  const delta = weekOverWeekTokenDeltaPct(data.weekly);
  const topProvider = topLabel(data.providerMix, 'No provider mix yet');
  const topModel = topLabel(data.modelMix, 'No model mix yet');
  const latest = data.weekly[data.weekly.length - 1];
  const observations = [
    latest
      ? `Latest period: ${latest.tokens.toLocaleString()} tokens and $${latest.costUsd.toFixed(2)} recorded.`
      : 'No latest usage period is available.',
    `Primary provider by recorded share: ${topProvider}.`,
    `Primary model by recorded share: ${topModel}.`,
    `Cache hit rate: ${Math.round(data.cacheHitRatePct)}%.`,
    signedPercent(delta)
  ];

  return {
    headline: delta === null
      ? 'Usage baseline established'
      : delta > 0
        ? 'Usage is trending up'
        : delta < 0
          ? 'Usage is trending down'
          : 'Usage is holding steady',
    summary: 'A concise readout of normalized daemon usage. It describes recorded activity only; it is not a provider-quality or cost-savings judgment.',
    observations,
    followUps: [
      {
        label: 'Review providers',
        href: '#/providers',
        reason: 'Inspect routing, account slots, and model health.'
      },
      {
        label: 'Open activity',
        href: '#/activity',
        reason: 'Inspect session-backed evidence behind the aggregates.'
      }
    ]
  };
}
