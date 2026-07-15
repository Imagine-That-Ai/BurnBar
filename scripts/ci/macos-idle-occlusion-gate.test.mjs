#!/usr/bin/env node
/**
 * macOS idle/occluded CPU regression gate — behavioral rAF pause tripwire (P-PERF-3).
 *
 * Loads the ACTUAL shipped `kernel-backdrop.js` bundle in a deterministic mock
 * DOM + rAF harness and proves:
 *
 *  1. After `window.__setBackdropActive(false)` the pending requestAnimationFrame
 *     (the animation loop) is cancelled and no new rAF is scheduled while hidden.
 *  2. After `window.__setBackdropActive(true)` the loop resumes (a new rAF is
 *     scheduled).
 *  3. The guard cannot be bypassed: a bundle with `cancelAnimationFrame` gutted
 *     from the `setHostVisible` path is caught (rAF not cancelled on occlusion).
 *
 * This is NOT a source-text assertion. It exercises the real JS bundle's
 * runtime behavior under a controllable VM, so a regression that preserves the
 * text strings but breaks the pause logic is still caught.
 *
 * The test also validates the budget file `budgets/macos-idle-cpu.perf.json`
 * is machine-consumed: its `gate.testTarget` must point at this file and its
 * `gate.tripwireClass` must match the test name below.
 */

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const bundlePath = path.join(root, "AgentLens/Resources/KernelBackdrop/kernel-backdrop.js");
const bundleSource = readFileSync(bundlePath, "utf8");
const budgetPath = path.join(root, "budgets/macos-idle-cpu.perf.json");
const budget = JSON.parse(readFileSync(budgetPath, "utf8"));

// ── Budget machine-consumption ──────────────────────────────────────────────

test("budget file is machine-consumed and points at this gate", () => {
  assert.equal(budget.gate?.type, "behavioral-assertion",
    "budget gate.type must be behavioral-assertion");
  assert.ok(budget.gate?.testTarget?.includes("macos-idle-occlusion-gate.test.mjs"),
    "budget gate.testTarget must point at this Node.js test file");
  assert.ok(budget.gate?.tripwireClass,
    "budget gate.tripwireClass must be named");
  assert.equal(budget.seededValues?.existingBaselineIncreased, false,
    "budget must assert no existing baseline was raised");
});

// ── Mock DOM + rAF harness ──────────────────────────────────────────────────

