import { describe, expect, it } from 'vitest';
import type { UsageCalendarEvent } from '../../tauriBridge.js';
import {
  CALENDAR_CARD_KINDS,
  CALENDAR_CARD_META,
  CALENDAR_LAYOUT_STORAGE_KEY,
  addDaysLocal,
  addMonthsLocal,
  attributionInstant,
  contiguousDays,
  decodeCalendarLayout,
  defaultCalendarLayout,
  emptyCalendarSelection,
  encodeCalendarLayout,
  heatOpacity,
  hourHeatOpacity,
  monthGridFor,
  monthSnapshotFor,
  monthStartLocal,
  normalizeModelKey,
  moveCalendarCard,
  nextMonthStartLocal,
  reconcileCalendarLayout,
  selectionBeginDrag,
  selectionEndDrag,
  selectionExtend,
  selectionSelect,
  selectionSnapshotFor,
  selectionToggle,
  selectionUpdateDrag,
  setCalendarCardSpan,
  setCalendarCardVisible,
  startOfDayLocal
} from './calendarMath.js';

// Events are built from LOCAL wall-clock components so these assertions hold in
// any runner timezone — the surface attributes usage by local start-of-day.
function localAt(y: number, m: number, d: number, hour = 12, minute = 0): string {
  return new Date(y, m, d, hour, minute).toISOString();
}

function event(overrides: Partial<UsageCalendarEvent> & { recordedAt: string }): UsageCalendarEvent {
  return {
    id: overrides.id ?? `e-${overrides.recordedAt}-${overrides.costUsd ?? 0}`,
    providerId: 'anthropic',
    modelId: 'claude-opus-4-8',
    inputTokens: 0,
    outputTokens: 0,
    cacheCreationTokens: 0,
    cacheReadTokens: 0,
    reasoningTokens: 0,
    costUsd: 1,
    ...overrides
  };
}

const dayKey = (y: number, m: number, d: number): number =>
  startOfDayLocal(new Date(y, m, d, 12));

describe('day primitives', () => {
  it('collapses any instant to local midnight', () => {
    const key = startOfDayLocal(new Date(2026, 6, 22, 23, 59));
    const at = new Date(key);
    expect(at.getHours()).toBe(0);
    expect(at.getMinutes()).toBe(0);
    expect(at.getDate()).toBe(22);
  });

  it('treats every instant within one local day as the same key', () => {
    const early = startOfDayLocal(new Date(2026, 6, 22, 0, 1));
    const late = startOfDayLocal(new Date(2026, 6, 22, 23, 58));
    expect(early).toBe(late);
  });

  it('keeps calendar arithmetic on local midnight across a full year (DST-safe)', () => {
    // A fixed +86_400_000ms step would drift an hour at each DST boundary;
    // addDaysLocal rebuilds the date, so midnight must survive every step.
    let cursor = dayKey(2026, 0, 1);
    for (let i = 0; i < 365; i++) {
      cursor = addDaysLocal(cursor, 1);
      expect(new Date(cursor).getHours()).toBe(0);
    }
    const end = new Date(cursor);
    expect(end.getFullYear()).toBe(2027);
    expect(end.getMonth()).toBe(0);
    expect(end.getDate()).toBe(1);
  });

  it('walks months without spilling into the wrong month', () => {
    const jan31 = monthStartLocal(new Date(2026, 0, 31));
    expect(new Date(addMonthsLocal(jan31, 1)).getMonth()).toBe(1);
    const dec = monthStartLocal(new Date(2026, 11, 5));
    const nextYear = nextMonthStartLocal(dec);
    expect(new Date(nextYear).getFullYear()).toBe(2027);
    expect(new Date(nextYear).getMonth()).toBe(0);
  });
});

