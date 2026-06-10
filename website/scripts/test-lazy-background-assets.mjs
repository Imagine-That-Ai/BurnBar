#!/usr/bin/env node
/**
 * test-lazy-background-assets.mjs — the bgDots/bgFx logo payloads must stay
 * lazy.
 *
 * dotConstellation.ts and easterEggFx.ts together reference ~1.1 MB of
 * provider logos + crests (32 unique files). Eagerly fetched, that cost
 * landed on every page load — including dark-theme visits where the dot
 * constellation never paints, and despite the easter-egg FX idling until a
 * 5-reversal scroll jiggle. Both scripts now defer loading:
 *   - dotConstellation: loads at parse time only when data-theme="light"
 *     (identical timing to the old eager path for light visitors), otherwise
 *     on the per-frame theme check after a dark→light toggle.
 *   - easterEggFx: loads on the first scroll-direction event in onDir(),
 *     well before the 5-reversals-in-1.5s summon threshold.
 *
 * Each script is executed in a stubbed DOM (mirroring the harness in
 * test-reduced-motion.mjs) with fetch/Image instrumented, and we assert no
 * asset request escapes before its trigger — and that all of them fire after.
 *
 * Run via: `node scripts/test-lazy-background-assets.mjs`.
 */

import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import vm from "node:vm";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const SCRIPTS = path.join(path.resolve(__dirname, ".."), "src", "scripts");

const constellationSource = await readFile(path.join(SCRIPTS, "dotConstellation.ts"), "utf8");
const fxSource = await readFile(path.join(SCRIPTS, "easterEggFx.ts"), "utf8");

// The rosters: 32 unique assets; the two crest SVGs appear in both fx lists.
const DOT_ASSETS = 32;
const FX_ASSETS = 34;

function makeCtx() {
  return {
    fillStyle: "",
    font: "",
    textAlign: "",
    textBaseline: "",
    globalAlpha: 1,
    lineWidth: 1,
    strokeStyle: "",
    setTransform() {},
    clearRect() {},
    beginPath() {},
    closePath() {},
    arc() {},
    rect() {},
    fill() {},
    stroke() {},
    fillRect() {},
    fillText() {},
    drawImage() {},
    save() {},
    restore() {},
    translate() {},
    rotate() {},
    scale() {},
    createRadialGradient: () => ({ addColorStop() {} }),
    createLinearGradient: () => ({ addColorStop() {} }),
    getImageData: () => ({ data: new Uint8ClampedArray(400 * 400 * 4) })
  };
}

function makeHarness({ source, canvasId, theme }) {
  const requests = []; // every fetch() or Image src assignment, in order
  const rafs = []; // captured but never auto-invoked, so loops can't spin
  const listeners = {};
  const attrs = { "data-theme": theme };

  const windowStub = {
    innerWidth: 1280,
    innerHeight: 800,
    devicePixelRatio: 1,
    scrollY: 0,
    matchMedia: () => ({ matches: false }),
    addEventListener(type, fn) {
      (listeners[type] ??= []).push(fn);
    }
  };
  const documentStub = {
    documentElement: {
      getAttribute: (name) => attrs[name] ?? null,
      scrollHeight: 4000
    },
    getElementById: (id) => (id === canvasId ? { getContext: () => makeCtx() } : null),
    createElement: () => ({ getContext: () => makeCtx() }),
    querySelectorAll: () => []
  };

  vm.runInNewContext(source, {
    window: windowStub,
    document: documentStub,
    requestAnimationFrame(cb) {
      rafs.push(cb);
      return rafs.length;
    },
    setTimeout: () => 1,
    clearTimeout() {},
    MutationObserver: class {
      observe() {}
    },
    fetch(url) {
      requests.push(url);
      return new Promise(() => {}); // never settles — count the request only
    },
    Image: class {
      set src(url) {
        requests.push(url);
      }
      get src() {
        return "";
      }
    },
    URL: { createObjectURL: () => "blob:stub", revokeObjectURL() {} },
    Blob: class {},
    performance: { now: () => 1000 }
  });

  return { requests, rafs, listeners, attrs, windowStub };
}

// ──────────── 1. dotConstellation: dark visits fetch nothing ────────────

{
  const run = makeHarness({ source: constellationSource, canvasId: "bgDots", theme: "dark" });
  assert.equal(run.requests.length, 0, "dark parse: no logo requests");
  assert.ok(run.rafs.length >= 1, "draw loop scheduled");

  // A painted dark frame must not load either — only the theme flip may.
  run.rafs[0](1000);
  assert.equal(run.requests.length, 0, "dark frame: still no logo requests");

  run.attrs["data-theme"] = "light";
  run.rafs[run.rafs.length - 1](1100);
  assert.equal(run.requests.length, DOT_ASSETS, "light frame: all logos requested");
}

// ──────────── 2. dotConstellation: light visits keep eager timing ────────

{
  const run = makeHarness({ source: constellationSource, canvasId: "bgDots", theme: "light" });
  assert.equal(run.requests.length, DOT_ASSETS, "light parse: logos requested immediately");
}

// ──────────── 3. easterEggFx: idle until the first scroll direction ──────

{
  const run = makeHarness({ source: fxSource, canvasId: "bgFx", theme: "dark" });
  assert.equal(run.requests.length, 0, "parse: no logo/crest requests");
  assert.equal(run.rafs.length, 0, "parse: FX loop idle");
  assert.ok(run.listeners.scroll?.length, "scroll trigger wired");

  run.windowStub.scrollY = 140; // first direction event (|d| > 2)
  run.listeners.scroll[0]();
  assert.equal(run.requests.length, FX_ASSETS, "first scroll: all logos + crests requested");
  assert.equal(run.rafs.length, 0, "first scroll: still idle — one event cannot summon");

  run.windowStub.scrollY = 280; // same direction — no double-load
  run.listeners.scroll[0]();
  assert.equal(run.requests.length, FX_ASSETS, "repeat scroll: assets requested exactly once");
}

console.log(
  `lazy-background-assets: bgDots defers ${DOT_ASSETS} and bgFx defers ${FX_ASSETS} asset requests until needed`
);
