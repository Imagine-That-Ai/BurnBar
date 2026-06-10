#!/usr/bin/env node
/**
 * @fileoverview Focused tests for the platform-mockup system.
 *
 * Covers (matches the plan):
 *   1. Glyph parity — the JS port of `glyph3x5` / `glyph6x7` matches the
 *      Swift bitmap tables for a hand-picked subset of characters.
 *   2. Provider-logo determinism — same provider name produces the same
 *      5×5 shape twice in a row.
 *   3. Layout sanity — every layout returns a 32×8 grid where lit-cell
 *      count is bounded (never empty for non-empty input, never fully on).
 *   4. SSR contract — the rendered HTML carries the data-attributes the
 *      hydrator needs.
 *   5. CSS reduced-motion — every animated component declares a
 *      `prefers-reduced-motion: reduce` rule.
 *   6. Static build smoke — `astro build` emits `/platforms/index.html`.
 *   7. Data layer + nav wiring — surfaces/nav reference the platform pages.
 *   8. Visibility gating — the hydrator's intervals only run while a
 *      mockup intersects the viewport in a visible tab, resume repaints
 *      the frozen frame, and reduced-motion still freezes everything
 *      (vm harness, same style as test-idle-canvas-loops.mjs).
 *
 * Run via: `node scripts/test-platform-mockups.mjs`.
 */

import assert from "node:assert/strict";
import { readFile, access, stat } from "node:fs/promises";
import path from "node:path";
import vm from "node:vm";
import { fileURLToPath } from "node:url";

import {
  COLUMNS,
  ROWS,
  glyph3x5,
  glyph6x7,
  blankGrid,
  paintProviderLogo,
  buildFrame,
  DEFAULT_ITEMS,
} from "./lib/pixel-clock-presenter.mjs";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, "..");
const COMPONENTS = path.join(ROOT, "src", "components", "platform");
const PUBLIC = path.join(ROOT, "public");
const DIST = path.join(ROOT, "dist");

// ─────────────────────────── 1. Glyph parity ──────────────────────────────

{
  // A handful of glyphs lifted verbatim from PixelClockPreviewView.swift.
  const expectations = {
    "0": [[1,1,1],[1,0,1],[1,0,1],[1,0,1],[1,1,1]],
    "9": [[1,1,1],[1,0,1],[1,1,1],[0,0,1],[1,1,1]],
    "A": [[0,1,0],[1,0,1],[1,1,1],[1,0,1],[1,0,1]],
    "%": [[1,0,1],[0,0,1],[0,1,0],[1,0,0],[1,0,1]],
    "!": [[1,0,0],[1,0,0],[1,0,0],[0,0,0],[1,0,0]],
    "Z": [[1,1,1],[0,0,1],[0,1,0],[1,0,0],[1,1,1]],
  };
  for (const [ch, expected] of Object.entries(expectations)) {
    assert.deepEqual(glyph3x5(ch), expected, `glyph3x5("${ch}") parity`);
  }
  // 6×7 sanity — pick a couple
  const eight = glyph6x7("8");
  assert.equal(eight.length, 7, "glyph6x7 is 7 rows tall");
  assert.equal(eight[0].length, 6, "glyph6x7 is 6 cols wide");
}

// ─────────────────────────── 2. Provider logos ────────────────────────────

{
  const grid1 = blankGrid();
  const grid2 = blankGrid();
  paintProviderLogo(grid1, { providerID: "anthropic", providerName: "Claude" });
  paintProviderLogo(grid2, { providerID: "anthropic", providerName: "Claude" });
  assert.deepEqual(grid1, grid2, "provider logos are deterministic");

  // Different providers paint different shapes.
  const gridOpenAI = blankGrid();
  paintProviderLogo(gridOpenAI, { providerID: "openai", providerName: "OpenAI" });
  assert.notDeepEqual(grid1, gridOpenAI, "different providers paint different logos");

  // The unknown-provider fallback still paints something (default 5×5).
  const gridUnknown = blankGrid();
  paintProviderLogo(gridUnknown, { providerID: "made-up", providerName: "Nobody" });
  const litUnknown = gridUnknown.flat().filter((p) => p.isLit).length;
  assert.ok(litUnknown > 0, "fallback logo paints visible pixels");
}

