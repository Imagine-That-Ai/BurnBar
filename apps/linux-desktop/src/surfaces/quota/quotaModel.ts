import type { ProviderCatalog, ProviderCatalogEntry, QuotaBucket } from '../../tauriBridge.js';
import { PROVIDER_GLYPHS } from '../../providerGlyphs.js';
import { remainingPct } from '../providers/providerQuotaMetrics.js';
import { computeIdealPace, type IdealPace } from './quotaPace.js';

export type QuotaViewMode = 'cards' | 'list';
export type QuotaSortMode = 'urgency' | 'spend' | 'alphabetical' | 'recentlyRefreshed';

export type QuotaSourceKind =
  | 'officialAPI'
  | 'localSession'
  | 'localCLI'
  | 'manualEstimate'
  | 'provider'
  | 'unavailable';

export type QuotaConfidence = 'high' | 'medium' | 'low' | 'stale';

export type SubscriptionBucketView = {
  id: string;
  label: string;
  usedPct: number;
  remainingPct: number;
  resetsAt?: string;
  state: QuotaBucket['state'];
  isEstimated: boolean;
  windowKind: 'short' | 'long' | 'sevenDay' | 'other';
  pace: IdealPace | null;
};

export type SubscriptionEntry = {
  id: string;
  providerId: string;
  providerLabel: string;
  accountLabel: string;
  planTierBadge: string | null;
  sourceKind: QuotaSourceKind;
  sourceLabel: string;
  confidence: QuotaConfidence;
  storageScope: 'cloud' | 'local' | 'keychain' | 'unknown';
  buckets: SubscriptionBucketView[];
  shortBucket: SubscriptionBucketView | null;
  longBucket: SubscriptionBucketView | null;
  sevenDayBucket: SubscriptionBucketView | null;
  primaryBucket: SubscriptionBucketView | null;
  pressure: number;
  remainingPercentRounded: number;
  nextResetDate: string | null;
  isInactive: boolean;
  isRefreshing: boolean;
};

export type SubscriptionSetupSlot = {
  id: string;
  providerId: string;
  providerLabel: string;
};

export type AggregateSummary = {
  activeCount: number;
  wideOpenCount: number;
  narrowingCount: number;
  nearEdgeCount: number;
  trackedPlanCount: number;
};

export type QuotaWorkspacePrefs = {
  viewMode: QuotaViewMode;
  sort: QuotaSortMode;
  showInactive: boolean;
};

const PREFS_KEY = 'openburnbar.linux.quota.prefs';

export function loadQuotaPrefs(): QuotaWorkspacePrefs {
  try {
    const raw = localStorage.getItem(PREFS_KEY);
    if (!raw) return { viewMode: 'cards', sort: 'urgency', showInactive: false };
    const parsed = JSON.parse(raw) as Partial<QuotaWorkspacePrefs>;
    return {
      viewMode: parsed.viewMode === 'list' ? 'list' : 'cards',
      sort: parsed.sort ?? 'urgency',
      showInactive: Boolean(parsed.showInactive)
    };
  } catch {
    return { viewMode: 'cards', sort: 'urgency', showInactive: false };
  }
}

export function saveQuotaPrefs(prefs: QuotaWorkspacePrefs): void {
  localStorage.setItem(PREFS_KEY, JSON.stringify(prefs));
}

type CatalogExt = ProviderCatalogEntry & {
  accountStorage?: 'cloud' | 'local' | 'keychain' | 'unknown';
  quotaSource?: string;
  quotaSourceKind?: QuotaSourceKind;
  quotaConfidence?: QuotaConfidence;
  planTierBadge?: string;
  isRefreshing?: boolean;
};

function classifyWindow(label: string): SubscriptionBucketView['windowKind'] {
  const lower = label.toLowerCase();
  if (/\d+\s*h|hour|5h|24h/.test(lower)) return 'short';
  if (/week|7.?day|7d/.test(lower)) return 'sevenDay';
  if (/month|daily|day|min/.test(lower)) return 'long';
  return 'other';
}

function bucketView(bucket: QuotaBucket, now = Date.now()): SubscriptionBucketView {
  const ext = bucket as QuotaBucket & { isEstimated?: boolean };
  const remaining = remainingPct(bucket);
  const used = Math.min(100, Math.max(0, bucket.usedPct));
  return {
    id: bucket.id,
    label: bucket.label,
    usedPct: used,
    remainingPct: remaining,
    resetsAt: bucket.resetsAt,
    state: bucket.state,
    isEstimated: Boolean(ext.isEstimated),
    windowKind: classifyWindow(bucket.label),
    pace: computeIdealPace(bucket, remaining, now)
  };
}

