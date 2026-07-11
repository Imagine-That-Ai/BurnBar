import type { MissionListResult, PendingApproval } from '../../tauriBridge.js';

export type MissionRecord = MissionListResult['missions'][number];

export type MissionLifecycle =
  | 'planned'
  | 'running'
  | 'partial'
  | 'blocked'
  | 'completed';

export type MissionStateFilterKey =
  | 'all'
  | 'planned'
  | 'running'
  | 'partial'
  | 'blocked'
  | 'completed'
  | 'awaitingApproval';

export const MISSION_STATE_FILTERS: ReadonlyArray<{
  key: MissionStateFilterKey;
  label: string;
}> = [
  { key: 'all', label: 'All' },
  { key: 'planned', label: 'Planned' },
  { key: 'running', label: 'Running' },
  { key: 'partial', label: 'Partial' },
  { key: 'blocked', label: 'Blocked' },
  { key: 'completed', label: 'Completed' },
  { key: 'awaitingApproval', label: 'Needs Approval' }
];

export type MissionGroupKey = MissionLifecycle;

export type MissionGroup = {
  key: MissionGroupKey;
  label: string;
  missions: MissionRecord[];
};

/** Design-token accent per lifecycle (OpenBurnBarOperatingPresentation parity). */
export function missionLifecycleAccent(lifecycle: MissionLifecycle): string {
  switch (lifecycle) {
    case 'planned':
      return 'var(--color-text-dim)';
    case 'running':
      return 'var(--color-brass-core)';
    case 'partial':
      return 'var(--color-brass-bright)';
    case 'blocked':
      return 'var(--color-seal-crimson)';
    case 'completed':
      return 'var(--color-tier-end-to-end)';
  }
}

export function missionFilterAccent(filter: MissionStateFilterKey): string {
  switch (filter) {
    case 'all':
      return 'var(--color-text-dim)';
    case 'planned':
      return 'var(--color-text-dim)';
    case 'running':
      return 'var(--color-brass-core)';
    case 'partial':
      return 'var(--color-brass-bright)';
    case 'blocked':
      return 'var(--color-seal-crimson)';
    case 'completed':
      return 'var(--color-tier-end-to-end)';
    case 'awaitingApproval':
      return 'var(--color-brass-bright)';
  }
}

export function normalizeMissionLifecycle(state: string): MissionLifecycle {
  const normalized = state.trim().toLowerCase();
  switch (normalized) {
    case 'planned':
    case 'plan':
      return 'planned';
    case 'running':
    case 'active':
    case 'in_progress':
    case 'in-progress':
      return 'running';
    case 'partial':
    case 'pending':
      return 'partial';
    case 'blocked':
    case 'cancelled':
    case 'canceled':
    case 'failed':
      return 'blocked';
    case 'completed':
    case 'done':
    case 'complete':
      return 'completed';
    default:
      return 'running';
  }
}

export function formatMissionLifecycleLabel(lifecycle: MissionLifecycle): string {
  switch (lifecycle) {
    case 'planned':
      return 'Planned';
    case 'running':
      return 'Running';
    case 'partial':
      return 'Partial';
    case 'blocked':
      return 'Blocked';
    case 'completed':
      return 'Completed';
  }
}

export type MissionApprovalDisplay = 'none' | 'pending' | 'cleared';

export function missionApprovalDisplay(
  missionId: string,
  pendingApprovals: PendingApproval[]
): MissionApprovalDisplay {
  if (pendingApprovals.some((a) => a.missionId === missionId)) return 'pending';
  return 'cleared';
}

export function formatMissionApprovalLabel(display: MissionApprovalDisplay): string {
  switch (display) {
    case 'pending':
      return 'Needs approval';
    case 'cleared':
      return 'Approved';
    case 'none':
      return 'No gate';
  }
}

export function missionApprovalAccent(display: MissionApprovalDisplay): string {
  switch (display) {
    case 'pending':
      return 'var(--color-brass-bright)';
    case 'cleared':
      return 'var(--color-tier-end-to-end)';
    case 'none':
      return 'var(--color-text-dim)';
  }
}

export function missionMatchesFilter(
  mission: MissionRecord,
  filter: MissionStateFilterKey,
  pendingApprovals: PendingApproval[]
): boolean {
  if (filter === 'all') return true;
  if (filter === 'awaitingApproval') {
    return missionApprovalDisplay(mission.id, pendingApprovals) === 'pending';
  }
  return normalizeMissionLifecycle(mission.state) === filter;
}

export function countMissionsForFilter(
  missions: MissionRecord[],
  filter: MissionStateFilterKey,
  pendingApprovals: PendingApproval[]
): number {
  return missions.filter((m) => missionMatchesFilter(m, filter, pendingApprovals)).length;
}

export function missionProjectKey(mission: MissionRecord): string | null {
  const slug = mission.projectSlug?.trim();
  if (slug) return slug;
  return null;
}