// ─────────────────────────── 3. Layout sanity ─────────────────────────────

{
  for (const layout of ["providerDashboard", "quotaCarousel", "burnStatus", "alertsOnly"]) {
    const { grid } = buildFrame({ layout, items: DEFAULT_ITEMS, tick: 0 });
    assert.equal(grid.length, ROWS, `${layout}: rows`);
    assert.equal(grid[0].length, COLUMNS, `${layout}: cols`);
    const lit = grid.flat().filter((p) => p.isLit).length;
    assert.ok(lit > 4, `${layout}: at least some pixels lit (got ${lit})`);
    assert.ok(lit < COLUMNS * ROWS, `${layout}: not every pixel is on (got ${lit})`);
  }
  // Empty items → mostly blank grid, no crash.
  const { grid } = buildFrame({ layout: "providerDashboard", items: [], tick: 0 });
  assert.equal(grid.length, ROWS);
}

// ─────────────────────────── 4. SSR contract ──────────────────────────────

{
  const nestHubSrc = await readFile(path.join(COMPONENTS, "NestHubScreen.astro"), "utf8");
  for (const attr of [
    "data-platform-screen",
    "data-platform-clock",
    "data-platform-date",
    "data-platform-top-pick-model",
    "data-platform-top-pick-score",
    "data-platform-top-pick-sources",
    "data-platform-provider-rail",
  ]) {
    assert.ok(
      nestHubSrc.includes(attr),
      `NestHubScreen.astro must expose ${attr} for the hydrator`
    );
  }

  const matrixSrc = await readFile(path.join(COMPONENTS, "PixelMatrix.astro"), "utf8");
  for (const attr of ["data-platform-matrix", "data-matrix-id", "data-matrix-config"]) {
    assert.ok(matrixSrc.includes(attr), `PixelMatrix.astro must expose ${attr}`);
  }

  // The showcase must reference the external hydrator (CSP-safe).
  const showcaseSrc = await readFile(path.join(COMPONENTS, "PlatformShowcase.astro"), "utf8");
  assert.ok(
    /<script\s+src="\/platform-mockups\.js"/.test(showcaseSrc),
    "PlatformShowcase.astro must <script src=\"/platform-mockups.js\">"
  );
  assert.ok(
    !/<script\s+is:inline/.test(showcaseSrc),
    "PlatformShowcase.astro must not use inline scripts (CSP enforces script-src 'self')"
  );
}

// ─────────────────────────── 5. Reduced-motion gates ──────────────────────

