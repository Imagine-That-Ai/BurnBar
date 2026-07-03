#!/usr/bin/env node
/**
 * Objective per-kernel legibility gate (inspection tool).
 *
 * For each of the 31 backdrop kernels it loads `/?kernel=<id>`, waits for the
 * fonts + the kinetic headline to settle + ~1.2s of backdrop animation, then —
 * IN PAGE — composites the painted kernel canvases + the hero-band scrim under
 * the <h1> box and computes the WORST WCAG contrast of `--ink-fg` against any
 * sampled background pixel. A kernel passes when worstContrast >= 4.5 (AA body).
 *
 * Because the per-glyph `--ink-halo` adds local contrast this flat sample can't
 * credit, passing here is a STRICT LOWER BOUND — real legibility is better.
 *
 * Usage:
 *   1. Serve the static export (or `next dev`): e.g. `npx serve out -l 4321`.
 *   2. node scripts/legibility-check.mjs --base http://localhost:4321
 *
 * Requires Playwright (an optional dev tool, not a build dependency):
 *   npm i -D playwright && npx playwright install chromium
 *
 * Exits non-zero and lists any kernel whose worstContrast < 4.5. Screenshots
 * are written to apps/console/.inspect/<id>.png.
 */

import { mkdir } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));
const OUT_DIR = resolve(__dirname, "..", ".inspect");

// Append-only — verbatim from lib/gl/engine/types.ts KernelId / KERNEL_INK keys.
const KERNEL_IDS = [
  "constellation", "flow", "aurora", "mesh", "moire", "volumetric", "lic",
  "fluid-aurora", "cloudfield", "plasma-orbs", "blobs-mesh", "retro-plasma",
  "inversion-lattice", "vogel-bloom", "crystal-drift", "ripple-lattice",
  "liquid-lumen", "spectral-drift", "mycelium-mesh", "oilfield",
  "suminagashi-drift", "kinetic-stipple", "neural-bloom", "agent1",
  "aether-lattice", "bat-signal", "storm-signal", "origami", "ink-diffusion",
  "petroleum-sheen", "boids",
];

const AA = 4.5;

function arg(flag, fallback) {
  const i = process.argv.indexOf(flag);
  return i >= 0 && process.argv[i + 1] ? process.argv[i + 1] : fallback;
}
const BASE = arg("--base", "http://localhost:4321").replace(/\/$/, "");

async function loadPlaywright() {
  try {
    return await import("playwright");
  } catch {
    console.error(
      "[legibility-check] Playwright is not installed.\n" +
        "  npm i -D playwright && npx playwright install chromium",
    );
    process.exit(2);
  }
}

// Runs in the browser: composite kernel canvases + hero scrim under the <h1>
// box and return the worst contrast of --ink-fg vs any sampled bg pixel.
function measureInPage() {
  const srgb = (c) => {
    c /= 255;
    return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
  };
  const relLum = (r, g, b) => 0.2126 * srgb(r) + 0.7152 * srgb(g) + 0.0722 * srgb(b);

  const fg = getComputedStyle(document.body).getPropertyValue("--ink-fg").trim() || "#F4F6FF";
  const m = fg.replace("#", "").match(/.{2}/g).map((h) => parseInt(h, 16));
  const Lfg = relLum(m[0], m[1], m[2]);

  const h1 = document.querySelector("h1");
  if (!h1) return { kernel: document.body.dataset.kernel || null, worstContrast: Infinity, note: "no-h1" };
  const box = h1.getBoundingClientRect();

  const off = document.createElement("canvas");
  off.width = Math.max(1, Math.ceil(box.width));
  off.height = Math.max(1, Math.ceil(box.height));
  const ctx = off.getContext("2d");

  // Snapshot every kernel canvas the engine painted (the .ink-backdrop host).
  document.querySelectorAll(".ink-backdrop canvas").forEach((cv) => {
    try {
      ctx.drawImage(cv, box.left, box.top, box.width, box.height, 0, 0, off.width, off.height);
    } catch {
      /* tainted/empty — skip */
    }
  });

  // Composite the worst-case (hero-band) scrim over the sampled region.
  const a =
    parseFloat(getComputedStyle(document.body).getPropertyValue("--ink-scrim-hero")) || 0.32;
  ctx.fillStyle = `rgba(6,7,14,${a})`;
  ctx.fillRect(0, 0, off.width, off.height);

  const { data } = ctx.getImageData(0, 0, off.width, off.height);
  let worst = Infinity;
  for (let i = 0; i < data.length; i += 16) {
    const Lbg = relLum(data[i], data[i + 1], data[i + 2]);
    const hi = Math.max(Lfg, Lbg);
    const lo = Math.min(Lfg, Lbg);
    const ratio = (hi + 0.05) / (lo + 0.05);
    if (ratio < worst) worst = ratio;
  }
  return { kernel: document.body.dataset.kernel || null, worstContrast: worst };
}

async function main() {
  const { chromium } = await loadPlaywright();
  await mkdir(OUT_DIR, { recursive: true });

  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });

  const failures = [];
  const results = [];

  for (const id of KERNEL_IDS) {
    try {
      await page.goto(`${BASE}/?kernel=${id}`, { waitUntil: "networkidle" });
      await page.waitForFunction(() => Boolean(document.body.dataset.kernel), null, {
        timeout: 8000,
      });
      await page.evaluate(() => document.fonts?.ready ?? Promise.resolve());
      // Headline played out of the "armed" state + backdrop animated a beat.
      await page
        .waitForFunction(
          () => {
            const h = document.querySelector("h1[data-kinetic]");
            return !h || h.getAttribute("data-kinetic") !== "armed";
          },
          null,
          { timeout: 5000 },
        )
        .catch(() => {});
      await page.waitForTimeout(1200);

      const result = await page.evaluate(measureInPage);
      results.push({ id, ...result });
      await page.screenshot({ path: resolve(OUT_DIR, `${id}.png`) });

      const ok = result.worstContrast >= AA;
      if (!ok) failures.push(result);
      const c = Number.isFinite(result.worstContrast) ? result.worstContrast.toFixed(2) : "n/a";
      console.log(`${ok ? "PASS" : "FAIL"}  ${id.padEnd(20)} worstContrast=${c}`);
    } catch (err) {
      failures.push({ id, error: String(err) });
      console.log(`ERROR ${id.padEnd(20)} ${String(err)}`);
    }
  }

  await browser.close();

  console.log(`\n${results.length - failures.length}/${KERNEL_IDS.length} kernels passed AA (>= ${AA}).`);
  if (failures.length) {
    console.error("Failing kernels:", failures.map((f) => f.kernel || f.id).join(", "));
    process.exit(1);
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