describe('attribution instant', () => {
  it('prefers the call start over the completion stamp', () => {
    const started = localAt(2026, 6, 10, 23, 50);
    const logged = localAt(2026, 6, 11, 0, 20);
    const at = attributionInstant(event({ recordedAt: logged, startTime: started }));
    expect(at.getTime()).toBe(new Date(started).getTime());
  });

  it('keeps a midnight-crossing call on the day it began', () => {
    // 23:50 -> 00:20 must land on the 10th, not the 11th.
    const row = event({
      recordedAt: localAt(2026, 6, 11, 0, 20),
      startTime: localAt(2026, 6, 10, 23, 50),
      costUsd: 3
    });
    expect(startOfDayLocal(attributionInstant(row))).toBe(dayKey(2026, 6, 10));
  });

  it('falls back to recordedAt when no start time was recorded', () => {
    // Rows written before BurnBarUsageEvent.startTime existed.
    const logged = localAt(2026, 6, 11, 0, 20);
    expect(attributionInstant(event({ recordedAt: logged })).getTime()).toBe(
      new Date(logged).getTime()
    );
  });

  it('ignores an unparseable start time rather than producing NaN', () => {
    const logged = localAt(2026, 6, 11, 9);
    const at = attributionInstant(event({ recordedAt: logged, startTime: 'not-a-date' }));
    expect(at.getTime()).toBe(new Date(logged).getTime());
  });
});

describe('normalizeModelKey', () => {
  it('collapses Cursor prefixes and casing into one grouping key', () => {
    expect(normalizeModelKey('custom:GPT-5')).toBe('gpt-5');
    expect(normalizeModelKey('Custom:gpt-5')).toBe('gpt-5');
    expect(normalizeModelKey('vibeproxy: -claude-opus-4-8')).toBe('claude-opus-4-8');
    expect(normalizeModelKey('  GPT-5  ')).toBe('gpt-5');
    expect(normalizeModelKey('gpt-5')).toBe('gpt-5');
  });

  it('merges prefixed and bare rows into a single Model Mix entry', () => {
    const day = dayKey(2026, 6, 10);
    const snap = selectionSnapshotFor(
      [
        event({ recordedAt: localAt(2026, 6, 10, 9), modelId: 'gpt-5', costUsd: 2 }),
        event({ recordedAt: localAt(2026, 6, 10, 10), modelId: 'custom:GPT-5', costUsd: 3 })
      ],
      new Set([day]),
      'en-US'
    );
    expect(snap.topModels).toHaveLength(1);
    expect(snap.topModels[0]).toMatchObject({ model: 'gpt-5' });
    expect(snap.topModels[0]!.costUsd).toBeCloseTo(5);
  });
});

describe('monthGridFor', () => {
  it('emits whole weeks that cover the month', () => {
    for (let month = 0; month < 12; month++) {
      const grid = monthGridFor(new Date(2026, month, 15), { firstWeekday: 0 });
      expect(grid.allDays.length % 7).toBe(0);
      expect(grid.weeks.every((w) => w.length === 7)).toBe(true);
      expect(grid.allDays.length).toBe(grid.weeks.length * 7);
      // The 1st and the last day of the month both live inside the grid.
      const first = grid.monthStart;
      const last = addDaysLocal(nextMonthStartLocal(first), -1);
      expect(grid.allDays).toContain(first);
      expect(grid.allDays).toContain(last);
    }
  });

  it('starts the grid on the configured first weekday', () => {
    const sunday = monthGridFor(new Date(2026, 6, 15), { firstWeekday: 0 });
    expect(new Date(sunday.gridStart).getDay()).toBe(0);
    const monday = monthGridFor(new Date(2026, 6, 15), { firstWeekday: 1 });
    expect(new Date(monday.gridStart).getDay()).toBe(1);
    expect(monday.weekdaySymbols).toHaveLength(7);
  });

  it('exposes gridEnd as an exclusive bound one day past the last cell', () => {
    const grid = monthGridFor(new Date(2026, 6, 15), { firstWeekday: 0 });
    const lastCell = grid.allDays[grid.allDays.length - 1]!;
    expect(grid.gridEnd).toBe(addDaysLocal(lastCell, 1));
  });
});