function createHarness(opts = {}) {
  const reducedMotion = opts.reducedMotion ?? false;

  let nextRafId = 1;
  const pendingRafs = new Map();
  let rafScheduleCount = 0;
  let rafCancelCount = 0;

  function requestAnimationFrame(cb) {
    const id = nextRafId++;
    pendingRafs.set(id, cb);
    rafScheduleCount++;
    return id;
  }

  function cancelAnimationFrame(id) {
    if (pendingRafs.has(id)) {
      pendingRafs.delete(id);
      rafCancelCount++;
    }
  }

  /** Fire all pending rAF callbacks in order, then clear. Returns count fired. */
  function tickRaf() {
    const callbacks = [...pendingRafs.values()];
    pendingRafs.clear();
    for (const cb of callbacks) {
      try { cb(1000); } catch { /* mock canvas may throw inside kernel.frame */ }
    }
    return callbacks.length;
  }

  function pendingRafCount() { return pendingRafs.size; }
  function resetRafCounters() { rafScheduleCount = 0; rafCancelCount = 0; }

  const performance = { now: () => 1000 };

  const win = {
    innerWidth: 800, innerHeight: 600, devicePixelRatio: 2,
    pageYOffset: 0, scrollY: 0,
    localStorage: { getItem: () => null, setItem: () => {}, removeItem: () => {} },
    matchMedia: (q) => ({
      matches: reducedMotion && q.includes("reduce"),
      addEventListener: () => {}, removeEventListener: () => {},
    }),
    setTimeout: (fn, ms) => setTimeout(fn, ms),
    clearTimeout: (id) => clearTimeout(id),
    addEventListener: () => {}, removeEventListener: () => {},
    requestAnimationFrame, cancelAnimationFrame,
  };

  const location = { hash: "", href: "https://localhost/", search: "", pathname: "/" };
  const navigator = {};

  class ResizeObserver { observe() {} unobserve() {} disconnect() {} }
  class IntersectionObserver { observe() {} unobserve() {} disconnect() {} takeRecords() { return []; } }

  function makeCtx2d() {
    return new Proxy({}, {
      get: (_t, p) => {
        if (p === "canvas") return null;
        if (p === "fillStyle" || p === "strokeStyle") return "#000";
        if (p === "lineWidth") return 1;
        if (p === "globalAlpha") return 1;
        if (p === "getImageData") return (_x, _y, w, h) => ({ data: new Uint8ClampedArray(w * h * 4) });
        if (p === "createImageData") return (w, h) => ({ data: new Uint8ClampedArray(w * h * 4) });
        if (p === "measureText") return (t) => ({ width: t.length * 8 });
        if (p === "createLinearGradient" || p === "createRadialGradient") return () => ({ addColorStop() {} });
        if (p === "getLineDash") return () => [];
        return () => {};
      },
      set: () => true,
    });
  }

  function createCanvas() {
    return {
      width: 0, height: 0, style: new Proxy({}, { set: () => true }),
      setAttribute: () => {}, getAttribute: () => null,
      getContext(type) { if (type === "2d") return makeCtx2d(); return null; },
      addEventListener: () => {}, removeEventListener: () => {},
      getBoundingClientRect: () => ({ width: 800, height: 600, left: 0, top: 0, right: 800, bottom: 600 }),
      toDataURL: () => "data:image/png;base64,",
    };
  }

  function createElement(tag) {
    if (tag === "canvas") return createCanvas();
    const children = [];
    return {
      tagName: (tag || "div").toUpperCase(), id: "",
      style: new Proxy({}, { set: () => true }),
      children, childNodes: children,
      classList: { add: () => {}, remove: () => {}, contains: () => false },
      setAttribute: () => {}, getAttribute: () => null, removeAttribute: () => {},
      addEventListener: () => {}, removeEventListener: () => {},
      appendChild(c) { children.push(c); return c; },
      removeChild(c) { const i = children.indexOf(c); if (i >= 0) children.splice(i, 1); return c; },
      getBoundingClientRect: () => ({ width: 800, height: 600, left: 0, top: 0, right: 800, bottom: 600 }),
      querySelectorAll: () => [], querySelector: () => null,
      innerHTML: "", textContent: "", parentNode: null, remove: () => {},
      cloneNode: () => createElement(tag),
      insertBefore: (n) => { children.unshift(n); return n; },
      contains: () => false,
    };
  }

  const elements = {};
  const document = {
    readyState: "complete", hidden: false,
    body: createElement("body"), documentElement: createElement("html"),
    getElementById: (id) => {
      if (!elements[id]) { elements[id] = createElement("div"); elements[id].id = id; }
      return elements[id];
    },
    createElement: (t) => createElement(t),
    addEventListener: () => {}, removeEventListener: () => {},
    querySelectorAll: () => [], querySelector: () => null,
    getComputedStyle: () => ({ getPropertyValue: () => "" }),
  };

  const globals = {
    document, window: win, performance,
    requestAnimationFrame, cancelAnimationFrame,
    location, navigator, ResizeObserver, IntersectionObserver,
    setTimeout: win.setTimeout, clearTimeout: win.clearTimeout,
    addEventListener: win.addEventListener, removeEventListener: win.removeEventListener,
    matchMedia: win.matchMedia, innerWidth: 800, innerHeight: 600, devicePixelRatio: 2,
  };

  return {
    globals, win, document, performance,
    requestAnimationFrame, cancelAnimationFrame,
    tickRaf, pendingRafCount, resetRafCounters,
    get rafScheduleCount() { return rafScheduleCount; },
    get rafCancelCount() { return rafCancelCount; },
  };
}

/** Load the bundle into a fresh harness and settle one-shot rAFs. */
function loadAndSettle(harness) {
  const fn = new Function(
    ...Object.keys(harness.globals),
    '"use strict";\n' + bundleSource
  );
  fn(...Object.values(harness.globals));
  // Fire one tick to let the initial harvest one-shot rAF fire, leaving only
  // the animation loop rAF pending.
  harness.tickRaf();
  return harness;
}

/** Load a modified bundle (e.g. with cancelAnimationFrame gutted). */
function loadModifiedBundle(harness, modifiedSource) {
  const fn = new Function(
    ...Object.keys(harness.globals),
    '"use strict";\n' + modifiedSource
  );
  fn(...Object.values(harness.globals));
  harness.tickRaf();
  return harness;
}

// ── Tests ───────────────────────────────────────────────────────────────────

test("bundle exposes __setBackdropActive and __backdropReady after bootstrap", () => {
  const h = createHarness();
  loadAndSettle(h);
  assert.equal(h.win.__backdropReady, true);
  assert.equal(typeof h.win.__setBackdropActive, "function");
});

test("animation loop is running before occlusion (rAF pending)", () => {
  const h = createHarness();
  loadAndSettle(h);
  assert.ok(h.pendingRafCount() > 0, "loop rAF should be pending after settle");
});

