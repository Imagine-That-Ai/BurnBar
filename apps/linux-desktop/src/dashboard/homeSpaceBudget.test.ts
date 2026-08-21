import { describe, expect, it } from 'vitest';
import {
  EMPTY_HOME_SPACE_PLAN,
  HomeSpaceBudget,
  appetiteCap,
  createHomeSlot,
  createRowAppetite,
  planColumnGroups,
  planHeight,
  planIsVisible,
  planRowCount,
  type HomeRowAppetite,
  type HomeSlot
} from './homeSpaceBudget.js';

function slot(
  id: string,
  opts: {
    rank?: number;
    floor?: number;
    ideal?: number;
    stretch?: number;
    rows?: HomeRowAppetite;
    ambient?: boolean;
    spans?: boolean;
  } = {}
): HomeSlot {
  return createHomeSlot({
    id,
    rank: opts.rank ?? 0,
    floor: opts.floor ?? 100,
    ideal: opts.ideal,
    stretch: opts.stretch,
    rows: opts.rows,
    isAmbient: opts.ambient,
    spans: opts.spans
  });
}

function appetite(available: number, baseline = 0, unit = 20, ceiling = 99): HomeRowAppetite {
  return createRowAppetite({ available, baseline, unit, ceiling });
}

describe('HomeSpaceBudget columns', () => {
  it('matches the two- and three-column thresholds', () => {
    expect(HomeSpaceBudget.columns(900, 1, 4)).toBe(1);
    expect(HomeSpaceBudget.columns(1_200, 1, 4)).toBe(2);
    expect(HomeSpaceBudget.columns(1_700, 2, 4)).toBe(3);
  });

  it('holds the current count inside the dead band', () => {
    expect(HomeSpaceBudget.columns(1_080, 1, 4)).toBe(1);
    expect(HomeSpaceBudget.columns(1_080, 2, 4)).toBe(2);
    expect(HomeSpaceBudget.columns(1_580, 2, 4)).toBe(2);
    expect(HomeSpaceBudget.columns(1_580, 3, 4)).toBe(3);
  });

  it('never exceeds the slot count', () => {
    expect(HomeSpaceBudget.columns(2_400, 3, 2)).toBe(2);
    expect(HomeSpaceBudget.columns(2_400, 3, 1)).toBe(1);
  });

  it('holds rather than collapsing on zero width', () => {
    expect(HomeSpaceBudget.columns(0, 3, 4)).toBe(3);
  });
});

describe('HomeSpaceBudget Feed before Breathe', () => {
  it('turns slack into rows before it becomes space', () => {
    const plan = HomeSpaceBudget.resolve({
      canvas: { width: 900, height: 600 },
      slots: [slot('list', { floor: 100, rows: appetite(40, 2) })],
      gutter: 12
    });

    expect(planRowCount(plan, 'list')).toBe(2 + 25);
    expect(planHeight(plan, 'list') ?? 0).toBeCloseTo(600, 1);
  });

  it('feeds rows round-robin across slots', () => {
    const plan = HomeSpaceBudget.resolve({
      canvas: { width: 900, height: 260 },
      slots: [
        slot('greedy', { rank: 0, floor: 100, rows: appetite(40, 0) }),
        slot('modest', { rank: 1, floor: 100, rows: appetite(40, 0) })
      ],
      gutter: 20
    });

    expect(planRowCount(plan, 'greedy')).toBe(1);
    expect(planRowCount(plan, 'modest')).toBe(1);
  });

  it('never invents filler past available data', () => {
    const plan = HomeSpaceBudget.resolve({
      canvas: { width: 900, height: 2_000 },
      slots: [slot('list', { floor: 100, rows: appetite(3, 0) })],
      gutter: 12
    });

    expect(planRowCount(plan, 'list')).toBe(3);
    expect(planHeight(plan, 'list') ?? 0).toBeCloseTo(2_000, 1);
  });

  it('caps an enormous canvas at the row ceiling', () => {
    const plan = HomeSpaceBudget.resolve({
      canvas: { width: 900, height: 4_000 },
      slots: [slot('list', { floor: 100, rows: appetite(500, 0, 20, 12) })],
      gutter: 12
    });

    expect(planRowCount(plan, 'list')).toBe(12);
  });
});

