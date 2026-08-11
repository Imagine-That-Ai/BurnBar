import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import {
  BENCH,
  EVIDENCE,
  EVIDENCE_CELLS,
  TRIALS_MEASURED,
  TASK_CELLS,
  EXCLUDED_MEASURED,
  RANKED_STACKS,
  ALL_STACKS,
  median,
  effectiveCost,
  isSubsidized,
  modelStat,
  benchKpis,
  reportStats,
  reportModels,
  reportMatrix,
  reportDataset,
  cellsDataset
} from "../src/data/bench";

/**
 * Guards for three ways the bench pages could publish something untrue.
 *
 *   C1 — `bench.json`'s `source.cells_measured` is a TRIAL count wearing a
 *        cell count's name. Copy that calls 3,070 "cells" overstates the
 *        suite by 4.7x. These tests pin the identity that makes the label
 *        wrong, and pin the corrected wording on every page that renders it.
 *
 *   C2 — Amendment 12: the muse-spark contributor tier is free under a
 *        data-sharing agreement, so its measured cost is a true $0.00 that
 *        almost nobody pays. A subsidized $0 must never render alone; the
 *        standard non-contributor equivalent goes next to it, everywhere.
 *
 *   C3 — `xs[Math.floor(xs.length / 2)]` is not a median. On even-length
 *        input it reports the upper middle value, biasing every published
 *        cost median upward — and every model in the current export has
 *        exactly 8 stack cells, so the bias was universal.
 *
 * The static source assertions below are deliberate: the numbers are computed
 * at build time and baked into HTML, so a wrong *label* is invisible to every
 * data-level check. Reading the page source is how a label regression gets
 * caught before it ships.
 */

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, "..");
const PAGES = join(ROOT, "src", "pages", "bench");

const REPORT = join(PAGES, "report.astro");
const DATA = join(PAGES, "data.astro");
const METHODOLOGY = join(PAGES, "methodology.astro");

/* The bench pages whose copy and cost rendering these tests own. Note that
   `src/pages/bench.astro` (the dashboard) renders the same trial count and is
   NOT covered here — it is owned elsewhere and still needs the same fix. */
const OWNED_PAGES: [string, string][] = [
  ["report.astro", REPORT],
  ["data.astro", DATA],
  ["methodology.astro", METHODOLOGY]
];

const read = (file: string): string => readFileSync(file, "utf8");

/* ───────────────────────── C3 · the median ───────────────────────── */

describe("median() — the real thing, both parities", () => {
  it("returns null on empty input rather than 0", () => {
    // "no measurement" and "zero dollars" must not render as the same number.
    expect(median([])).toBeNull();
  });

  it("returns the only element for single-element input", () => {
    expect(median([0.5])).toBe(0.5);
    expect(median([0])).toBe(0);
  });

  it("odd length: the middle value", () => {
    expect(median([1, 2, 3])).toBe(2);
    expect(median([5, 1, 3])).toBe(3);
    expect(median([1, 2, 3, 4, 5])).toBe(3);
  });

  it("even length: the MEAN of the two middle values, not the upper one", () => {
    expect(median([1, 2, 3, 4])).toBe(2.5);
    expect(median([1, 2, 3, 4])).not.toBe(3); // the pre-fix behaviour
    expect(median([2, 4])).toBe(3);
    expect(median([0, 10])).toBe(5);
  });

  it("sorts unsorted input before picking", () => {
    expect(median([4, 1, 3, 2])).toBe(2.5);
    expect(median([9, 1])).toBe(5);
  });

  it("handles duplicates, negatives, and floats", () => {
    expect(median([2, 2, 2, 2])).toBe(2);
    expect(median([-4, -2, 2, 4])).toBe(0);
    expect(median([0.003755, 0.004565])).toBeCloseTo(0.00416, 10);
  });

  it("does not mutate its input", () => {
    const input = [3, 1, 2];
    median(input);
    expect(input).toEqual([3, 1, 2]);
  });

  it("matches the naive index only on odd-length input", () => {
    const naive = (xs: number[]): number =>
      [...xs].sort((a, b) => a - b)[Math.floor(xs.length / 2)] as number;
    expect(median([1, 2, 3])).toBe(naive([1, 2, 3]));
    expect(median([1, 2, 3, 4])).not.toBe(naive([1, 2, 3, 4]));
  });
});

