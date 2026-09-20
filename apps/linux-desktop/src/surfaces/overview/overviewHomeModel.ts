import { DAEMON_FIXTURE_AVAILABLE } from '../../daemonFixture.js';
import { colorForProviderID } from '../../providerColors.js';
import { findProviderGlyph } from '../../providerGlyphs.js';
import type { MixEntry, MissionListResult, SessionEntry, UsageSummary } from '../../tauriBridge.js';
import { resolveCacheHitRateTier } from './cacheHitTier.js';

/** Reading measure is a property of a paragraph, not of the page. */
export const HOME_READING_MEASURE = {
  headline: 620,
  body: 680,
  editorial: 760
} as const;

export const STREAM_ROW_UNIT = 32;
export const STREAM_DAY_CHROME = 48;
export const ATLAS_ROW_UNIT = 32;
export const PROVIDER_ROW_UNIT = 42;

export type StreamEntry = {
  id: string;
  at: string;
  title: string;
  detail: string;
  costUsd: number;
};

export type StreamDay = {
  key: number;
  label: string;
  entries: StreamEntry[];
  totalCostUsd: number;
  isSpike: boolean;
};

export type AtlasAttentionRow = {
  id: string;
  title: string;
  priority: 'p1' | 'p2';
  comparison: string;
  kind: string;
};

export type AtlasKindRank = {
  kind: string;
  label: string;
  count: number;
  share: number;
  accent: string;
};

export type AtlasSplit = {
  needsYou: number;
  everythingElse: number;
  total: number;
  unreadShare: number;
  needsYouCaption: string;
  elseCaption: string;
  gapLabel: string;
};

export type AtelierHeroCopy = {
  headline: string;
  sub: string;
  chips: Array<{ id: string; label: string; tone: 'swarm' | 'kernel' }>;
};

const costFmt = new Intl.NumberFormat('en-US', {
  style: 'currency',
  currency: 'USD',
  minimumFractionDigits: 2,
  maximumFractionDigits: 2
});

export function overviewFixturesAllowed(fixtureMode: boolean): boolean {
  return fixtureMode === true && DAEMON_FIXTURE_AVAILABLE;
}

export function parseEventCost(detail: string): number {
  const match = detail.match(/\$([0-9]+(?:\.[0-9]+)?)/);
  return match ? Number(match[1]) : 0;
}

export function streamEntriesFromSummary(summary: UsageSummary | null): StreamEntry[] {
  if (!summary) return [];
  return summary.recentEvents
    .map((event) => ({
      id: event.id,
      at: event.at,
      title: event.title,
      detail: event.detail,
      costUsd: parseEventCost(event.detail)
    }))
    .sort((a, b) => new Date(b.at).getTime() - new Date(a.at).getTime());
}

function streamEntriesFromSessions(sessions: SessionEntry[]): StreamEntry[] {
  return sessions
    .map((session) => ({
      id: session.id,
      at: session.startedAt,
      title: session.title || `${session.provider} / ${session.model}`,
      detail: `${session.tokens.toLocaleString('en-US')} tokens · ${costFmt.format(session.costUsd)}`,
      costUsd: session.costUsd
    }))
    .sort((a, b) => new Date(b.at).getTime() - new Date(a.at).getTime());
}

export function resolveStreamEntries(
  summary: UsageSummary | null,
  sessions: SessionEntry[]
): StreamEntry[] {
  return sessions.length > 0 ? streamEntriesFromSessions(sessions) : streamEntriesFromSummary(summary);
}

function startOfLocalDay(iso: string): number {
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return 0;
  return new Date(date.getFullYear(), date.getMonth(), date.getDate()).getTime();
}

export function streamDayLabel(key: number, now: Date = new Date()): string {
  if (key === 0) return 'Unknown date';
  const today = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  const todayKey = today.getTime();
  if (key === todayKey) return 'Today';
  today.setDate(today.getDate() - 1);
  if (key === today.getTime()) return 'Yesterday';
  return new Date(key).toLocaleDateString('en-US', { weekday: 'long', month: 'short', day: 'numeric' });
}

/**
 * Newest `limit` rows, then grouped by day. Truncating before grouping keeps
 * recency the only order — taking N per day would surface a stale Tuesday
 * ahead of this morning's.
 */
