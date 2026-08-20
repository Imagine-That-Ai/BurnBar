import { findProviderGlyph } from '../../providerGlyphs.js';
import { colorForProviderID } from '../../providerColors.js';
import type { MixEntry, UsageInsights, UsageSummary } from '../../tauriBridge.js';
import { overviewFixturesAllowed } from './overviewHomeModel.js';

export type OverviewProviderRow = {
  id: string;
  label: string;
  costUsd: number;
  accent: string;
};

export type SpendCurveBand = {
  id: string;
  label: string;
  color: string;
  points: { date: Date; base: number; top: number }[];
};

export type SpendCurveModel = {
  bands: SpendCurveBand[];
  xDomain: { start: Date; end: Date };
  yMax: number;
  isEmpty: boolean;
  legend: { id: string; label: string; color: string }[];
};

const costFmt = new Intl.NumberFormat('en-US', {
  style: 'currency',
  currency: 'USD',
  minimumFractionDigits: 2,
  maximumFractionDigits: 2
});

const costFmt4 = new Intl.NumberFormat('en-US', {
  style: 'currency',
  currency: 'USD',
  minimumFractionDigits: 4,
  maximumFractionDigits: 4
});

export function formatProviderCost(usd: number): string {
  if (usd > 0 && usd < 0.01) return costFmt4.format(usd);
  return costFmt.format(usd);
}

/** macOS Atelier screenshot parity — fixture-only provider rail. */
export const ATELIER_FIXTURE_PROVIDER_ROWS: OverviewProviderRow[] = [
  { id: 'minimax', label: 'MiMo', costUsd: 252.43, accent: 'var(--color-brass-bright)' },
  { id: 'hermes', label: 'Hermes', costUsd: 202.58, accent: 'var(--color-text-mute)' },
  { id: 'grok', label: 'xAI', costUsd: 94.61, accent: 'var(--color-text-bright)' },
  { id: 'kimi', label: 'Kimi', costUsd: 87.42, accent: 'var(--color-tier-server-readable)' },
  { id: 'opencode', label: 'OpenCode', costUsd: 33.17, accent: 'var(--color-tier-end-to-end)' },
  { id: 'factory', label: 'MiniMax', costUsd: 9.64, accent: 'var(--color-brass-core)' },
  { id: 'windsurf', label: 'Windsurf', costUsd: 1.02, accent: 'var(--color-mercury-bright)' },
  { id: 'openai', label: 'Zai', costUsd: 0.07, accent: 'var(--color-brass-bright)' },
  { id: 'deepseek', label: 'DeepSeek', costUsd: 0.00004, accent: 'var(--color-tier-end-to-end)' },
  { id: 'ollama', label: 'Ollama', costUsd: 0, accent: 'var(--color-text-bright)' }
];

const PROVIDER_COLORS: Record<string, string> = {
  'claude-code': 'var(--color-tier-server-readable)',
  codex: 'var(--color-brass-bright)',
  antigravity: 'var(--color-mercury-bright)',
  factory: 'var(--color-tier-end-to-end)',
  cursor: 'var(--color-brass-core)',
  anthropic: 'var(--color-tier-server-readable)',
  openai: 'var(--color-tier-end-to-end)',
  google: 'var(--color-mercury-bright)',
  other: 'var(--color-text-mute)'
};

const LEGEND_ORDER = ['claude-code', 'codex', 'antigravity', 'factory', 'cursor', 'other'] as const;

export function providerRowsFromInsights(
  mix: MixEntry[],
  totalCostUsd: number,
  fixtureMode: boolean
): OverviewProviderRow[] {
  if (overviewFixturesAllowed(fixtureMode)) return ATELIER_FIXTURE_PROVIDER_ROWS;
  if (!mix.length || totalCostUsd <= 0) return [];
  return mix
    .map((m) => {
      const g = findProviderGlyph(m.id);
      return {
        id: m.id,
        label: m.label,
        costUsd: (m.pct / 100) * totalCostUsd,
        accent: g.accent
      };
    })
    .sort((a, b) => b.costUsd - a.costUsd);
}

function monotonePath(points: { x: number; y: number }[]): string {
  if (points.length === 0) return '';
  if (points.length === 1) return `M ${points[0].x} ${points[0].y}`;
  let d = `M ${points[0].x} ${points[0].y}`;
  for (let i = 0; i < points.length - 1; i++) {
    const p0 = points[Math.max(0, i - 1)];
    const p1 = points[i];
    const p2 = points[i + 1];
    const p3 = points[Math.min(points.length - 1, i + 2)];
    const cp1x = p1.x + (p2.x - p0.x) / 6;
    const cp1y = p1.y + (p2.y - p0.y) / 6;
    const cp2x = p2.x - (p3.x - p1.x) / 6;
    const cp2y = p2.y - (p3.y - p1.y) / 6;
    d += ` C ${cp1x} ${cp1y}, ${cp2x} ${cp2y}, ${p2.x} ${p2.y}`;
  }
  return d;
}