{
  const files = [
    path.join(COMPONENTS, "NestHubScreen.astro"),
    path.join(COMPONENTS, "PixelMatrix.astro"),
  ];
  for (const file of files) {
    const src = await readFile(file, "utf8");
    assert.ok(
      /@media\s*\(\s*prefers-reduced-motion\s*:\s*reduce\s*\)/.test(src),
      `${path.basename(file)} must respect prefers-reduced-motion`
    );
  }
  const hydrator = await readFile(path.join(PUBLIC, "platform-mockups.js"), "utf8");
  assert.ok(
    /matchMedia\(["']\(prefers-reduced-motion: reduce\)["']\)/.test(hydrator),
    "platform-mockups.js must gate intervals on prefers-reduced-motion"
  );
}

// ─────────────────────────── 6. Static build smoke ────────────────────────

{
  // Only assert if the build has been run; the verify pipeline runs the
  // build first, so this guards against drift, not against missing tooling.
  try {
    await access(path.join(DIST, "platforms", "index.html"));
    const idx = await readFile(path.join(DIST, "platforms", "index.html"), "utf8");
    assert.ok(idx.includes("Smart-display showcase".toLowerCase()) || idx.toLowerCase().includes("smart display"), "/platforms/ must mention smart displays");
    assert.ok(idx.includes("/platform-mockups.js"), "/platforms/ must include the hydrator script");
    // Confirm both device frames render in the dist HTML.
    assert.ok(idx.includes("deviceframe--nest"), "/platforms/ must contain a Nest Hub frame");
    assert.ok(idx.includes("deviceframe--ulanzi"), "/platforms/ must contain a Ulanzi frame");
    // SSR must paint the matrix grid (cells present).
    const cellMatches = idx.match(/class="px["\s]/g) ?? idx.match(/class="px /g) ?? [];
    assert.ok(cellMatches.length > 100, `/platforms/ must SSR the LED grid (>100 cells, got ${cellMatches.length})`);
  } catch (err) {
    if (err && err.code === "ENOENT") {
      console.log("  · /platforms/ not built yet, skipping build smoke (run `npm run build:offline` first)");
    } else {
      throw err;
    }
  }
}

// ─────────────────────────── 7. data layer + nav wiring ───────────────────

{
  const platformSurfaces = await readFile(path.join(ROOT, "src", "data", "platform-surfaces.ts"), "utf8");
  for (const id of ["nest-hub", "ulanzi-tc001"]) {
    assert.ok(platformSurfaces.includes(`id: "${id}"`), `platform-surfaces.ts must include id "${id}"`);
  }
  const siteData = await readFile(path.join(ROOT, "src", "data", "site.ts"), "utf8");
  assert.ok(/href:\s*"\/platforms"/.test(siteData), "NAV_PRIMARY must include /platforms");
  const surfacesData = await readFile(path.join(ROOT, "src", "data", "surfaces.ts"), "utf8");
  assert.ok(/href:\s*"\/platforms#smart-displays"/.test(surfacesData), "smart-display surface must link to /platforms#smart-displays");
}

// ─────────────────────── 8. Visibility-gated intervals ────────────────────

{
  const hydratorSource = await readFile(path.join(PUBLIC, "platform-mockups.js"), "utf8");

  // Boots the hydrator in a vm with stubbed DOM + timers, returning probes
  // for interval state, IntersectionObserver triggers, and paint counters.
  async function runHydrator({ reduceMotion = false } = {}) {
    const counts = { clockWrites: 0, matrixPaints: 0 };

    let clockText = "";
    const clockEl = { getAttribute: () => "hm" };
    Object.defineProperty(clockEl, "textContent", {
      set(v) {
        counts.clockWrites++;
        clockText = v;
      },
      get: () => clockText,
    });

    const cells = Array.from({ length: 256 }, () => {
      const classes = new Set();
      const props = {};
      return {
        classList: {
          add: (c) => classes.add(c),
          remove: (c) => classes.delete(c),
          contains: (c) => classes.has(c),
        },
        style: {
          setProperty: (k, v) => {
            props[k] = v;
          },
          removeProperty: (k) => {
            delete props[k];
          },
        },
        snapshot: () => (classes.has("px--on") ? props["--c"] ?? "on" : "off"),
      };
    });
    const matrixConfig = JSON.stringify({
      layout: "providerDashboard",
      items: [
        {
          providerID: "anthropic",
          providerName: "CLDE",
          percentUsed: 40,
          usageText: "60%",
          windowLabel: "CD",
        },
      ],
    });
    const matrixRoot = {
      getAttribute: (name) => (name === "data-matrix-config" ? matrixConfig : null),
      querySelectorAll: () => {
        counts.matrixPaints++;
        return cells;
      },
    };

    const listeners = {};
    const observers = [];
    const activeIntervals = new Map();
    let nextIntervalId = 1;

    const doc = {
      readyState: "complete",
      hidden: false,
      addEventListener(type, fn) {
        (listeners[type] ??= []).push(fn);
      },
      querySelectorAll(sel) {
        if (sel.includes("data-platform-matrix")) return [matrixRoot];
        if (sel.includes("data-platform-clock") && sel.includes("data-platform-date"))
          return [clockEl];
        if (sel.includes("data-platform-clock")) return [clockEl];
        return [];
      },
    };

    vm.runInNewContext(hydratorSource, {
      window: {
        // localhost short-circuits fetchRundown — no network in tests.
        location: { hostname: "localhost" },
        matchMedia: () => ({ matches: reduceMotion }),
      },
      document: doc,
      setInterval(fn, ms) {
        const id = nextIntervalId++;
        activeIntervals.set(id, { fn, ms });
        return id;
      },
      clearInterval(id) {
        activeIntervals.delete(id);
      },
      IntersectionObserver: class {
        constructor(cb) {
          this.cb = cb;
          this.targets = [];
          observers.push(this);
        }
        observe(t) {
          this.targets.push(t);
        }
      },
    });
    // Flush the fetchRundown().then(...) microtask before probing.
    await new Promise((resolve) => setTimeout(resolve, 0));

    return {
      counts,
      observers,
      doc,
      clockEl,
      matrixRoot,
      intervals: () => [...activeIntervals.values()],
      tickAll() {
        for (const { fn } of activeIntervals.values()) fn();
      },
      setIntersecting(el, isIntersecting) {
        for (const ob of observers) {
          if (ob.targets.includes(el)) ob.cb([{ target: el, isIntersecting }]);
        }
      },
      fire(type) {
        (listeners[type] ?? []).forEach((fn) => fn());
      },
      frame: () => cells.map((c) => c.snapshot()).join(","),
    };
  }

  // 8a. Offscreen at load: initial paints land, but zero intervals run.
  const run = await runHydrator();
  assert.equal(run.counts.clockWrites, 1, "offscreen: clock painted once at init");
  assert.equal(run.counts.matrixPaints, 1, "offscreen: matrix painted once at init");
  assert.equal(run.intervals().length, 0, "offscreen: no intervals while nothing intersects");
  assert.equal(run.observers.length, 2, "one observer gates the clock, one the matrix");

  // 8b. Matrix enters the viewport: immediate repaint + 1500ms cadence.
  run.setIntersecting(run.matrixRoot, true);
  assert.equal(run.counts.matrixPaints, 2, "enter: matrix repainted immediately");
  assert.deepEqual(
    run.intervals().map((i) => i.ms),
    [1500],
    "enter: matrix interval armed at the original 1500ms cadence"
  );
  run.tickAll();
  assert.equal(run.counts.matrixPaints, 3, "tick: interval advances the matrix");
  const frozenFrame = run.frame();

  // 8c. Exit freezes; re-enter repaints the SAME frame (no tick advance).
  run.setIntersecting(run.matrixRoot, false);
  assert.equal(run.intervals().length, 0, "exit: matrix interval cleared");
  run.setIntersecting(run.matrixRoot, true);
  assert.equal(run.frame(), frozenFrame, "re-enter: first visible frame is the frozen frame");
  run.tickAll();
  assert.notEqual(run.frame(), frozenFrame, "next tick: animation advances again");

  // 8d. Clock enters: immediate tick + 1000ms cadence alongside the matrix.
  run.setIntersecting(run.clockEl, true);
  assert.equal(run.counts.clockWrites, 2, "enter: clock re-ticked immediately");
  assert.deepEqual(
    run
      .intervals()
      .map((i) => i.ms)
      .sort((a, b) => a - b),
    [1000, 1500],
    "clock interval at 1000ms runs alongside the matrix interval"
  );

  // 8e. Hidden tab pauses everything; return resumes with immediate repaints.
  run.doc.hidden = true;
  run.fire("visibilitychange");
  assert.equal(run.intervals().length, 0, "hidden tab: all intervals cleared");
  const clockWritesHidden = run.counts.clockWrites;
  run.doc.hidden = false;
  run.fire("visibilitychange");
  assert.equal(run.intervals().length, 2, "visible again: both intervals resume");
  assert.equal(run.counts.clockWrites, clockWritesHidden + 1, "visible again: clock re-ticked");

  // 8f. Reduced motion: frozen initial frames, no observers, no intervals.
  const still = await runHydrator({ reduceMotion: true });
  assert.equal(still.counts.clockWrites, 1, "reduced motion: clock painted once");
  assert.equal(still.counts.matrixPaints, 1, "reduced motion: matrix painted once");
  assert.equal(still.observers.length, 0, "reduced motion: no observers wired");
  still.setIntersecting(still.matrixRoot, true);
  assert.equal(still.intervals().length, 0, "reduced motion: nothing ever animates");
}

console.log("platform-mockups: 8 test groups passed");