function resolveSource(entry: CatalogExt): { kind: QuotaSourceKind; label: string; confidence: QuotaConfidence } {
  if (entry.quotaSourceKind) {
    return {
      kind: entry.quotaSourceKind,
      label: sourceLabelForKind(entry.quotaSourceKind),
      confidence: entry.quotaConfidence ?? 'medium'
    };
  }
  const raw = (entry.quotaSource ?? '').toLowerCase();
  if (raw.includes('official') || raw.includes('api')) {
    return { kind: 'officialAPI', label: 'Official API', confidence: entry.quotaConfidence ?? 'high' };
  }
  if (raw.includes('session')) {
    return { kind: 'localSession', label: 'Local session', confidence: entry.quotaConfidence ?? 'medium' };
  }
  if (entry.quotaBuckets.some((b) => b.state === 'missing_credential')) {
    return { kind: 'unavailable', label: 'Unavailable', confidence: 'low' };
  }
  if (entry.quotaBuckets.length === 0) {
    return { kind: 'unavailable', label: 'Unavailable', confidence: 'low' };
  }
  return { kind: 'officialAPI', label: 'Official API', confidence: entry.quotaConfidence ?? 'high' };
}
export function sourceLabelForKind(kind: QuotaSourceKind): string {
  switch (kind) {
    case 'officialAPI':
      return 'Official API';
    case 'localSession':
      return 'Local session';
    case 'localCLI':
      return 'Local CLI';
    case 'manualEstimate':
      return 'Estimated';
    case 'unavailable':
      return 'Unavailable';
    default:
      return 'Provider';
  }
}

function inferStorage(entry: CatalogExt): SubscriptionEntry['storageScope'] {
  if (entry.accountStorage) return entry.accountStorage;
  const lower = entry.accountLabel.toLowerCase();
  if (lower.includes('keychain') || lower.includes('mac')) return 'keychain';
  if (lower.includes('workspace') || lower.includes('team') || lower.includes('cloud')) return 'cloud';
  if (lower.includes('personal') || lower.includes('local')) return 'local';
  return 'unknown';
}

function planTier(entry: CatalogExt): string | null {
  if (entry.planTierBadge) return entry.planTierBadge;
  const lower = entry.accountLabel.toLowerCase();
  if (lower.includes('pro')) return 'PRO';
  if (lower.includes('max')) return 'MAX';
  if (lower.includes('team')) return 'TEAM';
  return null;
}

function pressureFromBuckets(buckets: SubscriptionBucketView[]): number {
  if (buckets.length === 0) return 0;
  return Math.max(...buckets.map((b) => b.usedPct / 100));
}

function pickBuckets(views: SubscriptionBucketView[]) {
  const short =
    views.find((b) => b.windowKind === 'short') ??
    views.find((b) => /5h|hour|rolling/i.test(b.label)) ??
    null;
  const sevenDay = views.find((b) => b.windowKind === 'sevenDay') ?? null;
  const long =
    views.find((b) => b.windowKind === 'long' && b !== short) ??
    views.find((b) => /week|month|daily/i.test(b.label) && b !== short) ??
    views[0] ??
    null;
  const primary = views.reduce<SubscriptionBucketView | null>((best, b) => {
    if (!best || b.usedPct > best.usedPct) return b;
    return best;
  }, null);
  return { short, long, sevenDay, primary };
}

export function buildSubscriptionEntries(catalog: ProviderCatalog, now = Date.now()): SubscriptionEntry[] {
  return catalog.map((row) => {
    const entry = row as CatalogExt;
    const buckets = entry.quotaBuckets.map((b) => bucketView(b, now));
    const { short, long, sevenDay, primary } = pickBuckets(buckets);
    const pressure = pressureFromBuckets(buckets);
    const remaining = primary ? primary.remainingPct : 0;
    const source = resolveSource(entry);
    const resets = buckets
      .map((b) => b.resetsAt)
      .filter((r): r is string => Boolean(r))
      .sort((a, b) => Date.parse(a) - Date.parse(b))[0];
    return {
      id: entry.id,
      providerId: entry.id,
      providerLabel: entry.label,
      accountLabel: entry.accountLabel,
      planTierBadge: planTier(entry),
      sourceKind: source.kind,
      sourceLabel: source.label,
      confidence: source.confidence,
      storageScope: inferStorage(entry),
      buckets,
      shortBucket: short,
      longBucket: long,
      sevenDayBucket: sevenDay,
      primaryBucket: primary,
      pressure,
      remainingPercentRounded: Math.round(remaining),
      nextResetDate: resets ?? null,
      isInactive: buckets.length === 0 || buckets.every((b) => b.state === 'missing_credential'),
      isRefreshing: Boolean(entry.isRefreshing)
    };
  });
}