export function knownMissionProjects(missions: MissionRecord[]): string[] {
  const keys = new Set<string>();
  for (const m of missions) {
    const k = missionProjectKey(m);
    if (k) keys.add(k);
  }
  return [...keys].sort((a, b) => a.localeCompare(b));
}

export function missionMatchesProject(mission: MissionRecord, projectFilter: string | null): boolean {
  if (!projectFilter) return true;
  const key = missionProjectKey(mission);
  if (!key) return false;
  return key === projectFilter;
}

export type RunwayStripStats = {
  inFlight: number;
  planned: number;
  blocked: number;
  completed: number;
};

export function runwayStripStats(missions: MissionRecord[]): RunwayStripStats {
  let inFlight = 0;
  let planned = 0;
  let blocked = 0;
  let completed = 0;
  for (const m of missions) {
    const lifecycle = normalizeMissionLifecycle(m.state);
    if (lifecycle === 'running' || lifecycle === 'partial') inFlight += 1;
    else if (lifecycle === 'planned') planned += 1;
    else if (lifecycle === 'blocked') blocked += 1;
    else if (lifecycle === 'completed') completed += 1;
  }
  return { inFlight, planned, blocked, completed };
}

const GROUP_ORDER: MissionLifecycle[] = [
  'planned',
  'running',
  'partial',
  'blocked',
  'completed'
];

const GROUP_LABELS: Record<MissionLifecycle, string> = {
  planned: 'Planned',
  running: 'Running',
  partial: 'Partial',
  blocked: 'Blocked',
  completed: 'Completed'
};

export function groupMissions(missions: MissionRecord[]): MissionGroup[] {
  const buckets: Record<MissionLifecycle, MissionRecord[]> = {
    planned: [],
    running: [],
    partial: [],
    blocked: [],
    completed: []
  };

  for (const mission of missions) {
    const lifecycle = normalizeMissionLifecycle(mission.state);
    buckets[lifecycle].push(mission);
  }

  return GROUP_ORDER.map((key) => ({
    key,
    label: GROUP_LABELS[key],
    missions: buckets[key]
  })).filter((g) => g.missions.length > 0);
}

export function filterAndGroupMissions(
  missions: MissionRecord[],
  filter: MissionStateFilterKey,
  pendingApprovals: PendingApproval[]
): MissionGroup[] {
  const filtered = missions.filter((m) => missionMatchesFilter(m, filter, pendingApprovals));
  return groupMissions(filtered);
}

export function sortMissionsForDisplay(missions: MissionRecord[], pendingApprovals: PendingApproval[]): MissionRecord[] {
  const rank = (mission: MissionRecord): number => {
    if (missionApprovalDisplay(mission.id, pendingApprovals) === 'pending') return 0;
    switch (normalizeMissionLifecycle(mission.state)) {
      case 'blocked':
        return 1;
      case 'partial':
        return 2;
      case 'running':
        return 3;
      case 'planned':
        return 4;
      case 'completed':
        return 5;
    }
  };
  return [...missions].sort((a, b) => rank(a) - rank(b));
}

export type MissionStateTone = 'ok' | 'warn' | 'err';

export function missionStateTone(state: string): MissionStateTone {
  const lifecycle = normalizeMissionLifecycle(state);
  if (lifecycle === 'completed' || lifecycle === 'running' || lifecycle === 'planned') return 'ok';
  if (lifecycle === 'partial' || lifecycle === 'blocked') return 'warn';
  return 'err';
}

export interface ControllerStats {
  active: number;
  pendingApprovals: number;
  blocked: number;
}

export function controllerStats(
  missions: MissionRecord[],
  pendingApprovals: number
): ControllerStats {
  let active = 0;
  let blocked = 0;
  for (const m of missions) {
    const lifecycle = normalizeMissionLifecycle(m.state);
    if (lifecycle === 'planned' || lifecycle === 'running' || lifecycle === 'partial') {
      active += 1;
    }
    if (lifecycle === 'blocked') blocked += 1;
  }
  return { active, pendingApprovals, blocked };
}

export function formatRelativeTime(iso: string): string {
  const then = Date.parse(iso);
  if (Number.isNaN(then)) return iso;
  const deltaSec = Math.round((Date.now() - then) / 1000);
  if (deltaSec < 60) return 'just now';
  const mins = Math.round(deltaSec / 60);
  if (mins < 60) return `${mins}m ago`;
  const hours = Math.round(mins / 60);
  if (hours < 48) return `${hours}h ago`;
  const days = Math.round(hours / 24);
  return `${days}d ago`;
}

export function missionTitleById(missions: MissionRecord[], missionId: string): string {
  return missions.find((m) => m.id === missionId)?.title ?? missionId;
}

export function missionGateCode(missionId: string): string {
  const suffix = missionId.replace(/[^a-zA-Z0-9]/g, '').slice(-3).toUpperCase();
  return suffix.length > 0 ? suffix : '—';
}