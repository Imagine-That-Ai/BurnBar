#!/usr/bin/env node
/**
 * Cinematic-30 present clock — drives the shipped kernel-backdrop bundle
 * (and the TypeScript source of `cinematicClock.ts`) so paced 30 fps:
 *   - uses a divisor of refresh (never 30 on 144)
 *   - kernel `frame` receives a real `dt` (not a constant 16 ms)
 *   - skipped rAF ticks do not present
 *   - shutter mix uses a `dt`-based alpha
 */

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import test from "node:test";
import { fileURLToPath, pathToFileURL } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const bundlePath = path.join(root, "AgentLens/Resources/KernelBackdrop/kernel-backdrop.js");
const bundleSource = readFileSync(bundlePath, "utf8");
const clockPath = path.join(root, "packages/gl-engine/src/engine/cinematicClock.ts");

const clockModule = await import(pathToFileURL(clockPath).href);

function createTimedHarness() {
  let now = 0;
  let nextRafId = 1;
  const pendingRafs = new Map();

  function requestAnimationFrame(cb) {
    const id = nextRafId++;
    pendingRafs.set(id, cb);
    return id;
  }

  function cancelAnimationFrame(id) {
    pendingRafs.delete(id);
  }

  function pump(advanceMs) {
    now += advanceMs;
    const callbacks = [...pendingRafs.values()];
    pendingRafs.clear();
    for (const cb of callbacks) {
      try {
        cb(now);
      } catch {
        /* mock canvas may throw inside kernel.frame */
      }
    }
    return callbacks.length;
  }

  const performance = { now: () => now };
  const win = {
    innerWidth: 800,
    innerHeight: 600,
    devicePixelRatio: 2,
    pageYOffset: 0,
    scrollY: 0,
    localStorage: { getItem: () => null, setItem: () => {}, removeItem: () => {} },
    matchMedia: () => ({
      matches: false,
      addEventListener: () => {},
      removeEventListener: () => {},
    }),
    setTimeout: (fn, ms) => setTimeout(fn, ms),
    clearTimeout: (id) => clearTimeout(id),
    addEventListener: () => {},
    removeEventListener: () => {},
    requestAnimationFrame,
    cancelAnimationFrame,
  };

  function makeCtx2d() {
    return new Proxy(
      {},
      {
        get: (_t, p) => {
          if (p === "canvas") return null;
          if (p === "getImageData") {
            return (_x, _y, w, h) => ({ data: new Uint8ClampedArray(w * h * 4) });
          }
          if (p === "createImageData") {
            return (w, h) => ({ data: new Uint8ClampedArray(w * h * 4) });
          }
          if (p === "measureText") return (t) => ({ width: String(t).length * 8 });
          if (p === "createLinearGradient" || p === "createRadialGradient") {
            return () => ({ addColorStop() {} });
          }
          if (p === "getLineDash") return () => [];
          if (typeof p === "string") return () => {};
          return undefined;
        },
        set: () => true,
      },
    );
  }

  function createCanvas() {
    return {
      width: 8,
      height: 8,
      style: new Proxy({}, { set: () => true }),
      setAttribute: () => {},
      getAttribute: () => null,
      getContext(type) {
        if (type === "2d") return makeCtx2d();
        return null;
      },
      addEventListener: () => {},
      removeEventListener: () => {},
      getBoundingClientRect: () => ({
        width: 800, height: 600, left: 0, top: 0, right: 800, bottom: 600,
      }),
      toDataURL: () => "data:image/png;base64,",
    };
  }

  function createElement(tag) {
    if (tag === "canvas") return createCanvas();
    const children = [];
    return {
      tagName: (tag || "div").toUpperCase(),
      id: "",
      style: new Proxy({}, { set: () => true }),
      children,
      childNodes: children,
      classList: { add: () => {}, remove: () => {}, contains: () => false },
      setAttribute: () => {},
      getAttribute: () => null,
      removeAttribute: () => {},
      addEventListener: () => {},
      removeEventListener: () => {},
      appendChild(c) {
        children.push(c);
        return c;
      },
      removeChild(c) {
        const i = children.indexOf(c);
        if (i >= 0) children.splice(i, 1);
        return c;
      },
      getBoundingClientRect: () => ({
        width: 800, height: 600, left: 0, top: 0, right: 800, bottom: 600,
      }),
      querySelectorAll: () => [],
      querySelector: () => null,
      innerHTML: "",
      textContent: "",
      parentNode: null,
      remove: () => {},
      cloneNode: () => createElement(tag),
      insertBefore: (n) => {
        children.unshift(n);
        return n;
      },
      contains: () => false,
    };
  }

  const elements = {};
  const document = {
    readyState: "complete",
    hidden: false,
    body: createElement("body"),
    documentElement: createElement("html"),
    getElementById: (id) => {
      if (!elements[id]) {
        elements[id] = createElement("div");
        elements[id].id = id;
      }
      return elements[id];
    },
    createElement: (t) => createElement(t),
    addEventListener: () => {},
    removeEventListener: () => {},
    querySelectorAll: () => [],
    querySelector: () => null,
    getComputedStyle: () => ({ getPropertyValue: () => "" }),
  };

  const location = { hash: "", href: "https://localhost/", search: "", pathname: "/" };
  const globals = {
    document,
    window: win,
    performance,
    requestAnimationFrame,
    cancelAnimationFrame,
    location,
    navigator: {},
    ResizeObserver: class { observe() {} unobserve() {} disconnect() {} },
    IntersectionObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
      takeRecords() { return []; }
    },
    setTimeout: win.setTimeout,
    clearTimeout: win.clearTimeout,
    addEventListener: win.addEventListener,
    removeEventListener: win.removeEventListener,
    matchMedia: win.matchMedia,
    innerWidth: 800,
    innerHeight: 600,
    devicePixelRatio: 2,
  };

  return { globals, win, pump, pending: () => pendingRafs.size };
}