describe('HomeSpaceBudget overflow', () => {
  it('scrolls a short canvas rather than dropping content', () => {
    const plan = HomeSpaceBudget.resolve({
      canvas: { width: 900, height: 150 },
      slots: [
        slot('a', { rank: 0, floor: 100 }),
        slot('b', { rank: 1, floor: 100 }),
        slot('c', { rank: 2, floor: 100 })
      ],
      gutter: 12
    });

    expect(plan.overflows).toBe(true);
    expect(plan.placements).toHaveLength(3);
    expect(plan.placements.every((placement) => placement.isVisible)).toBe(true);
    expect(plan.placements.every((placement) => placement.height == null)).toBe(true);
  });

  it('yields ambient furniture before overflowing', () => {
    const plan = HomeSpaceBudget.resolve({
      canvas: { width: 900, height: 230 },
      slots: [
        slot('ribbon', { rank: 9, floor: 60, ambient: true }),
        slot('a', { rank: 0, floor: 100 }),
        slot('b', { rank: 1, floor: 100 })
      ],
      gutter: 12
    });

    expect(plan.overflows).toBe(false);
    expect(planIsVisible(plan, 'ribbon')).toBe(false);
    expect(planIsVisible(plan, 'a')).toBe(true);
    expect(planColumnGroups(plan).flat()).not.toContain('ribbon');
  });
});

describe('HomeSpaceBudget no dead space', () => {
  it('consumes the whole canvas with resolved heights plus gutters', () => {
    const canvas = { width: 900, height: 777 };
    const gutter = 14;
    const slots = [
      slot('head', { rank: 0, floor: 90, ideal: 120 }),
      slot('list', { rank: 1, floor: 80, ideal: 300, stretch: 1, rows: appetite(5, 1, 26) }),
      slot('tail', { rank: 2, floor: 70, ideal: 90 })
    ];

    const plan = HomeSpaceBudget.resolve({ canvas, slots, gutter });

    expect(plan.overflows).toBe(false);
    const total = plan.placements.reduce((sum, placement) => sum + (placement.height ?? 0), 0);
    expect(total + gutter * (slots.length - 1)).toBeCloseTo(canvas.height, 1);
  });

  it('spreads residual in proportion to ideal when nothing stretches', () => {
    const canvas = { width: 900, height: 500 };
    const plan = HomeSpaceBudget.resolve({
      canvas,
      slots: [
        slot('a', { rank: 0, floor: 100, ideal: 100 }),
        slot('b', { rank: 1, floor: 100, ideal: 300 })
      ],
      gutter: 0
    });

    const a = planHeight(plan, 'a') ?? 0;
    const b = planHeight(plan, 'b') ?? 0;
    expect(a + b).toBeCloseTo(canvas.height, 1);
    expect(b).toBeGreaterThan(a);
  });

  it('gives residual to the stretching slot', () => {
    const plan = HomeSpaceBudget.resolve({
      canvas: { width: 900, height: 500 },
      slots: [
        slot('rigid', { rank: 0, floor: 100, stretch: 0 }),
        slot('elastic', { rank: 1, floor: 100, stretch: 1 })
      ],
      gutter: 0
    });

    expect(planHeight(plan, 'rigid') ?? 0).toBeCloseTo(100, 1);
    expect(planHeight(plan, 'elastic') ?? 0).toBeCloseTo(400, 1);
  });
});

describe('HomeSpaceBudget column dealing', () => {
  it('balances columns by ideal height', () => {
    const assignment = HomeSpaceBudget.deal(
      [
        slot('tall', { rank: 0, floor: 100, ideal: 300 }),
        slot('short', { rank: 1, floor: 100, ideal: 100 }),
        slot('mid', { rank: 2, floor: 100, ideal: 150 })
      ],
      2
    );

    expect(assignment.tall).toBe(0);
    expect(assignment.short).toBe(1);
    expect(assignment.mid).toBe(1);
  });

  it('is deterministic on ties, sending them left', () => {
    const slots = [0, 1, 2, 3].map((i) => slot(`s${i}`, { rank: i, floor: 100, ideal: 100 }));
    const first = HomeSpaceBudget.deal(slots, 2);
    const second = HomeSpaceBudget.deal(slots, 2);
    expect(first).toEqual(second);
    expect(first.s0).toBe(0);
    expect(first.s1).toBe(1);
  });

  it('puts everything in column zero for a single column', () => {
    expect(HomeSpaceBudget.deal([slot('a'), slot('b')], 1)).toEqual({ a: 0, b: 0 });
  });

  it('gives each column the full height', () => {
    const slots = [
      slot('a', { rank: 0, floor: 400, ideal: 400 }),
      slot('b', { rank: 1, floor: 400, ideal: 400 })
    ];

    const stacked = HomeSpaceBudget.resolve({
      canvas: { width: 900, height: 500 },
      slots,
      gutter: 12,
      columns: 1
    });
    expect(stacked.overflows).toBe(true);

    const sideBySide = HomeSpaceBudget.resolve({
      canvas: { width: 1_400, height: 500 },
      slots,
      gutter: 12,
      columns: 2
    });
    expect(sideBySide.overflows).toBe(false);
    expect(planHeight(sideBySide, 'a') ?? 0).toBeCloseTo(500, 1);
    expect(planHeight(sideBySide, 'b') ?? 0).toBeCloseTo(500, 1);
  });
});

