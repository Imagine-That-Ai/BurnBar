/**
 * Fit / Feed / Breathe — the living-layout solver.
 *
 * Same reasoning as macOS `HomeSpaceBudget`, native TypeScript shape. A shell
 * declares appetite (`HomeSlot`); the canvas answers with a plan
 * (`HomeSpacePlan`). Pure arithmetic: no DOM, no React, no window.
 *
 * Resolution order is the design:
 *   1. Fit — can every slot have its floor? If not, ambient furniture yields,
 *      then the surface scrolls. Content is never dropped.
 *   2. Feed — spend slack on real rows, round-robin in rank order.
 *   3. Breathe — only leftover slack becomes space.
 */

export type Size = { width: number; height: number };

export type HomeRowAppetite = {
  /** Rows the data actually has. A slot can never be fed a row that does not exist. */
  available: number;
  /** Rows shown before any slack is spent. Part of the slot's floor. */
  baseline: number;
  /** Height one row costs, including its rule. */
  unit: number;
  /** Most rows worth showing here even on an enormous canvas. */
  ceiling: number;
};

export type HomeSlot = {
  id: string;
  /** Feeding order. Lower is fed first. */
  rank: number;
  /** Height at baseline rows. Never goes below this. */
  floor: number;
  /** Height this slot would choose if nothing were competing. */
  ideal: number;
  /** Share of post-Feed slack. `0` is rigid. */
  stretch: number;
  /** More rows this slot could honestly show. Omit for a headline / field / gauge. */
  rows?: HomeRowAppetite;
  /** Withheld on a canvas too short. True only for ambient furniture. */
  isAmbient: boolean;
  /** Keeps full canvas width above any column region. Rigid at `ideal`. */
  spans: boolean;
};

export type HomePlacement = {
  id: string;
  /** Resolved height. `null` when the surface overflows and the slot should hug. */
  height: number | null;
  /** How many rows to render. `0` for slots with no appetite. */
  rowCount: number;
  /** Column the slot was dealt into, 0-based. */
  column: number;
  /** Only ambient furniture is ever withheld. */
  isVisible: boolean;
};

export type HomeSpacePlan = {
  placements: HomePlacement[];
  columns: number;
  overflows: boolean;
  spanningIDs: string[];
};

export const EMPTY_HOME_SPACE_PLAN: HomeSpacePlan = {
  placements: [],
  columns: 1,
  overflows: false,
  spanningIDs: []
};

export function createRowAppetite(input: {
  available: number;
  baseline: number;
  unit: number;
  ceiling: number;
}): HomeRowAppetite {
  const available = Math.max(0, input.available);
  return {
    available,
    baseline: Math.max(0, Math.min(input.baseline, available)),
    unit: Math.max(1, input.unit),
    ceiling: Math.max(0, input.ceiling)
  };
}

export function appetiteCap(rows: HomeRowAppetite): number {
  return Math.min(rows.available, rows.ceiling);
}

export function createHomeSlot(input: {
  id: string;
  rank: number;
  floor: number;
  ideal?: number;
  stretch?: number;
  rows?: HomeRowAppetite;
  isAmbient?: boolean;
  spans?: boolean;
}): HomeSlot {
  const floor = Math.max(0, input.floor);
  const ideal = Math.max(floor, input.ideal ?? floor);
  return {
    id: input.id,
    rank: input.rank,
    floor,
    ideal,
    stretch: Math.max(0, input.stretch ?? 0),
    rows: input.rows,
    isAmbient: input.isAmbient ?? false,
    spans: input.spans ?? false
  };
}

export function planPlacement(plan: HomeSpacePlan, id: string): HomePlacement | undefined {
  return plan.placements.find((placement) => placement.id === id);
}

export function planRowCount(plan: HomeSpacePlan, id: string, fallback = 0): number {
  return planPlacement(plan, id)?.rowCount ?? fallback;
}

export function planHeight(plan: HomeSpacePlan, id: string): number | null | undefined {
  const placement = planPlacement(plan, id);
  if (!placement) return undefined;
  return placement.height;
}

