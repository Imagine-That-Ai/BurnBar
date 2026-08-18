#!/usr/bin/env node
/**
 * Kernel shader-compile gate (inspection tool).
 *
 * Loads `/?kernel=<id>` for EVERY backdrop kernel in a real browser, captures
 * every console error and page error while the kernel mounts (lazy chunk → GL
 * program compile/link → first frames), and verifies the kernel that resolved
 * is the kernel that was requested (no silent 2D fallback).
 *
 * Exits non-zero listing any kernel that errored or failed to resolve.
 *
 * Usage:
 *   1. `npm run dev` (or serve the static export).
 *   2. NODE_PATH=<path-with-playwright> node scripts/kernel-shader-gate.mjs \
 *        --base http://localhost:3000 [--headed]
 */

import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import { createRequire } from "node:module";

const __dirname = dirname(fileURLToPath(import.meta.url));

// Kernel ids are parsed out of the KernelId union so this gate can never drift
// from the registry (legibility-check.mjs hardcodes and has already drifted).
async function kernelIds() {
  const src = await readFile(resolve(__dirname, "../lib/gl/engine/types.ts"), "utf8");
  const union = src.match(/export type KernelId =([\s\S]*?);/);
  if (!union) throw new Error("KernelId union not found in types.ts");
  return [...union[1].matchAll(/"([^"]+)"/g)].map((m) => m[1]);
}

function arg(flag, fallback) {
  const i = process.argv.indexOf(flag);
  return i >= 0 && process.argv[i + 1] ? process.argv[i + 1] : fallback;
}
const BASE = arg("--base", "http://localhost:3000").replace(/\/$/, "");
const HEADED = process.argv.includes("--headed");

async function loadPlaywright() {
  try {
    return await import("playwright");
  } catch {
    // ESM ignores NODE_PATH — resolve via require against its entries.
    for (const dir of (process.env.NODE_PATH ?? "").split(":").filter(Boolean)) {
      try {
        return createRequire(resolve(dir, "x.js"))("playwright");
      } catch {
        /* try the next NODE_PATH entry */
      }
    }
    console.error("[kernel-shader-gate] Playwright is not installed (NODE_PATH?)");
    process.exit(2);
  }
}

async function main() {
  const ids = await kernelIds();
  const { chromium } = await loadPlaywright();
  const browser = await chromium.launch({ channel: "chrome", headless: !HEADED });

  const failures = [];
  for (const id of ids) {
    // A fresh page per kernel: no cross-kernel GL-context accumulation, so a
    // failure here is the kernel's own — never a leak from the previous one.
    const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });
    const errors = [];
    page.on("console", (msg) => {
      if (msg.type() === "error") errors.push(msg.text());
    });
    page.on("pageerror", (err) => errors.push(`pageerror: ${String(err)}`));

    try {
      await page.goto(`${BASE}/?kernel=${id}`, { waitUntil: "networkidle" });
      // The ink layer publishes the kernel actually rendered (post-fallback).
      await page.waitForFunction(() => Boolean(document.body.dataset.kernel), null, {
        timeout: 10000,
      });
      // Let the lazy chunk resolve, shaders compile, and a few frames paint.
      await page.waitForTimeout(1500);

      const resolved = await page.evaluate(() => document.body.dataset.kernel ?? null);
      const lost = await page.evaluate(() => {
        const cv = document.querySelector(".ink-backdrop canvas");
        const gl = cv?.getContext("webgl2");
        return gl ? gl.isContextLost() : false;
      });
      const backdropErrors = errors.filter((e) => !e.includes("favicon"));
      if (resolved !== id) {
        failures.push({ id, why: `resolved to "${resolved}" instead` });
        console.log(`FAIL  ${id.padEnd(20)} resolved=${resolved}`);
      } else if (lost) {
        failures.push({ id, why: "webgl context lost" });
        console.log(`FAIL  ${id.padEnd(20)} context lost`);
      } else if (backdropErrors.length) {
        failures.push({ id, why: backdropErrors.join(" | ") });
        console.log(`FAIL  ${id.padEnd(20)} ${backdropErrors[0]}`);
      } else {
        console.log(`PASS  ${id.padEnd(20)} resolved=${resolved}`);
      }
    } catch (err) {
      failures.push({ id, why: String(err) });
      console.log(`ERROR ${id.padEnd(20)} ${String(err)}`);
    } finally {
      await page.close();
    }
  }

  await browser.close();
  console.log(`\n${ids.length - failures.length}/${ids.length} kernels clean.`);
  if (failures.length) {
    console.error("\nFailures:");
    for (const f of failures) console.error(`  ${f.id}: ${f.why}`);
    process.exit(1);
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