/** Stacked provider burn curve (SVG-only port of AtelierSpendCurve). */
export function buildSpendCurveModel(
  insights: UsageInsights | null,
  summary: UsageSummary | null,
  fixtureMode: boolean
): SpendCurveModel {
  const now = new Date();
  const empty: SpendCurveModel = {
    bands: [],
    xDomain: { start: new Date(now.getTime() - 28 * 86400000), end: now },
    yMax: 1,
    isEmpty: true,
    legend: []
  };

  if (overviewFixturesAllowed(fixtureMode) && insights?.weekly?.length) {
    const weekly = insights.weekly;
    const mix = insights.providerMix;
    const start = new Date('2026-05-31T00:00:00Z');
    const end = new Date('2026-06-28T23:59:59Z');
    const n = weekly.length;
    const dates = weekly.map((_, i) => new Date(start.getTime() + (i / Math.max(1, n - 1)) * (end.getTime() - start.getTime())));

    const ranked = [...mix].sort((a, b) => b.pct - a.pct);
    const top = ranked.slice(0, 5);
    const otherPct = ranked.slice(5).reduce((s, m) => s + m.pct, 0);
    const bandDefs: { id: string; label: string; pct: number }[] = [
      ...top.map((m) => ({ id: m.id, label: findProviderGlyph(m.id).label, pct: m.pct })),
      ...(otherPct > 0 ? [{ id: 'other', label: 'Other', pct: otherPct }] : [])
    ];

    const cumulativeByDate: number[] = new Array(n).fill(0);
    const bands: SpendCurveBand[] = [];

    for (const def of bandDefs) {
      const points: { date: Date; base: number; top: number }[] = [];
      for (let i = 0; i < n; i++) {
        const slice = (weekly[i].costUsd * def.pct) / 100;
        const base = cumulativeByDate[i];
        const top = base + slice;
        points.push({ date: dates[i], base, top });
        cumulativeByDate[i] = top;
      }
      bands.push({
        id: def.id,
        label: def.label,
        color: PROVIDER_COLORS[def.id] ?? colorForProviderID(def.id),
        points
      });
    }

    const yMax = Math.max(...cumulativeByDate, 1);
    const scaledYMax = Math.max(15000, Math.ceil(yMax / 5000) * 5000);

    const legend = LEGEND_ORDER.map((id) => ({
      id,
      label:
        id === 'other'
          ? 'Other'
          : id === 'claude-code'
            ? 'Claude Code'
            : findProviderGlyph(id).label,
      color: PROVIDER_COLORS[id]
    }));

    return {
      bands,
      xDomain: { start, end },
      yMax: scaledYMax,
      isEmpty: false,
      legend
    };
  }

  if (!insights?.weekly?.length || !summary) return empty;

  const weekly = insights.weekly;
  const mix = insights.providerMix;
  const n = weekly.length;
  const start = new Date(now.getTime() - (n - 1) * 7 * 86400000);
  const dates = weekly.map((_, i) => new Date(start.getTime() + i * 7 * 86400000));
  const ranked = [...mix].sort((a, b) => b.pct - a.pct).slice(0, 5);
  const otherPct = 100 - ranked.reduce((s, m) => s + m.pct, 0);

  const cumulativeByDate: number[] = new Array(n).fill(0);
  const bandDefs = [
    ...ranked.map((m) => ({ id: m.id, label: m.label, pct: m.pct })),
    ...(otherPct > 0.5 ? [{ id: 'other', label: 'Other', pct: otherPct }] : [])
  ];
  const bands: SpendCurveBand[] = [];

  for (const def of bandDefs) {
    const points: { date: Date; base: number; top: number }[] = [];
    for (let i = 0; i < n; i++) {
      const slice = (weekly[i].costUsd * def.pct) / 100;
      const base = cumulativeByDate[i];
      const top = base + slice;
      points.push({ date: dates[i], base, top });
      cumulativeByDate[i] = top;
    }
    bands.push({
      id: def.id,
      label: def.label,
      color: PROVIDER_COLORS[def.id] ?? colorForProviderID(def.id),
      points
    });
  }

  const yMax = Math.max(...cumulativeByDate, summary.todayCostUsd, 1);

  return {
    bands,
    xDomain: { start: dates[0], end: dates[n - 1] },
    yMax,
    isEmpty: bands.every((b) => b.points.every((p) => p.top - p.base < 1e-9)),
    legend: bandDefs.map((d) => ({
      id: d.id,
      label: d.label,
      color: PROVIDER_COLORS[d.id] ?? 'var(--color-text-mute)'
    }))
  };
}

export { monotonePath };
