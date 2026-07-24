import { describe, expect, it } from 'vitest';
import { mapUsageSummary } from './tauriBridgeCoreDecoders.js';

const NOW = Date.parse('2026-07-21T12:00:00Z');

function totals(totalTokens: number, cost: number) {
  return {
    eventCount: 1,
    inputTokens: totalTokens,
    outputTokens: 0,
    cacheCreationTokens: 0,
    cacheReadTokens: 0,
    reasoningTokens: 0,
    totalTokens,
    cost
  };
}

describe('authoritative usage projection decoder', () => {
  it('uses the full projection for totals and bounded rows only for activity', () => {
    const result = mapUsageSummary({
      projection: {
        totals: totals(90_000, 4.5),
        buckets: [
          { dayUTC: '2026-07-20', totals: totals(5_000, 0.25) },
          { dayUTC: '2026-07-21', totals: totals(85_000, 4.25) }
        ]
      },
      recent: {
        usage: [{
          id: 'newest-only',
          providerID: 'anthropic',
          modelID: 'claude',
          inputTokens: 10,
          outputTokens: 2,
          cacheCreationTokens: 3,
          cacheReadTokens: 4,
          reasoningTokens: 1,
          cost: 0.01,
          recordedAt: '2026-07-21T11:00:00Z'
        }]
      }
    }, NOW);

    expect(result.todayTokens).toBe(85_000);
    expect(result.todayCostUsd).toBe(4.25);
    expect(result.sevenDay).toEqual([0, 0, 0, 0, 0, 5_000, 85_000]);
    expect(result.recentEvents[0]?.detail).toBe('20 tokens · $0.01');
  });

  it('adds provider and model buckets that share the same UTC day', () => {
    const result = mapUsageSummary({
      projection: {
        totals: totals(30, 0.3),
        buckets: [
          { dayUTC: '2026-07-21', totals: totals(10, 0.1) },
          { dayUTC: '2026-07-21', totals: totals(20, 0.2) }
        ]
      },
      recent: { usage: [] }
    }, NOW);

    expect(result.todayTokens).toBe(30);
    expect(result.todayCostUsd).toBeCloseTo(0.3);
  });

  it('rejects malformed projection data instead of undercounting from recent rows', () => {
    expect(() => mapUsageSummary({
      projection: {
        totals: totals(12, 0.1),
        buckets: [{ dayUTC: '2026-07-21', totals: totals(-1, 0.1) }]
      },
      recent: { usage: [{ totalTokens: 12 }] }
    }, NOW)).toThrow('must be a non-negative finite number');

    expect(() => mapUsageSummary({
      recent: { usage: [{ totalTokens: 12 }] }
    }, NOW)).toThrow('usage summary projection must be an object');
  });

  it('rejects normalized calendar dates and aggregate overflow', () => {
    expect(() => mapUsageSummary({
      projection: {
        totals: totals(1, 0),
        buckets: [{ dayUTC: '2026-02-30', totals: totals(1, 0) }]
      },
      recent: { usage: [] }
    }, Date.parse('2026-03-02T12:00:00Z'))).toThrow('must be a UTC calendar day');

    expect(() => mapUsageSummary({
      projection: {
        totals: totals(Number.MAX_SAFE_INTEGER, 0),
        buckets: [
          { dayUTC: '2026-07-21', totals: totals(Number.MAX_SAFE_INTEGER, 0) },
          { dayUTC: '2026-07-21', totals: totals(1, 0) }
        ]
      },
      recent: { usage: [] }
    }, NOW)).toThrow('must remain a safe integer');

    expect(() => mapUsageSummary({
      projection: {
        totals: totals(2, Number.MAX_VALUE),
        buckets: [
          { dayUTC: '2026-07-21', totals: totals(1, Number.MAX_VALUE) },
          { dayUTC: '2026-07-21', totals: totals(1, Number.MAX_VALUE) }
        ]
      },
      recent: { usage: [] }
    }, NOW)).toThrow('must remain finite');
  });
});
