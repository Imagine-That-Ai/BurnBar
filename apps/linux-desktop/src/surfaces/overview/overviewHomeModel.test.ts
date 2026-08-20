import { describe, expect, it } from 'vitest';
import { DAEMON_FIXTURE_AVAILABLE } from '../../daemonFixture.js';
import {
  buildAtelierHeroCopy,
  buildAtlasModel,
  formatGap,
  groupStreamByDay,
  overviewFixturesAllowed,
  parseEventCost,
  streamEntriesFromSummary,
  weeklyHalves
} from './overviewHomeModel.js';
import type { UsageSummary } from '../../tauriBridge.js';

const summary: UsageSummary = {
  todayTokens: 100,
  todayCostUsd: 12.5,
  sevenDay: [1, 2, 3],
  recentEvents: [
    { id: 'b', title: 'codex / gpt', detail: '10 tokens · $2.00', at: '2026-08-19T18:00:00Z' },
    { id: 'a', title: 'claude-code / sonnet', detail: '20 tokens · $4.50', at: '2026-08-19T19:00:00Z' },
    { id: 'c', title: 'codex / gpt', detail: '8 tokens · $1.00', at: '2026-08-18T12:00:00Z' }
  ]
};

describe('overviewFixturesAllowed', () => {
  it('never admits fixtures unless both the shell flag and the build flag are on', () => {
    expect(overviewFixturesAllowed(false)).toBe(false);
    expect(overviewFixturesAllowed(true)).toBe(DAEMON_FIXTURE_AVAILABLE);
  });
});

describe('stream river', () => {
  it('orders newest first and keeps every row on a timestamp', () => {
    const entries = streamEntriesFromSummary(summary);
    expect(entries.map((entry) => entry.id)).toEqual(['a', 'b', 'c']);
    expect(entries.every((entry) => entry.at.length > 0)).toBe(true);
  });

  it('truncates the flat list before grouping so recency stays the only order', () => {
    const days = groupStreamByDay(streamEntriesFromSummary(summary), 2);
    const ids = days.flatMap((day) => day.entries.map((entry) => entry.id));
    expect(ids).toEqual(['a', 'b']);
    expect(ids).not.toContain('c');
  });

  it('parses a cost out of the event detail without inventing one', () => {
    expect(parseEventCost('20 tokens · $4.50')).toBe(4.5);
    expect(parseEventCost('no money here')).toBe(0);
  });
});

describe('atlas split', () => {
  it('spells the gap out and puts a comparison on every row', () => {
    const model = buildAtlasModel({
      missions: null,
      events: streamEntriesFromSummary(summary),
      providerMix: [
        { id: 'claude-code', label: 'Claude Code', pct: 70 },
        { id: 'codex', label: 'Codex', pct: 20 },
        { id: 'cursor', label: 'Cursor', pct: 10 }
      ]
    });

    expect(model.split.needsYou).toBeGreaterThan(0);
    expect(model.split.gapLabel.length).toBeGreaterThan(0);
    expect(model.attention.every((row) => row.comparison.length > 0)).toBe(true);
    expect(model.rest.every((row) => row.comparison.length > 0)).toBe(true);
    expect(model.kinds.every((row) => row.share >= 0)).toBe(true);
  });

  it('uses pending missions as needs-you when they exist', () => {
    const model = buildAtlasModel({
      missions: {
        missions: [{ id: 'm1', title: 'Ship living layout', state: 'running', updatedAt: '2026-08-19T12:00:00Z', laneCount: 1 }],
        pendingApprovals: [
          { id: 'a1', missionId: 'm1', summary: 'Approve the merge', requestedAt: '2026-08-19T12:01:00Z', risk: 'high' }
        ],
        pendingQuestions: []
      },
      events: [],
      providerMix: []
    });
    expect(model.attention[0]?.title).toBe('Approve the merge');
    expect(model.attention[0]?.comparison).toMatch(/risk|decision/i);
    expect(model.split.gapLabel).toBe(formatGap(model.split.needsYou, model.split.everythingElse));
  });
});

describe('atelier hero copy', () => {
  it('drives headline and chips from real usage, not marketing copy', () => {
    const copy = buildAtelierHeroCopy({
      summary,
      providerCount: 2,
      cacheHitRatePct: 41,
      fixtureMode: false,
      kernelForward: true
    });
    expect(copy.headline.toLowerCase()).not.toMatch(/living substrate/);
    expect(copy.sub).toMatch(/\$12\.50/);
    expect(copy.chips.some((chip) => chip.label === 'Live usage')).toBe(true);
    expect(copy.chips.some((chip) => /41%/.test(chip.label))).toBe(true);
  });

  it('does not fabricate a busy field from an empty summary', () => {
    const copy = buildAtelierHeroCopy({
      summary: { todayTokens: 0, todayCostUsd: 0, sevenDay: [0, 0], recentEvents: [] },
      providerCount: 0,
      cacheHitRatePct: null,
      fixtureMode: false,
      kernelForward: false
    });
    expect(copy.headline).toMatch(/still/i);
    expect(copy.sub).toMatch(/Nothing is fabricated/);
  });
});

describe('weekly halves', () => {
  it('compares the window against itself', () => {
    const halves = weeklyHalves([{ costUsd: 10 }, { costUsd: 10 }, { costUsd: 30 }, { costUsd: 30 }]);
    expect(halves.first).toBe(20);
    expect(halves.second).toBe(60);
    expect(halves.delta).toBe(2);
  });
});
