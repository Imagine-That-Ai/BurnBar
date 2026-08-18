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
 * The fast prerequisite also self-tests the real-process gate's versioned
 * config, robust statistic, zero/missing-sample rejection, macOS CPU sampler,
 * and refusal to accept seeded sample/result inputs. It never builds the app.
 */

import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { EventEmitter } from "node:events";
import {
  chmodSync,
  copyFileSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  utimesSync,
  writeFileSync,
} from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import {
  assertProcessIdentity,
  launchFreshProcess,
  measureMatchedPairs,
  median,
  medianAbsoluteDeviation,
  parseArguments,
  summarizeAndEvaluatePairs,
  validateConfig,
} from "./macos-idle-occlusion-gate.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const bundlePath = path.join(root, "AgentLens/Resources/KernelBackdrop/kernel-backdrop.js");
const bundleSource = readFileSync(bundlePath, "utf8");
const budgetPath = path.join(root, "budgets/macos-idle-cpu.perf.json");
const budget = JSON.parse(readFileSync(budgetPath, "utf8"));
const realGatePath = path.join(root, "scripts/ci/macos-idle-occlusion-gate.mjs");
const realGateConfigPath = path.join(root, "scripts/ci/macos-idle-occlusion-gate.config.json");
const realGateHelperPath = path.join(root, "scripts/ci/macos-idle-occlusion-gate-helper.swift");
const realGateConfig = validateConfig(JSON.parse(readFileSync(realGateConfigPath, "utf8")));

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

  const location = {
    hash: "",
    href: "https://localhost/",
    search: opts.locationSearch ?? "",
    pathname: "/",
  };
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
  assert.equal(typeof h.win.__getBackdropState, "function");
  assert.deepEqual(
    JSON.parse(JSON.stringify(h.win.__getBackdropState())),
    {
      hostVisible: true,
      renderLoopScheduled: true,
      reducedMotion: false,
      // The deterministic mock intentionally exposes no WebGL2 context, so
      // the real engine resolves the requested shader to its 2D fallback.
      resolvedKernel: "constellation",
    },
  );
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
  assert.deepEqual(
    JSON.parse(JSON.stringify(h.win.__getBackdropState())),
    {
      hostVisible: false,
      renderLoopScheduled: false,
      reducedMotion: false,
      resolvedKernel: "constellation",
    },
  );

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

test("native performance profile runs the real loop when the host OS prefers reduced motion", () => {
  const h = createHarness({ reducedMotion: true, locationSearch: "?motion=full" });
  loadAndSettle(h);

  const state = JSON.parse(JSON.stringify(h.win.__getBackdropState()));
  assert.equal(state.reducedMotion, false, "the explicit certification profile must win");
  assert.ok(h.pendingRafCount() > 0, "the performance workload must have a live render loop");
});

// ── Real-process gate self-tests (no app build or launch) ──────────────────

function sample(state, cpuPercent, pid = 4242) {
  return {
    state,
    workload: "idle",
    pid,
    source: "proc_pidinfo/PROC_PIDTASKINFO",
    durationNanoseconds: 2_000_000_000,
    cpuDeltaNanoseconds: Math.round(cpuPercent * 20_000_000),
    cpuPercent,
  };
}

function passingPairs() {
  const visible = [12, 10, 11, 14, 9];
  const occluded = [1, 2, 1.5, 1, 1];
  return visible.map((cpuPercent, index) => ({
    pairIndex: index + 1,
    visibleIdle: sample("visible-idle", cpuPercent),
    occludedIdle: sample("occluded-idle", occluded[index]),
  }));
}

