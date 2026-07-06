import { describe, expect, it } from 'vitest';
import {
  countMissionsForFilter,
  groupMissions,
  missionMatchesFilter,
  normalizeMissionLifecycle
} from './missionGroups.js';
import type { MissionListResult } from '../../tauriBridge.js';

const sampleMissions: MissionListResult['missions'] = [
  { id: 'm1', title: 'A', state: 'active', updatedAt: '2026-01-01T00:00:00Z', laneCount: 1 },
  { id: 'm2', title: 'B', state: 'done', updatedAt: '2026-01-01T00:00:00Z', laneCount: 0 },
  { id: 'm3', title: 'C', state: 'blocked', updatedAt: '2026-01-01T00:00:00Z', laneCount: 2 }
];

describe('missionGroups', () => {
  it('normalizes daemon states to lifecycles', () => {
    expect(normalizeMissionLifecycle('active')).toBe('running');
    expect(normalizeMissionLifecycle('pending')).toBe('partial');
    expect(normalizeMissionLifecycle('done')).toBe('completed');
    expect(normalizeMissionLifecycle('cancelled')).toBe('blocked');
  });

  it('groups into five lifecycle buckets', () => {
    const groups = groupMissions(sampleMissions);
    expect(groups.map((g) => g.key)).toEqual(['running', 'blocked', 'completed']);
  });

  it('counts awaiting approval filter from pending approvals list', () => {
    const pending = [
      {
        id: 'a1',
        missionId: 'm1',
        summary: 'x',
        requestedAt: '2026-01-01T00:00:00Z',
        risk: 'standard' as const
      }
    ];
    expect(countMissionsForFilter(sampleMissions, 'awaitingApproval', pending)).toBe(1);
    expect(missionMatchesFilter(sampleMissions[0], 'awaitingApproval', pending)).toBe(true);
  });
});