export function groupStreamByDay(entries: StreamEntry[], limit: number): StreamDay[] {
  const newest = entries
    .slice()
    .sort((a, b) => new Date(b.at).getTime() - new Date(a.at).getTime())
    .slice(0, Math.max(0, limit));

  const buckets = new Map<number, StreamEntry[]>();
  for (const entry of newest) {
    const key = startOfLocalDay(entry.at);
    const list = buckets.get(key);
    if (list) list.push(entry);
    else buckets.set(key, [entry]);
  }

  const days: StreamDay[] = [...buckets.entries()]
    .sort(([a], [b]) => b - a)
    .map(([key, group]) => ({
      key,
      label: streamDayLabel(key),
      entries: group,
      totalCostUsd: group.reduce((sum, entry) => sum + entry.costUsd, 0),
      isSpike: false
    }));

  const mean =
    days.length === 0 ? 0 : days.reduce((sum, day) => sum + day.totalCostUsd, 0) / days.length;
  return days.map((day) => ({
    ...day,
    isSpike: mean > 0 && day.totalCostUsd > mean * 1.5
  }));
}

export function formatStreamTime(iso: string): string {
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return '';
  return date.toLocaleTimeString(undefined, { hour: 'numeric', minute: '2-digit' });
}

function kindFromTitle(title: string): string {
  return title.split('/')[0]?.trim() || title || 'other';
}

export function buildAtlasModel(input: {
  missions: MissionListResult | null;
  events: StreamEntry[];
  providerMix: MixEntry[];
}): {
  split: AtlasSplit;
  attention: AtlasAttentionRow[];
  rest: AtlasAttentionRow[];
  kinds: AtlasKindRank[];
} {
  const missionAttention = atlasFromMissions(input.missions);
  if (missionAttention) return missionAttention;

  const events = input.events;
  const mix = input.providerMix;
  if (mix.length > 0) {
    const ranked = [...mix].sort((a, b) => b.pct - a.pct);
    const equalShare = 100 / ranked.length;
    const needs = ranked.filter((entry) => entry.pct >= Math.max(20, equalShare * 1.5));
    const attentionSource = needs.length > 0 ? needs : ranked.slice(0, Math.min(2, ranked.length));
    const attentionIds = new Set(attentionSource.map((entry) => entry.id));
    const restMix = ranked.filter((entry) => !attentionIds.has(entry.id));
    const attention = attentionSource.map((entry) => ({
      id: entry.id,
      title: entry.label,
      priority: entry.pct >= 40 ? ('p1' as const) : ('p2' as const),
      comparison: `${Math.round(entry.pct)}% of window · ${deltaVsEqual(entry.pct, equalShare)}`,
      kind: 'provider'
    }));
    const rest = restMix.map((entry) => ({
      id: entry.id,
      title: entry.label,
      priority: 'p2' as const,
      comparison: `${Math.round(entry.pct)}% of window`,
      kind: 'provider'
    }));
    const kinds = ranked.map((entry) => ({
      kind: entry.id,
      label: entry.label,
      count: 0,
      share: entry.pct / 100,
      accent: findProviderGlyph(entry.id).accent || colorForProviderID(entry.id)
    }));
    const total = attention.length + rest.length;
    return {
      split: {
        needsYou: attention.length,
        everythingElse: rest.length,
        total,
        unreadShare: total === 0 ? 0 : attention.length / total,
        needsYouCaption: attention.length === 0 ? 'No provider dominating' : 'Share above the field',
        elseCaption: rest.length === 0 ? 'The whole mix needs you' : 'Worth knowing, not now',
        gapLabel: formatGap(attention.length, rest.length)
      },
      attention,
      rest,
      kinds
    };
  }

  const todayKey = startOfLocalDay(new Date().toISOString());
  const attentionEvents = events.filter((event) => startOfLocalDay(event.at) === todayKey);
  const restEvents = events.filter((event) => startOfLocalDay(event.at) !== todayKey);
  const attentionRows = (attentionEvents.length > 0 ? attentionEvents : events.slice(0, 2)).map((event) => ({
    id: event.id,
    title: event.title,
    priority: 'p1' as const,
    comparison: event.costUsd > 0 ? `${costFmt.format(event.costUsd)} today` : formatStreamTime(event.at),
    kind: kindFromTitle(event.title)
  }));
  const attentionIds = new Set(attentionRows.map((row) => row.id));
  const restRows = (attentionEvents.length > 0 ? restEvents : events.slice(2)).map((event) => ({
    id: event.id,
    title: event.title,
    priority: 'p2' as const,
    comparison: formatStreamTime(event.at),
    kind: kindFromTitle(event.title)
  }));
  const kindMap = new Map<string, number>();
  for (const event of events) {
    const kind = kindFromTitle(event.title);
    kindMap.set(kind, (kindMap.get(kind) ?? 0) + 1);
  }
  const kinds: AtlasKindRank[] = [...kindMap.entries()]
    .sort((a, b) => b[1] - a[1])
    .map(([kind, count]) => ({
      kind,
      label: findProviderGlyph(kind).label || kind,
      count,
      share: events.length === 0 ? 0 : count / events.length,
      accent: findProviderGlyph(kind).accent || colorForProviderID(kind)
    }));
  const total = attentionRows.length + restRows.filter((row) => !attentionIds.has(row.id)).length;
  const rest = restRows.filter((row) => !attentionIds.has(row.id));
  return {
    split: {
      needsYou: attentionRows.length,
      everythingElse: rest.length,
      total,
      unreadShare: total === 0 ? 0 : attentionRows.length / Math.max(1, events.length),
      needsYouCaption: attentionRows.length === 0 ? 'Clear' : 'Landed today',
      elseCaption: rest.length === 0 ? 'Nothing later' : 'Earlier in the window',
      gapLabel: formatGap(attentionRows.length, rest.length)
    },
    attention: attentionRows,
    rest,
    kinds
  };
}