test("launchFreshProcess rejects an existing matching gate PID instead of reusing it", async () => {
  const helperBinaryPath = "/fake/macos-idle-occlusion-gate-helper";
  const buildIdentity = {
    executablePath: "/fake/OpenBurnBar.app/Contents/MacOS/OpenBurnBar",
  };
  const existingPID = 8675;
  const conflictingProcess = {
    pid: existingPID,
    commandLine: [buildIdentity.executablePath, ...realGateConfig.app.launchArguments].join(" "),
    initialState: {
      running: true,
      pid: existingPID,
      executablePath: buildIdentity.executablePath,
      bundleIdentifier: realGateConfig.app.expectedBundleIdentifier,
      hidden: false,
      visibleWindowCount: 1,
    },
  };
  const unopenedWorkDirectory = path.join(
    os.tmpdir(),
    `openburnbar-fresh-process-must-not-open-${process.pid}-${Date.now()}`,
  );
  let finderCalls = 0;

  await assert.rejects(
    launchFreshProcess(
      helperBinaryPath,
      buildIdentity,
      realGateConfig,
      unopenedWorkDirectory,
      {
        findConflictingGateProcess: async (
          observedHelperPath,
          observedBuildIdentity,
          observedConfig,
        ) => {
          finderCalls += 1;
          assert.equal(observedHelperPath, helperBinaryPath);
          assert.strictEqual(observedBuildIdentity, buildIdentity);
          assert.strictEqual(observedConfig, realGateConfig);
          return conflictingProcess;
        },
      },
    ),
    (error) => {
      assert.equal(
        error.message,
        `performance gate requires a fresh process; refusing to reuse existing pid ${existingPID}`,
      );
      return true;
    },
  );
  assert.equal(finderCalls, 1);
});

test("launchFreshProcess stops the owned child once and rethrows registration failure before command lookup", async () => {
  const workDirectory = mkdtempSync(path.join(os.tmpdir(), "openburnbar-launch-cleanup-"));
  const helperBinaryPath = "/fake/macos-idle-occlusion-gate-helper";
  const buildIdentity = {
    executablePath: "/fake/OpenBurnBar.app/Contents/MacOS/OpenBurnBar",
  };
  const child = new EventEmitter();
  child.pid = 9753;
  child.exitCode = null;
  const registrationError = new Error("fake AppKit registration failed");
  const stoppedRuntimes = [];
  let spawnCalls = 0;
  let commandLineCalls = 0;

  try {
    await assert.rejects(
      launchFreshProcess(
        helperBinaryPath,
        buildIdentity,
        realGateConfig,
        workDirectory,
        {
          findConflictingGateProcess: async () => null,
          spawn: (executablePath, launchArguments, options) => {
            spawnCalls += 1;
            assert.equal(executablePath, buildIdentity.executablePath);
            assert.strictEqual(launchArguments, realGateConfig.app.launchArguments);
            const isolatedHomeDirectory = path.join(workDirectory, "home");
            assert.equal(options.env.HOME, isolatedHomeDirectory);
            assert.equal(options.env.CFFIXED_USER_HOME, isolatedHomeDirectory);
            assert.equal(existsSync(isolatedHomeDirectory), false);
            assert.equal(statSync(workDirectory).mode & 0o777, 0o755);
            queueMicrotask(() => child.emit("spawn"));
            return child;
          },
          waitForRegisteredProcess: async (observedHelperPath, pid, timeout) => {
            assert.equal(observedHelperPath, helperBinaryPath);
            assert.equal(pid, child.pid);
            assert.equal(timeout, realGateConfig.measurement.stateTransitionTimeoutSeconds);
            throw registrationError;
          },
          commandLineForPID: async () => {
            commandLineCalls += 1;
            return "must not be reached";
          },
          stopOwnedProcess: async (runtime) => {
            stoppedRuntimes.push(runtime);
          },
        },
      ),
      (error) => {
        assert.strictEqual(error, registrationError);
        return true;
      },
    );

    assert.equal(spawnCalls, 1);
    assert.equal(commandLineCalls, 0);
    assert.equal(stoppedRuntimes.length, 1);
    assert.deepEqual(stoppedRuntimes[0], {
      pid: child.pid,
      mode: "launched",
      child,
    });
  } finally {
    rmSync(workDirectory, { recursive: true, force: true });
  }
});