describe("published cost medians use median()", () => {
  it("every model's medianCost is the true median of its stack costs", () => {
    for (const m of BENCH.models) {
      const stat = modelStat(m.id);
      if (!stat) continue;
      const costs = RANKED_STACKS.filter((s) => s.model === m.id)
        .map((s) => s.cost_usd_median)
        .filter((c): c is number => c != null);
      expect(stat.medianCost).toBe(median(costs));
    }
  });

  it("an even-length priced slice is not reported as its upper middle value", () => {
    /* Not a hypothetical: every model in the current export has 8 priced
       stack cells, so the upper-median bug applied to all of them. */
    let checked = 0;
    for (const m of BENCH.models) {
      const costs = RANKED_STACKS.filter((s) => s.model === m.id)
        .map((s) => s.cost_usd_median)
        .filter((c): c is number => c != null)
        .sort((a, b) => a - b);
      if (costs.length === 0 || costs.length % 2 === 1) continue;
      const mid = costs.length >> 1;
      const lo = costs[mid - 1] as number;
      const hi = costs[mid] as number;
      if (lo === hi) continue; // the two conventions agree; nothing to prove
      checked += 1;
      const stat = modelStat(m.id);
      expect(stat?.medianCost).toBe((lo + hi) / 2);
      expect(stat?.medianCost).not.toBe(hi);
    }
    expect(checked).toBeGreaterThan(0);
  });

  it("every matrix cell's cost is the true median of its evidence cells", () => {
    const matrix = reportMatrix();
    for (const cell of matrix.cells.values()) {
      const costs = EVIDENCE_CELLS.filter(
        (c) => c.harness === cell.harness && c.model === cell.model
      )
        .map((c) => c.cost_usd_median)
        .filter((c): c is number => c != null);
      expect(cell.cost).toBe(median(costs));
    }
  });
});

/* ───────────────── C1 · trials are not cells ───────────────── */