export function buildInactiveSlots(catalog: ProviderCatalog): SubscriptionSetupSlot[] {
  const active = new Set(catalog.map((p) => p.id));
  return PROVIDER_GLYPHS.filter((g) => !active.has(g.id)).map((g) => ({
    id: `inactive-${g.id}`,
    providerId: g.id,
    providerLabel: g.label
  }));
}

export function aggregateSummary(entries: SubscriptionEntry[]): AggregateSummary {
  let wide = 0;
  let narrow = 0;
  let edge = 0;
  for (const e of entries.filter((x) => !x.isInactive)) {
    const p = e.pressure;
    if (p < 0.46) wide += 1;
    else if (p < 0.74) narrow += 1;
    else edge += 1;
  }
  const active = entries.filter((e) => !e.isInactive);
  return {
    activeCount: active.length,
    wideOpenCount: wide,
    narrowingCount: narrow,
    nearEdgeCount: edge,
    trackedPlanCount: entries.length
  };
}

export function eyebrowText(summary: AggregateSummary, focusedProvider: string | null, focusedLabel: string | null): string {
  if (focusedProvider && focusedLabel) {
    return `FOCUSED · ${focusedLabel.toUpperCase()} · ${summary.activeCount} ACTIVE ACCOUNT${summary.activeCount === 1 ? '' : 'S'}`;
  }
  return `SUBSCRIPTION VAULT · ${summary.activeCount} ACTIVE PLAN${summary.activeCount === 1 ? '' : 'S'}`;
}

export function headlineText(summary: AggregateSummary, focusedLabel: string | null): string {
  if (summary.activeCount === 0) return 'Connect a plan to start tracking quota';
  if (focusedLabel) {
    if (summary.nearEdgeCount > 0) {
      return `${focusedLabel} · ${summary.activeCount} plan${summary.activeCount === 1 ? '' : 's'} · ${summary.nearEdgeCount} near the edge`;
    }
    return `${focusedLabel} · ${summary.activeCount} plan${summary.activeCount === 1 ? '' : 's'} tracked`;
  }
  if (summary.nearEdgeCount > 0) {
    return `${summary.trackedPlanCount} plans tracked · ${summary.nearEdgeCount} near the edge`;
  }
  if (summary.narrowingCount > 0) {
    return `${summary.wideOpenCount} of ${summary.activeCount} plans wide open · ${summary.narrowingCount} narrowing`;
  }
  return `${summary.trackedPlanCount} plans tracked · all comfortable`;
}

export function sortEntries(entries: SubscriptionEntry[], sort: QuotaSortMode): SubscriptionEntry[] {
  const copy = [...entries];
  switch (sort) {
    case 'alphabetical':
      return copy.sort((a, b) => a.providerLabel.localeCompare(b.providerLabel));
    case 'spend':
      return copy.sort((a, b) => b.pressure - a.pressure);
    case 'recentlyRefreshed':
      return copy.sort((a, b) => a.providerLabel.localeCompare(b.providerLabel));
    case 'urgency':
    default:
      return copy.sort((a, b) => {
        if (a.pressure !== b.pressure) return b.pressure - a.pressure;
        const ar = a.nextResetDate ? Date.parse(a.nextResetDate) : Number.POSITIVE_INFINITY;
        const br = b.nextResetDate ? Date.parse(b.nextResetDate) : Number.POSITIVE_INFINITY;
        return ar - br;
      });
  }
}

export function providerOrbEntries(entries: SubscriptionEntry[]): SubscriptionEntry[] {
  const byProvider = new Map<string, SubscriptionEntry>();
  for (const e of entries) {
    const prev = byProvider.get(e.providerId);
    if (!prev || e.pressure > prev.pressure) byProvider.set(e.providerId, e);
  }
  return [...byProvider.values()].sort((a, b) => b.pressure - a.pressure);
}

export function filterByProvider(entries: SubscriptionEntry[], providerId: string | null): SubscriptionEntry[] {
  if (!providerId) return entries;
  return entries.filter((e) => e.providerId === providerId);
}