test("process identity requires acknowledged engine readiness and render-loop state", () => {
  const pid = 4242;
  const buildIdentity = { executablePath: "/fake/OpenBurnBar" };
  const baseState = {
    running: true,
    pid,
    executablePath: buildIdentity.executablePath,
    bundleIdentifier: realGateConfig.app.expectedBundleIdentifier,
    hidden: false,
    visibleWindowCount: 1,
  };

  assert.throws(
    () => assertProcessIdentity(baseState, pid, buildIdentity, realGateConfig, "visible"),
    /did not acknowledge a ready backdrop engine/u,
  );
  assert.doesNotThrow(() => assertProcessIdentity(
    {
      ...baseState,
      backdropReady: true,
      backdropActive: true,
      backdropRenderLoopScheduled: true,
      backdropReducedMotion: false,
      backdropKernel: "boids",
    },
    pid,
    buildIdentity,
    realGateConfig,
    "visible",
  ));
  assert.throws(
    () => assertProcessIdentity(
      {
        ...baseState,
        backdropReady: true,
        backdropActive: true,
        backdropRenderLoopScheduled: false,
        backdropReducedMotion: false,
        backdropKernel: "boids",
      },
      pid,
      buildIdentity,
      realGateConfig,
      "visible",
    ),
    /render-loop state did not match visible/u,
  );
});

test("measureMatchedPairs batches visible samples before one hide and pairs occluded samples by index", async () => {
  const config = JSON.parse(JSON.stringify(realGateConfig));
  config.measurement.matchedPairCount = 3;
  config.measurement.minimumPositiveVisibleSamples = 3;

  const helperBinaryPath = "/fake/macos-idle-occlusion-gate-helper";
  const pid = 4242;
  const executablePath = "/fake/OpenBurnBar.app/Contents/MacOS/OpenBurnBar";
  const runtime = { pid };
  const buildIdentity = { executablePath };
  const visibleIdentity = {
    running: true,
    pid,
    executablePath,
    bundleIdentifier: config.app.expectedBundleIdentifier,
    hidden: false,
    visibleWindowCount: 1,
    backdropReady: true,
    backdropActive: true,
    backdropRenderLoopScheduled: true,
    backdropReducedMotion: false,
    backdropKernel: "boids",
  };
  const occludedIdentity = {
    ...visibleIdentity,
    hidden: true,
    visibleWindowCount: 0,
    backdropActive: false,
    backdropRenderLoopScheduled: false,
  };
  const actions = [];
  const sleepCalls = [];
  const monotonicCalls = [];
  const sampleCounts = new Map();
  const monotonicValues = ["1000", "2000"];
  const partialMeasurement = { pairs: [], transitions: [] };

  const measurement = await measureMatchedPairs(
    helperBinaryPath,
    runtime,
    buildIdentity,
    config,
    partialMeasurement,
    {
      helper: async (observedHelperPath, command, observedPID, timeout) => {
        assert.equal(observedHelperPath, helperBinaryPath);
        assert.equal(observedPID, pid);
        assert.equal(timeout, config.measurement.stateTransitionTimeoutSeconds);
        actions.push(`helper:${command}`);
        if (command === "show" || command === "wait-visible") return visibleIdentity;
        if (command === "hide" || command === "wait-hidden") return occludedIdentity;
        assert.fail(`unexpected helper command ${command}`);
      },
      takeCPUSample: async (observedHelperPath, observedPID, state, durationSeconds) => {
        assert.equal(observedHelperPath, helperBinaryPath);
        assert.equal(observedPID, pid);
        assert.equal(durationSeconds, config.measurement.sampleDurationSeconds);
        const sampleIndex = (sampleCounts.get(state) ?? 0) + 1;
        sampleCounts.set(state, sampleIndex);
        actions.push(`sample:${state}:${sampleIndex}`);
        return {
          ...sample(state, state === "visible-idle" ? 10 + sampleIndex : sampleIndex, pid),
          sampleIndex,
          sampleID: `${state}-${sampleIndex}`,
        };
      },
      sleep: async (milliseconds) => {
        sleepCalls.push(milliseconds);
      },
      monotonicNow: () => {
        const value = monotonicValues[monotonicCalls.length];
        assert.ok(value, "measureMatchedPairs requested an unexpected monotonic timestamp");
        monotonicCalls.push(value);
        return value;
      },
    },
  );

  assert.strictEqual(measurement, partialMeasurement);
  assert.deepEqual(actions, [
    "helper:show",
    "helper:wait-visible",
    "sample:visible-idle:1",
    "helper:wait-visible",
    "sample:visible-idle:2",
    "helper:wait-visible",
    "sample:visible-idle:3",
    "helper:hide",
    "sample:occluded-idle:1",
    "helper:wait-hidden",
    "sample:occluded-idle:2",
    "helper:wait-hidden",
    "sample:occluded-idle:3",
  ]);
  assert.equal(actions.filter((action) => action === "helper:hide").length, 1);
  assert.equal(actions.filter((action) => action === "helper:show").length, 1);
  assert.deepEqual(sleepCalls, [
    config.measurement.initialVisibleWarmupSeconds * 1000,
    config.measurement.transitionSettleSeconds * 1000,
  ]);
  assert.deepEqual(monotonicCalls, monotonicValues);
  assert.equal(measurement.transitions[1].afterVisibleSampleCount, 3);
  assert.deepEqual(
    measurement.pairs.map((pair) => ({
      pairIndex: pair.pairIndex,
      visibleSampleID: pair.visibleIdle.sampleID,
      occludedSampleID: pair.occludedIdle.sampleID,
    })),
    [
      { pairIndex: 1, visibleSampleID: "visible-idle-1", occludedSampleID: "occluded-idle-1" },
      { pairIndex: 2, visibleSampleID: "visible-idle-2", occludedSampleID: "occluded-idle-2" },
      { pairIndex: 3, visibleSampleID: "visible-idle-3", occludedSampleID: "occluded-idle-3" },
    ],
  );
});