describe('monthSnapshotFor', () => {
  const grid = monthGridFor(new Date(2026, 6, 15), { firstWeekday: 0 });

  it('buckets rows by local day and tracks the month peak', () => {
    const snapshot = monthSnapshotFor(
      [
        event({ recordedAt: localAt(2026, 6, 10, 9), costUsd: 2 }),
        event({ recordedAt: localAt(2026, 6, 10, 21), costUsd: 3 }),
        event({ recordedAt: localAt(2026, 6, 11, 9), costUsd: 1 })
      ],
      grid
    );
    expect(snapshot.dayCosts.get(dayKey(2026, 6, 10))).toBeCloseTo(5);
    expect(snapshot.dayCosts.get(dayKey(2026, 6, 11))).toBeCloseTo(1);
    expect(snapshot.peakDayCost).toBeCloseTo(5);
  });

  it('attributes a late-evening row to its own local day, not the next (no UTC drift)', () => {
    // 23:30 local on the 10th is already the 11th in UTC for western zones —
    // the local-tz contract must keep it on the 10th.
    const snapshot = monthSnapshotFor(
      [event({ recordedAt: localAt(2026, 6, 10, 23, 30), costUsd: 4 })],
      grid
    );
    expect(snapshot.dayCosts.get(dayKey(2026, 6, 10))).toBeCloseTo(4);
    expect(snapshot.dayCosts.has(dayKey(2026, 6, 11))).toBe(false);
  });

  it('ranks at most three providers per day by that day cost', () => {
    const snapshot = monthSnapshotFor(
      [
        event({ recordedAt: localAt(2026, 6, 12), providerId: 'openai', costUsd: 1 }),
        event({ recordedAt: localAt(2026, 6, 12), providerId: 'anthropic', costUsd: 9 }),
        event({ recordedAt: localAt(2026, 6, 12), providerId: 'google', costUsd: 5 }),
        event({ recordedAt: localAt(2026, 6, 12), providerId: 'xai', costUsd: 0.5 })
      ],
      grid
    );
    expect(snapshot.dayProviders.get(dayKey(2026, 6, 12))).toEqual([
      'anthropic',
      'google',
      'openai'
    ]);
  });

  it('counts overflow cells in the heat but excludes them from the month total', () => {
    // A trailing cell from the neighbouring month still paints, yet the
    // month total must describe July alone.
    const overflow = grid.allDays.find((d) => d < grid.monthStart)!;
    const snapshot = monthSnapshotFor(
      [
        event({ recordedAt: new Date(overflow + 12 * 3_600_000).toISOString(), costUsd: 7 }),
        event({ recordedAt: localAt(2026, 6, 12), costUsd: 2 })
      ],
      grid
    );
    expect(snapshot.dayCosts.get(overflow)).toBeCloseTo(7);
    expect(snapshot.monthTotalCost).toBeCloseTo(2);
  });

  it('ignores rows outside the grid and unparseable timestamps', () => {
    const snapshot = monthSnapshotFor(
      [
        event({ recordedAt: localAt(2026, 2, 3), costUsd: 99 }),
        event({ recordedAt: 'not-a-date', costUsd: 99 }),
        event({ recordedAt: localAt(2026, 6, 12), costUsd: 1 })
      ],
      grid
    );
    expect(snapshot.monthTotalCost).toBeCloseTo(1);
    expect(snapshot.peakDayCost).toBeCloseTo(1);
  });
});

describe('heatOpacity', () => {
  it('is zero without spend or without a peak', () => {
    expect(heatOpacity(0, 10)).toBe(0);
    expect(heatOpacity(5, 0)).toBe(0);
  });

  it('scales to the month peak and stays within the ink budget', () => {
    expect(heatOpacity(10, 10)).toBeCloseTo(0.65);
    const mid = heatOpacity(2.5, 10);
    expect(mid).toBeGreaterThan(0.1);
    expect(mid).toBeLessThan(0.65);
  });

  it('rises monotonically with cost', () => {
    let previous = 0;
    for (const cost of [1, 2, 4, 8, 10]) {
      const value = heatOpacity(cost, 10);
      expect(value).toBeGreaterThan(previous);
      previous = value;
    }
  });
});

