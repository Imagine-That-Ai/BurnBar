#!/usr/bin/env node
/**
 * test-reduced-motion.mjs — the background scripts must honor
 * `prefers-reduced-motion: reduce`.
 *
 * The ember swarm is the heaviest animated surface on the site (1,500
 * particles, uncapped rAF, on all 30+ dark-theme pages), so it gets a real
 * behavioral test: emberSwarm.ts is executed in a stubbed DOM twice and we
 * assert that
 *   - reduced:  no rAF loop, no shape-cycle setTimeout chain, no
 *               setInterval, no scroll/mouse listeners — but a static ember
 *               frame IS painted (not a blank canvas), resize redraws stay
 *               wired, and a data-theme MutationObserver handles toggles
 *               (light clears, dark repaints).
 *   - default:  the rAF loop, cycle timer, interval, and scroll/mouse
 *               listeners all start exactly as before.
 *
 * The sibling backgrounds (dot constellation, easter-egg FX) keep their
 * lighter source-level gate checks, mirroring test-platform-mockups.mjs §5.
 *
 * Run via: `node scripts/test-reduced-motion.mjs`.
 */

import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import vm from "node:vm";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, "..");
const SCRIPTS = path.join(ROOT, "src", "scripts");

// ───────────────── 1. Source-level gates on every background ──────────────

const GATE = /matchMedia\(["']\(prefers-reduced-motion: reduce\)["']\)/;
for (const file of ["emberSwarm.ts", "dotConstellation.ts", "easterEggFx.ts"]) {
  const src = await readFile(path.join(SCRIPTS, file), "utf8");
  assert.ok(GATE.test(src), `${file} must gate on prefers-reduced-motion`);
}

// ───────────────── 2. Behavioral harness for the ember swarm ──────────────

const swarmSource = await readFile(path.join(SCRIPTS, "emberSwarm.ts"), "utf8");

function makeCanvasCtx(counts) {
  return {
    fillStyle: "",
    font: "",
    textAlign: "",
    textBaseline: "",
    fillRect() {
      counts.fillRect++;
    },
    clearRect() {
      counts.clearRect++;
    },
    beginPath() {},
    arc() {
      counts.arc++;
    },
    fill() {},
    fillText() {
      counts.fillText++;
    },
    // All-black sample → text shapes resolve to zero points; the swarm
    // tolerates empty shapes and the static frame stays in "swarm" mode.
    getImageData() {
      return { data: new Uint8ClampedArray(400 * 400 * 4) };
    }
  };
}

function runSwarm({ reducedMotion, theme }) {
  const counts = { fillRect: 0, clearRect: 0, arc: 0, fillText: 0 };
  const timers = { raf: 0, setTimeout: 0, setInterval: 0 };
  const listeners = {};
  const observed = [];
  let observerCallback = null;

  const mainCtx = makeCanvasCtx(counts);
  const offCtx = makeCanvasCtx({ fillRect: 0, clearRect: 0, arc: 0, fillText: 0 });
  const attrs = { "data-theme": theme };

  const windowStub = {
    innerWidth: 1280,
    innerHeight: 800,
    location: { pathname: "/" },
    matchMedia: (query) => ({
      matches: reducedMotion && query === "(prefers-reduced-motion: reduce)"
    }),
    addEventListener(type, fn) {
      (listeners[type] ??= []).push(fn);
    }
  };

  const documentStub = {
    documentElement: {
      getAttribute: (name) => attrs[name] ?? null
    },
    getElementById: (id) => (id === "bgCanvas" ? { getContext: () => mainCtx } : null),
    createElement: () => ({ getContext: () => offCtx }),
    querySelectorAll: () => []
  };

  vm.runInNewContext(swarmSource, {
    window: windowStub,
    document: documentStub,
    requestAnimationFrame(cb) {
      timers.raf++;
      return cb && 1; // count only — never re-invoke, so loops can't spin
    },
    setTimeout() {
      timers.setTimeout++;
      return 1;
    },
    setInterval() {
      timers.setInterval++;
      return 1;
    },
    MutationObserver: class {
      constructor(cb) {
        observerCallback = cb;
      }
      observe(target, opts) {
        observed.push(opts);
      }
    }
  });

  return {
    counts,
    timers,
    listeners,
    observed,
    setTheme(next) {
      attrs["data-theme"] = next;
      assert.ok(observerCallback, "theme change requires a MutationObserver callback");
      observerCallback();
    }
  };
}

// ───────────────── 3. Reduced motion: static frame, zero timers ───────────

{
  const run = runSwarm({ reducedMotion: true, theme: "dark" });
  assert.equal(run.timers.raf, 0, "reduced: no requestAnimationFrame loop");
  assert.equal(run.timers.setTimeout, 0, "reduced: no shape-cycle setTimeout chain");
  assert.equal(run.timers.setInterval, 0, "reduced: no updateInteractiveElements interval");
  assert.ok(!run.listeners.mousemove, "reduced: no mousemove listener");
  assert.ok(!run.listeners.mouseleave, "reduced: no mouseleave listener");
  assert.ok(!run.listeners.scroll, "reduced: no scroll listener");
  assert.ok(run.listeners.resize?.length >= 2, "reduced: resize still resizes AND redraws");
  assert.ok(run.counts.arc > 1000, `reduced: static ember frame painted (arc=${run.counts.arc})`);
  // JSON round-trip: the options object was created inside the vm realm, so
  // a direct deepEqual would fail on cross-realm prototypes.
  assert.deepEqual(
    JSON.parse(JSON.stringify(run.observed)),
    [{ attributes: true, attributeFilter: ["data-theme"] }],
    "reduced: data-theme MutationObserver wired for theme toggles"
  );

  // dark → light must clear the static frame…
  const clearsBefore = run.counts.clearRect;
  run.setTheme("light");
  assert.ok(run.counts.clearRect > clearsBefore, "reduced: toggling to light clears the canvas");

  // …and light → dark must repaint it.
  const arcsBefore = run.counts.arc;
  run.setTheme("dark");
  assert.ok(run.counts.arc > arcsBefore, "reduced: toggling back to dark repaints the frame");
}

// In light theme the swarm idles even when reduced — no embers painted.
{
  const run = runSwarm({ reducedMotion: true, theme: "light" });
  assert.equal(run.counts.arc, 0, "reduced+light: no embers painted");
  assert.ok(run.counts.clearRect > 0, "reduced+light: canvas cleared");
}

// ───────────────── 4. Default motion: loop untouched ──────────────────────

{
  const run = runSwarm({ reducedMotion: false, theme: "dark" });
  assert.ok(run.timers.raf >= 1, "default: rAF loop starts");
  assert.ok(run.timers.setTimeout >= 1, "default: shape cycle scheduled");
  assert.equal(run.timers.setInterval, 1, "default: interactive-element interval runs");
  assert.ok(run.listeners.mousemove?.length, "default: mousemove repulsion wired");
  assert.ok(run.listeners.scroll?.length, "default: scroll listener wired");
  assert.ok(run.counts.arc > 0, "default: first frame painted");
}

console.log("reduced-motion: 3 source gates + ember-swarm behavioral suite passed");