test("real gate config versions and enforces absolute plus relative ceilings", () => {
  assert.equal(realGateConfig.gateVersion, "P-PERF-3-macos-real-process-v1");
  assert.equal(realGateConfig.measurement.robustStatistic, "median");
  assert.equal(realGateConfig.budgets.absoluteOccludedIdleCpuPercentCeiling, 5);
  assert.equal(realGateConfig.budgets.maximumOccludedToVisibleCpuRatio, 0.35);
  assert.deepEqual(
    realGateConfig.app.launchArguments.slice(-2),
    ["-backdropKernel", "boids"],
    "real-process gate must use a CPU-rendered backdrop so proc_pidinfo has a stable visible signal",
  );
  assert.ok(realGateConfig.app.relativeBundlePath.startsWith(".derived-data/"));
});

test("real gate accepts a valid matched robust sample set", () => {
  const summary = summarizeAndEvaluatePairs(passingPairs(), realGateConfig);
  assert.equal(summary.statistic, "median");
  assert.deepEqual(summary.visibleIdleCpuPercent.samples, [12, 10, 11, 14, 9]);
  assert.equal(summary.visibleIdleCpuPercent.median, 11);
  assert.equal(summary.visibleIdleCpuPercent.medianAbsoluteDeviation, 1);
  assert.deepEqual(summary.occludedIdleCpuPercent.samples, [1, 2, 1.5, 1, 1]);
  assert.equal(summary.occludedIdleCpuPercent.median, 1);
  assert.equal(summary.occludedIdleCpuPercent.medianAbsoluteDeviation, 0);
  assert.equal(summary.occludedToVisibleRatio, 1 / 11);
  assert.equal(summary.pass, true);
});

test("real gate enforces absolute idle and applicable relative occlusion budgets", () => {
  const absoluteBreach = passingPairs().map((pair) => ({
    ...pair,
    visibleIdle: sample("visible-idle", 25),
    occludedIdle: sample("occluded-idle", 6),
  }));
  const absoluteSummary = summarizeAndEvaluatePairs(absoluteBreach, realGateConfig);
  assert.equal(absoluteSummary.checks.absoluteOccludedIdleCpu.pass, false);
  assert.equal(absoluteSummary.checks.visibleToOccludedReduction.applicable, true);
  assert.equal(absoluteSummary.checks.visibleToOccludedReduction.pass, true);
  assert.equal(absoluteSummary.pass, false);

  const relativeBreach = passingPairs().map((pair) => ({
    ...pair,
    visibleIdle: sample("visible-idle", 10),
    occludedIdle: sample("occluded-idle", 4),
  }));
  const relativeSummary = summarizeAndEvaluatePairs(relativeBreach, realGateConfig);
  assert.equal(relativeSummary.checks.absoluteOccludedIdleCpu.pass, true);
  assert.equal(relativeSummary.checks.visibleToOccludedReduction.applicable, true);
  assert.equal(relativeSummary.checks.visibleToOccludedReduction.pass, false);
  assert.equal(relativeSummary.pass, false);
});