export function planIsVisible(plan: HomeSpacePlan, id: string): boolean {
  return planPlacement(plan, id)?.isVisible ?? true;
}

export function planColumnGroups(plan: HomeSpacePlan): string[][] {
  if (plan.columns <= 0) return [];
  const spanning = new Set(plan.spanningIDs);
  const groups: string[][] = [];
  for (let column = 0; column < plan.columns; column += 1) {
    groups.push(
      plan.placements
        .filter((placement) => placement.column === column && placement.isVisible && !spanning.has(placement.id))
        .map((placement) => placement.id)
    );
  }
  return groups;
}

export function planVisibleSpanningIDs(plan: HomeSpacePlan): string[] {
  return plan.spanningIDs.filter((id) => planIsVisible(plan, id));
}

type ColumnResult = {
  placements: Array<{ id: string; height: number | null; rowCount: number; isVisible: boolean }>;
  overflows: boolean;
};

function resolveColumn(slots: HomeSlot[], height: number, gutter: number): ColumnResult {
  const kept = slots.slice();
  let chrome = gutter * Math.max(0, kept.length - 1);
  let floors = kept.reduce((sum, slot) => sum + slot.floor, 0);

  while (floors + chrome > height && kept.some((slot) => slot.isAmbient)) {
    let victim = -1;
    for (let i = kept.length - 1; i >= 0; i -= 1) {
      if (kept[i]!.isAmbient) {
        victim = i;
        break;
      }
    }
    if (victim < 0) break;
    floors -= kept[victim]!.floor;
    kept.splice(victim, 1);
    chrome = gutter * Math.max(0, kept.length - 1);
  }

  const keptIDs = new Set(kept.map((slot) => slot.id));
  const withheld = slots.filter((slot) => !keptIDs.has(slot.id));

  if (floors + chrome > height) {
    return {
      placements: [
        ...kept.map((slot) => ({
          id: slot.id,
          height: null,
          rowCount: slot.rows?.baseline ?? 0,
          isVisible: true
        })),
        ...withheld.map((slot) => ({
          id: slot.id,
          height: 0,
          rowCount: 0,
          isVisible: false
        }))
      ],
      overflows: true
    };
  }

  let slack = height - floors - chrome;
  const rowCounts = new Map(kept.map((slot) => [slot.id, slot.rows?.baseline ?? 0]));
  const feeding = kept.filter((slot) => slot.rows != null).sort((a, b) => a.rank - b.rank);

  let fed = true;
  while (slack > 0 && fed) {
    fed = false;
    for (const slot of feeding) {
      const appetite = slot.rows;
      if (!appetite) continue;
      const current = rowCounts.get(slot.id) ?? 0;
      if (current >= appetiteCap(appetite)) continue;
      if (slack < appetite.unit) continue;
      rowCounts.set(slot.id, current + 1);
      slack -= appetite.unit;
      fed = true;
    }
  }

  const totalStretch = kept.reduce((sum, slot) => sum + slot.stretch, 0);
  const totalIdeal = kept.reduce((sum, slot) => sum + slot.ideal, 0);

  const placements: ColumnResult['placements'] = [];
  for (const slot of kept) {
    const rowCount = rowCounts.get(slot.id) ?? 0;
    const bought = rowCount - (slot.rows?.baseline ?? 0);
    const earned = bought * (slot.rows?.unit ?? 0);
    let share: number;
    if (totalStretch > 0) {
      share = slack * (slot.stretch / totalStretch);
    } else if (totalIdeal > 0) {
      share = slack * (slot.ideal / totalIdeal);
    } else {
      share = slack / kept.length;
    }
    placements.push({
      id: slot.id,
      height: slot.floor + earned + share,
      rowCount,
      isVisible: true
    });
  }

  for (const slot of withheld) {
    placements.push({ id: slot.id, height: 0, rowCount: 0, isVisible: false });
  }

  return { placements, overflows: false };
}