test("occluded (__setBackdropActive(false)) cancels loop rAF and stops scheduling", () => {
  const h = createHarness();
  loadAndSettle(h);
  assert.ok(h.pendingRafCount() > 0, "rAF pending before occlusion");

  h.resetRafCounters();
  h.win.__setBackdropActive(false);

  assert.equal(h.pendingRafCount(), 0, "pending rAF must be 0 after occlusion");
  assert.ok(h.rafCancelCount > 0, "cancelAnimationFrame must have been called");

  // Tick while hidden: nothing fires, nothing re-schedules
  h.tickRaf();
  assert.equal(h.pendingRafCount(), 0, "no rAF after tick while hidden");
  assert.equal(h.rafScheduleCount, 0, "no new requestAnimationFrame while hidden");

  h.tickRaf();
  assert.equal(h.pendingRafCount(), 0, "still no rAF after second tick while hidden");
});

test("visible (__setBackdropActive(true)) resumes the rAF loop", () => {
  const h = createHarness();
  loadAndSettle(h);

  h.win.__setBackdropActive(false);
  assert.equal(h.pendingRafCount(), 0, "rAF cancelled after occlusion");

  h.resetRafCounters();
  h.win.__setBackdropActive(true);

  assert.ok(h.rafScheduleCount > 0, "requestAnimationFrame called after resume");
  assert.ok(h.pendingRafCount() > 0, "new rAF pending after resume");

  const fired = h.tickRaf();
  assert.ok(fired > 0, "rAF callback fires after resume");
  assert.ok(h.pendingRafCount() > 0, "loop re-schedules after tick while visible");
});

test("repeated __setBackdropActive(false) is idempotent", () => {
  const h = createHarness();
  loadAndSettle(h);

  h.win.__setBackdropActive(false);
  const cancelsAfterFirst = h.rafCancelCount;
  assert.equal(h.pendingRafCount(), 0);

  h.win.__setBackdropActive(false);
  assert.equal(h.rafCancelCount, cancelsAfterFirst, "no extra cancel on repeated false");
  assert.equal(h.pendingRafCount(), 0);
});

test("repeated __setBackdropActive(true) is idempotent (no double-start)", () => {
  const h = createHarness();
  loadAndSettle(h);

  const pendingBefore = h.pendingRafCount();
  h.win.__setBackdropActive(true); // already true
  assert.ok(h.pendingRafCount() <= pendingBefore + 1, "no second loop started");
});

test("occlusion → resume → occlusion cycle preserves pause/resume", () => {
  const h = createHarness();
  loadAndSettle(h);

  h.win.__setBackdropActive(false);
  assert.equal(h.pendingRafCount(), 0, "cycle 1: cancelled");

  h.win.__setBackdropActive(true);
  assert.ok(h.pendingRafCount() > 0, "cycle 1: resumed");

  h.win.__setBackdropActive(false);
  assert.equal(h.pendingRafCount(), 0, "cycle 2: cancelled");

  h.win.__setBackdropActive(true);
  assert.ok(h.pendingRafCount() > 0, "cycle 2: resumed");
});

test("broken bundle (cancelAnimationFrame no-op) is caught — rAF not cancelled on occlusion", () => {
  // Replace cancelAnimationFrame( with a no-op that still evaluates its argument
  // but does not cancel. This simulates the guard being removed/bypassed.
  const brokenSource = bundleSource.replace(
    /cancelAnimationFrame\(([^)]+)\)/g,
    "($1, 0)"
  );

  const h = createHarness();
  loadModifiedBundle(h, brokenSource);

  assert.equal(typeof h.win.__setBackdropActive, "function", "hook still exposed");

  const pendingBefore = h.pendingRafCount();
  assert.ok(pendingBefore > 0, "rAF pending before occlusion in broken bundle");

  h.resetRafCounters();
  h.win.__setBackdropActive(false);

  // Broken bundle: cancelAnimationFrame was gutted, so rAF should NOT be cancelled
  assert.ok(h.pendingRafCount() > 0,
    "broken bundle must still have pending rAF — gate catches this");
  assert.equal(h.rafCancelCount, 0,
    "broken bundle must not have called cancelAnimationFrame — gate catches this");
});

test("reduced-motion mode does not start the loop, but occlusion still cancels harvest rAF", () => {
  const h = createHarness({ reducedMotion: true });
  // In reduced-motion mode, the engine does not call startLoop(), so the loop
  // rAF should not be pending. But the initial harvest rAF is still scheduled.
  loadAndSettle(h);

  // After settle, the harvest one-shot has fired. No loop rAF should be pending.
  // __setBackdropActive(false) should be a no-op (no loop to cancel).
  h.resetRafCounters();
  h.win.__setBackdropActive(false);
  // No crash, no error — the guard handles reduced-motion gracefully.
  assert.equal(h.pendingRafCount(), 0, "no rAF in reduced-motion mode");

  // Resuming in reduced-motion mode should not start the loop
  h.win.__setBackdropActive(true);
  assert.equal(h.pendingRafCount(), 0, "no loop started in reduced-motion mode even when visible");
});