function atlasFromMissions(missions: MissionListResult | null): {
  split: AtlasSplit;
  attention: AtlasAttentionRow[];
  rest: AtlasAttentionRow[];
  kinds: AtlasKindRank[];
} | null {
  if (!missions) return null;
  const pendingApprovals = missions.pendingApprovals ?? [];
  const pendingQuestions = (missions.pendingQuestions ?? []).filter((question) => question.status === 'pending');
  const blocked = missions.missions.filter((mission) => {
    const state = mission.state.trim().toLowerCase();
    return state === 'blocked' || state === 'failed' || state.includes('awaiting');
  });
  if (pendingApprovals.length === 0 && pendingQuestions.length === 0 && blocked.length === 0 && missions.missions.length === 0) {
    return null;
  }

  const attention: AtlasAttentionRow[] = [
    ...pendingApprovals.map((approval) => ({
      id: approval.id,
      title: approval.summary,
      priority: approval.risk === 'high' ? ('p1' as const) : ('p2' as const),
      comparison: approval.risk === 'high' ? 'High risk gate' : 'Needs a decision',
      kind: 'approval'
    })),
    ...pendingQuestions.map((question) => ({
      id: question.id,
      title: question.title,
      priority: question.priority === 'critical' || question.priority === 'high' ? ('p1' as const) : ('p2' as const),
      comparison: question.dueAt ? `Due ${formatStreamTime(question.dueAt)}` : 'Open question',
      kind: 'question'
    })),
    ...blocked.map((mission) => ({
      id: mission.id,
      title: mission.title,
      priority: 'p1' as const,
      comparison: mission.state,
      kind: 'mission'
    }))
  ];
  const attentionIds = new Set(attention.map((row) => row.id));
  const rest: AtlasAttentionRow[] = missions.missions
    .filter((mission) => !attentionIds.has(mission.id))
    .map((mission) => ({
      id: mission.id,
      title: mission.title,
      priority: 'p2' as const,
      comparison: mission.state,
      kind: 'mission'
    }));
  const kindMap = new Map<string, number>();
  for (const row of [...attention, ...rest]) {
    kindMap.set(row.kind, (kindMap.get(row.kind) ?? 0) + 1);
  }
  const total = attention.length + rest.length;
  const kinds: AtlasKindRank[] = [...kindMap.entries()]
    .sort((a, b) => b[1] - a[1])
    .map(([kind, count]) => ({
      kind,
      label: kind === 'approval' ? 'Approvals' : kind === 'question' ? 'Questions' : kind === 'mission' ? 'Missions' : kind,
      count,
      share: total === 0 ? 0 : count / total,
      accent:
        kind === 'approval'
          ? 'var(--color-seal-crimson)'
          : kind === 'question'
            ? 'var(--color-brass-bright)'
            : 'var(--color-tier-server-readable)'
    }));
  return {
    split: {
      needsYou: attention.length,
      everythingElse: rest.length,
      total,
      unreadShare: total === 0 ? 0 : attention.length / total,
      needsYouCaption: `${pendingApprovals.length} gates · ${pendingQuestions.length} questions`,
      elseCaption: rest.length === 0 ? 'Nothing later' : 'Worth knowing, not now',
      gapLabel: formatGap(attention.length, rest.length)
    },
    attention,
    rest,
    kinds
  };
}