describe('hourHeatOpacity', () => {
  it('uses the wider ChartKitHeatmap ramp, not the month-grid one', () => {
    expect(hourHeatOpacity(0, 10)).toBe(0);
    expect(hourHeatOpacity(5, 0)).toBe(0);
    expect(hourHeatOpacity(10, 10)).toBeCloseTo(0.92);
    // Denser matrix ⇒ more contrast than the day cells at the same fraction.
    expect(hourHeatOpacity(2.5, 10)).toBeGreaterThan(heatOpacity(2.5, 10));
  });
});

describe('selection model', () => {
  const d10 = dayKey(2026, 6, 10);
  const d11 = dayKey(2026, 6, 11);
  const d12 = dayKey(2026, 6, 12);

  it('replaces the selection and moves the anchor on a plain click', () => {
    const first = selectionSelect(emptyCalendarSelection(), d10);
    expect([...first.selected]).toEqual([d10]);
    const second = selectionSelect(first, d12);
    expect([...second.selected]).toEqual([d12]);
    expect(second.anchor).toBe(d12);
  });

  it('toggles a single day without disturbing the rest', () => {
    const base = selectionSelect(emptyCalendarSelection(), d10);
    const added = selectionToggle(base, d12);
    expect(added.selected.has(d10)).toBe(true);
    expect(added.selected.has(d12)).toBe(true);
    const removed = selectionToggle(added, d12);
    expect(removed.selected.has(d12)).toBe(false);
    expect(removed.selected.has(d10)).toBe(true);
  });

  it('extends inclusively from the anchor in either direction', () => {
    const anchored = selectionSelect(emptyCalendarSelection(), d10);
    const forward = selectionExtend(anchored, d12);
    expect([...forward.selected].sort()).toEqual([d10, d11, d12]);

    const backward = selectionExtend(selectionSelect(emptyCalendarSelection(), d12), d10);
    expect([...backward.selected].sort()).toEqual([d10, d11, d12]);
  });

  it('paints a contiguous range while dragging and settles on release', () => {
    let sel = selectionBeginDrag(emptyCalendarSelection(), d10);
    expect(sel.isDragging).toBe(true);
    sel = selectionUpdateDrag(sel, d12);
    expect([...sel.selected].sort()).toEqual([d10, d11, d12]);
    // Dragging back toward the anchor shrinks rather than accumulates.
    sel = selectionUpdateDrag(sel, d11);
    expect([...sel.selected].sort()).toEqual([d10, d11]);
    sel = selectionEndDrag(sel);
    expect(sel.isDragging).toBe(false);
    expect(sel.dragAnchor).toBeNull();
    expect([...sel.selected].sort()).toEqual([d10, d11]);
  });

  it('builds inclusive contiguous ranges regardless of argument order', () => {
    expect(contiguousDays(d10, d12).size).toBe(3);
    expect(contiguousDays(d12, d10).size).toBe(3);
    expect(contiguousDays(d10, d10).size).toBe(1);
  });

  it('spans month boundaries without gaps', () => {
    const julyEnd = dayKey(2026, 6, 30);
    const augStart = dayKey(2026, 7, 2);
    const days = contiguousDays(julyEnd, augStart);
    expect(days.size).toBe(4);
    expect(days.has(dayKey(2026, 6, 31))).toBe(true);
    expect(days.has(dayKey(2026, 7, 1))).toBe(true);
  });
});