describe("C1 — cells_measured is a trial count, and the pages say so", () => {
  it("TRIALS_MEASURED is exactly the export's global trial count", () => {
    expect(TRIALS_MEASURED).toBe(BENCH.source.cells_measured);
    expect(TRIALS_MEASURED).toBe(EVIDENCE.global.n);
  });

  it("TRIALS_MEASURED equals the sum of every cell's n — it counts runs", () => {
    const summed = EVIDENCE_CELLS.reduce((a, c) => a + c.n, 0);
    expect(TRIALS_MEASURED).toBe(summed);
  });

  it("TASK_CELLS is the distinct (harness × model × task) count", () => {
    const distinct = new Set(EVIDENCE_CELLS.map((c) => `${c.harness}|${c.model}|${c.task}`));
    expect(distinct.size).toBe(EVIDENCE_CELLS.length);
    expect(TASK_CELLS).toBe(distinct.size);
  });

  it("the two numbers genuinely differ — which is why the label mattered", () => {
    /* If a future export ever makes `cells_measured` mean what it says, this
       fails and the page copy gets revisited instead of quietly inverting. */
    expect(TRIALS_MEASURED).toBeGreaterThan(TASK_CELLS);
  });

  it("reportStats keeps trials and cells distinct", () => {
    const stats = reportStats();
    expect(stats.trials).toBe(TRIALS_MEASURED);
    expect(stats.cells).toBe(TASK_CELLS);
    expect(stats.excluded).toBe(EXCLUDED_MEASURED);
  });

  it("benchKpis names its fields after what they count", () => {
    const kpis = benchKpis();
    expect(kpis.trialsMeasured).toBe(TRIALS_MEASURED);
    expect(kpis.taskCells).toBe(TASK_CELLS);
    expect(kpis.excludedMeasured).toBe(EXCLUDED_MEASURED);
    // The misleading name is gone, not merely aliased.
    expect(Object.keys(kpis)).not.toContain("cellsMeasured");
  });

  it.each(OWNED_PAGES)("%s reads the labelled constant, never the raw field", (_name, file) => {
    /* Reaching into `BENCH.source.*` is how the wrong label got written in the
       first place: the field name reads like a cell count at the call site.
       Prose that quotes the field to explain the misnomer is fine. */
    const src = read(file);
    expect(src).not.toMatch(/BENCH\.source\.cells_measured/);
    expect(src).not.toMatch(/BENCH\.source\.cells_excluded/);
  });

  it.each(OWNED_PAGES)("%s never puts the word 'cells' on the trial count", (_name, file) => {
    const src = read(file);
    /* Render sites only — the frontmatter import obviously mentions the
       constant without any copy around it. */
    const RENDERED = /\{\s*fmtInt\(\s*(?:TRIALS_MEASURED|stats\.trials)\s*\)\s*\}([\s\S]{0,120})/g;
    let sites = 0;
    for (const match of src.matchAll(RENDERED)) {
      sites += 1;
      const after = match[1] ?? "";
      // The noun immediately following the number must be "trials".
      expect(after.trimStart(), `${_name}: trial count labelled wrong`).toMatch(
        /^(?:measured\s+)?trials\b/
      );
    }
    expect(sites, `${_name} renders no trial count`).toBeGreaterThan(0);
  });

  it("every page that shows the trial count actually shows it", () => {
    // Cheap regression guard: the constant did not get dropped in editing.
    const users = OWNED_PAGES.filter(([, f]) => read(f).includes("TRIALS_MEASURED"));
    expect(users.map(([n]) => n).sort()).toEqual([
      "data.astro",
      "methodology.astro",
      "report.astro"
    ]);
  });

  it("methodology documents the upstream misnomer in prose", () => {
    const src = read(METHODOLOGY);
    expect(src).toContain("source.cells_measured");
    expect(src).toMatch(/counts\s*\n?\s*<strong>\s*trials<\/strong>/);
  });
});

/* ───────────── C2 · Amendment 12, every cost render site ───────────── */