function deltaVsEqual(pct: number, equalShare: number): string {
  const delta = pct - equalShare;
  const sign = delta > 0 ? '+' : '';
  return `${sign}${Math.round(delta)} pts vs equal share`;
}

export function formatGap(needsYou: number, everythingElse: number): string {
  if (needsYou === 0 && everythingElse === 0) return 'Nothing on either side';
  if (needsYou === 0) return 'Clear — everything can wait';
  if (everythingElse === 0) return 'The whole queue needs you';
  const ratio = needsYou / Math.max(1, everythingElse);
  if (ratio >= 1) return `${needsYou} need you against ${everythingElse} later`;
  return `${everythingElse - needsYou} more can wait than need you`;
}

export function formatPercent(value: number): string {
  if (!Number.isFinite(value) || value <= 0) return '0%';
  return `${Math.round(value * 100)}%`;
}

export function windowSessionCount(summary: UsageSummary | null): number {
  if (!summary) return 0;
  return new Set(summary.recentEvents.map((event) => event.id)).size;
}

export function windowTokenTotal(summary: UsageSummary | null): number {
  if (!summary) return 0;
  return summary.sevenDay.reduce((sum, value) => sum + value, 0);
}

export function buildAtelierHeroCopy(input: {
  summary: UsageSummary | null;
  providerCount: number;
  cacheHitRatePct: number | null;
  fixtureMode: boolean;
  kernelForward: boolean;
}): AtelierHeroCopy {
  const sessions = windowSessionCount(input.summary);
  const today = input.summary?.todayCostUsd ?? 0;
  const cache = resolveCacheHitRateTier(input.cacheHitRatePct);
  const chips: AtelierHeroCopy['chips'] = [];

  if (overviewFixturesAllowed(input.fixtureMode)) {
    chips.push({ id: 'source', label: 'Fixture transcript', tone: 'swarm' });
  } else if (input.summary) {
    chips.push({ id: 'source', label: 'Live usage', tone: 'swarm' });
  }
  if (input.kernelForward) {
    chips.push({ id: 'kernel', label: 'Kernel on this layout', tone: 'kernel' });
  }
  if (cache.id !== 'noSignal') {
    chips.push({ id: 'cache', label: `Cache ${cache.formattedValue}`, tone: 'kernel' });
  }

  if (!input.summary || (today === 0 && sessions === 0 && input.providerCount === 0)) {
    return {
      headline: 'The field is still.',
      sub: 'Sessions and spend land here as the daemon mines them. Nothing is fabricated to fill the plate.',
      chips
    };
  }

  const sessionBit = sessions === 1 ? 'One session in the window.' : `${sessions} sessions in the window.`;
  const providerBit =
    input.providerCount === 0
      ? 'No provider mix yet'
      : `${input.providerCount} provider${input.providerCount === 1 ? '' : 's'}`;
  return {
    headline: sessionBit,
    sub: `${providerBit} · ${costFmt.format(today)} today · cache ${cache.formattedValue}.`,
    chips
  };
}

export function weeklyHalves(weekly: Array<{ costUsd: number }>): { first: number; second: number; delta: number } {
  if (weekly.length === 0) return { first: 0, second: 0, delta: 0 };
  const mid = Math.ceil(weekly.length / 2);
  const first = weekly.slice(0, mid).reduce((sum, point) => sum + point.costUsd, 0);
  const second = weekly.slice(mid).reduce((sum, point) => sum + point.costUsd, 0);
  const delta = first === 0 ? (second > 0 ? 1 : 0) : (second - first) / first;
  return { first, second, delta };
}