describe('selectionSnapshotFor', () => {
  const d10 = dayKey(2026, 6, 10);
  const d11 = dayKey(2026, 6, 11);
  const d12 = dayKey(2026, 6, 12);

  const events: UsageCalendarEvent[] = [
    event({
      recordedAt: localAt(2026, 6, 10, 9),
      costUsd: 3,
      sessionId: 's1',
      providerId: 'anthropic',
      modelId: 'claude-opus-4-8',
      projectName: 'BurnBar',
      inputTokens: 100,
      outputTokens: 50,
      cacheReadTokens: 100,
      reasoningTokens: 25
    }),
    event({
      recordedAt: localAt(2026, 6, 10, 14),
      costUsd: 1,
      sessionId: 's1',
      providerId: 'openai',
      modelId: 'gpt-5',
      projectName: 'BurnBar'
    }),
    event({
      recordedAt: localAt(2026, 6, 12, 10),
      costUsd: 6,
      sessionId: 's2',
      providerId: 'anthropic',
      modelId: 'claude-opus-4-8'
    }),
    // Outside the selection — must never leak into the totals.
    event({ recordedAt: localAt(2026, 6, 20, 10), costUsd: 100, sessionId: 's9' })
  ];

  const snapshot = selectionSnapshotFor(events, new Set([d10, d11, d12]), 'en-US');

  it('totals only rows on the selected days', () => {
    expect(snapshot.totalCost).toBeCloseTo(10);
    expect(snapshot.isEmpty).toBe(false);
  });

  it('counts distinct sessions, not rows', () => {
    // Two rows share s1, so three in-selection rows are two sessions.
    expect(snapshot.sessionCount).toBe(2);
  });

  it('collapses rows without a session id into one synthetic session', () => {
    const day = dayKey(2026, 6, 10);
    const anonymous = selectionSnapshotFor(
      [
        event({ recordedAt: localAt(2026, 6, 10, 9), costUsd: 1 }),
        event({ recordedAt: localAt(2026, 6, 10, 10), costUsd: 1 }),
        event({ recordedAt: localAt(2026, 6, 10, 11), costUsd: 1, sessionId: 'named' })
      ],
      new Set([day]),
      'en-US'
    );
    // Two id-less rows are one bucket, not zero and not two.
    expect(anonymous.sessionCount).toBe(2);
  });

  it('separates active days from selected days', () => {
    expect(snapshot.selectedDays).toEqual([d10, d11, d12]);
    expect(snapshot.activeDays).toBe(2);
    expect(snapshot.averageCostPerDay).toBeCloseTo(10 / 3);
  });

  it('gap-fills silent days so the burn series stays continuous', () => {
    expect(snapshot.dailyBurn.map((b) => b.day)).toEqual([d10, d11, d12]);
    expect(snapshot.dailyBurn[0]!.costUsd).toBeCloseTo(4);
    expect(snapshot.dailyBurn[1]!.costUsd).toBe(0);
    expect(snapshot.dailyBurn[2]!.costUsd).toBeCloseTo(6);
    expect(snapshot.dailyBurn.every((b) => b.label.length > 0)).toBe(true);
  });

  it('ranks providers, models and projects by cost', () => {
    expect(snapshot.providerShares[0]).toMatchObject({ id: 'anthropic' });
    expect(snapshot.providerShares[0]!.costUsd).toBeCloseTo(9);
    expect(snapshot.topModels[0]!.model).toBe('claude-opus-4-8');
    // The unattributed $6 row outranks BurnBar's $4 — ordering is by cost alone.
    expect(snapshot.projectShares.map((p) => p.name)).toEqual(['Unattributed', 'BurnBar']);
    expect(snapshot.projectShares[0]!.costUsd).toBeCloseTo(6);
    expect(snapshot.projectShares[1]!.costUsd).toBeCloseTo(4);
  });

  it('labels rows without a project as Unattributed', () => {
    expect(snapshot.projectShares.some((p) => p.name === 'Unattributed')).toBe(true);
  });

  it('places spend in the local weekday/hour cell', () => {
    const at = new Date(new Date(localAt(2026, 6, 10, 9)).getTime());
    expect(snapshot.hourWeekdayCost[at.getDay()]![9]).toBeCloseTo(3);
    expect(snapshot.peakHour).toBe(10);
  });

  it('derives cache and reasoning ratios from the selection', () => {
    // cacheRead 100 over a prompt basis of input+cacheCreation+cacheRead = 200.
    expect(snapshot.cacheHitRate).toBeCloseTo(0.5);
    expect(snapshot.cacheReadTokens).toBe(100);
    // reasoning 25 of 275 total tokens.
    expect(snapshot.reasoningShare).toBeCloseTo(25 / 275);
  });

  it('reports an empty snapshot when nothing is selected', () => {
    const empty = selectionSnapshotFor(events, new Set(), 'en-US');
    expect(empty.isEmpty).toBe(true);
    expect(empty.totalCost).toBe(0);
    expect(empty.dailyBurn).toEqual([]);
    expect(empty.sessionCount).toBe(0);
    expect(Number.isFinite(empty.averageCostPerDay)).toBe(true);
  });

  it('handles a selection whose days hold no usage', () => {
    const quiet = selectionSnapshotFor(events, new Set([d11]), 'en-US');
    expect(quiet.isEmpty).toBe(true);
    expect(quiet.dailyBurn).toEqual([{ day: d11, label: expect.any(String), costUsd: 0 }]);
  });
});