function loadBundle(harness) {
  const fn = new Function(...Object.keys(harness.globals), `"use strict";\n${bundleSource}`);
  fn(...Object.values(harness.globals));
  harness.pump(0);
}

test("source cinematicPresentFps divides refresh and never picks 30 on 144", () => {
  const { cinematicPresentFps } = clockModule;
  assert.equal(cinematicPresentFps(60), 30);
  assert.equal(cinematicPresentFps(120), 30);
  assert.equal(cinematicPresentFps(144), 36);
  assert.notEqual(cinematicPresentFps(144), 30);
  assert.equal(cinematicPresentFps(90), 30);
});

test("source advanceCinematicPresent skips ticks and passes real dt plus shutter alpha", () => {
  const {
    advanceCinematicPresent,
    newCinematicClockState,
    shutterAlpha,
  } = clockModule;
  const state = newCinematicClockState();
  const first = advanceCinematicPresent(state, 0, 30);
  assert.equal(first.presented, true);
  assert.equal(first.alpha, 1);

  const skip = advanceCinematicPresent(state, 8, 30);
  assert.equal(skip.presented, false);
  assert.equal(skip.dt, 0);

  const skip2 = advanceCinematicPresent(state, 16, 30);
  assert.equal(skip2.presented, false);

  const present = advanceCinematicPresent(state, 34, 30);
  assert.equal(present.presented, true);
  assert.ok(present.dt > 16, `dt must be the real elapsed span, got ${present.dt}`);
  assert.ok(present.dt < 50, `dt should be one 30 fps interval, got ${present.dt}`);
  const expectedAlpha = shutterAlpha(present.dt);
  assert.ok(Math.abs(present.alpha - expectedAlpha) < 1e-9);
  assert.ok(present.alpha < 1, "paced 30 must shutter, not dump the raw frame");
});

test("shipped bundle exposes the cinematic clock and debug counters", () => {
  const h = createTimedHarness();
  loadBundle(h);
  assert.equal(h.win.__backdropReady, true);
  assert.equal(typeof h.win.__cinematicClock?.cinematicPresentFps, "function");
  assert.equal(typeof h.win.__getCinematicDebug, "function");
  assert.equal(h.win.__cinematicClock.cinematicPresentFps(144), 36);
  assert.equal(h.win.__cinematicClock.cinematicPresentFps(60), 30);
});

test("shipped engine at setMaxFps(30) skips rAF ticks, presents with real dt and dt-based shutter", () => {
  const h = createTimedHarness();
  loadBundle(h);
  h.win.__setMaxFps(30);

  const afterCap = h.win.__getCinematicDebug();
  assert.equal(afterCap.maxFps, 30);

  h.pump(8);
  h.pump(8);
  const mid = h.win.__getCinematicDebug();
  assert.ok(mid.skipCount > 0, "sub-interval rAF ticks must not call frame");
  const presentsBefore = mid.presentCount;

  h.pump(18);
  const after = h.win.__getCinematicDebug();
  assert.ok(after.presentCount > presentsBefore, "a full 30 fps interval must present");
  assert.ok(after.lastDt > 16, `presented dt must be real elapsed time, got ${after.lastDt}`);
  assert.notEqual(after.lastDt, 16);
  const expected = h.win.__cinematicClock.shutterAlpha(after.lastDt);
  assert.ok(Math.abs(after.lastAlpha - expected) < 1e-6, "shutter mix must use dt-based alpha");
  assert.ok(after.lastAlpha < 1, "paced 30 must shutter");
});