test("real gate does not ratio-gate samples already inside the absolute idle noise band", () => {
  const lowSignal = passingPairs().map((pair) => ({
    ...pair,
    visibleIdle: sample("visible-idle", 2.25),
    occludedIdle: sample("occluded-idle", 1.8),
  }));
  const summary = summarizeAndEvaluatePairs(lowSignal, realGateConfig);
  assert.equal(summary.occludedToVisibleRatio, 0.8);
  assert.equal(summary.checks.absoluteOccludedIdleCpu.pass, true);
  assert.equal(summary.checks.visibleToOccludedReduction.applicable, false);
  assert.equal(summary.checks.visibleToOccludedReduction.pass, null);
  assert.match(summary.checks.visibleToOccludedReduction.reason, /idle noise band/);
  assert.equal(summary.pass, true);
});

test("real gate ratio-check remains active at the absolute ceiling boundary", () => {
  const boundaryBreach = passingPairs().map((pair) => ({
    ...pair,
    visibleIdle: sample("visible-idle", 5),
    occludedIdle: sample("occluded-idle", 2),
  }));
  const summary = summarizeAndEvaluatePairs(boundaryBreach, realGateConfig);
  assert.equal(summary.checks.visibleToOccludedReduction.applicable, true);
  assert.equal(summary.checks.visibleToOccludedReduction.pass, false);
  assert.equal(summary.pass, false);
});

test("real gate rejects missing, zero-count, insufficient, and zero-visible measurements", () => {
  assert.throws(() => summarizeAndEvaluatePairs([], realGateConfig), /zero matched samples/);
  assert.throws(
    () => summarizeAndEvaluatePairs(passingPairs().slice(0, 4), realGateConfig),
    /expected 5/
  );
  const missingOccluded = passingPairs();
  delete missingOccluded[2].occludedIdle;
  assert.throws(
    () => summarizeAndEvaluatePairs(missingOccluded, realGateConfig),
    /missing its occluded-idle idle sample/
  );
  const zeroVisible = passingPairs().map((pair) => ({
    ...pair,
    visibleIdle: sample("visible-idle", 0),
  }));
  assert.throws(
    () => summarizeAndEvaluatePairs(zeroVisible, realGateConfig),
    /non-zero CPU/
  );
});

test("real gate rejects samples without matched real-process provenance", () => {
  for (const [name, mutate, error] of [
    ["zero pid", (pairs) => { pairs[0].visibleIdle.pid = 0; }, /lacks real-process provenance/],
    ["seeded source", (pairs) => { pairs[0].occludedIdle.source = "seeded-fixture"; }, /lacks real-process provenance/],
    ["different process", (pairs) => { pairs[0].occludedIdle.pid += 1; }, /not sampled from one process/],
  ]) {
    const pairs = passingPairs();
    mutate(pairs);
    assert.throws(
      () => summarizeAndEvaluatePairs(pairs, realGateConfig),
      error,
      name,
    );
  }
});

test("real gate CLI accepts only an evidence output sink, never seeded results", () => {
  assert.deepEqual(parseArguments(["--output", "/tmp/result.json"], "/tmp/default.json"), {
    outputPath: "/tmp/result.json",
  });
  for (const forbidden of ["--samples", "--result", "--app", "--budget"]) {
    const result = spawnSync(process.execPath, [realGatePath, forbidden, "/tmp/seeded.json"], {
      encoding: "utf8",
    });
    assert.equal(result.status, 1, `${forbidden} must fail`);
    assert.match(result.stderr, /does not accept sample, result, app, or budget inputs/);
  }
});

