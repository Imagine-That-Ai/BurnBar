import { describe, expect, it } from 'vitest';
import { mergeStageEvent, normalizeMercuryStage, type MercuryStageEvent } from './mediaStore.js';

describe('mediaStore stage reducer', () => {
  it('normalizes daemon phase words into the four Mercury stages', () => {
    expect(normalizeMercuryStage('starting')).toBe('connecting');
    expect(normalizeMercuryStage('streaming')).toBe('active');
    expect(normalizeMercuryStage('stopped')).toBe('ended');
    expect(normalizeMercuryStage('queued')).toBe('staged');
  });

  it('keeps stage events in rail order and replaces duplicate states', () => {
    const base: MercuryStageEvent[] = [
      { state: 'staged', at: '2026-07-05T00:00:00.000Z' },
      { state: 'active', at: '2026-07-05T00:02:00.000Z' }
    ];
    const merged = mergeStageEvent(base, {
      state: 'connecting',
      at: '2026-07-05T00:01:00.000Z',
      detail: 'control stream opening'
    });
    expect(merged.map((event) => event.state)).toEqual(['staged', 'connecting', 'active']);
    expect(merged[1].detail).toBe('control stream opening');

    const replaced = mergeStageEvent(merged, {
      state: 'streaming',
      at: '2026-07-05T00:03:00.000Z'
    });
    expect(replaced.map((event) => event.state)).toEqual(['staged', 'connecting', 'active']);
    expect(replaced[2].at).toBe('2026-07-05T00:03:00.000Z');
  });
});