describe('HomeSpaceBudget ordering', () => {
  it('keeps the declared slot order after dealing', () => {
    const plan = HomeSpaceBudget.resolve({
      canvas: { width: 1_400, height: 900 },
      slots: [
        slot('first', { rank: 2, floor: 100 }),
        slot('second', { rank: 0, floor: 100 }),
        slot('third', { rank: 1, floor: 100 })
      ],
      gutter: 12,
      columns: 2
    });

    expect(plan.placements.map((placement) => placement.id)).toEqual(['first', 'second', 'third']);
  });
});

describe('HomeSpaceBudget spanning band', () => {
  it('keeps a spanning slot full width above the columns', () => {
    const plan = HomeSpaceBudget.resolve({
      canvas: { width: 1_400, height: 800 },
      slots: [
        slot('field', { rank: 0, floor: 92, ideal: 104, spans: true }),
        slot('context', { rank: 1, floor: 90, stretch: 1, rows: appetite(20, 3, 30) }),
        slot('suggestions', { rank: 2, floor: 60, rows: appetite(5, 2, 28) })
      ],
      gutter: 16,
      columns: 2
    });

    expect(plan.spanningIDs).toEqual(['field']);
    expect(planColumnGroups(plan).flat()).not.toContain('field');
    expect(planColumnGroups(plan)).toHaveLength(2);
    expect(planColumnGroups(plan).every((group) => group.length > 0)).toBe(true);
  });

  it('keeps the spanning band rigid and gives columns the remainder', () => {
    const canvas = { width: 1_400, height: 800 };
    const gutter = 16;
    const plan = HomeSpaceBudget.resolve({
      canvas,
      slots: [
        slot('field', { rank: 0, floor: 92, ideal: 104, spans: true }),
        slot('context', { rank: 1, floor: 90, stretch: 1, rows: appetite(20, 3, 30) }),
        slot('suggestions', { rank: 2, floor: 60, rows: appetite(5, 2, 28) })
      ],
      gutter,
      columns: 2
    });

    expect(planHeight(plan, 'field') ?? 0).toBeCloseTo(104, 1);
    const columnBudget = canvas.height - 104 - gutter;
    expect(planHeight(plan, 'context') ?? 0).toBeCloseTo(columnBudget, 1);
    expect(planHeight(plan, 'suggestions') ?? 0).toBeCloseTo(columnBudget, 1);
  });

  it('treats spanning as inert in a single column', () => {
    const plan = HomeSpaceBudget.resolve({
      canvas: { width: 900, height: 800 },
      slots: [
        slot('field', { rank: 0, floor: 92, ideal: 104, spans: true }),
        slot('context', { rank: 1, floor: 90, stretch: 1 })
      ],
      gutter: 16,
      columns: 1
    });

    expect(plan.spanningIDs).toEqual([]);
    expect(planColumnGroups(plan)).toEqual([['field', 'context']]);
    const total = plan.placements.reduce((sum, placement) => sum + (placement.height ?? 0), 0);
    expect(total + 16).toBeCloseTo(800, 1);
  });
});

describe('HomeSpaceBudget degenerate input', () => {
  it('resolves empty slots to the empty plan', () => {
    const plan = HomeSpaceBudget.resolve({
      canvas: { width: 900, height: 600 },
      slots: [],
      gutter: 12
    });
    expect(plan).toEqual(EMPTY_HOME_SPACE_PLAN);
  });

  it('hugs content on a zero-height canvas', () => {
    const plan = HomeSpaceBudget.resolve({
      canvas: { width: 900, height: 0 },
      slots: [slot('a', { rows: appetite(9, 3) })],
      gutter: 12
    });

    expect(plan.overflows).toBe(true);
    expect(planHeight(plan, 'a')).toBeNull();
    expect(planRowCount(plan, 'a')).toBe(3);
  });

  it('clamps baseline to available data', () => {
    const clamped = createRowAppetite({ available: 2, baseline: 8, unit: 20, ceiling: 10 });
    expect(clamped.baseline).toBe(2);
    expect(appetiteCap(clamped)).toBe(2);
  });
});
