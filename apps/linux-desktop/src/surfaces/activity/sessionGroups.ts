import type { SessionEntry } from '../../tauriBridge.js';

export type DaySessionGroup = {
  key: number;
  title: string;
  sessions: SessionEntry[];
};

function startOfLocalDay(iso: string): number {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return 0;
  return new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
}

function daySectionTitle(bucketStartMs: number): string {
  if (bucketStartMs === 0) return 'Unknown date';
  return new Date(bucketStartMs).toLocaleDateString('en-US', { dateStyle: 'full' });
}

export function groupSessionsByDay(sessions: SessionEntry[]): DaySessionGroup[] {
  const buckets = new Map<number, SessionEntry[]>();
  for (const session of sessions) {
    const key = startOfLocalDay(session.startedAt);
    const list = buckets.get(key);
    if (list) list.push(session);
    else buckets.set(key, [session]);
  }
  return [...buckets.entries()]
    .sort(([a], [b]) => b - a)
    .map(([key, groupSessions]) => ({
      key,
      title: daySectionTitle(key),
      sessions: groupSessions
    }));
}