#!/usr/bin/env node
/**
 * test-idle-canvas-loops.mjs — the two theme-bound canvas backgrounds must
 * not burn CPU in the theme they don't paint, and the ember swarm's
 * interactive-rect tracking must never force layout per scroll event.
 *
 * Companion to test-reduced-motion.mjs (same vm harness style) but with a
 * pumpable requestAnimationFrame stub so loop parking/resuming is exercised
 * behaviorally:
 *   - emberSwarm.ts:       parks in LIGHT theme (zero rAF wakeups), resumes
 *                          via the data-theme MutationObserver, and coalesces
 *                          all rect refreshes (scroll storm / transitionend /
 *                          body reflow / fallback poll) into at most one
 *                          querySelectorAll + getBoundingClientRect pass per
 *                          painted frame.
 *   - dotConstellation.ts: parks in DARK theme after a single clear (zero rAF
 *                          wakeups, zero logo fetches), resumes on light.
 *
 * Run via: `node scripts/test-idle-canvas-loops.mjs`.
 */

import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import vm from "node:vm";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const SCRIPTS = path.join(path.resolve(__dirname, ".."), "src", "scripts");

// Pumpable rAF: callbacks queue until the test advances a frame.
function makeRafPump() {
  const pending = [];
  return {
    pending,
    request(cb) {
      pending.push(cb);
      return pending.length;
    },
    pump(now) {
      for (const cb of pending.splice(0)) cb(now);
    }
  };
}

// ───────────────────────── 1. Ember swarm (DARK-theme canvas) ─────────────

const swarmSource = await readFile(path.join(SCRIPTS, "emberSwarm.ts"), "utf8");

function runSwarm({ theme }) {
  const counts = { fillRect: 0, clearRect: 0, arc: 0, qsa: 0, gbcr: 0 };
  const raf = makeRafPump();
  const listeners = {};
  const observers = [];
  const resizeObservers = [];
  const intervals = [];
  const attrs = { "data-theme": theme };

  const ctxStub = {
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
    fillText() {},
    getImageData() {
      return { data: new Uint8ClampedArray(400 * 400 * 4) };
    }
  };

  // Offscreen text-sampling canvas gets an uncounted ctx so its fillRects
  // don't pollute the on-screen paint counters.
  const offCtxStub = {
    ...ctxStub,
    fillRect() {},
    clearRect() {},
    arc() {}
  };

  const fakeElement = {
    getBoundingClientRect() {
      counts.gbcr++;
      return { left: 100, top: 200, width: 120, height: 40 };
    }
  };

  vm.runInNewContext(swarmSource, {
    window: {
      innerWidth: 1280,
      innerHeight: 800,
      location: { pathname: "/" },
      matchMedia: () => ({ matches: false }),
      addEventListener(type, fn) {
        (listeners[type] ??= []).push(fn);
      }
    },
    document: {
      documentElement: { getAttribute: (name) => attrs[name] ?? null },
      body: {},
      getElementById: (id) => (id === "bgCanvas" ? { getContext: () => ctxStub } : null),
      createElement: () => ({ getContext: () => offCtxStub }),
      querySelectorAll() {
        counts.qsa++;
        return [fakeElement, fakeElement];
      }
    },
    requestAnimationFrame: raf.request,
    setTimeout: () => 1,
    setInterval(fn) {
      intervals.push(fn);
      return 1;
    },
    MutationObserver: class {
      constructor(cb) {
        observers.push(cb);
      }
      observe() {}
    },
    ResizeObserver: class {
      constructor(cb) {
        resizeObservers.push(cb);
      }
      observe() {}
    }
  });

  return {
    counts,
    raf,
    listeners,
    intervals,
    resizeObservers,
    fire(type) {
      (listeners[type] ?? []).forEach((fn) => fn());
    },
    setTheme(next) {
      attrs["data-theme"] = next;
      observers.forEach((cb) => cb());
    }
  };
}

// 1a. LIGHT theme: the swarm parks — zero rAF wakeups until the theme flips.
{
  const run = runSwarm({ theme: "light" });
  assert.ok(run.counts.clearRect >= 1, "light: canvas cleared once on park");
  assert.equal(run.raf.pending.length, 0, "light: loop parked — no rAF queued");
  assert.equal(run.counts.fillRect, 0, "light: no decay rect painted");

  const qsaParked = run.counts.qsa;
  run.fire("scroll");
  run.fire("scroll");
  assert.equal(run.raf.pending.length, 0, "light: scrolling never wakes the parked loop");
  assert.equal(run.counts.qsa, qsaParked, "light: scrolling does no rect reads while parked");

  run.setTheme("dark");
  assert.equal(run.raf.pending.length, 1, "dark flip: observer resumes the loop");
  run.raf.pump(16);
  assert.ok(run.counts.fillRect >= 1, "dark flip: decay frame painted on resume");
  assert.ok(run.counts.qsa > qsaParked, "dark flip: stale rects refreshed on resume");
  assert.equal(run.raf.pending.length, 1, "dark flip: loop re-armed");

  run.setTheme("light");
  const clearsBefore = run.counts.clearRect;
  run.raf.pump(32);
  assert.ok(run.counts.clearRect > clearsBefore, "light flip: canvas cleared again");
  assert.equal(run.raf.pending.length, 0, "light flip: loop parked again");
}