export const HomeSpaceBudget = {
  /** Width at which a composition earns a second column. */
  twoColumnWidth: 1_080,
  /** Width at which a third column earns its place. */
  threeColumnWidth: 1_580,
  /** Hysteresis either side of a threshold, so a drag cannot flicker. */
  columnDeadBand: 60,

  columns(width: number, current: number, slots: number): number {
    if (width <= 0) return Math.max(1, Math.min(current, Math.max(1, slots)));

    const ceiling = Math.max(1, Math.min(3, slots));
    let target: number;
    if (width >= this.threeColumnWidth + this.columnDeadBand) {
      target = 3;
    } else if (width <= this.threeColumnWidth - this.columnDeadBand) {
      if (width >= this.twoColumnWidth + this.columnDeadBand) {
        target = 2;
      } else if (width <= this.twoColumnWidth - this.columnDeadBand) {
        target = 1;
      } else {
        target = Math.min(Math.max(current, 1), 2);
      }
    } else {
      target = Math.min(Math.max(current, 2), 3);
    }
    return Math.min(target, ceiling);
  },

  deal(slots: HomeSlot[], columns: number): Record<string, number> {
    if (columns <= 1) {
      return Object.fromEntries(slots.map((slot) => [slot.id, 0]));
    }

    const loads = Array.from({ length: columns }, () => 0);
    const assignment: Record<string, number> = {};
    const ranked = slots.slice().sort((a, b) => a.rank - b.rank);

    for (const slot of ranked) {
      let target = 0;
      for (let column = 1; column < columns; column += 1) {
        if (loads[column]! < loads[target]! - 0.5) target = column;
      }
      assignment[slot.id] = target;
      loads[target]! += slot.ideal;
    }
    return assignment;
  },

  resolve(input: {
    canvas: Size;
    slots: HomeSlot[];
    gutter: number;
    columns?: number;
  }): HomeSpacePlan {
    const { canvas, slots, gutter } = input;
    if (slots.length === 0) return EMPTY_HOME_SPACE_PLAN;

    const requested = Math.max(1, input.columns ?? 1);
    const spanning = requested > 1 ? slots.filter((slot) => slot.spans) : [];
    const columnar = requested > 1 ? slots.filter((slot) => !slot.spans) : slots;
    const spanningIDs = spanning.map((slot) => slot.id);
    const columnCount = Math.max(1, Math.min(requested, Math.max(1, columnar.length)));
    const assignment = this.deal(columnar, columnCount);

    if (canvas.height <= 0) {
      return {
        placements: slots.map((slot) => ({
          id: slot.id,
          height: null,
          rowCount: slot.rows?.baseline ?? 0,
          column: assignment[slot.id] ?? 0,
          isVisible: true
        })),
        columns: columnCount,
        overflows: true,
        spanningIDs
      };
    }

    const placements: HomePlacement[] = [];
    let anyColumnOverflows = false;

    const bandHeight = spanning.reduce((sum, slot) => sum + slot.ideal, 0) + gutter * spanning.length;
    const columnHeight = canvas.height - bandHeight;

    for (const slot of spanning) {
      placements.push({
        id: slot.id,
        height: slot.ideal,
        rowCount: slot.rows?.baseline ?? 0,
        column: 0,
        isVisible: true
      });
    }

    for (let column = 0; column < columnCount; column += 1) {
      const members = columnar.filter((slot) => (assignment[slot.id] ?? 0) === column);
      if (members.length === 0) continue;
      const resolved = resolveColumn(members, columnHeight, gutter);
      anyColumnOverflows = anyColumnOverflows || resolved.overflows;
      for (const placement of resolved.placements) {
        placements.push({
          id: placement.id,
          height: placement.height,
          rowCount: placement.rowCount,
          column,
          isVisible: placement.isVisible
        });
      }
    }

    let finalPlacements = placements;
    if (anyColumnOverflows) {
      finalPlacements = placements.map((placement) => ({ ...placement, height: null }));
    }

    const order = new Map(slots.map((slot, index) => [slot.id, index]));
    finalPlacements.sort((a, b) => (order.get(a.id) ?? 0) - (order.get(b.id) ?? 0));

    return {
      placements: finalPlacements,
      columns: columnCount,
      overflows: anyColumnOverflows,
      spanningIDs
    };
  }
};
