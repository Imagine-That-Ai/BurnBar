import { describe, it, expect } from "vitest";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import {
  ALL_STACKS,
  EVIDENCE_CELLS,
  TRIALS_MEASURED,
  TASK_CELLS,
  EXCLUDED_MEASURED,
  isSubsidized,
  fmtInt,
  reportModels
} from "../../src/data/bench";

/**
 * What the bench pages actually SAY, read off the built HTML.
 *
 * The unit tests in `test/bench-data.test.ts` pin the numbers and the source
 * patterns; this file closes the last gap. Every bench number is computed at
 * build time and baked into static HTML, so the only way to prove the *copy*
 * is true is to read the page a visitor gets:
 *
 *   C1 — 3,070 is a trial count. It must never appear next to the word
 *        "cells"; the 658 distinct task cells are what "cells" means.
 *   C2 — Amendment 12: a subsidized $0.00 must never be printed on its own.
 *
 * Skips cleanly when `npm run build` has not produced a dist/, matching
 * `test/integration/build.test.ts`.
 */

const DIST = join(import.meta.dirname, "../../dist");
const SKIP = !existsSync(DIST);
const describeIf = (cond: boolean) => (cond ? describe : describe.skip);

/** Built page HTML, tags stripped, entities decoded, whitespace collapsed —
    i.e. roughly the words a reader sees. */
function pageText(route: string): string {
  const html = readFileSync(join(DIST, route, "index.html"), "utf8");
  const stripped = html
    .replace(/<script[\s\S]*?<\/script>/g, " ")
    .replace(/<style[\s\S]*?<\/style>/g, " ")
    .replace(/<[^>]+>/g, " ");
  const decoded = stripped
    .replace(/&nbsp;/g, " ")
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'");
  return decoded.replace(/\s+/g, " ");
}

const BENCH_ROUTES = ["bench/report", "bench/data", "bench/methodology"];

describeIf(!SKIP)("Published bench copy", () => {
  const trials = fmtInt(TRIALS_MEASURED); // "3,070"
  const cells = fmtInt(TASK_CELLS); // "658"

  /* ── C1 · the trial count is never called a cell count ── */

  it.each(BENCH_ROUTES)("%s never calls the trial count a cell count", (route) => {
    const text = pageText(route);
    const mislabelled = new RegExp(`${trials}\\s*(?:measured\\s+)?(?:task\\s+)?cells?\\b`, "i");
    expect(text).not.toMatch(mislabelled);
  });

  it.each(BENCH_ROUTES)("%s labels the trial count as trials", (route) => {
    const text = pageText(route);
    expect(text).toMatch(new RegExp(`${trials}\\s*(?:measured\\s+)?trials\\b`, "i"));
  });

  it("the distinct-cell count is the number that gets called cells", () => {
    for (const route of ["bench/report", "bench/data", "bench/methodology"]) {
      const text = pageText(route);
      expect(text).toMatch(new RegExp(`${cells}[^.]{0,40}?cells?\\b`, "i"));
    }
  });

  it("report and data still publish the excluded count without calling it cells", () => {
    for (const route of ["bench/data", "bench/methodology"]) {
      const text = pageText(route);
      expect(text).toContain(`${fmtInt(EXCLUDED_MEASURED)} excluded`);
      expect(text).not.toMatch(
        new RegExp(`${fmtInt(EXCLUDED_MEASURED)}\\s*cells\\s*excluded`, "i")
      );
    }
  });

  it("methodology explains the upstream misnomer to a reader, not just a reviewer", () => {
    const text = pageText("bench/methodology");
    expect(text).toMatch(/source\.cells_measured counts trials\s*,? not cells/i);
    expect(text).toContain(`cell count is ${cells}`);
  });

  /* ── C2 · Amendment 12 on every rendered cost ── */

  it.each(["bench/report", "bench/data"])("%s prints no bare subsidized $0.00", (route) => {
    const text = pageText(route);
    /* `$0.00` optionally followed by the derived-cost asterisk, then the
       standard-tier disclosure. Anything else is a bare zero. */
    const zeros = [...text.matchAll(/\$0\.00(?!\d)/g)];
    const bare = zeros.filter((m) => !/^\s*\*?\s*\(std \$/.test(text.slice(m.index + 5)));

    /* Not every $0.00 is a subsidy: a derived cost over zero recorded tokens
       is genuinely $0 with no standard-tier price to disclose, and inventing
       one would be a fabrication. Exactly those rows may print bare. */
    const legitimatelyBare = ALL_STACKS.filter(
      (s) => s.cost_usd_median === 0 && !isSubsidized(s)
    ).length;
    const expectedBare = route === "bench/data" ? legitimatelyBare : 0;

    expect(zeros.length, `${route} renders no $0.00 at all`).toBeGreaterThan(0);
    expect(
      bare.map((m) => text.slice(Math.max(0, m.index - 90), m.index + 30)),
      `${route}: subsidized $0.00 printed without its standard-tier price`
    ).toHaveLength(expectedBare);
  });

  it("the report's model card shows the subsidized median with its standard price", () => {
    const text = pageText("bench/report");
    const subsidized = reportModels().filter((m) => m.subsidized);
    expect(subsidized.length).toBeGreaterThan(0);
    for (const m of subsidized) {
      expect(text).toMatch(/median cost \/ task \$0\.00 \(std \$\d/);
    }
  });

  it("every subsidized stack row in the full table carries its equivalent", () => {
    const text = pageText("bench/data");
    const subsidizedRows = ALL_STACKS.filter(isSubsidized).length;
    const disclosed = [...text.matchAll(/\$0\.00(?!\d)\s*\*?\s*\(std \$/g)].length;
    expect(disclosed).toBe(subsidizedRows);
  });

  /* ── the JSON projections carry the same disclosure ── */

  it("/data/bench-report.json publishes the standard-tier median", () => {
    const json = JSON.parse(readFileSync(join(DIST, "data/bench-report.json"), "utf8")) as {
      models: {
        medianCost: number | null;
        medianStandardCost: number | null;
        subsidized: boolean;
      }[];
      matrix: { cells: { cost: number | null; costStandard: number | null }[] };
    };
    for (const m of json.models) {
      expect(m).toHaveProperty("medianStandardCost");
      if (m.medianCost === 0) {
        expect(m.subsidized).toBe(true);
        expect(m.medianStandardCost).not.toBeNull();
      }
    }
    for (const c of json.matrix.cells) expect(c).toHaveProperty("costStandard");
  });

  it("/data/bench-cells.json carries a standard-tier column for subsidized cells", () => {
    const json = JSON.parse(readFileSync(join(DIST, "data/bench-cells.json"), "utf8")) as {
      cells: (number | null)[][];
    };
    expect(json.cells.length).toBe(EVIDENCE_CELLS.length);
    const subsidized = EVIDENCE_CELLS.map((c, i) => [c, json.cells[i]] as const).filter(([c]) =>
      isSubsidized(c)
    );
    expect(subsidized.length).toBeGreaterThan(0);
    for (const [, row] of subsidized) {
      expect(row?.[6]).toBe(0);
      expect(row?.[10]).not.toBeNull();
    }
  });
});