// 1b. DARK theme: rect refreshes are flag-only + coalesced to one pass/frame.
{
  const run = runSwarm({ theme: "dark" });
  assert.equal(run.raf.pending.length, 1, "dark: loop armed");
  assert.equal(run.intervals.length, 1, "dark: one fallback poll registered");

  assert.equal(run.resizeObservers.length, 1, "dark: body ResizeObserver wired for reflows");

  const qsa0 = run.counts.qsa;
  for (let i = 0; i < 10; i++) run.fire("scroll");
  run.fire("transitionend");
  run.fire("animationend");
  run.resizeObservers[0]();
  run.intervals[0]();
  assert.equal(run.counts.qsa, qsa0, "dark: scroll storm + poll do zero synchronous rect reads");
  assert.equal(run.raf.pending.length, 1, "dark: dirty flag queues no extra rAFs");

  run.raf.pump(16);
  assert.equal(run.counts.qsa, qsa0 + 1, "dark: exactly one coalesced rect pass next frame");

  const qsa1 = run.counts.qsa;
  run.raf.pump(33);
  assert.equal(run.counts.qsa, qsa1, "dark: clean frame re-reads nothing");
  assert.ok(run.counts.arc > 0, "dark: particles still painting");
}

// ─────────────────── 2. Dot constellation (LIGHT-theme canvas) ────────────

const dotsSource = await readFile(path.join(SCRIPTS, "dotConstellation.ts"), "utf8");

function runDots({ theme }) {
  const counts = { clearRect: 0, images: 0, fetches: 0 };
  const raf = makeRafPump();
  const observers = [];
  const attrs = { "data-theme": theme };

  const ctxStub = {
    fillStyle: "",
    setTransform() {},
    clearRect() {
      counts.clearRect++;
    },
    beginPath() {},
    arc() {},
    fill() {}
  };

  vm.runInNewContext(dotsSource, {
    window: {
      innerWidth: 1280,
      innerHeight: 800,
      devicePixelRatio: 1,
      matchMedia: () => ({ matches: false }),
      addEventListener() {}
    },
    document: {
      documentElement: { getAttribute: (name) => attrs[name] ?? null },
      getElementById: (id) =>
        id === "bgDots" ? { width: 0, height: 0, getContext: () => ctxStub } : null,
      createElement: () => ({ getContext: () => ctxStub })
    },
    requestAnimationFrame: raf.request,
    setTimeout: () => 1,
    clearTimeout() {},
    MutationObserver: class {
      constructor(cb) {
        observers.push(cb);
      }
      observe() {}
    },
    Image: class {
      constructor() {
        counts.images++;
      }
    },
    fetch() {
      counts.fetches++;
      return new Promise(() => {});
    },
    URL: { createObjectURL: () => "blob:x", revokeObjectURL() {} },
    Blob: class {}
  });

  return {
    counts,
    raf,
    setTheme(next) {
      attrs["data-theme"] = next;
      observers.forEach((cb) => cb());
    }
  };
}

// DARK theme: clear once, park, fetch nothing; resume only when light.
{
  const run = runDots({ theme: "dark" });
  assert.equal(run.raf.pending.length, 1, "dark: first frame scheduled");
  run.raf.pump(16);
  assert.equal(run.counts.clearRect, 1, "dark: cleared exactly once");
  assert.equal(run.raf.pending.length, 0, "dark: loop parked — no rAF re-armed");
  assert.equal(run.counts.images + run.counts.fetches, 0, "dark: no logo loads while parked");
  run.raf.pump(32); // nothing queued — must be a no-op
  assert.equal(run.counts.clearRect, 1, "dark: parked loop stays silent");

  run.setTheme("light");
  assert.equal(run.raf.pending.length, 1, "light flip: observer resumes the loop");
  run.raf.pump(100);
  assert.equal(run.raf.pending.length, 1, "light: loop re-arms every frame");
  assert.ok(run.counts.images + run.counts.fetches > 0, "light: logo loading kicked off");

  run.setTheme("dark");
  run.raf.pump(116);
  assert.equal(run.raf.pending.length, 0, "dark flip: parked again");
}

console.log("idle-canvas-loops: ember-swarm + dot-constellation parking/coalescing suites passed");