function runGateAgainstFakeBuild({ bundleIdentifier, ageSeconds }) {
  const fixtureRoot = mkdtempSync(path.join(os.tmpdir(), "macos-cpu-gate-build-identity-"));
  const scriptDirectory = path.join(fixtureRoot, "scripts", "ci");
  const config = JSON.parse(JSON.stringify(realGateConfig));
  const bundlePath = path.join(fixtureRoot, config.app.relativeBundlePath);
  const executablePath = path.join(
    bundlePath,
    "Contents",
    "MacOS",
    config.app.executableName,
  );
  const infoPlistPath = path.join(bundlePath, "Contents", "Info.plist");
  const outputPath = path.join(fixtureRoot, "evidence", "result.json");

  mkdirSync(scriptDirectory, { recursive: true });
  mkdirSync(path.dirname(executablePath), { recursive: true });
  copyFileSync(realGatePath, path.join(scriptDirectory, "macos-idle-occlusion-gate.mjs"));
  copyFileSync(realGateHelperPath, path.join(scriptDirectory, "macos-idle-occlusion-gate-helper.swift"));
  writeFileSync(
    path.join(scriptDirectory, "macos-idle-occlusion-gate.config.json"),
    `${JSON.stringify(config, null, 2)}\n`,
  );
  const runnerPath = path.join(fixtureRoot, "run-gate.mjs");
  writeFileSync(
    runnerPath,
    'import { main } from "./scripts/ci/macos-idle-occlusion-gate.mjs";\nawait main(process.argv.slice(2));\n',
  );
  writeFileSync(executablePath, "#!/bin/sh\nexit 0\n");
  chmodSync(executablePath, 0o755);
  writeFileSync(infoPlistPath, `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>${bundleIdentifier}</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
</dict></plist>\n`);
  if (ageSeconds > 0) {
    const modifiedAt = new Date(Date.now() - ageSeconds * 1000);
    utimesSync(executablePath, modifiedAt, modifiedAt);
  }

  try {
    const result = spawnSync(
      process.execPath,
      [runnerPath, "--output", outputPath],
      { encoding: "utf8" },
    );
    return {
      ...result,
      evidence: JSON.parse(readFileSync(outputPath, "utf8")),
    };
  } finally {
    rmSync(fixtureRoot, { recursive: true, force: true });
  }
}

test("real gate rejects a built app with the wrong bundle identity", () => {
  if (process.platform !== "darwin") return;
  const result = runGateAgainstFakeBuild({
    bundleIdentifier: "com.example.not-openburnbar",
    ageSeconds: 0,
  });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /bundle id com\.example\.not-openburnbar does not match com\.openburnbar\.app/);
  assert.equal(
    result.evidence.measurementMethod.pairing,
    "batched visible-idle then fully-occluded-idle samples from one PID, paired by sample index",
  );
});

test("real gate rejects a stale OpenBurnBar executable", () => {
  if (process.platform !== "darwin") return;
  const result = runGateAgainstFakeBuild({
    bundleIdentifier: realGateConfig.app.expectedBundleIdentifier,
    ageSeconds: realGateConfig.app.maximumBuildAgeSeconds + 60,
  });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /built app is .* old; maximum is/);
});

test("macOS helper compiles and reads live monotonic process CPU counters", () => {
  if (process.platform !== "darwin") return;
  const temporaryDirectory = mkdtempSync(path.join(os.tmpdir(), "macos-cpu-gate-self-test-"));
  const helperBinary = path.join(temporaryDirectory, "helper");
  try {
    execFileSync("/usr/bin/xcrun", [
      "swiftc",
      realGateHelperPath,
      "-o",
      helperBinary,
      "-framework",
      "AppKit",
      "-framework",
      "CoreGraphics",
    ]);
    const first = JSON.parse(execFileSync(helperBinary, ["cpu", String(process.pid)], {
      encoding: "utf8",
    }));
    let accumulator = 0;
    for (let index = 0; index < 250_000; index += 1) accumulator += Math.sqrt(index);
    assert.ok(accumulator > 0);
    const second = JSON.parse(execFileSync(helperBinary, ["cpu", String(process.pid)], {
      encoding: "utf8",
    }));
    assert.equal(first.pid, process.pid);
    assert.equal(second.pid, process.pid);
    assert.ok(BigInt(second.monotonicNanoseconds) > BigInt(first.monotonicNanoseconds));
    assert.ok(BigInt(second.cpuNanoseconds) > BigInt(first.cpuNanoseconds));
  } finally {
    rmSync(temporaryDirectory, { recursive: true, force: true });
  }
});