describe("C2 — a subsidized $0 never renders without its standard-tier price", () => {
  it("the export really does contain subsidized $0 rows", () => {
    // Without this the rest of the section would pass vacuously.
    expect(ALL_STACKS.some(isSubsidized)).toBe(true);
    expect(EVIDENCE_CELLS.some(isSubsidized)).toBe(true);
  });

  it("isSubsidized only fires on a $0 with a published equivalent", () => {
    expect(isSubsidized({ cost_usd_median: 0, cost_standard_usd_median: 0.26 })).toBe(true);
    expect(isSubsidized({ cost_usd_median: 0, cost_standard_usd_median: null })).toBe(false);
    expect(isSubsidized({ cost_usd_median: 0.1, cost_standard_usd_median: 0.26 })).toBe(false);
    expect(isSubsidized({ cost_usd_median: null, cost_standard_usd_median: null })).toBe(false);
  });

  it("effectiveCost prefers the standard tier and falls back to measured", () => {
    expect(effectiveCost({ cost_usd_median: 0, cost_standard_usd_median: 0.26 })).toBe(0.26);
    expect(effectiveCost({ cost_usd_median: 0.1, cost_standard_usd_median: null })).toBe(0.1);
    expect(effectiveCost({ cost_usd_median: null, cost_standard_usd_median: null })).toBeNull();
  });

  it("a zero-cost row with no published equivalent is not called subsidized", () => {
    /* Some $0 rows are derived costs over zero recorded tokens. There is
       nothing to disclose, and inventing a comparison price would be a
       fabrication — so they stay bare. */
    const bare = ALL_STACKS.filter((s) => s.cost_usd_median === 0 && !isSubsidized(s));
    for (const s of bare) expect(s.cost_standard_usd_median).toBeNull();
  });

  it("every model whose median cost is $0 carries a standard-tier median", () => {
    let subsidizedModels = 0;
    for (const m of reportModels()) {
      if (m.medianCost !== 0) continue;
      subsidizedModels += 1;
      expect(m.subsidized).toBe(true);
      expect(m.medianStandardCost).not.toBeNull();
      expect(m.medianStandardCost as number).toBeGreaterThan(0);
    }
    expect(subsidizedModels).toBeGreaterThan(0);
  });

  it("the model-level standard median is the true median of the repriced slice", () => {
    for (const m of BENCH.models) {
      const stat = modelStat(m.id);
      if (!stat) continue;
      const repriced = RANKED_STACKS.filter((s) => s.model === m.id)
        .map(effectiveCost)
        .filter((c): c is number => c != null);
      expect(stat.medianStandardCost).toBe(median(repriced));
    }
  });

  it("the report projection publishes the equivalent next to the median", () => {
    const models = (reportDataset() as { models: Record<string, unknown>[] }).models;
    for (const m of models) {
      expect(m).toHaveProperty("medianStandardCost");
      expect(m).toHaveProperty("subsidized");
      if (m.medianCost === 0) expect(m.medianStandardCost).not.toBeNull();
    }
  });

  it("the matrix projection publishes a standard-tier cost for every cell", () => {
    for (const cell of reportMatrix().cells.values()) {
      expect(cell).toHaveProperty("costStandard");
      if (cell.cost === 0) expect(cell.costStandard).not.toBeNull();
    }
  });

  it("the cell-explorer dataset ships the equivalent for every subsidized cell", () => {
    const ds = cellsDataset() as { h: string[]; m: string[]; t: string[]; cells: unknown[][] };
    expect(ds.cells.length).toBe(EVIDENCE_CELLS.length);
    let subsidizedRows = 0;
    ds.cells.forEach((row, i) => {
      const cell = EVIDENCE_CELLS[i];
      expect(row.length).toBe(11); // …, noopRuns, costStandard
      if (cell && isSubsidized(cell)) {
        subsidizedRows += 1;
        expect(row[6]).toBe(0); // measured cost
        expect(row[10]).not.toBeNull(); // standard-tier equivalent rides along
      }
    });
    expect(subsidizedRows).toBeGreaterThan(0);
  });

  it.each(OWNED_PAGES)("%s discloses the standard tier at every cost it renders", (_name, file) => {
    const src = read(file);
    /* Every measured-cost render must have the Amendment 12 disclosure within
       reach. "Within reach" is the enclosing markup block, approximated as a
       generous window either side — tight enough that a bare `fmtCost(cost)`
       dropped somewhere new fails, loose enough to survive reformatting. */
    const MEASURED = /fmtCost\(\s*([A-Za-z0-9_.]*(?:cost_usd_median|medianCost))\s*\)/g;
    const DISCLOSURE = /cost_standard_usd_median|medianStandardCost/;
    let sites = 0;
    for (const match of src.matchAll(MEASURED)) {
      sites += 1;
      const from = Math.max(0, (match.index ?? 0) - 700);
      const window = src.slice(from, (match.index ?? 0) + 700);
      expect(
        DISCLOSURE.test(window),
        `bare measured cost at ${_name} offset ${match.index}: ${match[0]}`
      ).toBe(true);
    }
    // methodology.astro renders no live costs; the other two do.
    if (_name !== "methodology.astro") expect(sites).toBeGreaterThan(0);
  });

  it("report.astro pairs the model-card median with its standard-tier price", () => {
    const src = read(REPORT);
    expect(src).toContain("{fmtCost(m.medianCost)}");
    expect(src).toContain("m.subsidized && ` (std ${fmtCost(m.medianStandardCost)})`");
  });

  it("data.astro keeps the pattern report.astro now matches", () => {
    const src = read(DATA);
    expect(src).toContain("{fmtCost(s.cost_usd_median)}");
    expect(src).toContain("(std {fmtCost(s.cost_standard_usd_median)})");
  });
});