describe('card layout', () => {
  it('pins the storage key and ships every card visible by default', () => {
    expect(CALENDAR_LAYOUT_STORAGE_KEY).toBe('openburnbar.linux.calendarLayout.v1');
    const layout = defaultCalendarLayout();
    expect(layout).toHaveLength(CALENDAR_CARD_KINDS.length);
    expect(layout.every((c) => c.isVisible)).toBe(true);
    expect(layout.map((c) => c.kind)).toEqual([...CALENDAR_CARD_KINDS]);
  });

  it('describes every card kind with a title and a legal span', () => {
    for (const kind of CALENDAR_CARD_KINDS) {
      const meta = CALENDAR_CARD_META[kind];
      expect(meta.title.length).toBeGreaterThan(0);
      expect(meta.defaultSpan).toBeGreaterThanOrEqual(1);
      expect(meta.defaultSpan).toBeLessThanOrEqual(3);
    }
  });

  it('round-trips through JSON', () => {
    const layout = setCalendarCardSpan(
      setCalendarCardVisible(defaultCalendarLayout(), 'modelMix', false),
      'kpis',
      2
    );
    const restored = decodeCalendarLayout(encodeCalendarLayout(layout));
    expect(restored).toEqual(layout);
  });

  it('falls back to defaults for absent or corrupt payloads', () => {
    expect(decodeCalendarLayout(null)).toEqual(defaultCalendarLayout());
    expect(decodeCalendarLayout('')).toEqual(defaultCalendarLayout());
    expect(decodeCalendarLayout('{not json')).toEqual(defaultCalendarLayout());
    expect(decodeCalendarLayout('{"kind":"kpis"}')).toEqual(defaultCalendarLayout());
  });

  it('drops unknown kinds and appends cards added in later versions', () => {
    // A layout persisted before `reasoningShare` existed, plus a retired kind.
    const legacy = JSON.stringify([
      { kind: 'retiredCard', isVisible: true, span: 2 },
      { kind: 'kpis', isVisible: false, span: 2 }
    ]);
    const restored = decodeCalendarLayout(legacy);
    expect(restored).toHaveLength(CALENDAR_CARD_KINDS.length);
    expect(restored.some((c) => (c.kind as string) === 'retiredCard')).toBe(false);
    expect(restored[0]).toMatchObject({ kind: 'kpis', isVisible: false, span: 2 });
    expect(restored.some((c) => c.kind === 'reasoningShare')).toBe(true);
  });

  it('dedupes repeated kinds and clamps spans into 1...3', () => {
    const reconciled = reconcileCalendarLayout([
      { kind: 'kpis', isVisible: true, span: 99 },
      { kind: 'kpis', isVisible: false, span: 1 },
      { kind: 'providerMix', isVisible: true, span: -4 }
    ]);
    expect(reconciled.filter((c) => c.kind === 'kpis')).toHaveLength(1);
    expect(reconciled.find((c) => c.kind === 'kpis')!.span).toBe(3);
    expect(reconciled.find((c) => c.kind === 'providerMix')!.span).toBe(1);
    expect(reconciled).toHaveLength(CALENDAR_CARD_KINDS.length);
  });

  it('reorders a card onto its target slot', () => {
    const layout = defaultCalendarLayout();
    const moved = moveCalendarCard(layout, 'reasoningShare', 'kpis');
    expect(moved[0]!.kind).toBe('reasoningShare');
    expect(moved).toHaveLength(layout.length);
    // Every kind survives the move exactly once.
    expect(new Set(moved.map((c) => c.kind)).size).toBe(layout.length);
  });

  it('leaves the layout untouched for a no-op or unknown move', () => {
    const layout = defaultCalendarLayout();
    expect(moveCalendarCard(layout, 'kpis', 'kpis')).toEqual(layout);
  });
});
